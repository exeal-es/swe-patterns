---
title: "CLI de seed de escenarios contra Postgres local"
description: "Un CLI aparte que borra y vuelve a poblar la base de datos local con un catálogo fijo de escenarios de negocio, para poder probar a mano cada estado del sistema sin tener que reproducirlo pasando por cada integración real."
date: 2026-09-24
tags:
  - testing
  - postgres
  - dotnet
  - cli
maturity: explore
---

## Problema

Un sistema con varias máquinas de estado (un pedido, un cobro, una verificación de identidad...) tiene decenas de combinaciones de estado posibles, y muchas de ellas dependen de integraciones externas (una pasarela de pago, un proveedor de scoring, un servicio de verificación) que tardan, cuestan o simplemente no se pueden disparar a demanda en local. Para llegar a probar a mano un caso concreto — por ejemplo, un pedido rechazado por scoring, o uno con la verificación de dirección fallida — habría que arrastrar un pedido real por todo el flujo: crearlo, esperar la respuesta del proveedor de turno, forzar el caso concreto que se quiere ver.

Eso hace que probar el sistema desde el panel de administración, contra la API o directamente en `psql` sea lento y poco fiable: cada persona se monta sus propios datos a mano, de forma distinta, y nunca se sabe con certeza qué estados están cubiertos y cuáles no. Aparece en cualquier proyecto con reglas de negocio expresadas como máquinas de estado y varias integraciones externas de por medio, y se nota especialmente cuando hay que dar soporte, hacer una demo o verificar manualmente un caso raro sin montar todo el flujo de producción.

## Solución

Un CLI de test data aparte del servicio principal, que borra las tablas relevantes y vuelve a insertar un catálogo fijo de escenarios — siempre todos, siempre desde vacío — de modo que el resultado es un estado conocido y reproducible contra el que jugar a mano.

1. **Escríbelo por SQL directo, no a través de los mismos casos de uso que usa producción.** Los casos de uso de escritura del dominio existen para imponer invariantes de negocio y suelen llamar a integraciones externas (proveedores de scoring, de verificación...); un seeder offline no debe disparar ninguna de las dos cosas. El coste es que los mapeos de columnas hay que mantenerlos a mano en sincronía con el ORM (en un repo propietario, sin enlace, esto se resuelve con un fichero único de helpers SQL, uno por tabla, con un comentario explícito de que debe mantenerse a mano igual que el `OnModelCreating` del `DbContext`).

2. **Modela cada escenario como un dato, no como código imperativo.** Un catálogo (lista de registros) donde cada entrada es un caso de negocio con nombre y descripción, más las filas que ese caso produciría en cada tabla si se hubiera llegado a él de verdad — con `null` en las tablas que ese estado nunca llega a tocar (un pedido cancelado, por ejemplo, nunca resuelve una entidad de cliente):

```csharp
internal sealed record Scenario(
    string Name,
    string Description,
    CustomerRow? Customer,
    OrderRow Order,
    ReceivableRow? Receivable,
    AddressVerificationAttemptRow? AddressVerificationAttempt);
```

   Diseña el catálogo para que, entre todos los escenarios, quede representado al menos una vez cada valor de cada enum de estado relevante (todo `ReconcileOutcome`, todo `ReceivableStatus`, todo estado terminal de verificación...). Así el catálogo funciona como checklist: si se añade un valor nuevo a un enum de estado, el catálogo señala qué escenario falta.

3. **El comando `seed` borra las tablas afectadas dentro de una transacción y las vuelve a poblar con el catálogo entero.** No añade a lo que ya hay ni acepta seedear un subconjunto: el resultado siempre es el mismo estado conocido, para que dos personas viendo "el escenario 6" estén viendo exactamente lo mismo.

```csharp
await using var transaction = await connection.BeginTransactionAsync(cancellationToken);
await Sql.TruncateAllAsync(connection, transaction, cancellationToken);
foreach (var scenario in scenarios)
{
    if (scenario.Customer is not null) await Sql.InsertCustomerAsync(connection, transaction, scenario.Customer, cancellationToken);
    await Sql.InsertOrderAsync(connection, transaction, scenario.Order, cancellationToken);
    if (scenario.Receivable is not null) await Sql.InsertReceivableAsync(connection, transaction, scenario.Receivable, cancellationToken);
    if (scenario.AddressVerificationAttempt is not null) await Sql.InsertAddressVerificationAttemptAsync(connection, transaction, scenario.AddressVerificationAttempt, cancellationToken);
}
await transaction.CommitAsync(cancellationToken);
```

4. **Añade un guard que impida por completo ejecutarlo contra cualquier cosa que no sea el Postgres local de desarrollo**, comprobando el host y el nombre de la base de datos de la cadena de conexión resuelta, sin ninguna flag para saltárselo. Un comando que empieza truncando tablas enteras es demasiado peligroso como para confiar en que nadie apunte la variable de entorno equivocada a staging o producción:

```csharp
internal static class LocalDockerGuard
{
    private static readonly string[] AllowedHosts = ["localhost", "127.0.0.1"];
    private const string AllowedDatabase = "myapp_local";

    public static void EnsureLocalDocker(string connectionString)
    {
        var builder = new NpgsqlConnectionStringBuilder(connectionString);
        if (builder.Host is null || !AllowedHosts.Contains(builder.Host, StringComparer.OrdinalIgnoreCase))
            throw new InvalidOperationException($"Refusing to run: host '{builder.Host}' is not the local Docker Postgres.");
        if (!string.Equals(builder.Database, AllowedDatabase, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException($"Refusing to run: database '{builder.Database}' is not '{AllowedDatabase}'.");
    }
}
```

5. **Añade un comando de solo lectura (`list-scenarios`) que imprima el catálogo** (nombre y descripción de cada escenario) sin tocar la base de datos, para poder consultar qué casos existen sin tener que leer el código.

Con esto, probar un caso de negocio concreto pasa a ser `dotnet run -- seed` seguido de mirar el escenario correspondiente por su nombre — nunca montar el flujo real de punta a punta solo para llegar a un estado.

## Variantes

Para reglas de negocio que sí conviene probar de forma automatizada y exhaustiva (muchos casos, ejecutados en CI), un fake en memoria del repositorio sigue siendo mejor que este CLI: es más rápido y no depende de Postgres estar levantado. Este patrón no sustituye esa cobertura — resuelve un problema distinto, el de tener datos contra los que un humano pueda mirar y probar a mano, o contra los que hacer smoke tests manuales del panel de administración o la API.
