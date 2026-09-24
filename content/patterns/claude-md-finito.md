---
title: "CLAUDE.md finito"
description: "Un CLAUDE.md corto es un mapa hacia la documentación, no un lugar donde vive la documentación."
date: 2026-09-24
tags:
  - agentes
  - devex
maturity: adopt
---

## Problema

Es tentador convertir `CLAUDE.md` en el sitio donde se vuelca todo lo que un agente "debería saber": la arquitectura completa, las reglas de negocio, el contrato de la API, el histórico de decisiones. El resultado es un archivo que crece sin límite y que se desincroniza solo, porque cada cambio real (una entidad nueva, un endpoint, una regla de dominio) obliga a acordarse de tocar también el CLAUDE.md a mano — y nadie se acuerda siempre. Un CLAUDE.md largo tampoco resuelve nada mejor que uno corto: un agente no lee mejor 300 líneas que 40, y la información específica (qué endpoint hace qué, qué campo significa qué) cambia con frecuencia suficiente para que documentarla ahí sea garantía de que quede obsoleta.

## Contexto

Aparece en cualquier repo con `CLAUDE.md`/`AGENTS.md`, desde un servicio pequeño hasta un monorepo con varios servicios independientes. Se vuelve más visible cuanto más documentación real ya existe en el repo (`docs/ARCHITECTURE.md`, `docs/API-CONVENTIONS.md`, etc.) — ahí es donde la tentación de duplicar contenido en el CLAUDE.md, "para que el agente no tenga que ir a buscarlo", es mayor.

## Solución

El CLAUDE.md no explica el sistema: apunta a los documentos que lo explican, y dice cuándo leer cada uno. Es un índice de entrada, no un contenedor de conocimiento. Eso es lo que hace que se mantenga corto sin esfuerzo: casi nada de lo que cambia en el día a día del repo (una entidad nueva, un endpoint, una regla) obliga a tocarlo, porque casi nada de eso vive ahí.

En los cuatro repos, el patrón se repite casi textual:

- **Una o dos frases de qué es el proyecto** (`CashClarity is a personal treasury management app...`, `El Baúl helps families preserve, share and enrich their memories over decades.`).
- **Un listado plano de la estructura de directorios**, sin tabla, sin explicar cada carpeta, solo el nombre y una frase:
  ```
  api/         # ASP.NET Core backend
  app/         # End-user React application
  admin/       # Internal administration React application
  ```
- **Una sección "Documentation" que es una lista de rutas**, con una condición de cuándo leerlas ("antes de un cambio arquitectónico, de persistencia, de auth..."), nunca el contenido de esos documentos.
- **Convenciones de workflow que sí son estables** (trunk-based, Conventional Commits, idioma del repo) porque cambian mucho menos que la arquitectura o el dominio.
- **Un puntero a la skill de verificación**, no la matriz de riesgo completa (eso vive en `docs/architecture/testing.md`, ver [Skill Verify](/patterns/skill-verify/)).

Nada de lo anterior explica *cómo* funciona el dominio, *qué* hace cada endpoint, ni *por qué* se tomó una decisión de arquitectura — eso vive en `docs/`, donde el cambio que lo invalida y el cambio que lo actualiza son, casi siempre, el mismo commit.

## Qué no va en el CLAUDE.md, y por qué

El propio historial de estos archivos es la evidencia: no es que nunca se haya intentado meter más, es que se ha ido sacando deliberadamente, commit a commit.

- **Explicaciones de dominio o de arquitectura en prosa.** En un repo propietario (sin enlace), el CLAUDE.md llegó a tener un párrafo entero describiendo una regla de negocio de dominio, un patrón de reconciliación y el layout de proyectos con su justificación. El commit `3b83dd6` ("split README/CLAUDE.md into CONTEXT, ARCHITECTURE and DEPLOYMENT") lo saca todo a `docs/CONTEXT.md` y `docs/ARCHITECTURE.md`, y deja el CLAUDE.md como "an onboarding map: an abstract one-liner on the service's responsibility, a terse repository layout, and pointers to the docs".
- **Listas de comandos que ya viven en un script.** El commit `25832e8e` en El Baúl elimina del CLAUDE.md los cinco pasos manuales para regenerar el contrato OpenAPI tras cambiar un DTO — ese procedimiento ya lo ejecuta `./scripts/openapi` y `./scripts/verify`; mantenerlo también en prosa es una segunda copia que se desincroniza en cuanto el script cambia.
- **Explicaciones de por qué un documento es la fuente de verdad.** El commit `859a1ab3` retira un párrafo que explicaba que el OpenAPI generado es la fuente de verdad de la API y cómo se relaciona con `API-CONVENTIONS.md` — mensaje del commit: "keep the Documentation section as a plain list, consistent with the rest of the file". La lista de rutas ya dice dónde mirar; no hace falta justificar cada entrada.
- **Tablas markdown con metadatos que hay que mantener sincronizados a mano.** El commit `2094809c` sustituye una tabla `| Directorio | Contenido |` con descripciones y punteros a READMEs por texto plano de dos columnas, "dropping the per-service README pointers and version numbers for a terser, lower-maintenance overview" — cuantos más sitios apunten a un mismo dato, más sitios hay que actualizar cuando cambia.
- **Secciones que dejaron de ser ciertas.** El commit `25832e8e` retira una sección "Environment" sobre WSL2 que ya no aplicaba, junto con el resto de contenido obsoleto — un CLAUDE.md finito hace que detectar y borrar esto sea barato, porque no hay que revisar 300 líneas para encontrar la que ya no pinta nada.

El patrón inverso — lo que sí se añade con el tiempo — son punteros nuevos a documentación nueva (`docs/CONTEXT.md`, `docs/DEPLOYMENT.md`) y reglas de workflow que de verdad son estables (idioma del repo, trunk-based, qué skill usar antes de dar una tarea por terminada). Crecer así no engorda el archivo de forma descontrolada porque cada línea nueva sigue siendo un puntero o una convención, no una explicación.

## Implementación

- **En monorepos, un CLAUDE.md por servicio, más corto cuanto más específico.** El Baúl tiene un CLAUDE.md raíz (38 líneas, estructura + docs compartidas) y uno por servicio (`app/`, `api/`, `admin/`, `e2e-tests/`) de 9 a 13 líneas cada uno, que solo listan qué documentos leer antes de tocar ese servicio concreto — sin repetir nada del raíz.
- **AGENTS.md como symlink a CLAUDE.md, no como archivo hermano.** En `cashclarity` y en los cinco CLAUDE.md de `el-baul`, `AGENTS.md -> CLAUDE.md` es un enlace simbólico real. Una sola fuente, ningún riesgo de que ambos digan cosas distintas.
- **La sección "Documentation" nombra archivos, no explica su contenido.** Es una lista de rutas con, como mucho, una condición de cuándo consultarlas ("antes de un cambio arquitectónico, de persistencia, de auth, de testing o cross-service").
- **Lo único que se describe en prosa dentro del propio CLAUDE.md es lo que casi nunca cambia**: qué es el proyecto en una frase, el modelo de branching, el idioma del repo, qué skill usar antes de dar algo por terminado.

## Ejemplos

- **[CashClarity](https://github.com/ne2-studio/cashclarity)**: 41 líneas — descripción, estructura de dos servicios, cinco rutas de documentación, branching, y un puntero a la skill `verify`.
- **[El Baúl](https://github.com/ne2-studio/el-baul)**: CLAUDE.md raíz de 38 líneas más cuatro CLAUDE.md de servicio de 9-13 líneas cada uno; historial con múltiples commits de recorte explícito (`859a1ab3`, `2094809c`, `25832e8e`).
- **Un repo propietario (sin enlace)**: el más grande de los cuatro (55 líneas) y aun así separado en `CONTEXT.md`, `ARCHITECTURE.md` y `DEPLOYMENT.md` mediante el commit `3b83dd6`, que retira del CLAUDE.md justo la prosa de dominio y arquitectura que antes tenía.

## Alternativas

- **Un CLAUDE.md que documenta el dominio y la arquitectura in situ**: se desincroniza en cuanto el código cambia, porque nada obliga a tocarlo en el mismo commit que invalida su contenido — a diferencia de `docs/ARCHITECTURE.md`, que sí se edita junto al cambio que documenta.
- **Duplicar en el CLAUDE.md contenido que ya vive en un script o en otro doc** (pasos de un comando, tabla de directorios con metadatos): cada copia es un sitio más donde puede quedar desactualizado.
