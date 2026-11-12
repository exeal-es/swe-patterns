---
title: "Issue tracker como fuente única del estado del trabajo"
description: "El estado del trabajo (qué está hecho, qué se decidió, qué va primero) acaba repartido entre ficheros de los repos, una herramienta aparte y la cabeza de alguien, y ni las personas ni los agentes pueden fiarse de ninguna copia. La solución es llevarlo todo a un issue tracker con MCP y API, modelado para que cada pregunta habitual sea una consulta, y dejar en los repos solo el diseño, enlazado al issue que lleva su estado."
date: 2026-11-12
tags:
  - agentes
  - devex
maturity: trial
---

## Problema

Cuando humanos y agentes trabajan sobre el mismo backlog, el estado del trabajo se escapa por todas partes:

- **Vive en ficheros del repo.** Las debilidades conocidas de la plataforma (los *gaps*) eran un Markdown por gap, más una tabla en el README con el orden, el estado y los IDs. Había 84 abiertos; los 16 cerrados solo sobrevivían en el historial de git.
- **Vive dentro del diseño.** Las specs de proyecto llevaban su `Status: in progress`, lo que quedaba por hacer, un «Last checked» con fecha y una lista de checkboxes.
- **Vive duplicado.** El backlog estaba en otra herramienta, y 13 gaps se habían copiado allí a mano: estado y prioridad en dos sitios.
- **No vive en ningún sitio.** Una sesión de agente termina y lo que había avanzado se va con ella. En 45 días de conversaciones había unos 25 «esto no merece la pena» dichos en el chat; ninguno dejó rastro en el tracker ni en ninguna regla.

El resultado es que para saber cómo va un proyecto hay que preguntarme a mí, y un agente no puede ni contestar esa pregunta ni mantener el estado al día.

Aparece con varios repos, agentes haciendo buena parte del trabajo y una sola persona decidiendo qué va primero.

## Solución

Todo el estado del trabajo vive en el issue tracker, y los repos se quedan con el diseño, enlazado al issue que lleva su estado. Para que funcione con agentes hacen falta dos cosas: que el tracker se pueda leer y escribir desde una sesión (MCP para el día a día, API REST para lo demás) y que esté modelado para que cada pregunta habitual sea una consulta. Lo tengo probado con YouTrack, que trae ambas; la idea vale para cualquier tracker que las tenga.

### 1. Fijar la frontera: estado en el tracker, diseño en el repo

| Qué | Dónde vive |
|---|---|
| Qué hay que hacer, en qué estado está y qué prioridad tiene | Campos del issue |
| El desglose de un proyecto y su avance | Un epic y un issue por slice |
| El diseño del proyecto | La spec en el repo, con una línea `Tracking:` al epic y la key de cada slice. Sin checkboxes ni marcas de «hecho» |
| Las debilidades conocidas (gaps) | Issues con el tag `gap`. En el repo quedan el proceso y la plantilla |
| El progreso a medias | Un comentario en el issue |
| Por qué algo no se hace | El comentario de cierre, con un motivo tipado |
| Cómo está organizado el tracker | Un solo doc, en el [home repo](/patterns/home-repo-y-skills-compartidas/) |

Una spec, antes y después:

```diff
-**Status:** in progress. Routers deployed. Left: the ACL review.
-Last checked: 2026-10-13.
+**Status:** accepted. 2026-10-13.
+
+Tracking: epic [OPS-78](…). The state of each step lives
+there; this doc holds the design.

-- [x] Subnet routers in dev and prod
-- [ ] Review the ACLs
+1. **Subnet routers in dev and prod** ([OPS-79](…))
+2. **Review the ACLs** ([OPS-80](…))
```

El issue lleva el contenido del slice y enlaza de vuelta a la sección de la spec. Cómo se llega de una iniciativa a esa spec y a sus slices está en [De iniciativa a slices ejecutables](/patterns/de-iniciativa-a-slices-ejecutables/).

### 2. Modelar el tracker para que lo lea un agente

Un proyecto del tracker por dueño del arreglo, no por repo (tres proyectos para nueve repos). Si el trabajo cruza proyectos, el epic vive en uno y sus subtareas en cada proyecto que tiene algo que hacer.

| Campo | Valores | Qué responde |
|---|---|---|
| Type | Bug, Incident, Feature, Task, Improvement, Spike, Epic | Qué clase de trabajo es |
| State | Inbox, Ready, In Progress, In Review, Done, Won't Do | Nunca vacío: todo entra por Inbox |
| Priority | P0 a P4, o vacío | La banda. Vacío es «nadie lo ha priorizado» |
| Component | Por proyecto | Qué parte del sistema toca |
| Size | S, M, L | El coste. Un L nunca está Ready |
| Area | Security, Reliability, Operations, Product… | El tipo de riesgo, transversal a los proyectos |
| Source | Manual, Error log, Daily ritual, Support, Agent… | De dónde salió, no quién lo reportó |
| Technical Details | Markdown | El texto para quien hace el trabajo |

Las decisiones que hacen que el modelo se pueda consultar:

- **Dos textos para dos lectores.** La descripción es de producto, para cualquiera que lea el tracker: sin código, rutas ni comandos. *Technical Details* es un campo aparte con todo lo que necesita quien hace el trabajo: análisis, evidencia, rutas, comandos, pasos, rollback. Un agente que encuentra contenido técnico en la descripción lo mueve.
- **Vacío significa algo.** Un issue sin Priority aparece en la búsqueda de triaje; una subtarea sin Priority hereda la del epic.
- **Una regla escrita antes que una automatización.** La herencia no copia nada entre campos: «the inheritance is this rule, read by people and agents». Un valor propio gana al heredado.
- **Lo transversal es un campo.** Seguridad es un Area, no un componente: el issue se queda en el componente que toca.
- **Tags con significado único.** `gap` (debilidad conocida), `blocked` (espera algo de fuera del tracker; si el bloqueo es otro issue, se usa un enlace *depends on*), `needs-breakdown`, `paused`. Los dos de espera obligan a decir en un comentario qué o por qué.
- **Los estados nombran algo observable.** In Review va desde el PR hasta que el cambio está en producción; Done, cuando lo está.

El tracker no impone casi nada: una sola regla de workflow rechaza mover un issue a Ready sin Type ni Component. El resto lo comprueban los procesos de triaje y refinamiento, que están en [Gestión del backlog con skills](/patterns/gestion-del-backlog-con-skills/).

### 3. Las búsquedas guardadas son la superficie de lectura

Cada pregunta habitual tiene su consulta, escrita en el doc del tracker:

| Pregunta | Consulta |
|---|---|
| ¿Qué ha entrado sin priorizar? | `(Type: Epic or has: -{subtask of}) and State: Inbox and has: -Priority sort by: created asc` |
| ¿Qué se puede empezar ya? | `(has: -{depends on} or depends on: (#Resolved)) and State: Ready and Type: -Epic and tag: -blocked and Priority: -P4 sort by: Priority asc` |
| ¿Cómo va este proyecto? | `subtask of: <epic>` |
| ¿Esto ya se conoce? | `tag: gap <palabras>`, sin `#Unresolved`, para que cuenten los cerrados |
| ¿Cuál es el siguiente gap? | `tag: gap #Unresolved sort by: Priority asc, created asc` |
| ¿Qué se hizo esta semana? | `#Resolved resolved date: {This week}` |
| ¿Qué se aparcó a propósito? | `Priority: P4 #Unresolved sort by: updated asc` |
| ¿Qué se descartó por no merecer la pena? | `State: {Won't Do} "Won't Do: not worth it"` |

Las mismas búsquedas alimentan los tableros y el dashboard que leen los stakeholders: personas y agentes miran lo mismo.

### 4. Disciplina de escritura

- **Quién crea.** Solo yo creo issues y cambio sus campos; un agente crea uno cuando se lo pido. El resto de personas lee y comenta, con un rol hecho a medida.
- **El progreso a medias es un comentario.** La regla de la skill que cierra gaps: «When a gap cannot be finished in one session, add a comment instead: the Fix steps done (with date and commit), and what is next. Leave State In Progress». La siguiente sesión empieza leyendo los comentarios.
- **El cierre dice qué y dónde.** Un comentario con lo que se hizo y dónde está (commits, despliegues) antes de pasar a Done.
- **Won't Do con motivo tipado.** La primera línea del comentario es exactamente `Won't Do: <motivo>`, con uno de cuatro: `duplicate`, `superseded`, `not worth it`, `accepted risk`. Después, una frase de por qué y el enlace que lo respalda. Así una decisión de no hacer algo se puede buscar.
- **Los procesos firman.** El triaje deja un comentario `Triage applied` y el refinamiento uno `Refinement applied (<fecha>)`, con lo que se preguntó, lo que se respondió y lo que decidió el agente por su cuenta.
- **El código nombra su issue.** En el repo más activo: rama `feat/app-378-…`, asunto del commit acabado en `(APP-378)` y el issue en el cuerpo del PR. En los demás todavía es desigual. No hay integración que mueva el estado: lo mueve quien hace el trabajo.

### 5. Acceso: MCP para el día a día, REST para el resto

Cada repo declara el servidor MCP del tracker en su `.mcp.json` y lo aprueba en su `settings.json`. Es el mismo bloque en todos y se reparte con el cableado del [home repo](/patterns/home-repo-y-skills-compartidas/) (paso 6):

```json
{ "mcpServers": { "issue-tracker": { "type": "http", "url": "https://<instancia>.youtrack.cloud/mcp" } } }
```

El MCP cubre leer, crear y actualizar issues, enlazarlos y comentarlos. No quita un enlace, no ejecuta un comando sobre muchos issues y no toca administración (proyectos, campos, valores). Para eso hay una skill REST en el plugin compartido:

- Por defecto usa la API de comandos, con los mismos comandos que escribiría una persona (`State Inbox`, `tag gap`, `remove subtask of APP-44`), validados antes con `assist`.
- El token está en un fichero que solo cargan los scripts; el agente tiene denegada su lectura.
- Cambiar administración exige que yo lo pida.

Lo mecánico (listar una cola, aplicar un lote de decisiones) son scripts sobre la API REST, no llamadas sueltas del agente.

Los issues con Area Security solo los ve un grupo: un workflow pone la restricción cuando el issue se crea o cambia a esa Area.

### 6. Migrar sin perder la historia

Los 100 gaps (84 abiertos y 16 cerrados) pasaron de ficheros a issues así:

1. Un script construye el dataset desde los ficheros y git: `created` es la fecha del commit que añadió el fichero, `resolved` la del commit que lo borró.
2. Se importa con un paquete de importación, porque esas dos fechas no se pueden fijar por la API REST. Antes, un piloto de dos issues en un proyecto de usar y tirar.
3. Los IDs antiguos se quedan como prefijo del título (`[SEC-3] …`), porque commits, incidentes y chats los siguen usando.
4. Cada descripción termina con la ruta del fichero original: `git log --follow` recupera su historia.
5. Los enlaces entre gaps pasan a ser keys; los enlaces a otros repos, URLs de GitHub.
6. Se borran los ficheros y el check que validaba la cola, y la spec de la migración se retira: el doc del tracker describe el resultado.

El backlog que venía de la otra herramienta conserva su fecha de creación, y cada descripción termina con un enlace a la página original.

Cómo se sabe que quedó bien aplicado: en los repos no queda ningún checkbox de progreso y cada spec tiene su línea `Tracking:`. Un agente al que se le pregunta «¿esto ya se conoce?» lo encuentra con una búsqueda, que era el invariante de la migración. Y una sesión que se queda a medias deja un comentario del que arranca la siguiente.

### Gotchas

- **Sin MCP, el agente está ciego.** El contenido de los gaps ya no está en el repo. Es un coste aceptado, con una regla escrita: un agente sin MCP lo dice, no adivina.
- **En el tracker el agente soy yo.** Usa el MCP con mi usuario y la API con mi token, así que el historial no distingue sus cambios de los míos. Lo único que los marca es el campo Source y los comentarios firmados. En GitHub sí tiene identidad propia ([home repo](/patterns/home-repo-y-skills-compartidas/)).
- **El MCP da recuentos de enlaces, no los issues.** `get_issue` devuelve cuántos enlaces hay, sin keys ni dirección. Para verlos hace falta una lectura REST.
- **La dirección de un enlace engaña.** `depends on: APP-98` encuentra los issues que dependen de APP-98; de qué depende APP-98 es `is required for: APP-98`.
- **`get_issue` trae todos los comentarios aunque pidas cero.** Un issue largo cuesta su hilo entero. Para leer solo campos, una búsqueda que los pida.
- **`update_issue` solo lista campos personalizados entre los actualizados.** Un título o descripción cambiados no aparecen. Hay que fiarse de que la lista de fallos venga vacía, o releer.
- **La API de comandos responde `{}` funcione o no.** Primero `assist`, y después de la llamada real se relee el issue.
- **Un issue tiene un solo padre.** Hacerlo subtarea de otro epic lo mueve, pero los recuentos que devuelve el MCP justo después pueden mostrar los dos.
- **El lenguaje de consultas no niega cláusulas.** «Sin dependencias sin resolver» se escribe como «sin dependencias, o con alguna resuelta»: un issue con una resuelta y otra pendiente sigue saliendo como listo. Y un `sort by` detrás de un grupo `or` entre paréntesis rompe el agrupamiento.
- **Los IDs antiguos se buscan entre comillas.** `summary: "SEC-3"`; sin comillas coincide con otros issues.
- **Los valores archivados siguen vivos para el agente.** La interfaz los oculta, pero el esquema del MCP los lista y se aceptan al escribir.
- **Nada cierra un epic cuando se cierran sus subtareas.** Se quitaron los workflows por defecto ligados a estados.
- **Las consultas están en dos sitios.** El doc y el script de triaje llevan las mismas cadenas, y nada comprueba que coincidan.
- **La restricción de seguridad no se levanta sola** si el Area deja de ser Security.
- **Las fechas migradas son aproximadas.** La de resolución del backlog antiguo es la última edición de la página.
- **No todo acaba en el tracker.** Una skill que actualizaba desde el tracker el seguimiento que lleva otra persona se revirtió el mismo día: ese seguimiento sigue siendo suyo.

## Variantes

- **Mantener los ficheros y reflejarlos como issues puntero.** El contenido sigue en el repo y se lee sin MCP. Se descartó porque estado y prioridad vivirían en dos sitios.
- **Crear los issues por API o MCP en vez de importarlos.** Más simple, pero todos quedan fechados el día de la migración y se pierde cuándo se encontró y se cerró cada uno. Vale si esa historia no importa.

## Ejemplos

- **Un conjunto de repos propietarios (sin enlace), sobre YouTrack Cloud**: tres proyectos para nueve repos, el backlog entero migrado (unos 500 issues creados en seis semanas, inflados por las dos migraciones), 100 gaps importados con sus fechas, once documentos de ocho proyectos enlazados a su epic y ocho búsquedas guardadas. En uso desde hace algo más de dos semanas.

## Recursos

- [YouTrack MCP Server](https://www.jetbrains.com/help/youtrack/cloud/model-context-protocol-server.html): endpoint `/mcp`, autenticación y filtrado de tools.
- [YouTrack REST API](https://www.jetbrains.com/help/youtrack/devportal/youtrack-rest-api.html): lo que el MCP no cubre.
- [Home repo y skills compartidas entre repos](/patterns/home-repo-y-skills-compartidas/): dónde vive el doc del tracker y cómo se reparten el MCP, la skill REST y las credenciales.
- [Gestión del backlog con skills](/patterns/gestion-del-backlog-con-skills/): triaje, priorización y refinamiento sobre este modelo.
- [De iniciativa a slices ejecutables](/patterns/de-iniciativa-a-slices-ejecutables/): de dónde salen los epics y sus slices.
