---
title: "Comando de mantenimiento auto-descubierto"
description: "Tareas de mantenimiento (backfills, purgas, recálculos) como comandos individuales descubiertos por reflection, ejecutados sobre el mismo bootstrap de DI/config que la app real, sin levantar HTTP."
date: 2026-09-24
tags:
  - operations
  - dotnet
  - devex
maturity: adopt
---

## Problema

Tarde o temprano toda API necesita ejecutar una tarea de mantenimiento puntual: un backfill, recalcular una agregación, purgar registros huérfanos, deduplicar datos tras un bug. Esto suele degenerar en uno de dos extremos malos: SQL suelto ejecutado a mano contra producción, que se salta toda la lógica de dominio y las invariantes que la aplicación normalmente garantiza; o un programa aparte con su propio wiring de DI y configuración, que diverge del real con el tiempo (otra cadena de conexión, otras validaciones, otro `appsettings`). Además, si cada comando nuevo requiere registrarse a mano en una lista central, esa lista se olvida y queda desactualizada.

## Contexto

Aplica a cualquier API con un composition root no trivial (DI container, configuración por entorno, logging estructurado) que necesita ejecutar lógica de negocio real fuera del ciclo request/response — no solo leer o escribir filas, sino invocar los mismos servicios de dominio que la app usa para garantizar sus invariantes. Es especialmente relevante cuando la tarea necesita reutilizar servicios de aplicación ya existentes (un agregador, un motor de fusión de duplicados, un validador) en vez de reimplementar su lógica en un script.

## Solución

Dos piezas: un contrato mínimo para cada comando y un runner que reutiliza el bootstrap real de la app.

Cada comando es una clase que implementa una interfaz mínima (`IMaintenanceCommand` con un único `RunAsync(dryRun)` que devuelve el exit code) y se marca con un atributo (`[MaintenanceCommand("nombre-del-comando")]`). No hay que registrarlo en ningún sitio más: el runner descubre por reflection todas las clases del ensamblado que implementan la interfaz, lee su atributo para saber con qué nombre se invocan, y lanza un error explícito en el arranque si alguna implementa la interfaz sin atributo — así el olvido de "cablear" un comando nuevo es imposible, no solo improbable.

El runner (`dotnet Maintenance.dll <comando> [--dry-run]`) es un ejecutable standalone que se publica junto a la API pero no lo referencia. Su truco central: bootstrapea con el mismo `WebApplication.CreateBuilder` que usa `Program.cs` de la app real, y llama a la misma `AddInfrastructure(config)` — así toda la resolución de `appsettings.json` / `appsettings.<Environment>.json` / variables de entorno, y todo el wiring de DI, es idéntico al de producción. La diferencia es que nunca llama a `Run()`/`Start()`: `Build()` no levanta Kestrel por sí solo, así que no hay puerto, ni pipeline HTTP, ni auth — es un proceso aparte que se puede ejecutar tranquilamente contra un despliegue ya corriendo, no un segundo listener compitiendo por el mismo puerto.

El comando solo contiene lógica de negocio: recibe sus dependencias por constructor (resueltas del mismo container que la app), y decide qué hacer con el flag `--dry-run`. Todo lo demás — parsing de argumentos comunes, logging estructurado con las líneas canónicas de inicio/fin/duración, captura de excepción como fallo, flush del sink de logs antes de salir — vive una sola vez en el runner.

Ejemplo real (El Baúl, simplificado):

```csharp
// El comando: solo lógica de negocio.
[MaintenanceCommand("aggregate-user-activity")]
public class AggregateUserActivityCommand(
    IUserActivityDailyAggregator aggregator,
    MaintenanceCommandArguments arguments,
    ILogger<AggregateUserActivityCommand> logger) : IMaintenanceCommand
{
    public async Task<int> RunAsync(bool dryRun)
    {
        // ... parsea --from/--to de arguments, valida, y por cada fecha:
        if (dryRun)
        {
            logger.LogInformation("Would aggregate user activity for {Date}", date);
            continue;
        }
        await aggregator.AggregateForDateAsync(date);
        // ...
    }
}
```

```csharp
// El runner: descubre comandos, reutiliza el bootstrap real, ejecuta.
var builder = WebApplication.CreateBuilder(args); // misma config que la app real
builder.Services.AddInfrastructure(builder.Configuration); // mismo DI que la app real

foreach (var (name, type) in Commands.Value) // descubiertos por reflection + atributo
    builder.Services.AddKeyedScoped(typeof(IMaintenanceCommand), name, type);

await using var app = builder.Build(); // nunca Run()/Start(): sin Kestrel
using var scope = app.Services.CreateScope();

var command = (IMaintenanceCommand)scope.ServiceProvider
    .GetRequiredKeyedService(typeof(IMaintenanceCommand), commandName);
var exitCode = await command.RunAsync(dryRun);
```

El descubrimiento por reflection:

```csharp
private static List<(string Name, Type Type)> DiscoverCommands() =>
    typeof(MaintenanceCommandRunner).Assembly.GetTypes()
        .Where(t => t is { IsClass: true, IsAbstract: false } && typeof(IMaintenanceCommand).IsAssignableFrom(t))
        .Select(t => (Attribute: t.GetCustomAttribute<MaintenanceCommandAttribute>(), Type: t))
        .Select(x => x.Attribute is null
            ? throw new InvalidOperationException(
                $"{x.Type.Name} implementa {nameof(IMaintenanceCommand)} pero no tiene [{nameof(MaintenanceCommandAttribute)}]")
            : (x.Attribute.Name, x.Type))
        .ToList();
```

Un detalle práctico al montar esto: `WebApplicationBuilder.Build()` en Development valida por defecto que todo el grafo de dependencias registrado sea resoluble — una validación pensada para la app real, que registra su grafo completo. Si el runner registra deliberadamente un grafo más pequeño (solo lo que sus comandos necesitan), esa validación falla en falso. Hay que desactivarla explícitamente (`options.ValidateOnBuild = false`) para igualar el comportamiento que Production ya tiene por defecto.

El resultado: un comando de mantenimiento nuevo es "la app de verdad, ejecutando una ruta de código distinta" — misma config, mismo DI, mismas conexiones, mismas invariantes de dominio — en vez de un script paralelo que hay que mantener sincronizado a mano.
