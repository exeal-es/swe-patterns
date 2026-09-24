---
title: "API Lite"
description: "Un segundo host de la misma API, con toda la infraestructura sustituida por implementaciones en memoria, para desarrollo de frontend y tests de Playwright deterministas."
date: 2026-09-24
tags:
  - dotnet
  - testing
  - devex
maturity: adopt
---

## Problema

Un frontend (o una suite de Playwright) que depende del backend real para poder trabajar arrastra todos los problemas del backend real: hay que levantar Postgres, colas, un proveedor OIDC, a veces Hangfire o un bucket S3, y el estado se acumula entre ejecuciones. Para tocar UI esto es fricción pura — nadie necesita persistencia real para ver si un botón pinta bien. Para tests de extremo a extremo es peor: los tests dejan de ser deterministas (dependen de datos que quedaron de ejecuciones anteriores, de latencia real contra servicios externos, de que Postgres/Hangfire arranquen a tiempo) y se vuelven lentos de levantar y frágiles de mantener.

La tentación fácil es mockear a nivel de HTTP (interceptar `fetch` en el frontend, o levantar un backend "de mentira" con rutas ad-hoc) pero eso hace que frontend y tests dejen de ejercitar el contrato real: si la API cambia una forma de respuesta, el mock no se entera y el test sigue en verde mintiendo.

## Contexto

Aparece en aplicaciones .NET con arquitectura hexagonal (puertos y adaptadores) y separación en módulos: hay una capa `Core`/`Application` con los casos de uso y los puertos (`IPhotoRepository`, `IEmailSender`, etc.), y una capa `Infra` con los adaptadores reales (Postgres, S3, Hangfire, un proveedor de IA). Como los casos de uso ya dependen de interfaces y no de las implementaciones concretas, sustituir toda la infraestructura por otra cosa no exige tocar el dominio ni la capa HTTP — solo cambiar qué se registra en el contenedor de DI.

Se vuelve necesario en cuanto alguno de estos dos casos aparece: un equipo de frontend necesita iterar contra la API sin gestionar Postgres/Docker en su máquina, o una suite de Playwright necesita arrancar rápido, sin estado compartido entre specs, y sin que un servicio externo real (OIDC, IA, colas) introduzca no-determinismo.

## Solución

Construir un segundo host ejecutable de la misma API, que comparte con el host real todo lo que no depende de infraestructura (rutas, controladores, auth, middlewares, casos de uso) y sustituye únicamente los adaptadores de infraestructura por implementaciones en memoria, con el mismo ciclo de vida de proceso: un diccionario o una lista en memoria en vez de una tabla, un `Singleton` en el contenedor de DI en vez de una conexión a base de datos.

La inversión de dependencias es lo que hace esto posible sin duplicar lógica: los casos de uso solo conocen los puertos (interfaces), así que el host Lite simplemente registra otra implementación de esas interfaces. La modularidad (separar "el host HTTP" de "la infraestructura" en proyectos/paquetes distintos) es lo que permite que ese segundo host sea, literalmente, otro proyecto pequeño que referencia los mismos módulos de dominio y de HTTP, pero un módulo de infraestructura distinto.

El resultado son dos imágenes/ejecutables de la misma API:

- **El host real**: infraestructura real (Postgres, colas, servicios externos).
- **El host Lite**: mismos endpoints, misma autenticación, mismo pipeline HTTP compilado — pero cada puerto de salida resuelve a una implementación en memoria, con estado que vive mientras vive el proceso y desaparece al reiniciarlo.

Esto da a frontend y a Playwright un backend real (mismo contrato HTTP, misma autenticación real) pero sin ninguna dependencia externa, arranque instantáneo, y estado predecible y descartable entre ejecuciones.

## Implementación

El patrón aparece con tres niveles de madurez distintos, visibles en los tres repos donde está adoptado:

1. **Un solo proyecto, todo junto (CashClarity).** El host Lite es un único proyecto ASP.NET con su propio `Program.cs`: registra listas en memoria (`List<JournalEntryResponse>` como `Singleton`) detrás de los mismos puertos (`IAccountsRepository`, `IJournalEntriesRepository`) y sustituye la autenticación real por un `FakeBearerAuthenticationHandler`. No comparte código de pipeline con un host real explícito — es el punto de partida más simple, sin capa `Common` separada.

2. **Extensiones de DI compartidas (un segundo repo, propietario, sin enlace).** El host Lite reutiliza el pipeline real llamando a las mismas extensiones de registro (`AddXxxApi`, `UseXxxApi`, `AddXxxApiSwaggerGen`) que monta el host real — controladores, auth JWT/OIDC real (contra un `fake-oidc` real, no un mock de autenticación), CORS y Swagger son literalmente el mismo código. Lo único que cambia son los puertos de infraestructura, registrados como `Singleton` en memoria (colas, repositorios de dominio, límites de crédito...). Además añade un endpoint exclusivo del host Lite, `POST /lite/testing/seed`, deliberadamente sin autenticar, que Playwright llama directamente (no a través del navegador) para dejar cada spec en un estado inicial conocido antes de interactuar con la UI.

3. **Separación en proyecto propio (El Baúl), el punto más maduro.** El pipeline HTTP compartido se extrae a su propio proyecto, `ElBaul.Api.Common`, con un único método `ElBaulApiHost.Build(builder)` que registra controladores, auth JWT, CORS, rate limiting y el cableado de casos de uso — usado tanto por el host real como por `ElBaul.Api.Lite`. La infraestructura en memoria vive en otro proyecto propio, `ElBaul.Infra.Lite`, con un método `AddLiteInfrastructure` que registra una implementación en memoria por cada puerto de salida (`InMemoryPhotoRepository`, `FakeEmailSender`, `FakeAiChatBackend`, `FakeBackgroundJobScheduler`...), cada uno `Singleton` porque ahí "es" el almacenamiento — no hay base de datos detrás que sobreviva entre requests. El propio `Program.cs` del host Lite es mínimo:

```csharp
var builder = WebApplication.CreateBuilder(args);

// The only infrastructure this image knows about: everything in-memory.
builder.Services.AddLiteInfrastructure(builder.Configuration);

// Shared with the real host via ElBaul.Api.Common — same compiled pipeline,
// just backed by different ports underneath.
var app = ElBaulApiHost.Build(builder);

app.Run();
```

Un detalle que se repite en los tres repos: lo que se sustituye siempre son los puertos de infraestructura (repositorios, envío de email, IA, storage), nunca la autenticación por un mock trivial que salte todo el flujo — el segundo repo y El Baúl siguen validando JWT reales contra un proveedor OIDC real (`fake-oidc`), solo que ese proveedor también corre en memoria/contenedor ligero. Eso es lo que permite que Playwright ejercite el login real y no un atajo que nunca se prueba en producción.

## Trade-offs reales observados

- **Compartir el pipeline HTTP (`Api.Common`) evita que host real y host Lite diverjan silenciosamente**, pero exige diseñar ese proyecto desde el principio como "todo lo que no depende de infraestructura" — si el reparto no es limpio, algo específico de infraestructura se cuela ahí y el host Lite deja de ser un espejo fiel.
- **Un endpoint de seed sin autenticar (`/lite/testing/seed`) es deliberadamente inseguro**, pero es aceptable porque el host Lite nunca corre con datos reales ni se despliega donde importe.
- **El nivel más simple (CashClarity, un solo proyecto) es más rápido de montar** pero no protege contra que el host real y el Lite diverjan en el pipeline HTTP, porque no hay una pieza compartida explícita que lo impida.

## Alternativas

- Mockear HTTP en el frontend (interceptar `fetch`/`axios`): no ejercita el contrato real, se desincroniza en silencio si la API cambia.
- Backend de mentira con rutas ad-hoc, no generado a partir de los mismos casos de uso: duplica lógica y diverge del comportamiento real con el tiempo.
- Levantar el backend real con Testcontainers para cada test: correcto y fiel, pero mucho más lento y no aplicable a "que un frontend arranque rápido en local sin Docker".
