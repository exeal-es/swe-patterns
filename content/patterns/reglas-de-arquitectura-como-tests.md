---
title: "Reglas de arquitectura como tests"
description: "Las reglas de arquitectura que solo viven en un documento se erosionan PR a PR, y un agente que trabaja dentro de una funcionalidad las rompe sin que nada falle, porque todo compila y los tests pasan. La solución escribe cada regla como un test que inspecciona el código compilado y devuelve la lista de violaciones, con su propio check en CI, un mensaje que dice cómo arreglarlo y unas excepciones que solo pueden encoger."
date: 2026-11-12
tags:
  - arquitectura
  - testing
  - agentes
  - dotnet
maturity: trial
---

## Problema

«El dominio no conoce la base de datos», «un controlador no toca el repositorio», «de un módulo solo es público lo que hay en su raíz». Son decisiones tomadas, a menudo escritas en un ADR, y ninguna la conoce el compilador cuando todo vive en el mismo proyecto o cuando la referencia entre proyectos es legal en un sentido y no en otro.

Lo que las rompe es el camino corto. Quien implementa una funcionalidad inyecta el `DbContext` en una clase de dominio, hace público un tipo para usarlo desde otro módulo o abre un setter porque así el test se escribe antes. Compila, los tests pasan y el cambio hace lo que se pedía. La única barrera es que alguien lo vea en la revisión.

Con agentes esa barrera no aguanta. El agente no ha leído el ADR en el momento en que importa, la instrucción «sigue las convenciones» en `CLAUDE.md` es una sugerencia, y quien revisa decenas de PRs a la semana no reconstruye el grafo de dependencias en cada una. La erosión se descubre meses después, al intentar extraer un módulo.

Hay un segundo caso: la regla se decide hoy sobre un código que ya la incumple en cien sitios. Si no se puede exigir hasta arreglarlos todos, no se exige nunca.

## Solución

Cada regla que importa se escribe como un test que inspecciona el código compilado, devuelve la lista de violaciones y espera que esté vacía. La regla deja de ser un párrafo que alguien tiene que recordar y pasa a ser un check que falla, con nombre propio en CI.

La receta es la de un monolito modular en .NET donde cada módulo es un ensamblado con su raíz pública, `Domain/` e `Infra/`. Donde el compilador puede hacer el trabajo (proyectos separados, `internal`), que lo haga él: los tests cubren lo que no alcanza.

### 1. Una regla es una función que devuelve violaciones

Los helpers viven en el proyecto de soporte de tests que comparten todos los módulos. Cada uno devuelve una lista ordenada de cadenas, una por violación:

```csharp
public static class ModuleLayering
{
    /// <summary>The frameworks a module's domain never names; adapters in Infra/ do.</summary>
    public static IReadOnlyList<string> InfrastructureNamespaces { get; } =
        ["Microsoft.EntityFrameworkCore", "Npgsql", "Hangfire", "System.Net.Http"];

    public static IReadOnlyList<string> DomainViolations(Assembly module)
    {
        var root = module.GetName().Name!;
        return Violations(module, $"{root}.Domain", [$"{root}.Infra", .. InfrastructureNamespaces]);
    }

    public static IReadOnlyList<string> Violations(
        Assembly assembly, string fromNamespace, IEnumerable<string> forbiddenNamespaces)
    {
        var forbidden = forbiddenNamespaces.ToList();
        return assembly.GetTypes()
            .Where(type => IsIn(type, fromNamespace))
            .SelectMany(type => TypeDependencies.Of(type)
                .Where(dependency => forbidden.Any(ns => IsIn(dependency, ns)))
                .Select(dependency => $"{type.FullName} -> {dependency.FullName}"))
            .Distinct().Order(StringComparer.Ordinal).ToList();
    }
}
```

Y el test de cada módulo es una línea:

```csharp
[Trait("Category", "Architecture")]
public sealed class LayeringTests
{
    [Fact]
    public void The_domain_depends_neither_on_infra_nor_on_infrastructure_frameworks() =>
        ModuleLayering.DomainViolations(typeof(Order).Assembly).Should().BeEmpty();
}
```

Cuando falla, la salida es la lista completa de pares `Tipo -> TipoProhibido`, no el primero que encontró.

`TypeDependencies.Of` es la pieza que hace fiable todo lo demás: los tipos que un tipo nombra en su base, interfaces, campos, propiedades y firmas, **y en el IL de sus métodos**. Sin lo segundo, un `new HttpClient()` dentro de un método no aparece en ninguna firma y la regla pasa. Son unas cien líneas de reflexión: recorrer `GetILAsByteArray()`, resolver cada token con `Module.ResolveMember` y aplanar genéricos, para que `Task<IEnumerable<T>>` cuente como una dependencia de `T`. Las lambdas y los métodos `async` no necesitan caso aparte: el compilador los convierte en tipos anidados y salen al recorrer los tipos del ensamblado.

### 2. Elige las reglas que el compilador no ve

Merece test la decisión cuya violación compila y pasa los demás tests. Las de esta receta:

| Regla | Qué mira el test |
|---|---|
| `Domain/` no nombra `Infra/` ni frameworks de infraestructura | Dependencias de tipos, por namespace |
| La superficie pública del módulo es una lista aprobada | `GetExportedTypes()` contra un array |
| Nada fuera de una clase de dominio cambia su estado | Propiedades con setter no privado |
| Un edge de webhook solo referencia el framework compartido | Ensamblados referenciados |
| Solo una clase escribe en el almacén de pedidos | Qué tipos reciben el puerto en su constructor |
| La suite de caja negra no compila contra el código que prueba | El `.csproj` y los ensamblados referenciados |
| Las suites de aceptación de módulo no nombran tipos internos | Dependencias de tipos |

No todo lo que suena a arquitectura va aquí. «El tiempo y los ids salen del `TimeProvider`» es una lista de APIs prohibidas en un analyzer, que marca la línea exacta en el editor. Y las reglas sobre comportamiento (qué pasa cuando un módulo llama a otro) las fijan las suites de aceptación del módulo.

Cada regla tiene un identificador en el documento de convenciones y el test lo cita (`rule M2, docs/architecture/modules.md`). Documento y check se señalan el uno al otro.

### 3. La superficie pública es una lista aprobada

```csharp
[Trait("Category", "Architecture")]
public sealed class PublicSurfaceTests
{
    private static readonly string[] Approved =
    [
        "IOrderQuery",
        "OrderPage",
        "OrderStatus",
        "OrderView",
        "OrdersServiceCollectionExtensions",
    ];

    [Fact]
    public void Only_the_approved_types_are_public() =>
        PublicSurface.Unapproved(typeof(IOrderQuery).Assembly, Approved).Should().BeEmpty();
}
```

`Unapproved` devuelve `added: X` por cada tipo público que no está en la lista y `removed: X` por cada aprobado que ya no lo es. Hacer público un tipo deja de ser un modificador que nadie mira y pasa a ser una línea más en un array, en el diff. Es el mismo principio que un [snapshot de contrato OpenAPI](/patterns/snapshot-contrato-openapi/), aplicado a la API interna del módulo.

Los nombres van relativos a la raíz, así que un tipo que se escapa de `Domain/` se lee `added: Domain.Algo`.

### 4. Las excepciones son una lista dentro del test, y solo encoge

La regla nueva que el código ya incumple no espera a que esté todo arreglado. Se activa con las infracciones de hoy apuntadas:

```csharp
/// <summary>
/// The open setters the rule found when it was written. This list only shrinks:
/// closing a setter deletes its line.
/// </summary>
private static readonly string[] Remaining =
[
    "Acme.Orders.Domain.OrderIntake.Currency",
    "Acme.Orders.Domain.OrderIntake.Status",
    "Acme.Orders.Domain.OrderIntake.Total",
    // … 14 más
];

[Fact]
public void Nothing_outside_a_domain_class_sets_its_state_but_what_is_still_listed() =>
    AggregateEncapsulation.OpenSetters(typeof(Order).Assembly).Should().Equal(Remaining);
```

La comparación es por igualdad, no por inclusión. Un setter nuevo falla, y uno arreglado que sigue en la lista también: quien lo cierra borra su línea, así que la lista nunca miente.

Lo mismo sirve con recuentos cuando la unidad es un fichero. La suite de caja negra lleva un diccionario `fichero → número de esperas con reloj real` (`Task.Delay`, `Thread.Sleep`) que solo puede bajar.

Estas listas son una [baseline que solo encoge](/patterns/baseline-de-calidad-que-solo-encoge/) y necesitan lo mismo que cualquier otra: que quien abre la PR no pueda ampliarlas por su cuenta. Vivir dentro del test ayuda, porque añadir una excepción es un diff de una línea junto a la regla. Para que además no se mergee sin que nadie lo vea, los ficheros de estos tests tienen que estar entre las rutas que exigen revisión humana. La variante en PHP ya lo hace; en esta receta todavía depende de quien revisa.

### 5. El fallo le dice al agente qué hacer

El agente que rompe la regla va a leer el test que falla; es el único sitio donde seguro que lee la norma. Así que el test dice qué arreglo se espera y cuál no:

```csharp
/// Pins the module's layering (rule M2, docs/architecture/modules.md) […]
/// A failure here is the prompt to put a port in Domain/ for the adapter to implement,
/// not to move the rule.
```

```csharp
/// A failure here is the prompt to apply the rule — make the new writer a step of the pass,
/// or have it take the lease — not to widen the list.
```

El nombre del test es la regla en una frase, y cuando la aserción admite un porqué, va ahí.

### 6. Suite propia y check propio

Todas las clases llevan `[Trait("Category", "Architecture")]`. Un comando las corre solas, en segundos y sin Docker, y las suites de unit e integración las excluyen por el mismo trait:

```bash
architecture() {
  # Only the projects that hold a rule: a test module with no test left by the filter fails
  # (zero tests ran).
  local projects=() proj
  while IFS= read -r -d '' proj; do
    grep -rqs --include='*.cs' 'Trait("Category", "Architecture")' "$(dirname "$proj")" && projects+=("$proj")
  done < <(discover_projects "Tests"; discover_projects "AcceptanceTests")
  restore_and_build_backend
  test_module_args=(--filter-trait "Category=Architecture")
  run_test_projects architecture "$(getconf _NPROCESSORS_ONLN)" "${projects[@]}"
}
```

En CI es un job en paralelo con los de tests, con su propio check. Un `architecture` en rojo dice qué tipo de cosa se rompió antes de abrir ningún log, y el deploy lo espera como a los demás.

### Gotchas

- **Las firmas no bastan.** Una dependencia que solo aparece en el cuerpo de un método es invisible sin leer el IL. Si la regla se escribe solo con reflexión sobre miembros, pasa en verde justo en el caso más común.
- **Un test sin el trait no se pierde, pero tampoco está en el check.** Sigue corriendo en su suite de unit. La clase de una regla nueva tiene que llevar el trait para aparecer donde se la espera.
- **Filtrar por trait deja proyectos con cero tests, y eso falla.** Por eso el comando selecciona antes los proyectos que contienen alguna regla.
- **No toda clase con setters es un agregado.** La regla de encapsulación deja fuera los records (su `init` es cómo funciona `with`), las clases `*Options` (las rellena el binding de configuración) y los tipos generados por el compilador. Sin esas exclusiones la lista de excepciones nace llena de ruido.
- **El código generado es público por defecto.** El ORM genera las migraciones como `public`; se hacen `internal` y la que se olvide aparece como `added: Infra.Persistence.Migrations.…` en el test de superficie.
- **«Un solo escritor» comprobado por constructor solo ve constructores.** El test fija qué tipos reciben el puerto por inyección. La garantía vale lo que vale esa lista: quien obtuviera la dependencia por otra vía no saldría.
- **Una regla que mira el código fuente se encuentra a sí misma.** El test que cuenta `Task.Delay` con una expresión regular tiene que excluir su propio fichero.

## Variantes

- **Herramienta declarativa más reglas del analizador estático.** En PHP no hay ensamblado sobre el que reflexionar, y las capas de un código legacy se definen por convenciones de namespace. Ahí la receta se reparte en tres:
  - [deptrac](https://github.com/deptrac/deptrac) para las capas, como lista blanca de a qué puede apuntar cada una, con su baseline de pares de clases:

    ```yaml
    ruleset:
      EntryPoint: [FrameworkEdge, Application, ApplicationPort, ApiClient, Entity, Message]
      Application: [ApplicationPort, ApiClient, Repository, Entity, Message, Persistence]
      ApiClient: [ApplicationPort, Message, VendorHttp]
      Repository: [Entity, Persistence]
      Entity: [Repository]
    ```

  - Reglas propias de PHPStan para lo que un grafo de dependencias no expresa. deptrac solo ve que una clase nombra a otra: un controlador que ya nombraba un repositorio puede añadir diez consultas más sin que cambie nada. La regla del analizador cuenta cada llamada, y su error lleva la instrucción y el ADR: `An entry point does not call EntityManager::flush(): a use case or a service reaches the data (ADR-006)`.
  - Un test normal para lo que cruza ficheros que no son código: cada comando del crontab tiene que vivir en el namespace de crons, con una lista de excepciones que solo encoge.

  Dos cosas que esta variante hace y la receta no. **Las reglas tienen tests**: cada una se ejecuta contra clases de ejemplo, una que la rompe y otra que la cumple, y cambiar una regla cambia su test en el mismo commit. Y como el analizador no sabe ejecutar solo algunas reglas, el job de arquitectura corre el análisis entero y juzga únicamente los errores cuyo identificador lleva el prefijo del proyecto; el resto son del job de análisis estático.
- **Librería de tests de arquitectura.** Con [ArchUnitNET](https://github.com/TNG/ArchUnitNET) las reglas de dependencias entre namespaces se declaran en una API fluida (`Types().That().Are(InputPorts).Should().NotDependOnAny(OutputPorts)`) y no hay que escribir el recorrido del IL. Es la opción corta cuando todas las reglas son de ese tipo, como en la [arquitectura hexagonal](/patterns/arquitectura-hexagonal-puertos-y-adaptadores/). En la receta, varias reglas no son de dependencias entre namespaces (superficie pública, setters, constructores, el `.csproj`), y el helper propio para las que sí lo son ocupa cien líneas.
- **Snapshot del grafo en vez de reglas.** Cuando no hay una regla que enunciar pero quieres que cualquier arista nueva entre módulos pase por una aprobación, un [DSM Snapshot](/patterns/dsm-snapshot/) versiona la matriz entera. Las dos cosas conviven: el snapshot enseña lo que cambia, la regla prohíbe lo que ya sabes que no quieres.

## Ejemplos

- **Un backend .NET propietario (sin enlace).** Una veintena de clases de reglas repartidas en siete módulos, las primeras desde finales de septiembre: capas, superficie pública y encapsulación en cuatro módulos de dominio, y tres edges de webhook autocontenidos. Quedan 17 setters listados de una sola clase.
- **Un backend PHP/Symfony propietario (sin enlace).** La variante declarativa: capas con deptrac, cinco reglas propias del analizador y el test del crontab. Al escribir las reglas el código tenía 403 llamadas a persistencia y a entidades desde los puntos de entrada, en 100 ficheros, y 129 pares de clases en la baseline de capas. Se arreglaron todas esa semana y la baseline de capas está vacía.
- **[El Baúl](https://github.com/ne2-studio/el-baul)**: `api/ElBaul.Core/Tests/ArchitectureTests.cs`, con ArchUnitNET. Puertos de entrada y de salida disjuntos, y `Domain` como capa más interna.

## Recursos

- [ArchUnitNET](https://github.com/TNG/ArchUnitNET): tests de arquitectura declarativos para .NET.
- [deptrac](https://github.com/deptrac/deptrac): capas y reglas de dependencia para PHP.
- [PHPStan: Custom Rules](https://phpstan.org/developing-extensions/rules): cómo escribir y testear una regla propia.
- [Baseline de calidad que solo encoge](/patterns/baseline-de-calidad-que-solo-encoge/): cómo impedir que las listas de excepciones crezcan.
- [Host fino y módulos deep](/patterns/host-fino-y-modulos-deep/): la forma de módulo que estas reglas protegen.
- [DSM Snapshot](/patterns/dsm-snapshot/): el grafo de dependencias entero como snapshot aprobado.
