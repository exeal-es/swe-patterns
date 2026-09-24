---
title: "Snapshot de contrato OpenAPI aceptado explícitamente"
description: "El documento OpenAPI generado del código se versiona como snapshot aprobado; un test lo regenera y lo compara contra ese snapshot, y solo un comando explícito puede actualizarlo."
date: 2026-09-24
tags:
  - dotnet
  - testing
  - frontend
maturity: adopt
---

## Problema

Cuando el contrato HTTP de una API se genera automáticamente a partir del código (controladores, DTOs, atributos), nadie lo "escribe" a mano — y por eso nadie lo revisa a propósito tampoco. Un refactor interno que renombra un campo, cambia su tipo, o hace opcional algo que antes era obligatorio, cambia el contrato público como efecto secundario silencioso: compila, los tests unitarios pasan, y el PR se fusiona sin que nadie haya mirado el swagger. El consumidor de esa API (un frontend, otro servicio, un cliente externo) se entera cuando algo se rompe en producción, no en la revisión del cambio.

La causa no es que el contrato se genere del código — eso es correcto, es la única fuente de verdad real. El problema es que no hay ningún punto en el proceso donde ese contrato generado se compare contra "lo que se aprobó la última vez" y alguien tenga que decir explícitamente "sí, este cambio de contrato es intencionado".

## Contexto

Aparece en cualquier API con un contrato público generado a partir del código (OpenAPI/Swagger es el caso más común, pero el mismo problema lo tiene un contrato gRPC/protobuf, un schema GraphQL, o un contrato de eventos) que tiene consumidores que dependen de su forma exacta — un frontend con tipos generados a partir de ese contrato, otro equipo, un cliente externo. Se vuelve necesario en cuanto ese contrato deja de ser solo documentación y empieza a ser algo de lo que "cuelga" código real: tipos TypeScript generados (`schema.ts`), un cliente HTTP tipado, o simplemente la promesa hecha a un consumidor externo.

## Solución

El documento OpenAPI generado se versiona en el repo como un **snapshot aprobado** (`v1.swagger.json`). Un test automatizado, que corre en CI como cualquier otro test:

1. Levanta la aplicación (o solo el pipeline de controladores, sin base de datos ni auth) lo justo para generar el swagger actual en memoria.
2. Lo compara byte a byte contra el snapshot commiteado.
3. Si coinciden, pasa. Si no, falla — y deja el contrato recién generado en un fichero `.received.json` (git-ignored) al lado del snapshot, para que se pueda diffear con una herramienta normal.

El único modo de que el test vuelva a pasar es que alguien revise ese diff y decida explícitamente que el cambio es intencionado, ejecutando un comando dedicado (`accept-contract`) que regenera el snapshot commiteado a partir del contrato actual. Ese comando no existe para saltarse el test — existe para dejar constancia de que alguien lo aceptó, y el diff resultante del snapshot aparece en el PR como cualquier otro cambio de código, donde se revisa igual que se revisaría cualquier otro archivo.

Esto invierte la carga: en vez de que un cambio de contrato pase desapercibido por defecto y alguien tenga que darse cuenta activamente de que ocurrió, un cambio de contrato rompe el build por defecto y hace falta un acto consciente para dejarlo pasar.

## Implementación

Visto en dos repos .NET distintos, con la misma forma exacta — evidencia de que no es una idiosincrasia de un proyecto sino un patrón que emerge solo del mismo problema:

**El test de snapshot** (patrón común a ambos casos, con la forma vista en El Baúl):

```csharp
[Fact]
public async Task OpenApi_v1_matches_the_reviewed_contract_snapshot()
{
    var snapshotPath = Path.Combine(RepositoryRoot(), "api", "openapi", "v1.swagger.json");
    var receivedPath = Path.Combine(RepositoryRoot(), "api", "openapi", "v1.swagger.received.json");
    var currentContract = await GenerateOpenApiJsonAsync();

    if (Environment.GetEnvironmentVariable(UpdateSnapshotEnvironmentVariable) == "1")
    {
        Directory.CreateDirectory(Path.GetDirectoryName(snapshotPath)!);
        await File.WriteAllTextAsync(snapshotPath, currentContract);
        File.Delete(receivedPath);
        return;
    }

    Assert.True(File.Exists(snapshotPath), $"Missing OpenAPI snapshot at {snapshotPath}. ...");

    var approvedContract = await File.ReadAllTextAsync(snapshotPath);
    if (approvedContract == currentContract)
    {
        File.Delete(receivedPath);
        return;
    }

    await File.WriteAllTextAsync(receivedPath, currentContract);
    Assert.Fail(
        $"OpenAPI contract changed. Review the diff between {snapshotPath} and {receivedPath}; " +
        "if intentional, run: ./scripts/openapi accept-contract; ...");
}
```

El contrato se genera reflejando solo sobre los controladores, sin levantar base de datos ni auth real (El Baúl inicializa la infraestructura en memoria del patrón [API Lite](/patterns/api-lite) para esto; el segundo repo, propietario, construye directamente un `WebApplication` desnudo con solo los controladores montados) — lo que importa para el contrato es la forma de las rutas y los DTOs, no que la app funcione de verdad.

**El comando de aceptación**, en ambos repos un script `scripts/openapi` con un subcomando `accept-contract` que pone la variable de entorno que activa la rama de "regenerar" del test de arriba:

```bash
accept_contract() {
  need dotnet
  run env UPDATE_OPENAPI_SNAPSHOT=1 dotnet test "$ROOT_DIR/.../Tests.csproj" --configuration Release
}
```

En El Baúl, donde ya hay frontend, el mismo script tiene un segundo subcomando, `generate-types`, que corre `openapi-typescript` contra el snapshot ya aceptado para regenerar los tipos TypeScript crudos que consume el frontend (`app/src/api/generated/schema.ts`, varios miles de líneas, nunca editado a mano). El orden importa y está documentado: primero `accept-contract` (fija el nuevo contrato), luego `generate-types` (deriva los tipos de ese contrato ya aceptado) — así los tipos del frontend nunca se generan a partir de un contrato que nadie ha revisado todavía.

En el segundo repo (propietario, sin frontend aún) el mismo mecanismo existe sin ese segundo paso, con el comentario explícito en el propio script de que `generate-types` es lo próximo que hará falta "el mismo día que el admin panel exista, de la misma forma que ya lo hace el otro repo" — el patrón se adoptó completo (test + snapshot + comando de aceptación) antes incluso de que hubiera un consumidor real de los tipos generados, precisamente porque el problema que resuelve (contrato que se mueve solo) no depende de que exista ese consumidor.

## Alternativas

- **No versionar el contrato y confiar en la revisión de código del DTO/controlador cambiado**: funciona si quien revisa piensa activamente en "¿esto cambia el contrato público?", pero no hay ningún mecanismo que lo fuerce — es fácil que un cambio de forma se cuele en un PR grande centrado en otra cosa.
- **Publicar el contrato generado sin snapshot ni test** (solo servir `/swagger.json` en caliente): documenta el estado actual, pero no da ninguna señal de que el contrato cambió respecto a antes, ni obliga a nadie a mirarlo.
- **Versionado semántico manual de la API** (anunciar "v2" a mano cuando se decide romper compatibilidad): resuelve el problema de comunicar el cambio a consumidores externos, pero no el de detectar que un cambio de contrato ocurrió en primer lugar — sigue dependiendo de que alguien se dé cuenta sin ayuda de una herramienta.
