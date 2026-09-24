---
title: "DSM Snapshot"
description: "Versionar la matriz de dependencias entre módulos como snapshot aprobado, para que cualquier acoplamiento nuevo o en dirección prohibida falle el build hasta que alguien lo revise conscientemente."
date: 2026-09-24
tags:
  - arquitectura
  - testing
maturity: adopt
---

## Problema

En cualquier arquitectura modular (features, bounded contexts, capas) el acoplamiento interno se degrada con el tiempo sin que nadie lo note. Un import "de conveniencia" cruza una frontera que el diagrama de arquitectura dice que no debería cruzarse, o convierte una dependencia unidireccional en un ciclo. Nada lo impide técnicamente — el compilador no sabe que "Feed no debería depender de Chat" — así que solo lo frena la memoria y la disciplina del equipo, que no escalan. El resultado se descubre meses después, en una auditoría o cuando alguien intenta extraer un módulo y se encuentra un grafo de dependencias mucho más enredado de lo que el diagrama sugería.

Esto aparece en cualquier codebase con módulos que se supone deben respetar ciertas fronteras de dependencia — features de una modular monolith, capas de una arquitectura hexagonal, bounded contexts — pero donde esas fronteras son solo convención o documentación, no algo que el compilador fuerce (a diferencia de una separación en proyectos/ensamblados distintos con visibilidad restringida, que si el lenguaje la ofrece sí actúa como frontera dura). Es el caso típico de namespaces dentro del mismo proyecto: `ElBaul.Core.Bauls` y `ElBaul.Core.Feed` compilan igual de bien se importen en la dirección que se importen, así que nada evita que una nueva dependencia se cuele sin que nadie la valore.

## Solución

Generar automáticamente una DSM (Design Structure Matrix: filas y columnas son los módulos, cada celda dice si el módulo fila depende del módulo columna) a partir del código real, versionarla como snapshot aprobado, y comparar esa matriz contra el snapshot en un test. Si el grafo de dependencias cambió — una arista nueva entre dos módulos antes desacoplados, un ciclo nuevo, un ciclo que crece — el test falla hasta que alguien revisa el diff y decide explícitamente si aprobarlo. Es el mismo principio que un snapshot de contrato OpenAPI, pero aplicado a la arquitectura interna en vez de al contrato HTTP externo: la arquitectura declarada no es solo aspiracional, se verifica en cada build.

Nótese la diferencia con una frontera de módulo forzada por el compilador (proyectos separados, `InternalsVisibleTo`, etc.): el DSM no impide que una dependencia nueva compile. Es una red de seguridad para las fronteras que el compilador no puede forzar — dependencias dentro del mismo proyecto/ensamblado, o entre módulos que sí pueden referenciarse pero solo en ciertas direcciones. No bloquea, hace visible y exige aprobación consciente.

En El Baúl esto vive en tres piezas que se generan juntas a partir del mismo grafo, para que nunca diverjan entre sí:

1. **Un generador** (`DsmGenerator.cs`) que escanea el código fuente de `ElBaul.Core` con una regex simple sobre `namespace ElBaul.Core.X` y `using ElBaul.Core.X(.Application|.OutputPorts)?;`, construye el grafo de dependencias entre features, y calcula sus componentes fuertemente conexas (Tarjan) para detectar ciclos. Deliberadamente no es una compilación Roslyn real — es una aproximación rápida y sin dependencias que basta mientras el estilo del código sea "un namespace por fichero, sin global usings, sin referencias por FQN in place"; el propio comentario del código documenta que si eso cambia, empezará a infracontar aristas silenciosamente. Es una elección consciente de mantenerlo simple y sin dependencia de un compilador real, a cambio de ese límite conocido.
2. **Un snapshot aprobado** (`CoreDsm.snapshot.json`), serialización determinista del grafo (features, aristas con su tipo — `Public` si importa solo la API pública del feature, `Deep` si importa `.Application`/`.OutputPorts` ajenos —, y grupos cíclicos).
3. **Un test de aprobación** (`DsmApprovalTests.cs`) que regenera el grafo actual, lo compara byte a byte contra el snapshot y falla si difieren, escribiendo el grafo actual a un `.received.json` para poder diffearlo contra el aprobado — el mismo patrón que un test de aprobación de snapshot cualquiera.

```csharp
[Fact]
public void CoreDependencyGraph_MatchesApprovedSnapshot()
{
    var dsm = DsmGenerator.Generate();
    var currentJson = DsmGenerator.ToJson(dsm);

    var approvedJson = File.ReadAllText(snapshotPath);
    if (approvedJson == currentJson)
    {
        File.Delete(receivedPath);
        return;
    }

    File.WriteAllText(receivedPath, currentJson);
    Assert.Fail(
        $"ElBaul.Core's cross-feature dependency graph changed. Review the diff between {snapshotPath} and " +
        $"{receivedPath}; if intentional, run: ./scripts/dsm approve.");
}
```

Cuando el test falla, el flujo es: mirar el diff entre `CoreDsm.snapshot.json` y `CoreDsm.received.json`, decidir si la arista nueva es deliberada y está justificada (o si reduce ciclos/imports profundos, mejor aún), y si es así correr `./scripts/dsm approve` — que regenera **a la vez** el snapshot y `docs/architecture/core-dsm.md` (una tabla Markdown legible con `●` para deep import, `○` para import público, casilla vacía si no hay dependencia) desde el mismo grafo, para que doc y snapshot no puedan divergir entre sí: si el doc se regenerase a mano por separado, con el tiempo dejaría de coincidir con el snapshot y mentiría sobre la arquitectura real.

El coste de aprobar es deliberadamente alto: no hay un flag de "aceptar automáticamente", `./scripts/dsm approve` exige haber corrido el test, visto el fallo y revisado el diff primero. El propio docstring del test es explícito: "never approve just to silence the test" — aprobar sin revisar el diff destruye el propósito del patrón.

## Variantes

- **Confiar en revisión de código y disciplina del equipo**: no escala, y una dependencia nueva entre módulos no siempre salta a la vista en un diff que toca un solo fichero.
- **Análisis de arquitectura en CI que solo alerta (linter de arquitectura sin snapshot)**: detecta violaciones contra una regla fija, pero no captura que el grafo entero cambió de forma; un snapshot versionado además sirve como documentación viva del estado real, no solo de las reglas.
- **Separar módulos en proyectos/ensamblados distintos**: es una frontera más fuerte (el compilador la fuerza), pero no siempre es viable — reorganizar un monolito modular en proyectos separados es un cambio estructural caro, y no cubre direcciones de dependencia permitidas-pero-restringidas entre módulos que sí pueden referenciarse.

## Ejemplos

- **[El Baúl](https://github.com/ne2-studio/el-baul)**: `scripts/dsm`, `api/ElBaul.Core/Tests/DsmGenerator.cs`, `DsmApprovalTests.cs` y `docs/architecture/core-dsm.md`. La matriz actual documenta explícitamente que el grafo de features **no** es acíclico (hay un grupo cíclico entre Bauls, Chapters, Personas, Photos y Recuerdos) — el patrón no obliga a que la arquitectura sea perfecta, obliga a que cualquier cambio en esa imperfección sea visible y aprobado, no silencioso.
