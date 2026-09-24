---
title: "Host fino y módulos deep"
description: "Construir la aplicación como un host casi vacío al que se enchufan módulos con una interfaz narrow y una implementación deep, para que cada módulo se pueda diseñar, testear y validar como una pieza aislada — y para que una IA trabajando sobre un módulo no necesite ver el resto del sistema."
date: 2026-09-24
tags:
  - arquitectura
  - dotnet
  - modularidad
maturity: trial
---

## Problema

A medida que una aplicación crece, es fácil que todo acabe en un único proyecto (o en una pila de proyectos sin fronteras reales) donde cualquier clase puede llamar a cualquier otra. El resultado son dos problemas que se retroalimentan:

- **No se puede razonar ni testear una pieza en aislamiento.** Para validar la lógica de un caso de uso hace falta levantar medio sistema, porque nada impide que esa lógica dependa de detalles internos de otra parte de la aplicación.
- **Una IA (o una persona nueva) que trabaja sobre una funcionalidad concreta necesita cargar contexto de todo el sistema** para saber qué es seguro tocar y qué no, porque la superficie pública y la implementación interna son indistinguibles a simple vista.

Esto se agrava en aplicaciones con piezas muy distintas entre sí: un listener de webhooks, una API administrativa, lógica de negocio con jobs en background. Cada una tiene su propia complejidad interna, pero todas acaban compartiendo el mismo espacio de nombres sin fronteras que el compilador conozca.

## Solución

La idea central es la de **deep module** de John Ousterhout (*A Philosophy of Software Design*): un módulo útil tiene una interfaz pequeña (narrow) que esconde una implementación con mucha sustancia (deep). Cuanto más pequeña la interfaz en relación con lo que hay detrás, menos tiene que saber quien lo usa — y menos contexto necesita cargar quien trabaja *dentro* del módulo, porque el resto del sistema es invisible desde ahí.

La receta consiste en construir la aplicación como un **host finísimo** (un `Program.cs` que básicamente registra módulos y monta rutas, sin lógica propia) y añadir funcionalidad como **módulos independientes**, cada uno con:

- Una interfaz narrow: unos pocos tipos públicos — interfaces, DTOs, un delegate de evento — que son lo único que el host y el resto de módulos pueden ver.
- Una implementación deep: todo lo demás (persistencia, jobs, clientes HTTP, lógica de dominio) vive en clases `internal`, invisibles desde fuera del ensamblado.

### 1. Un ensamblado por módulo, con la implementación marcada `internal`

En .NET la frontera la da el ensamblado, no una convención de carpetas: cada módulo es su propio proyecto, y todo lo que no forma parte de la interfaz pública se declara `internal`. Esto no es una cuestión de estilo — es lo que fuerza que nada fuera del módulo pueda depender de su implementación, y por tanto que el módulo sea de verdad sustituible y testeable como pieza única. Cuando el módulo necesita exponer algo a sus propios tests, usa `InternalsVisibleTo` en vez de hacerlo público:

```csharp
// AssemblyInfo.cs de un módulo
using System.Runtime.CompilerServices;

[assembly: InternalsVisibleTo("Acme.Payments.ShopifyWebhooks.Tests")]
```

La interfaz pública de un módulo suele reducirse a esto — un delegate que representa el único punto de fuga de información del módulo hacia el host:

```csharp
namespace Acme.Payments.ShopifyWebhooks;

/// <summary>
/// Se dispara una vez, en tiempo real, para cada pedido que este módulo ha
/// filtrado como relevante. Es la única costura del módulo hacia el resto del
/// sistema: todo lo anterior (verificación HMAC, enrutado, parseo del payload,
/// el filtro de negocio) es invisible desde fuera de este ensamblado.
/// </summary>
public delegate void OrderUpdated(string shopDomain, long shopifyOrderId);
```

### 2. Dos métodos de extensión como interfaz de composición: `AddXxx` y `UseXxx`

Cada módulo expone su interfaz de arranque siguiendo la misma convención que usa ASP.NET Core internamente para sus propios subsistemas (por ejemplo `AddControllers()`/`UseRouting()`, o `AddAuthentication()`/`UseAuthentication()`): un método `AddXxx(IServiceCollection)` que registra los servicios del módulo en el contenedor DI, y un método `UseXxx(IEndpointRouteBuilder)` o `MapXxx(...)` que monta sus rutas en el pipeline HTTP. El host solo necesita conocer estos dos verbos por módulo — nunca los tipos internos que hay detrás.

```csharp
// Acme.Payments.ShopifyWebhooks.ShopifyWebhookServiceCollectionExtensions
public static class ShopifyWebhookServiceCollectionExtensions
{
    public static IServiceCollection AddShopifyWebhooks(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        services
            .AddOptions<ShopifyWebhookOptions>()
            .Bind(configuration.GetSection(ShopifyWebhookOptions.SectionName))
            .ValidateDataAnnotations()
            .ValidateOnStart();

        services.AddSingleton<ShopifyWebhookAuthenticator>();
        services.AddScoped<ShopifyWebhookIngestor>();

        return services;
    }
}

// Acme.Payments.ShopifyWebhooks.ShopifyWebhookEndpointRouteBuilderExtensions
public static class ShopifyWebhookEndpointRouteBuilderExtensions
{
    public static IEndpointRouteBuilder MapShopifyWebhooks(
        this IEndpointRouteBuilder endpoints,
        OrderUpdated onOrderUpdated,
        string basePath = "webhooks/shopify")
    {
        var group = endpoints.MapGroup(basePath);
        group.MapPost("/orders/create", Handler("orders/create", onOrderUpdated));
        // ...resto de rutas
        return endpoints;
    }
}
```

`ShopifyWebhookAuthenticator`, `ShopifyWebhookIngestor` y todo lo relacionado con el parseo del payload son `internal`: nadie fuera del módulo puede instanciarlos ni depender de ellos, aunque estén registrados en el contenedor DI del host.

El `Program.cs` del host, entonces, se reduce a una secuencia de llamadas a `AddXxx`/`UseXxx` de cada módulo — sin lógica de negocio propia:

```csharp
builder.Services.AddShopifyWebhooks(builder.Configuration);
builder.Services.AddAdminApi(builder.Configuration);
builder.Services.AddOrders(builder.Configuration, connectionString);
// ...

var app = builder.Build();
app.MapShopifyWebhooks(onOrderUpdated: (shop, orderId) => /* enlaza con el módulo Orders */);
app.UseAdminApi(basePath: "/admin");
```

### 3. Deja que la profundidad del módulo crezca sin miedo

Como la interfaz es narrow y está protegida por la visibilidad del ensamblado, el módulo puede volverse tan profundo como necesite sin que eso afecte a quien lo consume: persistencia con EF Core, jobs de background con Hangfire, lógica de dominio con varias colaboradoras internas. Todo eso es invisible desde el host, así que se puede rediseñar libremente por dentro sin romper a nadie.

```csharp
public static class OrdersServiceCollectionExtensions
{
    public static IServiceCollection AddOrders(
        this IServiceCollection services, IConfiguration configuration, string connectionString)
    {
        services.AddDbContext<OrdersDbContext>(/* ... */);

        services.AddScoped<IOrderQuery, OrderQuery>();
        services.AddScoped<IOrderMutation, OrderMutation>();
        services.AddScoped<ICreditAssessor, CreditLimitAssessor>();
        services.AddScoped<IReconcileOrderQueue, HangfireReconcileOrderQueue>();
        services.AddSingleton<PayLaterOrderScreen>();
        services.AddScoped<CreditDecisionEngine>();
        services.AddScoped<ReceivableOpener>();
        services.AddScoped<OrderReconciler>();
        services.AddScoped<ReconcileOrderJob>();       // job de Hangfire
        services.AddScoped<ReconciliationSweepJob>();  // job de Hangfire

        return services;
    }
}
```

De todas estas clases, solo `IOrderQuery`, `IOrderMutation` y algún DTO son públicos si otro módulo necesita leerlos; el resto (el motor de decisión de crédito, los jobs, la persistencia) es `internal` y solo el propio módulo lo conoce.

Una variante de este mismo patrón, para un módulo que expone endpoints HTTP propios en vez de (o además de) un evento, es montar sus controllers bajo una ruta que decide el host, manteniendo los controllers como parte de la interfaz pero el resto (autenticación, mappers, DbContext) interno:

```csharp
public static IServiceCollection AddAdminApi(this IServiceCollection services)
{
    services.AddControllers().AddApplicationPart(typeof(AdminApiServiceCollectionExtensions).Assembly);
    return services;
}

public static WebApplication UseAdminApi(this WebApplication app, string basePath)
{
    app.UseCors(AdminCorsServiceCollectionExtensions.AdminPolicy);
    app.UseAuthentication();
    app.UseAuthorization();
    app.MapGroup(basePath).MapControllers();
    return app;
}
```

Cómo saber que quedó bien aplicado: cada módulo es su propio proyecto, compila con casi todas sus clases `internal`, y el host solo referencia — por nombre, no por tipo — los dos o tres métodos de extensión de cada módulo. Si para cambiar algo dentro de un módulo hay que tocar el host, la interfaz se ha vuelto demasiado ancha.

**Beneficio no probado:** al quedar cada módulo aislado detrás de una interfaz narrow y sin dependencias internas hacia el resto del sistema, en teoría debería facilitar el trasplante completo de un módulo desde un host a otro — el movimiento típico al partir un monolito modular en microservicios. Esto no se ha validado todavía en la práctica; es una hipótesis derivada del diseño, no una experiencia real de migración.

## Gotcha: la testabilidad de la infraestructura de un módulo

Este patrón deja sin resolver un problema concreto: cuando otro host (por ejemplo uno "lite", en memoria, para tests end-to-end) necesita sustituir la infraestructura real de un módulo por un stand-in, no hay una forma limpia de hacerlo. Las implementaciones concretas son `internal`, así que ese host no puede reutilizarlas — tiene que reimplementar sus propios dobles de los mismos puertos públicos (`IOrderQuery`, `IReceivables`, etc.), duplicando lógica que ya existe como fake en los tests del propio módulo:

> *"Modelled on `AdminApi.Tests.Fakes.FakeOrderQuery` (not referenced directly — that type is `internal` to a test project, and a Docker-shipped project must never depend on a test project)."*

La alternativa que sí funciona hoy es que el propio módulo incluya, bundleado junto a su implementación real, un "stand-in" de sus puertos secundarios para cuando el proveedor real todavía no está integrado (por ejemplo, una implementación no-op de un puerto de notificación a un proveedor externo mientras dura el rollout), seleccionable por configuración en su propio `AddXxx`. Esto funciona porque el stand-in vive *dentro* del módulo, no fuera:

```csharp
internal sealed class StandInCollections(ILogger<StandInCollections> logger) : ICollections
{
    public Task<Result> OpenAsync(ReceivableForCollection receivable, CancellationToken ct)
    {
        logger.LogInformation("ReceivableHandedToCollections (stand-in); receivableId={Id}", receivable.ReceivableId);
        return Task.FromResult(Result.Success());
    }
}
```

Pero esto no resuelve el caso general: sustituir *toda* la infraestructura de un módulo (no solo un puerto puntual) por una versión en memoria, desde fuera del módulo, sigue exigiendo reimplementar dobles de la interfaz pública en cada sitio que lo necesite. Queda por explorar si combinar este patrón con una [arquitectura hexagonal (puertos y adaptadores)](/patterns/arquitectura-hexagonal-puertos-y-adaptadores/) dentro de cada módulo — separando explícitamente sus propios puertos secundarios en un sub-ensamblado que sí se pueda referenciar desde un host de test — daría una forma limpia de sustituir esa infraestructura sin duplicar fakes.

## Ejemplos

Usado en un repo propietario, sin enlace. El host se limita a registrar y montar módulos; entre los módulos hay un listener de webhooks de pedidos de Shopify (interfaz pública: un único delegate de evento), una API administrativa que monta sus propios controllers bajo una ruta que decide el host, y un módulo de lógica de negocio (gestión de pedidos y crédito) cuya implementación interna incluye varios jobs de Hangfire para reconciliación periódica.
