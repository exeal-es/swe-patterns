---
title: "De iniciativa a slices ejecutables: PRD, tech spec y plan de slices"
description: "Una iniciativa grande entregada tal cual a un agente acaba en un PR enorme, con alcance que nadie pidió y decisiones de negocio tomadas sobre la marcha. La solución es bajarla por etapas, cada una con su documento y su puerta: un PRD que valida negocio, una tech spec que fija el diseño, un plan de slices verticales derivado de un modelo de complejidad, y cada slice convertida en un issue que un agente implementa en su worktree, test-first y con su propio PR."
date: 2026-11-12
tags:
  - agentes
  - devex
maturity: adopt
---

## Problema

Una iniciativa que no cabe en un PR no se le puede dar entera a un agente:

- **Sale un bloque.** La primera versión de mi skill de implementación hacía todo el proyecto en un worktree y una rama, con las slices como commits y un único PR al final.
- **Crece alcance que nadie pidió.** «Demasiadas cosas a la vez, dime el primer paso mínimo» aparece tres veces en mis conversaciones: un trabajo grande presentado como pequeño es la forma más común de gastar mi tiempo.
- **Negocio opina tarde.** En una revisión de PRD, el responsable de negocio cambió un plazo de 14 días a 1. Descubierto después de implementar, eso es rehacer.
- **Las incógnitas con terceros aparecen al final.** Dos integraciones respondieron algo distinto de lo que el diseño daba por hecho.
- **El troceo por capas no enseña nada hasta el final.** Base de datos, luego backend, luego API, luego frontend: nada observable hasta la última.

Aparece con iniciativas de más de un PR, con gente de negocio que tiene que validar y no vive en el repo, y con agentes implementando. Para trabajo de un solo PR no hace falta nada de esto: va directo al backlog ([Gestión del backlog con skills](/patterns/gestion-del-backlog-con-skills/)).

## Solución

La iniciativa baja por etapas. Cada etapa produce un documento que responde una sola pregunta, tiene una puerta que abre una persona concreta y es la entrada de la siguiente.

| Etapa | Artefacto | Pregunta | Quién da el ok | Skill |
|---|---|---|---|---|
| 1 | PRD | ¿Qué tiene que pasar y para quién? | Negocio, fuera del repo | Sesión de preguntas con el agente |
| 2 | Tech spec | ¿Cómo, y qué no vamos a hacer? | Yo, decisión a decisión | [`tech-spec`](https://github.com/ppardalj/skills/blob/main/skills/tech-spec/SKILL.md) |
| 3 | Plan de implementación | ¿En qué incrementos de un PR, y en qué orden? | Yo, sobre el modelo de complejidad | [`vertical-slice`](https://github.com/ppardalj/skills/blob/main/skills/vertical-slice/SKILL.md) |
| 4 | Epic y un issue por slice | ¿Qué está hecho? | | Skill de escritura de issues |
| 5 | Un PR por slice | | Quien revisa el PR | [`implement-slice`](https://github.com/ppardalj/skills/blob/main/skills/implement-slice/SKILL.md), [`implement-tech-spec`](https://github.com/ppardalj/skills/blob/main/skills/implement-tech-spec/SKILL.md) |
| 6 | Retirada de los documentos | | | |

Los tres documentos viven juntos en `docs/projects/<slug>/` del repo dueño, o en el [home repo](/patterns/home-repo-y-skills-compartidas/) si la iniciativa cruza repos.

Las skills son mías, no de la empresa: están en [un plugin personal público](https://github.com/ppardalj/skills), activado a nivel de usuario, y leen del repo lo que es específico. La spec cuenta el coste en los términos de la rúbrica de priorización «when the repo has a prioritisation doc», el slicing respeta el umbral de tamaño de PR «when it states one», y la implementación saca la rama base y el comando de verificación del `CLAUDE.md`.

### 1. PRD: lo que pide negocio, en su idioma

Se escribe con el agente en una sesión de preguntas, a partir de lo que trae negocio. Sin código. La estructura que se repite:

```markdown
**Status:** draft | accepted. <fecha>. <quién lo revisó>
Tracking: epic [APP-67](…). The open questions are tracked in [APP-97](…).

## 1. Problem
## 2. Constraints
## 3. Requirements              — numerados: R1, R2…
## 4. Scenarios
## 5. What operators and customers see
## 6. Before and after
## 7. Out of scope
## 8. Decisions                 — con nombre y fecha
## 9. Rejected alternatives
## 10. Risks and open questions — incluye «Questions for <negocio>»
```

- **La revisión es fuera de banda.** Lo repaso con mis analistas de negocio y el resto del equipo fuera del repo. El PRD lleva preparadas las preguntas para ellos.
- **Las respuestas vuelven al documento**, fechadas y con nombre, en Decisions («Business (nombre, fecha): …»), en un commit que dice que registra la revisión.
- **Si negocio trae su propio borrador**, se refina y una tabla «Changes from the original draft» (original, ahora, por qué) deja constancia de cada cambio. El texto original queda en git.
- **Lo que sigue abierto se convierte en issues** enlazados desde el PRD. No se decide en el documento.
- **La spec no empieza hasta que el PRD tiene el ok de negocio.**

### 2. Tech spec: el diseño, decidido conmigo

La skill [`tech-spec`](https://github.com/ppardalj/skills/blob/main/skills/tech-spec/SKILL.md) no escribe hasta el paso 5:

1. **Busca lo que ya hay**: specs vivas, docs de los módulos y specs retiradas (`git log --diff-filter=D -- docs/projects`).
2. **Lee las restricciones**: el doc de lenguaje de dominio, las reglas de arquitectura, el README de cada módulo que toca.
3. **Mapea el estado actual contra el código.** Hecho cuando cada afirmación lleva su `file:line`.
4. **Evalúa y decide conmigo.** Informa del estado actual, juzga mi propuesta por sus méritos (qué aguanta, qué rompe), propone un diseño refinado y las alternativas que rechaza. Después me pasa cada decisión que cambia la forma del diseño, con la opción recomendada primero, e itera hasta que confirmo. Las que lo merecen acaban como ADR propuesto.
5. **Escribe** sobre un esqueleto fijo.
6. **Informa** y ofrece el plan como siguiente paso.

```markdown
**Status:** draft | accepted | amended | implemented. <date>. <what amended it, if anything>

## 1. Goal                  — the requirement, in the user's terms
## 2. Current state         — verified against code, with file:line
## 3. Design                — the shape first, then one subsection per moving part
## 4. Data                  — tables and migrations, per owning module and schema
## 5. Contracts             — ports, HTTP endpoints, provider and webhook wire changes
## 6. UI / admin
## 7. Invariants            — before and after
## 8. Decisions             — what the user decided; prior decisions this spec reverses
## 9. Rejected alternatives — each with the reason it falls
## 10. Risks
## 11. Testing              — which suite covers which risk
## 12. Open questions
## 13. Steps                — coarse order; the implementation plan slices it. Last step: retire the spec
```

Y pasa unas comprobaciones antes de darse por buena. Las dos que más ahorran:

- **El coste está contado**: ficheros, agregados, migraciones, librerías nuevas, en los términos de la rúbrica del repo y con el impacto que reclama.
- **Las alternativas rechazadas nombran lo que el proyecto no va a hacer**: las partes de la petición que ningún requisito pide, quitadas a propósito, «so a slice does not grow them back».

### 3. Plan de slices: primero el modelo de complejidad

La skill [`vertical-slice`](https://github.com/ppardalj/skills/blob/main/skills/vertical-slice/SKILL.md) tiene dos fases y no deja mezclarlas.

**Fase 1, modelar la complejidad.** Una iniciativa grande es difícil de trocear porque tiene varias dimensiones de complejidad independientes. Se buscan en el delta entre el estado actual y el objetivo:

| Dimensión | Progresión | Por qué importa |
|---|---|---|
| Proveedor | Stand-in → proveedor real | Mete la integración externa |
| Resultado | Éxito → rechazo → fallo técnico | Cada uno es una transición distinta |
| Ejecución | Síncrona → asíncrona | Hay que suspender y reanudar |
| Entrega | Una vez → duplicada | Mete idempotencia |

Los componentes no son dimensiones: base de datos, backend o frontend dicen dónde se implementa, no cómo crece el comportamiento. El agente me discute el modelo con preguntas concretas («trato el rechazo y el fallo como variantes del mismo eje, pero se recuperan distinto: ¿es otra dimensión?») y no saca slices mientras el modelo no esté estable.

**Fase 2, trocear.** Se empieza por el camino más fino que da comportamiento observable o aprendizaje: una variante de cada dimensión, no todas las de una. Cada slice siguiente añade la mínima complejidad útil.

- **Una slice es una capacidad**: «Given X, the system can now Y». «Implementar el cliente del proveedor» o «crear las tablas» son tareas dentro de una slice.
- **Cabe en un PR** bajo el umbral del repo. Si no cabe, son dos slices.
- **El orden busca validar pronto**, no seguir dependencias: primero lo que reduce la mayor incertidumbre, aunque dé poco valor visible. En la práctica la primera slice es un trazador o un spike.
- **Independientes cuando se pueda**, para implementarlas en paralelo. La dependencia que quede, explícita.
- **Se pregunta qué complejidad se puede no soportar todavía**, no cómo partir todos los requisitos en tareas más pequeñas.

El plan es un documento aparte, `implementation-plan.md`: contexto, modelo de complejidad, estrategia (con el grafo de dependencias en ASCII), las slices y una tabla de cobertura que cruza requisito del PRD, sección de la spec y slice. Cada slice tiene siempre las mismas cinco partes:

```markdown
## S4 — No upload within a day stops the order

Tracking: [APP-174](…).

### Capability
Given a document request with nothing uploaded a day after the link went out, the order stops;
a document uploaded in time is waited for while the provider reviews it.

### Complexity covered
Time: the 1-day window, and uploaded in time.

### Implementation
Expiry from the request's notification time; expiry on read with an injectable clock; the admin
shows the deadline and the blocker.

### Verification
Acceptance with a fake clock: no upload past a day stops the order; an upload before the
deadline, reviewed after it, approves it.

### Dependencies
S2. Size S.
```

La lista de slices tiene un solo dueño, el plan. La sección de pasos de la spec apunta a él, y si el PRD traía su propio troceo, el plan lo sustituye.

### 4. Del plan al tracker

La skill de escritura de issues crea el epic y un issue por slice:

- El epic lleva en la descripción un mapa de las slices (el grafo de dependencias con las keys) y los enlaces a PRD, spec y plan.
- Cada issue se llama como la capacidad de la slice («Each attempt knows the provider that produced it»), nunca como un componente («Add provider column»).
- Los enlaces *depends on* son los que dice el plan y ninguno más.
- Cada key se escribe de vuelta en la línea `Tracking:` de su slice.

A partir de aquí el estado vive en el tracker y los documentos se quedan con el diseño ([Issue tracker como fuente única del estado del trabajo](/patterns/tracker-fuente-unica-del-estado-del-trabajo/)).

### 5. Implementar: un worktree y un PR por slice

[`implement-slice`](https://github.com/ppardalj/skills/blob/main/skills/implement-slice/SKILL.md) hace una slice:

1. **Lee** la slice, las secciones transversales del plan y las de la spec que cubre. Hecho cuando puede decir el alcance en una frase y qué se queda fuera.
2. **Crea su worktree y su rama.** El checkout principal, las demás ramas y el stash se quedan como estaban.
3. **Implementa test-first.** Para cada comportamiento, el test primero y verlo en **rojo**: una ejecución real que falla en su aserción. Un error de compilación no es rojo. Commits pequeños, de un solo tipo, cada uno compila y pasa sus tests.
4. **No adivina.** Una ambigüedad menor se resuelve por la opción conservadora y se apunta como desviación. Una que cambia comportamiento es una pregunta (`BLOCKED: REQUIREMENT_AMBIGUITY`).
5. **Abre el PR** con la skill [`pr`](https://github.com/ppardalj/skills/blob/main/skills/pr/SKILL.md) cuando la verificación completa pasa ([Skill Verify](/patterns/skill-verify/)). El cuerpo lleva resumen, commits, decisiones y desviaciones, evidencia (los tests vistos en rojo), peligro del merge, cambios incompatibles, pasos de release y cabos sueltos.
6. **Informa**, incluidas las notas de traspaso para las slices siguientes.

[`implement-tech-spec`](https://github.com/ppardalj/skills/blob/main/skills/implement-tech-spec/SKILL.md) es el orquestador de un proyecto entero. No implementa nada: lanza un subagente por slice, en orden, con este prompt:

```text
Implement **Slice <N> — <title>** of the `<project>` tech spec with the `implement-slice` skill,
from the repo `<main checkout>`, with `--base <previous slice branch>`, stacked on PR <previous PR>.

Already on the base: slices <1..N-1> (<titles>), PRs <URLs>.
Hand-off notes from slice <N-1>: <its deviations and loose ends>

Read first: in `docs/projects/<project>/implementation-plan.md`, "<slice heading>" and
<cross-cutting sections>; in `tech-spec-<project>.md`, §<sections>.

Scope: slice <N> only. Later slices' work stays out: <what they will do>.
```

- **Los PR forman una pila.** La primera slice sale de la rama principal; cada una de las siguientes sale de la rama de la anterior y apunta a ella.
- **Comprueba cada informe antes de lanzar la siguiente**: que cada commit de comportamiento tenga su test en rojo o una razón, y que el PR apunte a la base correcta.
- **Arrastra las desviaciones y las notas de traspaso** al prompt siguiente: «This carry-over is what keeps later slices consistent».

Las slices independientes se pueden lanzar a la vez, cada una en su worktree.

### 6. Enmendar y retirar

- **La spec se enmienda, no se congela.** La línea de Status dice qué la cambió («Amended the same day while slicing»). El resultado de un spike enmienda la spec; una respuesta de negocio a medio camino rehace slices.
- **Una slice descartada se cierra como Won't Do**, con su motivo.
- **Recortar alcance es mover slices.** Las que salen del lanzamiento pasan a otro epic, para que el primero pueda cerrarse.
- **Al terminar, los documentos se borran.** Las decisiones duraderas pasan a los docs del módulo dueño; PRD, spec y plan se eliminan y el epic cita el commit donde leerlos. El paso de retirada está escrito en el propio plan, y la próxima `tech-spec` los encuentra en el historial.

Cómo se sabe que funciona: del plan a la primera slice fusionada pasan uno o dos días, y una iniciativa de ocho a diez slices se cierra en tres a ocho. En los proyectos recientes, cada título de PR acaba con la key de su issue. Y los proyectos terminados no dejan documentos vivos.

### Gotchas

- **Un PR por spec no se puede revisar.** Era el diseño original. Ahora es un PR apilado por slice.
- **Los worktrees hermanos rompían el entorno.** Fuera del checkout, el contenedor de desarrollo ejecutaba el código del checkout principal: tests en verde que no probaban nada. La skill manda ejecutar los comandos como digan los docs del repo para worktrees, y un repo cuyo contenedor no ve la ruta por defecto fija la suya en su `CLAUDE.md`.
- **La pila cruza repos.** Si una slice cambia un contrato, aterriza y se despliega en el repo productor antes del push que lo usa, y el PR lo dice en sus pasos de release.
- **El primer spike cambia la spec.** Un proveedor contestó con un error a algo que el diseño daba por válido. Por eso la mayor incógnita va en la primera slice.
- **Aparecen slices que no estaban en el plan.** Un arreglo descubierto implementando se abre como su propio PR, no se cuela en la slice en curso.
- **Planificar de más.** Un plan de treinta slices se recortó al alcance de lanzamiento, y catorce pasaron a un epic posterior.
- **Las slices habilitadoras existen, y se dicen.** «Value: preparation. Nothing reads the new column»: sin comportamiento, pero etiquetada como lo que es.
- **Entre slices puede quedar un comportamiento más estricto**, hasta que una posterior lo relaja. El plan lo avisa en su contexto.
- **No siempre es PRD primero.** Dos veces el PRD se extrajo de la spec después, cuando esta había acumulado requisitos, escenarios y preguntas de negocio.
- **Las marcas de progreso vuelven.** La skill todavía pide marcar la slice como hecha en el plan, y la regla del repo dice que ningún documento registra progreso. Hay un plan con «S1–S8 implemented».
- **El umbral de tamaño se supera a menudo.** En una iniciativa reciente, 10 de 13 PR pasan de 400 líneas, aunque en una pila el recuento puede incluir commits heredados.
- **Un diagnóstico de entorno se comprueba antes de repetirlo.** Un subagente informó de «0.5 GB free» de RAM como si fuera disco. El orquestador ejecuta él mismo el comando de evidencia.
- **Las dos skills que mandan solo corren si las escribo yo.** `vertical-slice` e `implement-tech-spec` tienen desactivada la invocación por el modelo.

## Variantes

- **Sin PRD.** Las iniciativas técnicas o internas empiezan en la tech spec. Son la mayoría: no hay nadie de negocio que tenga que validar.
- **Spec con pasos, sin plan de slices.** Para infraestructura y upgrades, la última sección de la spec es una lista ordenada de pasos y cada uno es un issue.
- **Lista de slices sin spec.** Un rediseño de interfaz guiado por mockups y un documento de principios de UX: «Each slice below is one increment that ships on its own: an API change and the screen it unlocks, in the order that pays back soonest».
- **Una slice suelta.** `implement-slice` también acepta un issue o una tarea descrita en palabras, para trabajo de un PR que sale del backlog sin spec.

## Ejemplos

- **Un conjunto de repos propietarios (sin enlace)**: más de treinta iniciativas en tres repos en unos dos meses. Siete con PRD, 27 con tech spec y 24 con plan de slices, de 2 a 29 slices por plan (mediana 7). Cinco recorrieron la cadena completa de PRD, spec y plan.
- **[ppardalj/skills](https://github.com/ppardalj/skills)**: las skills con las que se hizo todo lo anterior, públicas e instalables como plugin de Claude Code: [`tech-spec`](https://github.com/ppardalj/skills/blob/main/skills/tech-spec/SKILL.md), [`vertical-slice`](https://github.com/ppardalj/skills/blob/main/skills/vertical-slice/SKILL.md), [`implement-slice`](https://github.com/ppardalj/skills/blob/main/skills/implement-slice/SKILL.md), [`implement-tech-spec`](https://github.com/ppardalj/skills/blob/main/skills/implement-tech-spec/SKILL.md) y [`pr`](https://github.com/ppardalj/skills/blob/main/skills/pr/SKILL.md).

## Recursos

- [ppardalj/skills](https://github.com/ppardalj/skills): el plugin con las skills de este artículo. El README explica cómo instalarlo.
- [Gestión del backlog con skills](/patterns/gestion-del-backlog-con-skills/): la rúbrica que cuenta el coste, la Definition of Ready de cada slice y el refinamiento de un epic entero.
- [Issue tracker como fuente única del estado del trabajo](/patterns/tracker-fuente-unica-del-estado-del-trabajo/): la línea `Tracking:` y por qué los documentos no llevan progreso.
- [Home repo y skills compartidas entre repos](/patterns/home-repo-y-skills-compartidas/): dónde viven las iniciativas que cruzan repos.
- [Skill Verify](/patterns/skill-verify/): la verificación que cierra cada slice.
