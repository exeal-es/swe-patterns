---
title: "Arquitectura hexagonal (puertos y adaptadores) en .NET"
description: "Aislar la lógica de aplicación en un proyecto sin dependencias de infraestructura, exponiendo puertos primarios y secundarios que otros proyectos implementan, para que el core sea unit-testable sin mocks de framework y la frontera arquitectónica la fuerce el compilador, no la disciplina."
date: 2026-09-24
tags:
  - arquitectura
  - dotnet
  - testing
maturity: adopt
---

## Problema

Cuando la lógica de aplicación y la infraestructura (base de datos, storage, proveedores externos) conviven en el mismo proyecto, es fácil que un caso de uso acabe llamando directamente a un `DbContext`, un cliente HTTP o `HttpContext`. El código compila, funciona, pero deja de ser unit-testable: cualquier test de un caso de uso arrastra un contenedor de base de datos o un mock del framework web. Con el tiempo esto también acopla el dominio a decisiones de infraestructura que deberían poder cambiar solas — cambiar de ORM, servir el mismo core desde dos hosts distintos (uno con infraestructura real y otro en memoria para tests de frontend), o simplemente entender qué necesita realmente un caso de uso del mundo exterior.

El problema se agrava cuando la separación entre "lógica de aplicación" e "infraestructura" es solo una convención de carpetas dentro del mismo proyecto/ensamblado: nada impide técnicamente que un manager importe un repositorio EF Core directamente, así que la frontera se erosiona sin que el compilador lo note — el mismo problema de fondo que resuelve un DSM Snapshot para las dependencias *entre* módulos, pero aquí aplicado a la frontera *entre capas*.

Aparece sobre todo en backends con lógica de negocio no trivial que se quiere:
- Testar unitariamente sin levantar infraestructura real.
- Servir desde más de un host con las mismas reglas de negocio pero infraestructura distinta (producción con Postgres/S3 real, un modo "lite" en memoria para tests end-to-end del frontend).
- Mantener explícito qué necesita cada caso de uso del mundo exterior, en vez de descubrirlo leyendo implementaciones concretas.

## Solución

La idea central: el core de la aplicación (casos de uso + dominio) vive en su propio proyecto .NET, que no referencia ningún paquete de infraestructura ni de framework web. Ese proyecto declara **puertos** — interfaces — en dos direcciones: puertos primarios (lo que el mundo exterior puede pedirle al core) y puertos secundarios (lo que el core necesita del mundo exterior). Otros proyectos implementan esos puertos: uno o varios proyectos "Api" consumen los puertos primarios para exponerlos por HTTP, y uno o varios proyectos "Infra" implementan los puertos secundarios con adaptadores reales (EF Core, un storage, un cliente externo). La separación no es una convención de carpetas: son proyectos distintos, y la dirección de dependencia (`Core` no referencia a nadie; `Api`/`Infra` referencian a `Core`) la fuerza el compilador.

Guía de implementación:

1. **Crea un proyecto `<Producto>.Core` sin dependencias de infraestructura.** Solo debe referenciar librerías de propósito general (logging abstractions, utilidades compartidas). Nada de ORM, nada de ASP.NET Core, nada de SDK de un proveedor cloud. Esta restricción es la que garantiza que el core sea unit-testable en aislamiento.

2. **Organiza el core por feature, no por capa técnica.** Dentro de `Core`, cada feature (`Bauls/`, `Photos/`, `Personas/`, ...) es su propia carpeta/namespace, con esta forma interna:
   - **Raíz del feature** (`Core.Personas`): interfaces de caso de uso (puertos primarios, p. ej. `IPersonaManager`) y los DTOs que exponen. Esto es lo que un consumidor externo (un controller) puede ver.
   - **`Application/`**: la implementación de esos casos de uso — una clase manager por agregado, que implementa el puerto primario correspondiente.
   - **`Domain/`**: entidades y value objects propios del feature.
   - **`OutputPorts/`**: interfaces de todo lo que ese feature necesita del exterior — repositorios, pero también abstracciones más finas como `IClock`, `IIdGenerator`, `ICurrentUserProvider`, un storage de ficheros. Cada efecto externo se abstrae en su propio puerto, no en un puerto "genérico de infraestructura".

   ```
   Core/Personas/
     IPersonaManager.cs          // puerto primario (input port)
     PersonaDto.cs
     Application/
       PersonaManager.cs         // implementa IPersonaManager
     Domain/
       Persona.cs
     OutputPorts/
       IPersonaRepository.cs     // puerto secundario (output port)
   ```

3. **Fuerza la disjunción entre puertos primarios y secundarios con un test de arquitectura**, no solo con la convención de carpetas. Con [ArchUnitNET](https://github.com/TNG/ArchUnitNET) (o equivalente) puedes comprobar por namespace que:
   - los puertos primarios nunca dependen de los secundarios, y viceversa (solo el `Domain` puede aparecer en ambos lados);
   - `Domain` no depende de `Application`, `InputPorts` ni `OutputPorts` — es la capa más interna.

   ```csharp
   [Fact]
   public void OutputPorts_ShouldNotDependOn_InputPorts()
   {
       Types()
           .That().Are(OutputPorts)
           .Should().NotDependOnAny(InputPorts)
           .Because("InputPorts y OutputPorts deben permanecer disjuntos — solo los tipos de Domain pueden aparecer en ambos lados de un puerto")
           .Check(Architecture);
   }
   ```

   Este test es el que convierte la regla de "los puertos no se mezclan" en algo que rompe el build, no en una nota en un documento que nadie relee.

4. **Crea un proyecto `<Producto>.Infra` que implementa los puertos secundarios** con adaptadores reales (repositorios EF Core, un cliente de storage, etc.) y expone un único método de composición (`AddInfrastructure(services)`) para registrarlos todos. `Infra` referencia a `Core`, nunca al revés.

5. **Crea uno o más proyectos `<Producto>.Api` que consumen los puertos primarios.** Los controllers dependen solo de las interfaces de caso de uso de `Core` (`IPersonaManager`, etc.), nunca de `Infra` ni de las clases concretas de `Application`. Un controller es un adaptador HTTP delgado: mapea la petición a una llamada al puerto primario y traduce el resultado a una respuesta HTTP, sin lógica de negocio.

   ```csharp
   [ApiController]
   [Route("api/baules/{baulId:guid}/personas")]
   public class PersonasController(IPersonaManager personaManager) : ControllerBase
   {
       [HttpGet]
       public async Task<IActionResult> GetAll(BaulId baulId)
       {
           var result = await personaManager.GetPersonasAsync(baulId);
           return result.ToActionResult();
       }
   }
   ```

6. **Registra la implementación de cada puerto primario junto al host**, no dentro de `Core` (`Core` no sabe qué lo implementa a nivel de contenedor DI):

   ```csharp
   builder.Services.AddScoped<IPersonaManager, PersonaManager>();
   ```

   y la de cada puerto secundario junto al `Infra` correspondiente (`AddInfrastructure()`).

7. **Si necesitas dos hosts con las mismas reglas de negocio pero infraestructura distinta** (por ejemplo, un modo "lite" en memoria para tests de frontend, sin base de datos real), extrae a un proyecto compartido (`Api.Common`) todo lo que debe ser idéntico entre ambos hosts — controllers, autenticación, pipeline HTTP, el grafo de registro de los puertos primarios — y crea un segundo `Infra.Lite` que implemente los mismos puertos secundarios con adaptadores en memoria. Así los dos hosts no pueden divergir en nada salvo en qué adaptador hay detrás de cada puerto, porque comparten literalmente el código que decide eso.

Cómo saber que quedó bien aplicado: `Core` compila sin ningún paquete de infraestructura ni de framework web en sus referencias; los tests de los managers no necesitan levantar nada externo (bastan fakes o stubs de los puertos secundarios); y un test de arquitectura falla si algún día alguien intenta saltarse la frontera.

## Ejemplos

- **[El Baúl](https://github.com/ne2-studio/el-baul)**: `api/ElBaul.Core` (casos de uso + dominio, sin dependencias de infraestructura salvo `Microsoft.Extensions.Logging.Abstractions`), `api/ElBaul.Infra`/`api/ElBaul.Infra.Lite` (adaptadores reales y en memoria de los mismos puertos secundarios) y `api/ElBaul.Api`/`api/ElBaul.Api.Common`/`api/ElBaul.Api.Lite` (los dos hosts HTTP, compartiendo controllers y registro de puertos primarios vía `Api.Common`). La frontera InputPorts/OutputPorts/Application/Domain está forzada por `ArchitectureTests` (ArchUnitNET) en `ElBaul.Core.Tests`, documentada en `docs/architecture/backend.md`.
