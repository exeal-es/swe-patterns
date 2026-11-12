---
title: "Gestión del backlog con skills"
description: "Con agentes haciendo el trabajo, el backlog crece más deprisa de lo que una persona puede priorizar y refinar, y su criterio para decir «esto no merece la pena» solo existe en el chat. La solución es escribir ese criterio como una rúbrica con ejemplos y repartir triaje, refinamiento y redacción de issues en skills donde el agente investiga y propone, un script aplica, y la persona decide por lotes."
date: 2026-11-12
tags:
  - agentes
  - devex
maturity: explore
---

## Problema

Con agentes implementando, el cuello de botella deja de ser el código y pasa a ser decidir:

- **Entra más de lo que se decide.** En seis semanas se crearon unos 500 issues (con dos migraciones dentro) y se resolvieron 130. De 260 issues en Inbox, 235 esperaban solo una prioridad.
- **Solo yo triajo, y mi criterio vive en el chat.** En 45 días de sesiones había unos 25 rechazos explícitos por coste de oportunidad («¿no estamos overengineering?»). Ninguno dejó rastro en el tracker ni en ninguna regla. De 19 issues cerrados como Won't Do, ninguno decía «no merece la pena».
- **Los agentes sobreproducen.** Hallazgos, gaps y alcance que nadie va a atender, «because no rule tells them when to stop».
- **Priorizado no es listo.** Un issue con prioridad puede seguir teniendo una decisión abierta, ser demasiado grande o no decir cómo se comprueba.

Aparece con una sola persona decidiendo, agentes haciendo buena parte del trabajo y el estado de ese trabajo ya en el tracker ([Issue tracker como fuente única del estado del trabajo](/patterns/tracker-fuente-unica-del-estado-del-trabajo/)).

## Solución

Los agentes proponen y yo decido, pero decido por lotes. El problema medido es el volumen de decisiones, no quién tiene la autoridad. Para eso hay tres textos que llevan el juicio (una rúbrica de priorización, una Definition of Ready y una plantilla de issue), cuatro skills que llevan los procesos y un script que hace la mitad mecánica. Los textos viven en el [home repo](/patterns/home-repo-y-skills-compartidas/) y las skills se reparten desde su plugin compartido.

### 1. Escribir el juicio como rúbrica

Un doc que da a cada issue o hallazgo su banda sin preguntarme. La regla en una línea: **lo que no toca ninguno de los tres impactos es `someday`, y la carga de la prueba es del hallazgo, no mía.**

- **Impacto.** Cuentan tres: el camino del ingreso (lo que el negocio no puede permitirse perder, según el snapshot de ingresos del home repo), la seguridad de producción y el foco actual (un epic de la lista de foco). Todo lo demás es «ninguno»: higiene, deriva, comodidad, hipótesis.
- **El impacto necesita evidencia.** Un pedido, una línea de log, un número, una petición reproducida. Algo que *podría* fallar en una condición que nadie ha visto es una hipótesis: impacto ninguno, esté donde esté. El Area de un issue es una etiqueta, no evidencia.
- **Coste.** Es el campo Size: S, un PR limpio; M, un PR con riesgo (migración o un tercero); L, más de un PR. Un L nunca es un issue suelto: se parte o pasa a ser un epic con spec ([De iniciativa a slices ejecutables](/patterns/de-iniciativa-a-slices-ejecutables/)).
- **Banda.** Impacto × coste. Con impacto, P0 a P3 por severidad; sin impacto, `someday` (P4) o Won't Do `not worth it`, que solo vale si el comentario nombra la señal concreta que lo reabriría.

Una banda es una reacción, no un puesto en una cola:

| Banda | Qué hago yo | Qué hace un agente |
|---|---|---|
| P0 · en llamas | Lo dejo todo | Para y me lo dice en la sesión, sin esperar al digest ni al triaje |
| P1 · lo siguiente | Entra al sprint ya | Si está libre, coge un P1 antes que nada |
| P2 · planificada | Elijo entre ellas el lunes | Solo trabaja en una si está en el sprint. Caduca a las ocho semanas fuera de un sprint |
| P3 · de paso | Nunca la planifico | La incluye en el PR cuando el cambio que tiene entre manos toca lo mismo |
| P4 · `someday` | La miro una vez al trimestre | Nada |

Y la parte que más enseña, los ejemplos trabajados: rechazos reales, con mi frase literal, la banda que da la rúbrica y la señal que la cambiaría.

| Propuesta | Impacto | Coste | Banda | Por qué |
|---|---|---|---|---|
| Un lock contra una carrera entre dos ejecuciones («¿lock para qué? ¿no estamos overengineering?») | Camino del ingreso, pero sin ninguna ocurrencia: ninguno | S | `someday` | Una hipótesis en el camino del ingreso sigue siendo una hipótesis. La señal: un duplicado en los logs |
| Una pantalla para importar un CSV («me pasan el csv y lo importo yo») | Ninguno | M | `someday` | La variante barata da el resultado a coste cero. Espera a un segundo usuario o a una frecuencia semanal |
| Un servicio de 35 $ al mes («me parece excesivo») | Ninguno | S, recurrente | Won't Do: `not worth it` | Se reabre cuando la alternativa manual cueste más de 35 $ de tiempo al mes |
| Borrar recursos cloud y esquema muertos («me gusta borrar código muerto») | Ninguno demostrado | S | P3 | Borrar lo muerto siempre compensa si es barato. La rúbrica propuso primero `someday` |
| «Demasiadas cosas a la vez, dime el primer paso mínimo» | Cualquiera | L | Epic con spec, o solo el primer slice S | Un L presentado como S es la forma más común de gastar mi tiempo en alcance que no pedí |

La tabla se alimenta sola: los Won't Do `not worth it` del tracker la extienden y, cuando uno la contradice, la que está mal es la rúbrica y se corrige. Si dos agentes leen bandas distintas del mismo hallazgo, lo que está mal especificado es el hallazgo.

### 2. Los hallazgos van a un digest, no a issues

Lo que un agente encuentra mientras trabaja en otra cosa no se convierte en issue. Es una fila en el digest de la semana: un único issue (`Digest 2026-W45`) que se queda In Progress para no aparecer en ninguna cola, con una tabla en la descripción.

```text
| Band | Finding | Evidence | Source | Date |
|---|---|---|---|---|
| P4 | The sync job could race on two concurrent runs; no occurrence seen | <log or file link> | agent (APP-100) | 2026-11-03 |
```

La banda sale de la rúbrica. Un P0 además se me dice en la sesión en el acto. El lunes leo el digest: la fila que merece un issue se promociona (el issue enlaza al digest y la fila recibe su key) y el resto se cierra con él. Un `someday` queda escrito igualmente, para que el siguiente agente que se lo encuentre sepa que ya se sopesó.

### 3. Triaje: una tabla a la semana

Una tarea programada lanza la skill `triage-pass` el domingo a las 22:00 en un hilo nuevo, con orden de no cambiar nada hasta que yo conteste. El lunes me encuentro esto:

1. **La leyenda de bandas primero**, para decidir con los significados frescos.
2. **Una tabla por tipo de decisión**, en el orden en que más necesitan una mirada: bandas que cambian una prioridad existente, P0 a P2 nuevos, P3, Won't Do, P4. Columnas: issue, ahora → propuesta, por qué, y si ya está listo o qué puntos de la Definition of Ready le fallan. La regla de la skill: «A row a busy CTO cannot decide from is not finished».
3. **Cómo contestar.** Un solo mensaje: `ok todo, salvo APP-5 P2, OPS-72 someday`. Lo que no nombro es `ok`.

Cada propuesta es una línea con gramática fija:

```text
P2, Type Bug, Component Core, Size S, Area Reliability, epic APP-75, ready
```

Las respuestas también: `ok`, una banda, `someday`, `inherit`, `epic: APP-75`, `wontdo: <motivo> <por qué>`. El agente escribe un fichero de decisiones y el script las aplica:

```json
[{ "issue": "APP-38", "proposal": "P2, Type Bug, Component Core, ready", "reply": "ok" }]
```

El reparto entre skill y script:

- **La skill pone el juicio**: lee cada issue y el código al que apunta, aplica la rúbrica, propone campos y epic padre. Proponer no escribe nada en el tracker. No usa acceso a producción: la evidencia que solo darían los datos reales es un hueco que queda para el refinamiento.
- **`triage-queue list`** saca las colas, ordenadas por la banda efectiva (la propia o la heredada del epic).
- **`triage-queue apply`** parsea todas las decisiones antes de tocar nada (una respuesta ilegible para el lote entero), valida cada comando, aplica uno por issue y deja un comentario `Triage applied` con la propuesta, la respuesta y si se aceptó tal cual. Tiene `--dry-run`.
- **`triage-queue stats`** lee esos comentarios y da la tasa de aceptación.

Texto libre no es una respuesta: una pregunta mía se contesta en la sesión con una fila nueva, nunca se aplica.

### 4. Definition of Ready

El triaje da la banda; estar listo es otra cosa. Un issue está Ready cuando:

1. **Tiene banda** de la rúbrica (propia o del epic) y no es P4.
2. **Es S o M**: un PR. Antes de que exista código se estima con un proxy sobre los Technical Details: un repo, como mucho una migración, los ficheros a tocar se pueden nombrar (unos ocho de techo), ninguna librería nueva, un tipo principal de cambio.
3. **No tiene nada abierto**: ninguna decisión pendiente en el texto, ningún tag `blocked`, dependencias enlazadas y resueltas o planificadas.
4. **Tiene criterios de aceptación y cómo verificarlos**: comportamientos numerados (AC1, AC2…) que podrían romperse, y para cada uno su comprobación.
5. **Un agente puede empezar desde los Technical Details** sin preguntar.
6. **Tiene los campos**: Type, Component y Size.

El triaje mueve a Ready lo que ya lo cumple. El resto se queda en Inbox con su banda, en la cola de refinamiento.

### 5. Refinar bajo demanda

`refine-issue` lleva un issue a la Definition of Ready con una política: **investigar antes que preguntar, preguntar antes que adivinar.** Una pregunta solo merece mi tiempo si una suposición equivocada cambiaría lo que se construye: comportamiento de producto, alcance o arquitectura. Todo lo demás lo decide el agente, y lo deja escrito.

1. **Lee** el issue, su epic, sus enlaces y hermanos, y da veredicto por cada punto de la Definition of Ready.
2. **Investiga** código y docs. Un hecho puede estar caducado, ser falso o faltar. Una decisión abierta que los docs o una respuesta mía anterior ya resuelven es un hallazgo, no una pregunta.
3. **Decide la forma.** Se queda en uno o se parte en issues hermanos, nunca en subtareas, y solo si cada parte sigue siendo un slice: da valor sola, se prioriza sola y tiene un resultado observable. Se parte si es L, si sus partes merecen bandas distintas o si tienen dependencias distintas.
4. **Redacta** con la skill del paso 6.
5. **Me pregunta**, en ejecutivo: veredicto en una línea, dos o tres hallazgos que pesan en la decisión, y las preguntas con la respuesta recomendada primero. Cada pregunta nombra la key y el título, para que se entienda sola.
6. **Aplica** lo que contesté: reescribe el issue, crea los hermanos, enlaza, mueve a Ready y deja un comentario `Refinement applied (<fecha>)` con preguntas y respuestas, hallazgos, lo decidido por el agente y la partición.

`refine-backlog` hace lo mismo por lotes, con una sola ronda de preguntas. El refinamiento se tira, no se barre: hace falta trabajo Ready para un sprint o dos, no la cola entera refinada. Cada issue cuesta entre 60 y 150 mil tokens de subagente y cada pregunta un minuto de mi atención, así que el lote es de cuatro por defecto y nunca corre programado.

- **Issues sueltos**: un subagente por issue, cada uno con contexto limpio, porque no comparten nada.
- **Los slices de un epic**: un solo subagente, que primero hace un mapa (duplicados, solapes, slices obsoletos, orden de dependencias) y luego refina en ese orden, para que lo que decide un slice ya se sepa al redactar el siguiente.

### 6. Escribir issues para dos lectores

La skill `write-youtrack-issue` fija la plantilla:

- **Descripción**, en términos de producto. El porqué contado con un ejemplo concreto (un cliente con nombre, un pedido verosímil). Un antes y después visual solo cuando una imagen dice lo que los criterios no pueden. Y los criterios de aceptación: una línea cada uno, situación y resultado, sin identificadores de código, solo comportamientos que podrían romperse. Los que se comprueban en producción llevan `(prod)` y son el «done when».
- **Technical Details.** Primera línea, la banda y su motivo (`Band: P2, Production safety`). Después el trabajo como piezas y orden, enlaces a las secciones exactas de la spec, la evidencia justa, y una línea por criterio: `AC1 → <nivel>: <comprobación>`.
- **Corto gana a completo.** Un issue S cabe en una pantalla. Cada hecho se dice una vez.

Un issue nuevo entra en Inbox sin prioridad: la banda propuesta va en la primera línea de los Technical Details y el campo se queda para el triaje.

### 7. El ritmo semanal

1. Domingo por la noche: la tabla de triaje.
2. Lunes: contesto la tabla. Si quedan menos de unos cinco P0 o P1 listos para empezar, o va a arrancar un epic, lanzo `refine-backlog`.
3. Leo el digest, promociono lo que merece issue y lo cierro.
4. Ordeno el backlog y arrastro al sprint lo que empieza esta semana.
5. El primer lunes de cada trimestre, repaso `someday`.

Cómo se sabe que funciona: por la tasa de aceptación de las propuestas (el primer retriaje fueron 134 decisiones, el 89 % aceptadas tal cual) y por los issues de Inbox que llevan más de 14 días sin decisión (141 al empezar, objetivo menos de 20).

### Gotchas

- **Un comentario por issue no me ahorraba ninguna visita.** La primera versión dejaba cada propuesta como comentario en su issue. Se cambió a una tabla en la sesión el mismo día.
- **Sin banda hasta estar refinado: tres P0 sin prioridad.** La primera pasada no daba banda a lo que no estaba refinado. Ahora el triaje da banda a todo y el refinamiento es otra cola.
- **189 subtareas no estaban en ninguna cola.** Un epic con banda está listo; sus slices no. La cola de refinamiento incluye las subtareas de los epics con banda, y el script las ordena por la banda heredada porque el tracker las pone al final.
- **Un tope de P1 empuja P1 reales a P2.** Hubo un máximo de tres P1 abiertos; duró unos commits. P1 se queda con el test de la rúbrica.
- **Un campo para la banda.** `someday` empezó como tag y acabó siendo Priority P4.
- **La rúbrica aplicó de más «sin impacto, someday».** En el primer retriaje corregí tres casos, que entraron como reglas con su ejemplo: borrar lo muerto es P3 si es barato, superficie de seguridad sobrante es P2 si es barata, una ayuda de depuración en el camino del ingreso es P3.
- **Dos agentes leyeron la rúbrica distinto.** Se cerraron las ambigüedades una a una: el camino compartido cuenta por componente, una elección A/B abierta cuesta lo que la opción más barata, un trabajo manual es recurrente si se ve en dos semanas distintas.
- **Partir en subtareas no daba slices.** Un L se parte en issues hermanos enlazados, cada uno con su banda.
- **Los comandos no son búsquedas.** Las llaves son sintaxis de búsqueda y fallan en un comando, y `tag` se traga el resto de la línea, así que va al final.
- **Deshacer incluye borrar el comentario.** `Triage applied` es a la vez registro y fuente de la métrica: si se revierte una decisión y se deja, la tasa miente.
- **Una respuesta que es una pregunta no se aplica.** «¿Seguro que esto no se arregló ya?» se investiga y se vuelve a preguntar.
- **La tarea programada solo corre con el portátil encendido.**
- **La métrica de turnos cuenta de más.** Los prompts que un agente padre escribe en sesiones delegadas cuentan como míos.
- **La spec que diseñó esto se quedó atrás.** Está enmendada solo en parte: todavía describe el tag `someday` y la partición en subtareas. El resultado vigente está en los docs.

## Variantes

- **Que los agentes muevan a Ready los issues de banda baja sin preguntar.** Descartado por ahora: el problema medido es el volumen de decisiones, no la autoridad, y el lote resuelve el volumen sin cambiar quién decide. Se revisa cuando se conozca la tasa de aceptación.
- **Hallazgos como issues sueltos filtrados por la rúbrica.** Descartado: lo que no pasa el umbral se pierde sin rastro, y el digest deja un registro barato y revisable.

## Ejemplos

- **Un conjunto de repos propietarios (sin enlace), sobre YouTrack**: una rúbrica con 13 ejemplos trabajados, cuatro skills (`triage-pass`, `refine-issue`, `refine-backlog`, `write-youtrack-issue`) y un script de unas 400 líneas con sus tests. Primer retriaje de 134 decisiones y una prueba de refinamiento sobre siete issues. En uso desde hace menos de dos semanas.

## Recursos

- [Issue tracker como fuente única del estado del trabajo](/patterns/tracker-fuente-unica-del-estado-del-trabajo/): el modelo de campos, estados y búsquedas sobre el que corre todo esto.
- [Home repo y skills compartidas entre repos](/patterns/home-repo-y-skills-compartidas/): dónde viven la rúbrica y las skills, y cómo llegan a cada repo.
- [De iniciativa a slices ejecutables](/patterns/de-iniciativa-a-slices-ejecutables/): qué pasa con lo que es demasiado grande para un issue.
