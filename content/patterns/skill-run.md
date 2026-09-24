---
title: "Skill Run"
description: "Hacer reproducible para un agente la ejecución local de una aplicación."
date: 2026-09-24
tags:
  - agentes
  - devex
maturity: trial
---

## Problema

Cuando pido a Claude que levante un proyecto en local, suele liarse: no sabe qué variables de entorno necesita, en qué orden arrancar los servicios, o qué comando exacto usar. Cada vez que lo hace, redescubre el mismo proceso a base de prueba y error, y encima con proyectos con frontend + backend + infra, "levantar el proyecto" no es una sola cosa: a veces solo hace falta el frontend contra un backend de mentira para tocar UI, a veces hace falta el backend real con Postgres para depurar persistencia, a veces hace falta todo tal cual se despliega. Sin un contrato claro, el agente tiende a levantar de más (todo el stack cuando solo hacía falta el frontend) o de menos (arranca el backend a pelo, sin las variables de entorno correctas, y luego no sabe por qué falla la autenticación).

## Contexto

Aparece en proyectos donde levantar el entorno local no es un único comando obvio: hay varios pasos, dependencias externas (Postgres, un proveedor OIDC, almacenamiento tipo MinIO, colas), o configuración que no está documentada en ningún sitio salvo en mi cabeza. Se vuelve crítico en cuanto un agente necesita el entorno vivo para algo más que "arrancar": inspeccionar, hacer una captura de pantalla, ejercitar la API a mano, o reproducir un bug con un usuario concreto.

## Solución

Separar dos cosas:

1. Un script determinista (`scripts/run-env` en los repos donde está adoptado) que levanta el proyecto siempre de la misma forma, sin ambigüedad, y que sabe reconciliar su propio estado anterior en vez de acumular procesos huérfanos.
2. Una skill de Claude Code (`.claude/skills/run/SKILL.md`) que explica al agente cuándo usar cada modo del script, qué hacer si algo falla, y qué NO hacer (no levantar servicios a mano, no tocar procesos ajenos, no mezclar esto con la estrategia de verificación, que es responsabilidad de otra skill).

El script es la fuente de verdad del "cómo". La skill es la fuente de verdad del "cuándo" y del contexto que el script no puede expresar por sí solo — qué modo elegir según la tarea, cómo autenticarse, dónde mirar si algo no arranca.

Este reparto no es un capricho de diseño: [`ne2-factory`](https://github.com/ne2-studio/ne2-factory) (el "agentic software factory" que opera sobre un backlog de GitHub Issues) lo ha convertido en un contrato explícito entre el orquestador de agentes y cualquier repo que quiera trabajar con él. Su [`docs/environment-contract.md`](https://github.com/ne2-studio/ne2-factory/blob/main/docs/environment-contract.md) define `run` como una **capability** obligatoria — sin ella, "el repo no puede ser conducido por la factory" — con una interfaz fija (entrada: petición de entorno vivo, opcionalmente acotada a una superficie; salida: entorno corriendo + resumen con URL primaria, cómo autenticarse como un usuario de prueba, logs, cómo limpiar) y unas garantías explícitas: reproducible, deja la superficie realmente usable (no solo un puerto abierto), no toca procesos que no sean del proyecto, y nunca cae en "arráncalo tú a mano" como salida de emergencia. El "cómo" interno (comandos, puertos, nombres de servicio) es cosa del proyecto y la factory nunca lo nombra — exactamente la misma separación cómo/cuándo, pero llevada a nivel de spec entre sistemas en lugar de entre archivos de un mismo repo.

## Implementación

El patrón madura en tres pasos observables en el histórico real de los repos que lo adoptan:

1. **Un script mínimo por modo.** En [CashClarity](https://github.com/ne2-studio/cashclarity) (el primer repo en tenerlo) `run-env` ya distingue tres modos — `frontend-dev`, `backend-dev`, `full-stack` — cada uno con su propia combinación de Docker/proceso local, y valida antes de arrancar que los puertos que necesita estén libres o sean suyos de una ejecución anterior (`require_port_free_unless_owned`), esperando salud real (`wait_http`, `wait_postgres`) en vez de asumir que un puerto abierto significa "listo".
2. **Reconciliación de estado.** Cambiar de modo no dice "arranca esto encima", dice "deja el repo en este estado exacto": `reconcile_frontend_dev`, `reconcile_backend_dev`, etc. paran lo que sobra del modo anterior (proceso de `dotnet` con PID guardado en `.run/`, contenedor de Postgres) antes de levantar lo nuevo. Sin esto, un agente que va de `backend-dev` a `frontend-dev` deja un `dotnet run` zombi ocupando el puerto 5050 y el siguiente intento falla con un error de puerto que no explica nada.
3. **Aislamiento por worktree.** El salto real de complejidad llegó cuando dos worktrees del mismo repo (uno para el agente, otro para revisión humana en paralelo) intentaban levantar el mismo modo a la vez y colisionaban en los mismos puertos fijos y el mismo nombre de proyecto de Docker Compose. El fix, primero en [El Baúl](https://github.com/ne2-studio/el-baul) y días después en un tercer repo (propietario, sin enlace público), es un offset determinista: un hash corto (`sha1sum` del path absoluto del worktree) se convierte en un desplazamiento de puerto y en un sufijo para el nombre del proyecto Compose y las imágenes construidas. El checkout principal detecta que su `git-dir` y su `git-common-dir` coinciden y mantiene los puertos fijos de siempre — así CI y `docker compose up` a pelo no se enteran del cambio — pero cualquier worktree enlazado obtiene sus propios puertos, contenedores y volúmenes sin pisar a nadie. Una colisión de hash residual no se trata como caso especial: simplemente sale como el mismo error de "puerto ocupado" de cualquier otro conflicto.

Ejemplo simplificado de esa derivación de puertos (real, de [El Baúl](https://github.com/ne2-studio/el-baul/blob/main/scripts/run-env)):

```bash
compute_worktree_context() {
  WORKTREE_OFFSET=0
  WORKTREE_SUFFIX=""
  git_dir="$(git -C "$ROOT_DIR" rev-parse --git-dir)"
  git_common_dir="$(git -C "$ROOT_DIR" rev-parse --git-common-dir)"
  [[ "$git_dir" == "$git_common_dir" ]] && return 0   # checkout principal: nada cambia

  hash_hex="$(printf '%s' "$toplevel" | sha1sum | cut -c1-10)"
  WORKTREE_OFFSET=$(( (16#$hash_hex % 5000 + 1) * 10 ))
  WORKTREE_SUFFIX="$(printf '%s' "$toplevel" | sha1sum | cut -c1-8)"
}
```

La skill (`.claude/skills/run/SKILL.md`), consistente en los distintos repos donde está adoptada, fuerza al agente a:

- Elegir el modo más estrecho para la tarea (no levantar `full-stack` para tocar un botón del frontend).
- Usar siempre el helper, nunca reconstruir el arranque a mano ni "trabajar alrededor" de un fallo del script.
- Copiar literalmente el resumen final que imprime el script (modo, URLs, cómo autenticarse, logs, cómo limpiar) en vez de inventar una URL o un puerto de memoria — importante en cuanto los puertos dejan de ser fijos por el aislamiento de worktree.
- Usar la identidad de prueba que ofrece el propio entorno (un proveedor `fake-oidc` con usuarios conocidos) en vez de inventarse credenciales.
- No mezclar esta skill con la de verificación: `run` decide *qué hay corriendo*, `verify` decide *qué evidencia hace falta* — mezclarlas hace que la skill crezca sin control y que el agente no sepa cuál consultar para qué.

## Ejemplos

- **[CashClarity](https://github.com/ne2-studio/cashclarity)**: primer repo con el patrón. Tres modos, sin aislamiento por worktree — puertos fijos porque en el momento de escribirlo no había necesidad de correr dos instancias a la vez.
- **[El Baúl](https://github.com/ne2-studio/el-baul)**: mismo patrón, más superficie real (MinIO, imgproxy, Mailpit, `fake-oidc`, panel de admin además de la app de consumidor) y el añadido del aislamiento por worktree tras detectar la colisión en producción de agentes trabajando en paralelo. También añade un script hermano, `fake-oidc-token`, para conseguir un bearer token sin pasar por navegador cuando `backend-dev` no tiene frontend delante — necesario para reproducir bugs de autorización entre dos usuarios distintos por `curl`.
- **Un tercer repo (propietario, sin enlace)**: hereda el aislamiento por worktree casi desde el nacimiento del script (a los pocos commits de introducirlo), y añade al `SKILL.md` una sección de "Required configuration" que documenta qué opciones (auth, credenciales de un proveedor externo...) ya vienen resueltas por el helper con valores de desarrollo, para que un error de validación de configuración se interprete como un defecto real a investigar y no como "te falta configurar una variable".
- **[ne2-factory](https://github.com/ne2-studio/ne2-factory)**: no tiene un `run.sh` propio porque no es una aplicación que se levante — es un plugin de agentes que opera sobre otros repos. En su lugar formaliza el patrón como contrato ([`environment-contract.md`](https://github.com/ne2-studio/ne2-factory/blob/main/docs/environment-contract.md)): cualquier repo que quiera ser trabajado por la factory debe exponer una skill llamada exactamente `run` con esas garantías. Es el caso que confirma la regla por ausencia: el patrón no aplica al propio ne2-factory porque no hay "un entorno local" que levantar, solo agentes que consumen el `run` de otros.

## Trade-offs reales observados

- **Puertos fijos es más simple, pero no escala a trabajo paralelo.** CashClarity fue el más simple porque nadie necesitaba dos entornos a la vez; en cuanto El Baúl y el tercer repo tuvieron agentes trabajando en worktrees paralelos, los puertos fijos se convirtieron en el primer punto de fallo. El aislamiento por hash añade complejidad real (offset, sufijo, exportar variables a cada `docker compose`/`dotnet run`) a cambio de que dos worktrees nunca se pisen.
- **"Esperar a que responda" cuesta más que "esperar a que el puerto exista", pero es la diferencia entre un script fiable y uno que miente.** Los `run-env` de los distintos repos usan `wait_http` contra un endpoint de salud real en vez de sondear el puerto — más lento de escribir, pero evita que el agente reciba "listo" y falle dos segundos después contra un servicio que aún no aceptaba conexiones.
- **Reconciliar en vez de acumular exige que el script sepa parar lo suyo.** Guardar PIDs en `.run/*.pid` y nombres de contenedor fijos permite que cambiar de modo limpie lo anterior sin intervención; el coste es que el script tiene que saber exactamente qué procesos y contenedores son "suyos" para no tocar nada ajeno — de ahí `require_port_free_unless_owned`, que distingue "el puerto está ocupado por mi propio contenedor de una ejecución anterior" de "el puerto está ocupado por algo que no debería tocar".
- **El contrato solo vale si la skill se queda pequeña y enfocada.** Las skills de `run` evitan explícitamente colar la estrategia de verificación o el histórico de workarounds — hay una skill `verify` aparte para eso. Meter todo en una sola skill la hace más difícil de mantener y de que el agente sepa cuándo consultarla.
- **No todos los repos necesitan este patrón.** ne2-factory no tiene `run.sh` porque no tiene "local" que levantar; forzar el patrón ahí habría sido documentar un script que nunca se ejecuta.

## Alternativas

- `README` con instrucciones manuales: más fácil de dejar desactualizado, y el agente tiene que interpretarlo en vez de ejecutarlo.
- `Makefile`/`justfile` sin skill asociada: el agente puede no saber que existe o cuándo usarlo, ni qué modo elegir para la tarea.
- Puertos fijos sin aislamiento por worktree: más simple mientras solo hay una copia del repo corriendo a la vez; deja de funcionar en cuanto hay trabajo paralelo (agente + revisión humana, o dos agentes) sobre el mismo repo.
