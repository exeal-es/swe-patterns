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

Aparece en cualquier API con un contrato público generado a partir del código (OpenAPI/Swagger es el caso más común, pero el mismo problema lo tiene un contrato gRPC/protobuf, un schema GraphQL, o un contrato de eventos) que tiene consumidores que dependen de su forma exacta — un frontend con tipos generados a partir de ese contrato, otro equipo, un cliente externo. Se vuelve necesario en cuanto ese contrato deja de ser solo documentación y empieza a ser algo de lo que "cuelga" código real: tipos TypeScript generados (`schema.ts`), un cliente HTTP tipado, o simplemente la promesa hecha a un consumidor externo.

## Solución

El documento OpenAPI generado se versiona en el repo como un **snapshot aprobado** (`v1.swagger.json`). Un test automatizado lo regenera y lo compara byte a byte contra ese snapshot; si difieren, el test falla y el único modo de que vuelva a pasar es que alguien revise el diff y lo acepte explícitamente con un comando dedicado.

1. **Versiona el contrato generado como fichero commiteado** (`api/openapi/v1.swagger.json`), no como algo que solo se sirve en caliente desde `/swagger.json`.

2. **Escribe un test que regenera el contrato y lo compara contra el snapshot**, corriendo en CI como cualquier otro test. Genera el contrato reflejando solo sobre los controladores, sin levantar base de datos ni auth real — para el contrato solo importa la forma de las rutas y los DTOs, no que la app funcione de verdad (por ejemplo, montando un `WebApplication` desnudo con solo los controladores, o usando la infraestructura en memoria del patrón [API Lite](/patterns/api-lite)). Si coincide, pasa. Si no, falla y deja el contrato recién generado en un fichero `.received.json` (git-ignored) al lado del snapshot, para poder diferenciarlo con una herramienta normal:

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

3. **Añade un comando dedicado de aceptación** (`accept-contract`) que pone la variable de entorno que activa la rama de "regenerar" del test de arriba. No existe para saltarse el test, sino para dejar constancia de que alguien lo aceptó — el diff resultante del snapshot aparece en el PR como cualquier otro cambio de código, y se revisa igual que se revisaría cualquier otro archivo:

```bash
accept_contract() {
  need dotnet
  run env UPDATE_OPENAPI_SNAPSHOT=1 dotnet test "$ROOT_DIR/.../Tests.csproj" --configuration Release
}
```

4. **Si hay un frontend con tipos generados a partir del contrato, añade un segundo subcomando** (`generate-types`) que corre `openapi-typescript` contra el snapshot ya aceptado, para regenerar los tipos TypeScript crudos que consume el frontend (un `schema.ts` de varios miles de líneas, nunca editado a mano). El orden importa y hay que documentarlo: primero `accept-contract` (fija el nuevo contrato), luego `generate-types` (deriva los tipos de ese contrato ya aceptado) — así los tipos del frontend nunca se generan a partir de un contrato que nadie ha revisado todavía. Si todavía no hay frontend, el patrón se adopta igual (test + snapshot + comando de aceptación): el problema que resuelve, un contrato que se mueve solo, no depende de que exista ya un consumidor de los tipos generados.

Esto invierte la carga: en vez de que un cambio de contrato pase desapercibido por defecto y alguien tenga que darse cuenta activamente de que ocurrió, un cambio de contrato rompe el build por defecto y hace falta un acto consciente para dejarlo pasar. Sabes que está bien aplicado cuando un cambio de DTO o de ruta hace fallar el test de snapshot en CI, y el único camino para que vuelva a pasar es correr `accept-contract` y que ese diff se revise en el PR como código.

## Variantes

- **No versionar el contrato y confiar en la revisión de código del DTO/controlador cambiado**: funciona si quien revisa piensa activamente en "¿esto cambia el contrato público?", pero no hay ningún mecanismo que lo fuerce — es fácil que un cambio de forma se cuele en un PR grande centrado en otra cosa.
- **Publicar el contrato generado sin snapshot ni test** (solo servir `/swagger.json` en caliente): documenta el estado actual, pero no da ninguna señal de que el contrato cambió respecto a antes, ni obliga a nadie a mirarlo.
- **Versionado semántico manual de la API** (anunciar "v2" a mano cuando se decide romper compatibilidad): resuelve el problema de comunicar el cambio a consumidores externos, pero no el de detectar que un cambio de contrato ocurrió en primer lugar — sigue dependiendo de que alguien se dé cuenta sin ayuda de una herramienta.

## Ejemplos

Visto en dos repos .NET distintos, con la misma forma exacta — evidencia de que no es una idiosincrasia de un proyecto sino un patrón que emerge solo del mismo problema:

- **[El Baúl](https://github.com/ne2-studio/el-baul)**: test de snapshot con infraestructura en memoria del patrón [API Lite](/patterns/api-lite), script `scripts/openapi` con `accept-contract` y `generate-types` (este último regenera `app/src/api/generated/schema.ts` para el frontend).
- Un segundo repo propietario, sin enlace público: mismo mecanismo (test + snapshot + `accept-contract` con un `WebApplication` desnudo), adoptado antes de tener frontend, con el comentario explícito en el propio script de que `generate-types` es lo próximo que hará falta el día que exista un admin panel.

## Recursos

- [API Lite](/patterns/api-lite): patrón usado para levantar la infraestructura en memoria que genera el contrato sin base de datos ni auth real.
