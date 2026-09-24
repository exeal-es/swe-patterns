---
title: "Result tipado"
description: "Un tipo Result<T>/ApplicationError que representa los fracasos de negocio esperados como valores de retorno, reservando las excepciones para fallos técnicos, con un único punto que mapea cada error a su respuesta HTTP."
date: 2026-09-24
tags:
  - dotnet
  - architecture
  - error-handling
maturity: adopt
---

## Problema

En un caso de uso hay dos tipos de "fallo" completamente distintos, y usar excepciones para ambos los mezcla en el mismo mecanismo: "crédito denegado" o "el email ya está registrado" son resultados esperados del dominio — pasan en producción todos los días y el código que llama al caso de uso tiene que decidir qué hacer con ellos — mientras que "la base de datos no responde" o "el proveedor de scoring ha dado timeout" son fallos de infraestructura que no le competen al dominio decidir, solo propagar para que alguien reintente o salte una alerta.

Modelar lo primero con excepciones es el antipatrón clásico de usar excepciones para control de flujo esperado: es costoso (el stack unwinding no es gratis si pasa en cada petición con crédito denegado) y semánticamente confuso, porque un `catch (Exception)` genérico no distingue "el usuario ha hecho algo inválido" de "se ha caído la base de datos" — ambos llegan por el mismo sitio. Y sin un tipo de error compartido, cada endpoint acaba inventando su propio mapeo a HTTP: uno devuelve 400 donde otro devuelve 422 para el mismo tipo de problema, porque cada controlador decide por su cuenta.

Aparece en APIs .NET con arquitectura por capas/hexagonal, donde los casos de uso viven en una capa de aplicación separada del transporte HTTP. Se vuelve necesario en cuanto los casos de uso empiezan a tener más de un motivo de fallo esperado (validación, no encontrado, no autorizado, conflicto, dependencia externa caída) y hay más de un controlador — sin un tipo de error compartido y un mapeo centralizado, la inconsistencia entre endpoints es cuestión de tiempo.

Se ha visto de forma independiente en dos repos con dominios muy distintos (una API de gestión de fotos y un motor de evaluación de riesgo/crédito), lo que sugiere que no es una idiosincrasia de un proyecto sino una forma razonable de resolver el mismo problema estructural.

## Solución

Un `Result`/`Result<T>` (railway-oriented programming) que un caso de uso devuelve en vez de lanzar, con un `ApplicationError` tipado por código cuando falla, y un único mapeo de ese código a la respuesta HTTP.

Primero, el tipo de error, tipado por código:

```csharp
public readonly record struct ApplicationError(ApplicationErrorCode Code, string Message)
{
    public static ApplicationError Validation(string message) => new(ApplicationErrorCode.Validation, message);
    public static ApplicationError NotFound(string message) => new(ApplicationErrorCode.NotFound, message);
    public static ApplicationError Forbidden(string message) => new(ApplicationErrorCode.Forbidden, message);
    public static ApplicationError ExternalDependencyUnavailable(string message) =>
        new(ApplicationErrorCode.ExternalDependencyUnavailable, message);
}
```

`Result<T>` trae `Bind`/`Map`/`Traverse` para componer pasos que pueden fallar (parsear un id, construir un value object, autorizar, ejecutar el caso de uso) sin un `if (result.IsFailure)` manual después de cada uno — el fallo se propaga solo, como en cualquier railway-oriented programming.

Después, el mapeo de cada código de error a su respuesta HTTP vive en un único sitio, no en cada controlador:

```csharp
public static class ErrorMapping
{
    public static IActionResult ToActionResult(ApplicationError error)
    {
        var body = new { error = error.Message };
        return error.Code switch
        {
            ApplicationErrorCode.Forbidden => new ObjectResult(body) { StatusCode = StatusCodes.Status403Forbidden },
            ApplicationErrorCode.NotFound => new NotFoundObjectResult(body),
            ApplicationErrorCode.Validation => new BadRequestObjectResult(body),
            ApplicationErrorCode.ExternalDependencyUnavailable =>
                new ObjectResult(body) { StatusCode = StatusCodes.Status503ServiceUnavailable },
            _ => new BadRequestObjectResult(body)
        };
    }
}
```

Cuando aparece un motivo de fallo esperado que no encaja en los códigos existentes, se añade un código nuevo — por ejemplo `Conflict`, para una petición bien formada que choca con el estado existente de una forma que no se puede resolver en silencio (una clave de idempotencia reutilizada para una petición lógica distinta, una restricción de unicidad, una transición de estado inválida), y que ni `Validation` (sobre la petición en sí) ni `ExternalDependencyUnavailable` (nunca reintentable a ciegas) cubren bien.

Así se sabe que el patrón está bien aplicado: añadir un código de error nuevo es tocar dos sitios como mucho (el enum `ApplicationErrorCode` y el switch de `ErrorMapping`), nunca N controladores.

## Variantes

- **Excepciones para todo (incluida la denegación de negocio)**: obliga a un `catch` que distinga tipos de excepción para decidir el status HTTP, y confunde en los logs/alertas un "crédito denegado" (esperado, no accionable) con un fallo real de infraestructura.
- **Cada controlador mapea sus propios errores a HTTP**: funciona al principio, pero diverge con el tiempo — dos endpoints acaban devolviendo status distintos para el mismo tipo de error porque nadie centralizó la decisión.
- **Modelar la denegación de negocio como valor exitoso, no como error**: no todos los fracasos de negocio tienen que vivir en `ApplicationError`. En un motor de evaluación de riesgo, la denegación de crédito no se modela como un error dentro de `Result` — se modela como un valor dentro de un resultado *exitoso*: el caso de uso `ICreditAssessor.AssessAsync` devuelve `Result<CreditAssessment>`, y `CreditAssessment` lleva un `CreditDecision` (`Approved`/`Rejected`) con un `CreditDenialReason` machine-readable cuando deniega. El `Result.Failure` de esa misma llamada queda reservado exclusivamente para "no se pudo completar la evaluación" (el proveedor de scoring no respondió, la base de datos de balances está caída):

  ```csharp
  /// <returns>
  /// Un CreditAssessment — aprobado, o denegado con un CreditDenialReason
  /// machine-readable — en éxito. En fallo, cualquier ApplicationError: una
  /// dependencia que la evaluación necesitaba no estaba disponible. Eso es un
  /// fallo operacional que quien llama reintenta; nunca es una denegación.
  /// </returns>
  Task<Result<CreditAssessment>> AssessAsync(CustomerId customerId, Money orderAmount, CancellationToken ct);
  ```

  Es la misma frontera de fondo (negocio vs técnico) llevada un paso más allá: una denegación de crédito no es ni siquiera un "error" desde el punto de vista del propio caso de uso — es el resultado normal y esperado de evaluar una regla de negocio, así que vive dentro del `T` de `Result<T>`, no en el canal de error.

- **Traducir el `Result` a excepción en el borde con un mecanismo que solo entiende excepciones**: el adaptador HTTP contra un proveedor externo de scoring atrapa la excepción de transporte y la convierte en un `Result.Failure(ApplicationError.ExternalDependencyUnavailable(...))` — nunca deja escapar la excepción original desde el adaptador. Pero en la capa que orquesta el reintento del proceso completo (un motor de decisión que corre dentro de un job de Hangfire), ese mismo `Result.Failure` se relanza explícitamente como excepción:

  ```csharp
  var assessment = await assessor.AssessAsync(customerId, orderAmount, cancellationToken);
  if (assessment.IsFailure)
  {
      // Un dependencia que la evaluación necesitaba no estaba disponible.
      // Reintentable, y NO es una denegación.
      throw new InvalidOperationException(
          $"Credit assessment could not complete for order {order.Id} "
          + $"(customer {customerId}): {assessment.Error.Message}");
  }
  ```

  Es decir: `Result`/`ApplicationError` es el vocabulario dentro de una capa de aplicación que compone pasos entre sí, pero en el borde donde ese resultado tiene que cruzar a un mecanismo de reintento que solo entiende excepciones (Hangfire reintenta un job si su método lanza), se traduce a excepción a propósito, en ese único punto — no se propaga la excepción de transporte original, ni se usa el `Result.Failure` como si fuera un valor más para seguir componiendo.
