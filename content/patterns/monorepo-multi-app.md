---
title: "Monorepo multi-app con pipeline independiente por app"
description: "Cuando frontend, backend y admin viven en repos separados, cualquier cambio que cruce esa frontera exige coordinar varios PRs y decidir el orden de merge y de deploy entre repos. La solución empaqueta todas las apps del producto en un único repositorio, con un pipeline independiente por app gateado por un glob de rutas."
date: 2026-09-24
tags:
  - monorepo
  - ci-cd
  - arquitectura
maturity: adopt
---

## Problema

Un producto real rara vez es una sola aplicación: suele ser un frontend, un backend, un panel de administración y, según el caso, algún componente de apoyo (un storage, un proxy de imágenes, un worker de background). Cuando cada uno vive en su propio repositorio, cualquier cambio que cruce esa frontera — un endpoint nuevo que el frontend necesita, un contrato que cambia entre backend y admin — deja de ser un commit y pasa a ser una coordinación entre varios repos: hay que abrir varios PRs, decidir el orden de merge y de deploy, y confiar en que nadie despliegue a medias. El riesgo de integración no desaparece, solo se difiere al momento del deploy.

Esto pesa especialmente cuando quien hace el cambio es un agente (o una persona nueva): tener que saltar entre repos distintos para ver "cómo encaja todo" añade fricción a algo que debería ser un único diff coherente. Y versionar la compatibilidad entre apps a mano (qué versión del backend requiere qué versión del admin) es trabajo extra que un monorepo resuelve gratis: si están en el mismo commit, están versionadas juntas por definición.

## Solución

La idea central: un único repositorio git con un directorio de primer nivel por app (`api/`, `app/`, `admin/`, y opcionalmente `imgproxy/`, `worker/`, etc.), de modo que cualquier refactor que cruce apps sea un solo commit — sin coordinar merges entre repos ni versionar contratos a mano — pero cada app se sigue construyendo, testeando y desplegando de forma independiente.

1. **Un directorio por app en la raíz del repo**, cada uno con su propio stack, dependencias y build. No hay un `package.json`/`.csproj` raíz que las una: cada carpeta es autocontenida y se podría, en principio, extraer a su propio repo sin tocar código.

2. **Un pipeline de CI/CD por app, gateado por un glob de rutas sobre su subdirectorio**, para que tocar el admin no dispare un build+deploy del backend:

   ```yaml
   # .github/workflows/backend-cicd.yml
   on:
     push:
       branches: [main]
       paths:
         - '.github/workflows/backend-cicd.yml'
         - 'api/**'
         - 'lib/**'
         - 'scripts/**'
   concurrency:
     group: backend-cicd-${{ github.ref }}
     cancel-in-progress: false
   ```

   Cada pipeline corre en paralelo y de forma independiente de los demás — su propio `concurrency.group` evita que dos pushes a la misma app se pisen, pero no bloquea a las otras apps.

3. **El glob no es solo "mi carpeta": incluye también todo lo que ese pipeline construye o ejercita aunque viva en otra carpeta.** Es el punto donde más fácil es dejar un agujero. Por ejemplo, un pipeline de frontend que hace tests de aceptación contra una imagen "lite" del backend depende de esa imagen, así que su glob tiene que vigilar también las rutas del backend de las que esa imagen se construye:

   ```yaml
   # .github/workflows/frontend-cicd.yml
   on:
     push:
       paths:
         - 'app/**'
         - 'docker-compose.lite.yml'
         - 'scripts/**'
         # Todo lo de lo que se construye la imagen api-lite: un cambio aquí puede
         # romper este pipeline aunque app/ no se haya tocado.
         - 'api/ElBaul.Core/**'
         - 'api/ElBaul.Api.Common/**'
         - 'api/ElBaul.Api.Lite/**'
   ```

   Si se omite esa dependencia cruzada, un cambio en el backend que rompe el contrato con el frontend pasa desapercibido hasta que alguien toque `app/` y el pipeline por fin se dispare.

4. **El deploy independiente por app solo es seguro si se respetan dos reglas, porque no hay garantía de en qué orden ni con qué solape terminan los despliegues de cada pipeline:**

   - **La API de cada app se mantiene siempre retrocompatible.** Un backend nunca rompe un contrato del que ya depende un frontend o un admin desplegados, aunque el cambio "real" que motiva el commit sea del lado del backend. Añadir campos o endpoints es seguro; quitar o cambiar de forma incompatible uno existente no lo es hasta que ya no lo usa nadie desplegado.
   - **Toda feature nueva que dependa de una API nueva de otra app del monorepo va detrás de un feature flag**, apagado por defecto. Como los pipelines son independientes, puede haber una ventana en la que el frontend ya esté desplegado con código que llama a un endpoint que el backend todavía no tiene — el flag evita que esa ventana se traduzca en errores para usuarios reales. Se activa solo cuando los despliegues de ambos lados ya han terminado.

   Cómo se sabe que quedó bien aplicado: se puede desplegar cualquier app del monorepo sola, en cualquier momento, sin coordinar con las demás — y si algo se rompe al hacerlo, es señal de que una de las dos reglas se saltó, no de que el patrón falle.

## Ejemplos

- **[El Baúl](https://github.com/ne2-studio/el-baul)**: `api/`, `app/`, `admin/`, `imgproxy/`, más `e2e-tests/` y `storybook/`. Nueve pipelines independientes (`backend-cicd`, `frontend-cicd`, `admin-cicd`, `imgproxy-cicd`, `storybook-cicd`, `android-ci`, entre otros), cada uno con su propio glob de `paths`; el de `admin-cicd` vigila explícitamente partes de `api/` porque sus tests de aceptación levantan `el-baul-api-lite` junto al admin.
- **[CashClarity](https://github.com/ne2-studio/cashclarity)**: `backend/` y `frontend/`, con `backend-deploy.yml` y `frontend-deploy.yml` como los dos únicos pipelines de producto; el de frontend vigila también `backend/CashClarity.Api/**` y `backend/CashClarity.Api.Lite/**` por la misma razón que en El Baúl.
- Un repo propietario, sin enlace: frontend, backend y panel de administración en el mismo monorepo, con la misma disciplina de retrocompatibilidad y feature flags para proteger los deploys parciales.
