---
title: "Tests de persistencia del repositorio real"
description: "Cuando la lógica de negocio se testea contra un repositorio fake en memoria, la implementación real (SQL, EF Core) puede quedar sin probar — queries que no traducen bien, constraints que el fake no reproduce. La solución es un puñado de tests que ejercitan esa implementación real contra un Postgres real con Testcontainers."
date: 2026-09-24
tags:
  - testing
  - testcontainers
  - dotnet
maturity: adopt
---

## Problema

Con el patrón Repositorio, la lógica de negocio se testea contra una implementación fake en memoria del repositorio: rápida, sin dependencias externas, perfecta para cubrir reglas de negocio con muchos casos. El problema es que esos tests solo prueban la lógica de negocio — nunca ejercitan la implementación real del repositorio, la que de verdad habla con la base de datos en producción.

Eso deja un hueco concreto: una query LINQ que EF Core no puede traducir a SQL y falla en tiempo de ejecución, un `GroupBy`/`Join`/`Distinct` que en memoria cuenta bien porque ejecuta el mismo predicado C# pero en SQL agrupa distinto, una constraint única que en producción vive en el esquema de la base de datos pero que el fake in-memory no reproduce porque no impone ninguna unicidad, una condición de carrera que solo se resuelve con un `INSERT ... ON CONFLICT` real. Nada de esto puede fallar en un test contra el fake, porque el fake y la implementación real solo comparten la interfaz — su comportamiento interno es completamente distinto. El fake existe justamente para no pagar el coste de hablar con una base de datos real en cada test de negocio, así que por construcción no puede detectar estos fallos.

El síntoma aparece siempre igual: la suite de negocio está en verde, la review pasa, y el fallo se descubre en producción o en el mejor de los casos en un smoke test de aceptación mucho más caro y mucho más tarde en el pipeline. Aparece en cualquier proyecto que use el patrón Repositorio con una implementación fake para testear lógica de negocio — que es la inmensa mayoría de los proyectos que se toman en serio separar dominio de infraestructura — y se vuelve crítico en cuanto la implementación real empieza a apoyarse en queries no triviales (agregaciones, joins) o en garantías que solo existen a nivel de esquema (constraints, índices únicos).

## Solución

Un conjunto de tests específico para la implementación real del repositorio, que la ejercita contra un Postgres real levantado con Testcontainers en vez de contra el motor de base de datos de producción compartido o mockeado. No repite la suite de negocio — solo prueba lo que el fake no puede: que la traducción a SQL es correcta y que el esquema real (constraints, índices, migraciones) se comporta como se espera.

1. **Créalo como un proyecto de tests aparte**, dedicado solo a la implementación real de persistencia, distinto del proyecto de tests de negocio. Documenta explícitamente en un README o comentario por qué existe, para que nadie lo confunda con una segunda copia de la suite de dominio: no testea reglas de negocio, testea el adaptador SQL.

2. **Levanta un Postgres real con Testcontainers, compartido por toda la colección de tests** (no un contenedor por test — es caro) y corre las mismas migraciones que se usan en producción, para que el esquema bajo test sea idéntico al real:

```csharp
public sealed class PostgresFixture : IAsyncLifetime
{
    private PostgreSqlContainer _container = null!;

    public async Task InitializeAsync()
    {
        _container = new PostgreSqlBuilder("postgres:16")
            .WithDatabase("persistence_tests")
            .WithUsername("app").WithPassword("app")
            .Build();
        await _container.StartAsync();

        _options = new DbContextOptionsBuilder<AppDbContext>()
            .UseNpgsql(_container.GetConnectionString())
            .Options;

        await using var dbContext = CreateDbContext();
        await dbContext.Database.MigrateAsync();
    }

    public async Task ResetAsync() { /* TRUNCATE ... RESTART IDENTITY CASCADE por test */ }
}
```

3. **Aísla el estado entre tests con un `TRUNCATE` en vez de reiniciar el contenedor.** Arrancar un contenedor de Postgres nuevo por test es lento; truncar las tablas relevantes al principio o al final de cada test mantiene la suite rápida sin perder aislamiento.

4. **Escribe solo los tests que el fake no puede sustituir**, no una cobertura exhaustiva del repositorio entero:
   - Queries con agregaciones o traducción no trivial (`GroupBy`, `Join`, `Distinct`, propiedades computadas) que el ORM tiene que traducir a SQL correctamente.
   - Constraints y comportamiento real del esquema: unicidad, foreign keys, upserts resueltos con `ON CONFLICT`.

```csharp
[Collection(PersistenceTestCollection.Name)]
public class RaceSafeUpsertTests(PostgresFixture fixture) : PersistenceTestBase(fixture)
{
    [Fact]
    public async Task Concurrent_upserts_respect_the_unique_constraint()
    {
        // un índice único real y un ON CONFLICT DO UPDATE/DO NOTHING:
        // exactamente lo que un fake in-memory, sin unicidad, no puede reproducir.
    }
}
```

5. **Corre esta suite en CI en paralelo a la de negocio**, no como sustituto — ambas son necesarias, cada una cubre un riesgo distinto y a un coste distinto.

Se sabe que está bien aplicado cuando esta suite solo contiene tests que fallarían de verdad si la traducción SQL o el esquema real se rompieran, y que el fake in-memory no podría detectar por diseño; si un test aquí pasaría igual contra el fake, probablemente pertenece a la suite de negocio, no a esta.

## Variantes

- **Suite de contrato compartida entre fake e implementación real**, en vez de una suite separada solo para el repositorio real: se define una única batería de escenarios contra una interfaz común, y tanto el fake como la implementación real (con `PostgresFixture`) la ejecutan como consumidores:

```csharp
// escenario compartido, agnóstico de la implementación
public static async Task Photo_list_filters_orders_and_counts_recuerdos(
    IListReadModelContractStore store) { /* ... */ }

// consumidor real, contra Postgres
[Fact]
public async Task Photo_list_filters_orders_and_counts_recuerdos()
{
    await using var dbContext = Fixture.CreateDbContext();
    await ListReadModelContractScenarios.Photo_list_filters_orders_and_counts_recuerdos(new EfStore(dbContext));
}
```

  Esto garantiza, por construcción, que fake e implementación real cumplen exactamente el mismo contrato observable — no solo la misma interfaz de tipos, sino el mismo comportamiento ante los mismos escenarios. Compensa cuando el repositorio expone comportamiento de lectura complejo (filtros, orden, paginación, conteos) que es fácil implementar de forma sutilmente distinta en el fake y en la query SQL; para repositorios simples de CRUD, una suite separada solo para lo que el fake no puede reproducir (constraints, traducción SQL) es más simple y suficiente.

## Ejemplos

- **[El Baúl](https://github.com/ne2-studio/el-baul)**: usa ambas variantes a la vez. Un proyecto `ElBaul.Infra/PersistenceTests` dedicado solo a lo que el fake in-memory no puede reproducir (traducción LINQ→SQL en agregaciones, constraints únicas resueltas con `ON CONFLICT`), con un `PostgresFixture` compartido por colección; y una suite de contrato (`ElBaul.ReadModelContractTests`) con escenarios agnósticos de la implementación, ejecutados tanto contra los repositorios fake in-memory como contra los repositorios EF Core reales sobre ese mismo `PostgresFixture`.
