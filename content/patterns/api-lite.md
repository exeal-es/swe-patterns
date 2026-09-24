---
title: "API Lite: un segundo host con infraestructura en memoria"
description: "Un frontend o una suite de Playwright que depende del backend real arrastra Postgres, colas y proveedores externos, haciendo el desarrollo lento y los tests no deterministas. API Lite es un segundo host de la misma API con toda la infraestructura sustituida por implementaciones en memoria, para desarrollo y tests deterministas."
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

El problema aparece en aplicaciones .NET con arquitectura hexagonal (puertos y adaptadores) y separación en módulos: hay una capa `Core`/`Application` con los casos de uso y los puertos (`IPhotoRepository`, `IEmailSender`, etc.), y una capa `Infra` con los adaptadores reales (Postgres, S3, Hangfire, un proveedor de IA). Como los casos de uso ya dependen de interfaces y no de las implementaciones concretas, sustituir toda la infraestructura por otra cosa no exige tocar el dominio ni la capa HTTP — solo cambiar qué se registra en el contenedor de DI.

Se vuelve necesario en cuanto alguno de estos dos casos aparece: un equipo de frontend necesita iterar contra la API sin gestionar Postgres/Docker en su máquina, o una suite de Playwright necesita arrancar rápido, sin estado compartido entre specs, y sin que un servicio externo real (OIDC, IA, colas) introduzca no-determinismo.

## Solución

Construir un segundo host ejecutable de la misma API, que comparte con el host real todo lo que no depende de infraestructura (rutas, controladores, auth, middlewares, casos de uso) y sustituye únicamente los adaptadores de infraestructura por implementaciones en memoria, con el mismo ciclo de vida de proceso: un diccionario o una lista en memoria en vez de una tabla, un `Singleton` en el contenedor de DI en vez de una conexión a base de datos.

La receta recomendada es la separación en proyectos propios, que evita que host real y host Lite diverjan silenciosamente:

1. **Extrae el pipeline HTTP compartido a su propio proyecto** (`Api.Common`), con un único método de arranque (p. ej. `ElBaulApiHost.Build(builder)`) que registra controladores, auth JWT, CORS, rate limiting y el cableado de casos de uso. Este proyecto lo usan tanto el host real como el host Lite — es literalmente el mismo código compilado en los dos. Que el reparto sea limpio aquí es la clave: si algo específico de infraestructura se cuela en este proyecto, el host Lite deja de ser un espejo fiel del real.
2. **Crea un proyecto de infraestructura en memoria** (`Infra.Lite`), con un método de registro (p. ej. `AddLiteInfrastructure`) que da de alta una implementación en memoria por cada puerto de salida (`InMemoryPhotoRepository`, `FakeEmailSender`, `FakeAiChatBackend`, `FakeBackgroundJobScheduler`...). Cada una se registra como `Singleton`, porque ahí "es" el almacenamiento — no hay base de datos detrás que sobreviva entre requests.
3. **No sustituyas la autenticación por un mock trivial que salte todo el flujo.** El host Lite sigue validando JWT reales contra un proveedor OIDC real (`fake-oidc`), solo que ese proveedor también corre en memoria o en un contenedor ligero. Eso es lo que permite que Playwright ejercite el login real y no un atajo que nunca se prueba en producción.
4. **Deja el `Program.cs` del host Lite mínimo**, montando solo la infraestructura en memoria sobre el pipeline compartido:

```csharp
var builder = WebApplication.CreateBuilder(args);

// The only infrastructure this image knows about: everything in-memory.
builder.Services.AddLiteInfrastructure(builder.Configuration);

// Shared with the real host via ElBaul.Api.Common — same compiled pipeline,
// just backed by different ports underneath.
var app = ElBaulApiHost.Build(builder);

app.Run();
```

5. **Añade, si Playwright lo necesita, un endpoint exclusivo del host Lite para sembrar estado** (p. ej. `POST /lite/testing/seed`), deliberadamente sin autenticar, que Playwright llama directamente (no a través del navegador) para dejar cada spec en un estado inicial conocido. Que no lleve autenticación es un riesgo aceptable porque el host Lite nunca corre con datos reales ni se despliega donde importe.

El resultado son dos imágenes/ejecutables de la misma API: el host real con infraestructura real (Postgres, colas, servicios externos), y el host Lite con los mismos endpoints, la misma autenticación, el mismo pipeline HTTP compilado, pero con cada puerto de salida resuelto a una implementación en memoria cuyo estado vive mientras vive el proceso y desaparece al reiniciarlo.

Se sabe que el patrón está bien aplicado cuando frontend y Playwright hablan contra un backend con contrato HTTP y autenticación reales, sin ninguna dependencia externa, con arranque instantáneo y estado predecible y descartable entre ejecuciones — y cuando un cambio en el pipeline HTTP del host real se refleja automáticamente en el host Lite por compartir el mismo código, sin tener que tocar nada a mano.

## Variantes

La receta anterior es el punto más maduro; el patrón también aparece en dos niveles previos, más simples pero con peor protección frente a divergencia:

- **Extensiones de DI compartidas, sin proyecto `Common` separado.** En vez de extraer un proyecto propio, el host Lite reutiliza directamente las mismas extensiones de registro (`AddXxxApi`, `UseXxxApi`, `AddXxxApiSwaggerGen`) que monta el host real, y solo cambia qué puertos de infraestructura se registran. Es más rápido de montar que separar en proyectos, pero depende de que nadie llame a las extensiones "a medias" en alguno de los dos hosts.
- **Un solo proyecto con todo junto.** El host Lite es un único proyecto ASP.NET con su propio `Program.cs`, que registra listas en memoria (`List<JournalEntryResponse>` como `Singleton`) detrás de los mismos puertos y sustituye la autenticación real por un handler de autenticación falso. Es el punto de partida más simple y el más rápido de montar, pero no hay ninguna pieza compartida explícita que impida que el host real y el Lite diverjan en el pipeline HTTP con el tiempo.

Alternativas descartadas, fuera de este patrón:

- Mockear HTTP en el frontend (interceptar `fetch`/`axios`): no ejercita el contrato real, se desincroniza en silencio si la API cambia.
- Backend de mentira con rutas ad-hoc, no generado a partir de los mismos casos de uso: duplica lógica y diverge del comportamiento real con el tiempo.
- Levantar el backend real con Testcontainers para cada test: correcto y fiel, pero mucho más lento y no aplicable a "que un frontend arranque rápido en local sin Docker".

## Ejemplos

- **[CashClarity](https://github.com/ne2-studio/cashclarity)**: el nivel más simple, un solo proyecto con su propio `Program.cs`, sin capa `Common` separada.
- **[El Baúl](https://github.com/ne2-studio/el-baul)**: el punto más maduro, con `ElBaul.Api.Common` y `ElBaul.Infra.Lite` como proyectos separados, y el endpoint `POST /lite/testing/seed` para Playwright.
- **Un repo propietario, sin enlace**: el nivel intermedio, con extensiones de DI compartidas (`AddXxxApi`, `UseXxxApi`) pero sin proyecto `Common` explícito.
