---
title: "Baseline de calidad que solo encoge"
description: "En un repo con deuda, un límite estricto deja el CI en rojo desde el primer día y uno laxo deja crecer la deuda, y un agente que solo quiere el check en verde acaba ampliando la lista de excepciones en vez de arreglar el código. La solución congela la deuda de hoy en ficheros versionados, juzga cada PR contra la versión de su rama base y falla si algo empeora, de modo que la lista solo puede encoger y subirla queda en manos de una persona."
date: 2026-11-12
tags:
  - agentes
  - ci-cd
  - testing
maturity: explore
---

## Problema

Quieres límites estrictos de complejidad, cobertura, análisis estático y código muerto en un repo que ya tiene deuda. Las dos salidas habituales fallan:

- **Límite estricto para todo.** El CI nace en rojo con cientos de infracciones que nadie va a arreglar esta semana, así que el check se desactiva o se queda en aviso.
- **Límite laxo, o un porcentaje global.** «Cobertura mínima del 40 %» deja empeorar mientras sigas por encima, castiga borrar código que estaba testeado y no dice nada del código nuevo.

La salida intermedia es conocida: una baseline, un fichero con las infracciones que ya existían, y el check solo falla con las nuevas. El problema es que **ese fichero vive en el repo y quien abre la PR puede editarlo**. Un agente al que le falla el check tiene delante tres caminos para ponerlo en verde: arreglar el código, añadir su infracción a la baseline o quitar el paso del pipeline. Los dos últimos son más baratos, y si el check los acepta, los usará. No hace falta mala fe: su objetivo local es que el CI pase.

El fondo del asunto es ese. Con agentes abriendo decenas de PRs al mes, y parte de ellas mergeándose sin revisión humana, no basta con que la deuda esté apuntada: hace falta que **quien trabaja no pueda aumentarla**, y que la codebase mejore con el tiempo precisamente mientras es un agente el que la toca. Un guardrail que el vigilado puede aflojar no vigila nada.

## Solución

Tres piezas que se sostienen entre sí:

1. La deuda de hoy queda **congelada en ficheros versionados**, una lista de infractores por métrica. El código nuevo cumple el límite estricto; el que ya lo incumplía no puede empeorar.
2. Cada PR se juzga contra **la versión de esos ficheros en su rama base**, nunca contra la suya. Un cambio no puede bajarse su propio listón.
3. **Bajar** una lista es libre y se mergea solo. **Subirla** es una decisión humana que no pasa por una PR de agente, y los ficheros que definen el check tampoco.

Lo que sigue es la receta tal como funciona en un backend PHP/Symfony, con `dev` como rama de integración.

### 1. Mide por unidad, no totales

Un total (suma de complejidad, porcentaje global) se mueve con el crecimiento sano y con el borrado de código testeado: tumba PRs buenas y esconde las malas. Cada métrica necesita una unidad a la que señalar:

| Métrica | Unidad | Regla |
|---|---|---|
| Complejidad ciclomática | método | Límite 10. Un método nuevo por encima falla; uno listado no puede empeorar |
| CRAP (complejo y mal testeado) | método | Límite 30, misma regla |
| Errores del analizador estático | error en fichero | Ninguna entrada nueva ni recuento mayor |
| Código muerto | símbolo | Lo reporta el propio analizador, así que entra en su baseline |
| Violaciones de capas | par de clases | Ningún par nuevo (las reglas, en [Reglas de arquitectura como tests](/patterns/reglas-de-arquitectura-como-tests/)) |
| Cobertura | repo | La única global, con una regla doble (paso 4) |

CRAP es `c² · (1 − cobertura)³ + c`, con `c` la complejidad del método. Con límite 30, un método sin ningún test falla a partir de complejidad 6 (CRAP 42). Es la métrica que más empuja: no pide «más tests», pide tests justo donde hay ramas.

### 2. Congela la deuda de hoy

Mide el repo y escribe lo que hay. El CI queda en verde desde el primer commit y la deuda pasa a ser una lista con nombres:

```json
{
  "complexity": {
    "limit": 10,
    "offenders": {
      "App\\Service\\OrderSyncService::syncOrder": 60,
      "App\\Service\\FulfillmentService::fulfillOrder": 37,
      "App\\Command\\FetchPaymentCommand::populateCustomer": 33
    }
  },
  "crap": {
    "limit": 30,
    "offenders": {
      "App\\Service\\FulfillmentService::fulfillOrder": 1406,
      "App\\Service\\OrderSyncService::syncOrder": 65.78
    }
  },
  "coverage": { "uncovered_lines": 11322, "line_percent": 44.24 }
}
```

Las dos listas no dicen lo mismo: el método de complejidad 60 tiene un CRAP de 66 porque está testeado, y el de 37 llega a 1.406 porque no tiene ni un test.

Para los errores del analizador y las violaciones de capas no inventes formato: PHPStan y deptrac ya generan su baseline (`phpstan-baseline.neon`, `deptrac/baseline.yaml`). Son tres ficheros y una sola regla.

### 3. Una CLI que mide y juzga, la misma en local y en CI

Todo pasa por un comando del repo (`bin/quality`, con su código en `tools/quality/` para que sus propias líneas no cuenten como producto):

```bash
bin/quality report complexity --top 20   # los peores infractores, hoy
bin/quality check --fast                 # sin cobertura ni CRAP, que necesitan las suites
bin/quality check                        # todo; el CI lo corre por partes con --only=…
bin/quality baseline regenerate          # reescribe las baselines del analizador y de capas
```

`check` sale con 0 (limpio), 1 (regresión) o 2 (la herramienta no pudo medir). El 2 también rompe el CI: un gate que no puede medir no pasa.

La regla de las listas cabe en un bucle:

```php
foreach ($this->offenders($measured) as $unit => $value) {   // los que superan el límite
    $recorded = $this->recorded[$unit] ?? null;
    if (null === $recorded) {
        $regressions[] = "$unit CC $value > {$this->limit}: extract branches into smaller methods";
    } elseif ($value > $recorded) {
        $regressions[] = "$unit CC $value > $recorded recorded on dev (limit {$this->limit}): …";
    }
}
```

Los mensajes están escritos para el agente que tiene que arreglarlo: dicen qué método, cuánto se pasa, qué hacer y qué no hacer (`do not edit quality-baseline.json`). Es el único sitio donde seguro que va a leer la norma.

Que sea un comando local y no una plataforma alojada es deliberado: el agente necesita los mismos números antes de hacer push, y un objetivo del tipo «baja la complejidad de este servicio» necesita un comando contra el que iterar. La [skill de verificación](/patterns/skill-verify/) del repo solo tiene que apuntar a él.

### 4. Cobertura: ni porcentaje solo ni recuento solo

El porcentaje solo castiga borrar código testeado. El recuento de líneas sin cubrir solo castiga una feature bien testeada que deja tres líneas fuera. Así que el cambio pasa si **cualquiera de los dos** no empeora:

```php
public function regression(self $measured): ?string
{
    if ($measured->uncoveredLines <= $this->uncoveredLines || $measured->linePercent > $this->linePercent) {
        return null;
    }

    return "Coverage: uncovered lines {$measured->uncoveredLines} > {$this->uncoveredLines} and line coverage "
        ."{$measured->linePercent}% <= {$this->linePercent}% recorded on dev: add tests for the new code; "
        .'do not edit quality-baseline.json';
}
```

Borrar código testeado pasa. Añadir código sin tests, no.

La cobertura sale de fusionar todas las suites en un informe, contando también los ficheros que ningún test toca. Antes de imponerla, mide su varianza: aquí diez ejecuciones sobre el mismo commit dieron informes idénticos y no hizo falta tolerancia.

### 5. La referencia es la base de la PR, nunca la PR

Este es el paso que impide al agente subirse el listón. `check` no lee `quality-baseline.json` del árbol de trabajo: lo saca de la referencia con `git show <ref>:quality-baseline.json`. Lo que la PR haya escrito en su copia no cuenta para juzgarla.

En local la referencia es `origin/dev`. En CI es el primer padre del merge ref, el commit sobre el que se construyó la PR, para que un `dev` que avanza a mitad de ejecución no le mueva el listón:

```yaml
- name: Find the PR's base
  id: base
  if: github.event_name == 'pull_request'
  run: |
    git fetch --no-tags --depth=2 origin "$GITHUB_SHA"
    echo "sha=$(git rev-parse HEAD^1)" >> "$GITHUB_OUTPUT"

- name: Baseline does not grow
  if: github.event_name == 'pull_request'
  run: bin/quality check --only=static-analysis --reference="${{ steps.base.outputs.sha }}"
```

Además de medir el código, `check` compara los propios ficheros de la PR con los de la base y falla si alguno **sube**: un límite más alto, un infractor nuevo o con peor valor, menos cobertura, una entrada nueva o un recuento mayor en la baseline del analizador, un par nuevo en la de capas. Este segundo control hace falta porque el analizador sí lee su baseline del árbol de trabajo: sin él, la PR añade su error a la lista y el analizador pasa.

### 6. El listón sigue a la rama de integración sin editar el fichero

Si cada PR que mejora algo tiene que actualizar la baseline, con decenas de PRs al mes todas chocan en el mismo fichero. Y si no la actualiza nadie, la mejora se puede perder en la PR siguiente. La salida: el listón es **el más estricto entre el fichero y lo que `dev` mide hoy**, método a método.

- **Complejidad.** `check` mide el código de la referencia en el momento (un segundo, sin tests). Un método que `dev` simplificó queda sujeto a su valor nuevo; si bajó del límite, sale de la lista.
- **CRAP y cobertura.** Necesitan las suites, así que cada push a `dev` publica un `metrics.json` como artefacto. El job de la PR descarga el del commit más reciente que sea ancestro de su base y se lo pasa a `check`. Si no hay ninguno, juzga solo contra el fichero y avisa.

Una mejora se convierte en listón en cuanto aterriza, sin PR y sin conflictos. La medición solo aprieta, nunca afloja, y los límites siguen siendo los del fichero, que queda como suelo y como registro en git. Por lo mismo, la PR que arregla un error del analizador no tiene que tocar su baseline (`reportUnmatchedIgnoredErrors: false`).

### 7. Cierra las puertas de atrás

Con el paso 5 el agente ya no puede subir la lista. Le quedan otras formas de aflojar el gate, y cada una se cierra aparte:

| Puerta | Cierre |
|---|---|
| Quitar el paso del pipeline | Los workflows que corren los checks exigen revisión humana |
| Vaciar una regla propia del analizador, o el test que la fija | Reglas y tests de las reglas exigen revisión humana |
| Aportar una medición propia más favorable | El job solo busca la medición en las ejecuciones de push a `dev`; lo que publique una PR no se mira |
| Ampliar la lista de rutas que se mergean solas | El bot lee esa política desde `dev`, no desde la PR |
| Subir la baseline «legítimamente» | No hay camino desde una PR: lo hace una persona en `dev` |

Aquí las PRs de bajo riesgo las mergea un bot cuando el CI está verde, según las rutas que tocan. La política queda así:

```yaml
read:                        # se mergean solas con CI verde
  - "docs/**"
  - "tests/**"
  - "quality-baseline.json"  # el gate las vigila: una PR que solo las baja entra sola
  - "phpstan-baseline.neon"
  - "deptrac/baseline.yaml"

never_read:                  # gana a `read`: espera a una persona
  - ".github/risk-paths.yml"
  - ".github/workflows/_ci_backend.yml"
  - ".github/workflows/pull_requests.yml"
  - "tests/PHPStan/**"       # las reglas propias y los tests que las fijan
```

Las baselines están en `read` a propósito: como el gate rechaza cualquier subida, una PR que solo las baja no necesita a nadie. También están en el `paths-ignore` de los despliegues, para que bajarlas no despliegue nada.

Subir una baseline tiene casos válidos: cambio de versión de una herramienta, recalibrar un límite, un método renombrado o una regla nueva que tiene que listar las infracciones de hoy. Todos son decisión de una persona.

### 8. Usa las listas como backlog

Una baseline con nombres y valores es trabajo ya troceado: `report --top 20` da los peores, y «deja la baseline del analizador en cero» es un objetivo que un agente puede perseguir PR a PR, porque cada una se mergea sola si solo baja la lista. Aquí la baseline del analizador pasó de casi 2.500 errores a ninguno en cinco días.

### Gotchas

- **Un checkout atrasado carga con culpas ajenas.** Si tu rama no contiene `origin/dev`, lo que `dev` mejoró después cuenta como regresión tuya. `check` aborta antes de medir con un error de herramienta.
- **La PR que estrena la baseline no tiene referencia.** El fichero aún no existe en `dev`. Hace falta un camino de arranque que lea el de la propia PR con un aviso; queda muerto en cuanto se mergea.
- **Cambiar de herramienta mueve los números sin que cambie el código.** Otro recolector de cobertura lee unas líneas menos y el gate falla; otro medidor de complejidad cuenta distinto y el límite hay que traducirlo. Es un caso legítimo de re-medir la baseline, y por tanto de persona.
- **Una regla nueva vuelve a llenar la baseline.** La del analizador quedó vacía y al día siguiente tenía 29 entradas: se activó la detección de código muerto y se decidió conservar esos miembros. No es una regresión, pero tampoco puede hacerlo una PR de agente.
- **No todas las baselines obligan a limpiarse.** deptrac falla si una violación listada ya no ocurre, así que quien la arregla borra su línea. PHPStan, con `reportUnmatchedIgnoredErrors: false`, deja entradas rancias hasta que alguien regenera el fichero. Regenerar de vez en cuando es mantenimiento pendiente, no automático.
- **El artefacto caduca.** Si el push a `dev` no corrió CI o el artefacto expiró, el listón de CRAP y cobertura cae al fichero, que puede ir muy por detrás de la realidad. El check dice contra qué commit juzgó: míralo cuando una PR pase algo que no debería.
- **No pongas el gate delante del deploy.** `main` va por detrás de `dev`: una release fallaría contra un listón que `dev` ya bajó. El gate solo juzga PRs; los pushes solo miden.
- **Lo rápido en local no cubre todo.** `check --fast` omite CRAP y cobertura porque necesitan las suites (unos cuatro minutos). Un agente que solo corre lo rápido se encuentra el rojo en CI.
- **El informe local no es exactamente el de CI.** Ha diferido en unas pocas líneas del de CI, que usa otro driver de cobertura. El veredicto es el de CI.
- **El código muerto depende de qué cuentas como uso.** Los usos desde tests no cuentan, y el analizador tiene que leer el contenedor de servicios de producción: el de test hace públicos los servicios y esconde lo muerto.
- **Sin branch protection, un check rojo no impide el merge.** El gate informa; lo que lo hace cumplir es el bot que solo mergea en verde y la persona que revisa el resto.
- **Goodhart sigue ahí.** Lógica repartida en métodos privados para bajar la complejidad, tests sin asserts para subir la cobertura. El framework de tests configurado para fallar en tests que no comprueban nada tapa lo segundo; lo primero sigue siendo cosa de quien revisa.

## Variantes

- **Bajar la baseline a mano.** En un backend .NET el mismo patrón prescinde del paso 6: `./scripts/verify --update-baselines` reescribe los ficheros con lo medido y quien mejora algo los baja en su PR. Como ese flag también aceptaría una regresión, el CI compara el directorio de baselines de la PR con el de su base y falla si algo sube. Es mucho menos fontanería (ni artefactos ni medir la referencia) a cambio de que las mejoras no cuenten hasta que alguien actualiza. Encaja con menos PRs concurrentes. Dos diferencias más: la baseline de código muerto falla si un símbolo listado ya no está muerto, así que se limpia sola, y la cobertura lleva una tolerancia de 0,1 puntos porque algunas líneas de las suites de integración se alcanzan o no según el timing.
- **Sin fichero, solo contra la última medición de la rama de integración.** Siempre apretado e imposible de editar, pero no deja historia en git y el agente no puede comprobar nada en local sin CI. El paso 6 adopta la mitad: la medición aprieta, el fichero queda de suelo.
- **Plataforma alojada (SonarQube, Codecov y similares).** Da los informes hechos. Se descartó porque el agente necesita los números en local antes del push y porque envía el código a un tercero.

## Ejemplos

- **Un backend PHP/Symfony propietario (sin enlace).** Una semana en marcha. Arrancó con casi 2.500 errores del analizador en baseline y 41 métodos sobre el límite de complejidad; a los seis días, 37 métodos y la baseline del analizador vaciada, con 29 miembros muertos aceptados después al activar esa regla. Quedan 93 métodos sobre el límite de CRAP y un 44 % de cobertura de líneas.
- **Un backend .NET propietario (sin enlace).** La variante manual, adoptada una semana después con sus propias herramientas: 30 métodos listados por complejidad, 3 por CRAP, 7 símbolos muertos y un 94 % de cobertura de líneas como suelo.

## Recursos

- [PHPStan: The Baseline](https://phpstan.org/user-guide/baseline): el fichero de errores aceptados y `reportUnmatchedIgnoredErrors`.
- [deptrac](https://github.com/deptrac/deptrac): reglas de capas con baseline propia.
- [shipmonk/dead-code-detector](https://github.com/shipmonk-rnd/dead-code-detector): código muerto como errores de PHPStan.
- [Roslynator CLI](https://josefpihrt.github.io/docs/roslynator/cli/): `find-symbol --unused` para el código muerto en .NET.
- [Snapshot de contrato OpenAPI aceptado explícitamente](/patterns/snapshot-contrato-openapi/) y [DSM Snapshot](/patterns/dsm-snapshot/): el mismo principio de fichero versionado que solo cambia a conciencia, aplicado al contrato y a las dependencias.
- [Reglas de arquitectura como tests](/patterns/reglas-de-arquitectura-como-tests/): las reglas de capas cuyas excepciones vigila esta baseline.
- [Skill Verify](/patterns/skill-verify/): cómo sabe el agente qué comando correr antes de dar algo por hecho.
