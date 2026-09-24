---
title: "Tests de aceptación de frontend sobre la imagen ya construida"
description: "Playwright contra la imagen Docker del frontend ya empaquetada y el mecanismo api-lite como backend, para verificar el artefacto que se despliega en vez del código fuente."
date: 2026-09-24
tags:
  - frontend
  - testing
  - docker
  - playwright
maturity: adopt
---

## Problema

Un frontend construido con Vite y servido como estático (nginx) no se despliega como código fuente: se despliega como imagen Docker. Una suite de Playwright que arranca contra `vite dev` o contra un build en el propio runner de CI no ejercita nada de lo que hay entre ese código y el artefacto real — el `Dockerfile`, si nginx sirve las rutas de la SPA correctamente, si el entrypoint que inyecta la configuración en tiempo de arranque (ver el patrón de runtime env config) realmente deja la app apuntando a la API correcta. Todo eso puede pasar los tests unitarios y de componente y romperse solo en la imagen empaquetada.

El problema se agrava cuando el pipeline de CI está pensado como "1 build, many deploys": la imagen se construye una sola vez, se escanea, y esa misma imagen se promociona a cada entorno reconfigurando solo variables de entorno en tiempo de arranque, sin volver a compilar. Si los tests de Playwright corren contra un build distinto al que de verdad se sube al registry y se despliega, esa promesa es falsa en la práctica: lo que se probó y lo que se shipea son dos artefactos distintos que, la mayoría de las veces, coinciden — pero nada lo garantiza.

El segundo problema, independiente del primero, es contra qué backend correr estos tests. Levantar el backend real completo (Postgres, colas, un proveedor OIDC real, servicios externos) para tests de UI es lento y no determinista — el mismo problema que resuelve el mecanismo de api-lite: un segundo host de la misma API con toda la infraestructura sustituida por implementaciones en memoria, arranque instantáneo y estado descartable entre ejecuciones.

Aparece en cualquier frontend (SPA o similar) que se empaqueta como imagen y se promociona sin reconstruir entre entornos, en cuanto quieres una señal de "este artefacto concreto funciona" antes de publicarlo — no solo "este código pasa sus tests".

## Solución

Un proyecto de tests de Playwright separado de los tests unitarios/de componente, que recibe la imagen del frontend ya construida y la API Lite ya construida por variable de entorno, las levanta juntas en un `docker-compose` propio y minimalista, y las estimula solo a través del navegador y de la API pública — nunca importando código fuente ni tipos internos de la aplicación.

1. **Compose propio y mínimo, separado del stack de desarrollo completo.** Un `docker-compose.lite.yml` con solo tres servicios: el frontend, `api-lite` y un proveedor OIDC de mentira (`fake-oidc`) — sin Postgres, sin almacenamiento de objetos, sin colas. Ambas imágenes (frontend y api-lite) se reciben por variable de entorno (`APP_IMAGE`, `API_LITE_IMAGE`), nunca se construyen dentro de este compose:

```yaml
app:
  image: ${APP_IMAGE:-el-baul-app:local}
  environment:
    VITE_API_URL: "http://localhost:${API_LITE_PORT:-5051}"
    VITE_OIDC_AUTHORITY: "http://localhost:${FAKE_OIDC_PORT:-5000}"
    VITE_OIDC_CLIENT_ID: "el-baul-app"
    VITE_OIDC_CALLBACK_URI: "http://localhost:${APP_PORT:-3000}/callback"
  ports:
    - "${APP_PORT:-3000}:80"
```

2. **La configuración de estos tests entra por las mismas variables de entorno que usaría cualquier despliegue real**, nunca reconstruyendo la imagen. Esto es lo que conecta el mecanismo de "1 build, many deploys" con la garantía de que la imagen probada es la que se shipea: la misma imagen que se acaba de construir, escanear y que se va a subir al registry se redirige a este stack de acceptance tests solo con variables de entorno leídas en tiempo de arranque (`window.__ENV__`, ver el patrón de runtime env config) — nunca con un `--build-arg` ni un rebuild condicional. Si el entrypoint que genera esa configuración en tiempo de arranque estuviera roto, se rompería aquí, con el mismo artefacto que llegaría a producción.

3. **`globalSetup` de Playwright levanta el compose sin `--build`** y espera activamente a que los servicios respondan por HTTP — nunca un `sleep` fijo:

```ts
// No --build: api-lite/app son imágenes suministradas desde fuera (APP_IMAGE/API_LITE_IMAGE)
// — esta suite verifica el artefacto, no un rebuild suyo.
execSync(`docker compose -f ${COMPOSE_FILE} up -d`, { cwd: REPO_ROOT, stdio: 'inherit' });

await waitForOk('http://localhost:5051/health', 120_000);
await waitForOk('http://localhost:3000', 120_000);
await waitForOk('http://localhost:5000/.well-known/jwks.json', 120_000);
```

4. **Estimula la app solo por el navegador, con queries de accesibilidad, no de implementación.** `getByRole`, `getByText`, nunca un `data-testid` acoplado a un nombre de componente interno ni, mucho menos, nada que dependa de cómo React organiza el árbol de componentes. Esto es lo que hace que estos tests sean independientes del framework y de la arquitectura interna de la app: sobreviven a una reescritura completa de un componente, a cambiar de React a otra cosa, o a una reorganización de carpetas, porque solo conocen el DOM final y su semántica de accesibilidad — igual que un usuario real:

```ts
await page.goto('/');
await page.getByRole('button', { name: 'Continuar con Google' }).click();
await page.waitForURL('**/authorize**', { timeout: 15_000 });
await page.getByRole('button', { name: 'Admin User' }).click();
```

5. **Siembra estado a través de la API real (api-lite), nunca mockeando `fetch` ni tocando el store de la app.** Se extrae un token de acceso real de `localStorage` tras el login y se usa para llamar a la API pública igual que lo haría cualquier cliente:

```ts
const accessToken = await page.evaluate(() => {
  const raw = localStorage.getItem('oidc.user:http://localhost:5000:el-baul-app');
  return raw ? JSON.parse(raw).access_token : null;
});

const response = await page.request.post(`${API_BASE_URL}/api/baules`, {
  headers: { Authorization: `Bearer ${accessToken}` },
  data: { name: baulName, description: null },
});
```

6. **Engánchalo en CI justo después de construir y escanear la imagen, antes de publicarla.** El job construye la imagen del frontend, la escanea, construye (o reutiliza en caché) `api-lite`, corre esta suite contra ambas, y solo si pasa continúa con el push al registry y el despliegue. Un fallo aquí bloquea la publicación, no solo el merge.

Se sabe que quedó bien aplicado cuando la imagen que se estimula en estos tests es exactamente la misma que se sube al registry (misma capa, ninguna variable de build distinta), cuando la suite entera arranca en segundos porque no hay infraestructura real detrás de la API, y cuando ningún test conoce el nombre de un componente, un hook o una estructura de carpetas de la app — solo botones, textos y roles visibles en el DOM.

### Gotchas

- **Esperar solo el healthcheck del backend no basta si depende de un tercero.** `api-lite` valida JWT contra `fake-oidc`; si `docker compose` solo garantiza que el contenedor de `fake-oidc` arrancó (`depends_on: service_started`), puede que su servidor HTTP aún no acepte conexiones cuando llega la primera petición autenticada. Hay que esperar explícitamente también al endpoint del proveedor de identidad (`/.well-known/jwks.json`), no solo al `/health` de la propia app.
- **El rate limiting pensado para tráfico real es demasiado agresivo para una suite de tests.** Cada `page.goto()` en un test es una recarga completa, y cada una vuelve a pedir configuración pública; varios specs seguidos superan de sobra un límite pensado para una IP real. La solución no es limitar los tests, es subir el límite en la configuración de este stack concreto — no se está probando el rate limiting aquí.
- **El destino tras el login no es un único sitio fijo si el estado se reutiliza entre tests.** Como `api-lite` mantiene su estado en memoria durante toda la ejecución de la suite, una misma identidad puede aterrizar en onboarding, en "crear baúl" o directamente dentro de un baúl ya existente según lo que hayan dejado tests anteriores. Un `waitForURL` con una única ruta fija es frágil; hace falta un predicado que acepte los varios destinos válidos.
- **Nombres únicos por test, siempre.** Como el estado no se resetea entre specs de la misma ejecución, un nombre fijo (un baúl, una persona) acaba colisionando con uno dejado por un test anterior y rompe locators en modo estricto ("resolved to N elements"). Usar un sufijo derivado de tiempo o UUID en cualquier entidad que cree un test.
- **Nada de `VITE_*` como build args en la imagen que se prueba.** Si el pipeline pasara configuración en tiempo de build para estos tests, dejaría de probar el mecanismo real de runtime config — y de paso, la imagen probada ya no sería bit a bit la misma que se despliega en producción.

## Variantes

- **Un stack de extremo a extremo completo, con infraestructura real, aparte de esta suite**: para verificar el cableado del sistema completo (login contra un proveedor real, persistencia real) en vez de comportamiento de UI, tiene sentido mantener una suite adicional de Playwright contra el `docker-compose` de desarrollo completo (Postgres, almacenamiento de objetos, colas). Esa suite cubre wiring de infraestructura, no debe duplicar los mismos recorridos de negocio que ya cubre la suite contra api-lite, y puede correr con menos frecuencia (por ejemplo nightly) porque es más cara de levantar.

## Ejemplos

- **[El Baúl](https://github.com/ne2-studio/el-baul)**: `app/acceptance-tests/` (frontend consumidor) y `admin/acceptance-tests/` (panel de administración), ambas contra `docker-compose.lite.yml` y `el-baul-api-lite`, gateando `frontend-cicd.yml`/`admin-cicd.yml` justo antes de publicar la imagen. `/e2e-tests/` en la raíz del repo es la variante de stack completo, con infraestructura real, corriendo nightly.
