---
title: "Runtime Env Config"
description: "Cómo hacer que una imagen de frontend construida una sola vez sirva para varios entornos, inyectando las variables de entorno en el arranque del contenedor en vez de plancharlas en el build."
date: 2026-09-24
tags:
  - frontend
  - docker
  - devex
maturity: adopt
---

## Problema

Un frontend construido con Vite lee sus variables de entorno (`VITE_*`) en tiempo de build: Vite las sustituye literalmente en el bundle. Eso significa que la URL de la API, el authority OIDC o el DSN de Sentry quedan "planchados" dentro del JavaScript compilado. Si quieres desplegar la misma app en `staging` y en `production` con distinta configuración, te ves obligado a construir una imagen por entorno — un pipeline de CI que hace build, build y build otra vez, cada uno con sus `--build-arg`, solo para cambiar cuatro strings.

Eso rompe la promesa de "construyes una vez, despliegas esa misma imagen donde haga falta": la imagen que pasó los tests en staging no es bit a bit la misma que llega a producción, porque cada entorno tiene su propio build.

## Contexto

Aparece en cualquier frontend servido como estático (Vite + nginx, típicamente) que se construye en un pipeline de CI y se despliega como imagen de contenedor a varios entornos. Tiene sentido aplicarlo en cuanto quieres "1 build, many deploys": una única imagen versionada que se promociona de un entorno a otro sin reconstruir, y donde cada entorno solo aporta configuración (URLs, IDs de cliente OIDC, tokens de analítica), nunca código distinto.

No hace falta si cada entorno tiene su propio pipeline de build y nunca promocionas la misma imagen entre entornos — ahí plantar los `VITE_*` en build time es simplemente más simple.

## Solución

En vez de depender solo de las variables `VITE_*` en build time, la app las lee en tiempo de ejecución desde un objeto global (`window.__ENV__`) que un script de arranque del contenedor genera a partir de las variables de entorno reales del contenedor, sustituyéndolas en una plantilla con `envsubst`.

El flujo:

1. En build time, Vite compila la app normalmente. El bundle incluye un archivo estático adicional, `env-config.template.js`, con placeholders (`${VITE_API_URL}`, etc.) en vez de valores.
2. Al arrancar el contenedor (nginx sirve la imagen), un script de entrypoint corre `envsubst` sobre esa plantilla usando las variables de entorno del contenedor, y genera `env-config.js` con los valores reales de ese entorno concreto.
3. `index.html` carga `env-config.js` antes que el bundle de la app, dejando esos valores en `window.__ENV__`.
4. El código de la app no lee `import.meta.env.VITE_*` directamente: pasa por una función `getEnv()` que mira primero `window.__ENV__` y solo si no hay valor cae al `import.meta.env` compilado.

Esto hace que la misma imagen, sin recompilar nada, sirva staging o producción según qué variables de entorno le pases al `docker run`/manifiesto de despliegue — y sigue funcionando igual (con el valor compilado en build time como fallback) en builds donde no hay un runtime que ejecute el entrypoint, como una app nativa/PWA empaquetada con Capacitor.

## Implementación

En El Baúl (frontends `app` y `admin`, ambos Vite + nginx) esto se monta así:

**`env-config.template.js`** (estático, parte del bundle, nunca se ejecuta tal cual — solo se usa como plantilla):

```js
window.__ENV__ = {
  VITE_API_URL: "${VITE_API_URL}",
  VITE_OIDC_AUTHORITY: "${VITE_OIDC_AUTHORITY}",
  VITE_OIDC_CLIENT_ID: "${VITE_OIDC_CLIENT_ID}",
  VITE_OIDC_CALLBACK_URI: "${VITE_OIDC_CALLBACK_URI}",
  VITE_ZITADEL_ORGANIZATION_ID: "${VITE_ZITADEL_ORGANIZATION_ID}",
  VITE_SENTRY_DSN: "${VITE_SENTRY_DSN}",
  VITE_PUBLIC_POSTHOG_PROJECT_TOKEN: "${VITE_PUBLIC_POSTHOG_PROJECT_TOKEN}",
  VITE_PUBLIC_POSTHOG_HOST: "${VITE_PUBLIC_POSTHOG_HOST}",
};
```

**Script de entrypoint** (`docker-entrypoint.d/95-generate-runtime-env.sh`), que aprovecha que la imagen base de nginx ya ejecuta automáticamente cualquier script en `/docker-entrypoint.d/` antes de arrancar, y que ya trae `envsubst`:

```sh
#!/bin/sh
set -eu

envsubst '${VITE_API_URL} ${VITE_OIDC_AUTHORITY} ${VITE_OIDC_CLIENT_ID} ${VITE_OIDC_CALLBACK_URI} ${VITE_ZITADEL_ORGANIZATION_ID} ${VITE_SENTRY_DSN} ${VITE_PUBLIC_POSTHOG_PROJECT_TOKEN} ${VITE_PUBLIC_POSTHOG_HOST}' \
  < /usr/share/nginx/html/env-config.template.js \
  > /usr/share/nginx/html/env-config.js
```

La lista explícita de variables entre comillas es importante: sin ella, `envsubst` sustituye *cualquier* `$VARIABLE` que encuentre en el archivo, lo que puede romper cosas si hay texto con `$` en otro sitio del bundle.

**Lectura en el código de la app** (`src/runtimeConfig.ts`), que decide la prioridad entre override de runtime y valor compilado:

```ts
declare global {
  interface Window {
    __ENV__?: Record<string, string>;
  }
}

export function getEnv(key: RuntimeEnvKey): string {
  return window.__ENV__?.[key] || (import.meta.env[key] as string) || '';
}
```

**Dockerfile**, uniendo las dos piezas — build normal de Vite (con `ARG`/`ENV` que siguen sirviendo de fallback para builds nativos) y copia del script de entrypoint en la imagen final de nginx:

```dockerfile
FROM node:22-alpine AS build
...
RUN npm run build

FROM nginx:alpine
COPY --from=build /src/dist/ /usr/share/nginx/html/
COPY --chmod=755 docker-entrypoint.d/95-generate-runtime-env.sh /docker-entrypoint.d/
```

El patrón se repite igual en el frontend `admin` del mismo repo, con su propio juego de variables — la mecánica (plantilla + `envsubst` en el entrypoint + `getEnv()` con fallback) es idéntica.

## Alternativas

- **Un build por entorno**: más simple de montar, pero pierdes la garantía de que lo que se probó en staging es exactamente lo que llega a producción, y el pipeline de CI se alarga con un build por entorno.
- **Montar `env-config.js` como volumen/ConfigMap** en vez de generarlo con `envsubst` en el entrypoint: evita depender de `envsubst`, pero exige que la plataforma de despliegue soporte montar archivos, y añade una pieza de infraestructura más que gestionar por entorno.
- **Servir la config desde un endpoint HTTP** (`GET /config`) en vez de un archivo estático generado en build: más flexible (permite cambiar config sin reiniciar el contenedor) pero añade una llamada de red bloqueante antes de que la app pueda arrancar, y una pieza de backend extra solo para esto.
