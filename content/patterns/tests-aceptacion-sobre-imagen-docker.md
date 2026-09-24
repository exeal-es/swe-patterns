---
title: "Tests de aceptación sobre la imagen Docker ya construida"
description: "Un proyecto de tests separado, sin dependencia de código fuente, que levanta la imagen Docker del backend ya construida junto a sus dependencias reales con Testcontainers y la estimula solo por sus interfaces públicas."
date: 2026-09-24
tags:
  - dotnet
  - testing
  - docker
  - testcontainers
maturity: adopt
---

## Problema

Un backend .NET no se despliega como código fuente: se despliega como imagen Docker. Entre el código que pasa los tests unitarios y la imagen que corre en producción hay una capa entera que ningún test contra el código fuente toca — el `Dockerfile`, las variables de entorno que el contenedor espera recibir, si el puerto publicado es el correcto, si las migraciones corren al arrancar, si el healthcheck responde. Un `WebApplicationFactory` o un test de integración que arranca la app in-process compila contra las mismas clases que ya se probaron, así que no puede detectar ninguno de esos fallos — están todos fuera del código, en el empaquetado.

El síntoma típico es el desajuste silencioso: un nombre de variable de entorno que cambia en el código de configuración pero no en el manifiesto de despliegue, una migración que se le olvida a alguien correr en el arranque, un multi-stage build que deja fuera un fichero necesario. Todo eso pasa los tests, pasa la review del código, y explota al desplegar — porque nada, hasta ese momento, ha probado el artefacto real, solo el código que lo compone.

El problema se agrava si los tests de "aceptación" que sí existen viven dentro de la solución principal y referencian tipos internos (DTOs, repositorios, servicios) del propio backend. En ese caso ni siquiera protegen del problema que deberían: si un refactor rompe el contrato HTTP (renombra un campo de una respuesta, por ejemplo) pero lo hace de forma consistente en ambos lados, esos tests recompilan contra el mismo tipo ya roto y siguen en verde. Aparece en cualquier backend .NET que se empaqueta como imagen Docker y se despliega así — es decir, en la inmensa mayoría de los backends actuales — y se vuelve imprescindible en cuanto el proceso de build/deploy tiene más de un paso (build multi-stage, migraciones, variables de entorno inyectadas por el orquestador) donde algo se puede desalinear sin que ningún test se entere.

## Solución

Un proyecto de tests de aceptación, completamente aparte de la solución principal, que recibe la imagen Docker ya construida por variable de entorno, levanta sus dependencias reales con Testcontainers en una red aislada, y la estimula únicamente por las interfaces que expondría en producción: variables de entorno, puertos HTTP, nada más. El sujeto bajo test es el artefacto, no el código — como si lo hubiera construido un proveedor externo del que solo se conoce la imagen, su contrato de variables de entorno y su API HTTP pública.

1. **Créalo como proyecto y solución aparte, fuera de la `.slnx` principal** — directorio propio (`acceptance-tests/`), `.csproj` y `.slnx` propios, sin que la solución principal lo referencie ni viceversa. Esto no es solo organización: es lo que hace estructuralmente imposible que el proyecto adquiera sin querer una dependencia del código fuente del backend. Añade además un test de arquitectura que falla si alguna vez aparece un `ProjectReference` hacia el backend, para que la violación se vea como un cambio explícito en una review, no como un `using` que se cuela:

```csharp
[Fact]
public void This_project_has_no_ProjectReference_to_anything()
{
    var csproj = File.ReadAllText(FindThisProjectsCsproj());
    Assert.DoesNotContain("ProjectReference", csproj);
}
```

2. **La imagen entra siempre desde fuera, nunca se construye como parte de correr los tests.** Un fixture (`IAsyncLifetime`) la recibe vía una variable de entorno (`BACKEND_IMAGE`) y falla explícitamente si no está:

```csharp
var backendImage = Environment.GetEnvironmentVariable("BACKEND_IMAGE")
    ?? throw new InvalidOperationException(
        "BACKEND_IMAGE is required — point it at the image under test, " +
        "e.g. BACKEND_IMAGE=ghcr.io/org/api:latest");
```

3. **Levanta las dependencias reales con Testcontainers en una red Docker aislada** — Postgres, un almacenamiento de objetos (MinIO), un proveedor OIDC de mentira, lo que la imagen necesite en producción — configuradas igual que las configuraría un operador desde fuera: imágenes públicas, variables de entorno, puertos. Nunca fakes inyectados en proceso ni un contenedor levantado a mano fuera de Testcontainers:

```csharp
Network = new NetworkBuilder().Build();
await Network.CreateAsync();

Postgres = new ContainerBuilder("postgres:16")
    .WithNetwork(Network)
    .WithNetworkAliases("postgres")
    .WithEnvironment("POSTGRES_USER", PostgresUser)
    .WithWaitStrategy(Wait.ForUnixContainer().UntilCommandIsCompleted(
        "pg_isready", "-U", PostgresUser, "-d", PostgresDatabase))
    .Build();
```

4. **Arranca la imagen bajo test en esa misma red, con el mismo conjunto de variables de entorno que tendría en un despliegue real**, apuntando a los alias de red de sus dependencias, y espera a que su propio healthcheck HTTP responda — no a un `sleep`, ni a que el contenedor esté "running":

```csharp
var backendBuilder = new ContainerBuilder(backendImage)
    .WithNetwork(Network)
    .WithNetworkAliases("backend")
    .WithPortBinding(8080, true)
    .WithWaitStrategy(Wait.ForUnixContainer().UntilHttpRequestIsSucceeded(r => r
        .ForPort(8080)
        .ForPath("/health")));
foreach (var (key, value) in BackendEnvironment)
    backendBuilder = backendBuilder.WithEnvironment(key, value);
Backend = backendBuilder.Build();
await Backend.StartAsync();
```

5. **Estimula la imagen solo por `HttpClient`, nunca por `WebApplicationFactory` ni por DI.** No hay contenedor de inyección de dependencias en este proyecto apuntando al backend — hay un cliente HTTP hablando con un contenedor real, exactamente como cualquier otro consumidor real lo haría.

6. **Define las formas de petición/respuesta a mano en este proyecto** (`JsonDocument` o records propios), nunca reutilizando los DTOs del backend. Es lo que hace que una regresión de contrato — un campo renombrado, un tipo cambiado — se detecte aquí aunque el propio backend compile perfectamente contra su tipo ya roto.

7. **Organiza los tests en un puñado de grupos deliberadamente pequeños**: uno de humo (arranca, se queda arriba, responde `/health`, recoge configuración de variables de entorno, falla rápido y con logs si una dependencia obligatoria no está), uno de compatibilidad de infraestructura (habla de verdad con Postgres — migraciones corridas, tablas esperadas — y con lo que haga falta), y un puñado corto de recorridos críticos de negocio de punta a punta. No es una segunda copia de la suite de dominio del backend — esa ya cubre las reglas de negocio mucho más barato contra fakes hechos a mano. Aquí solo se prueba que el contrato público del artefacto sigue funcionando.

8. **Engánchalo en CI justo antes de `docker push`**, contra la imagen recién construida en el runner (nunca una ya publicada), de forma que un fallo bloquee la publicación y el despliegue posterior.

Se sabe que está bien aplicado cuando el proyecto de aceptación no tiene ninguna forma —ni por `ProjectReference`, ni por tipos compartidos— de saber nada del backend que no sea su imagen, su contrato de variables de entorno y su API HTTP; y cuando un cambio que rompe ese contrato (una variable de entorno renombrada, un campo de respuesta cambiado, una migración que deja de correr) hace fallar estos tests aunque los tests unitarios y de integración del propio backend sigan en verde.

## Variantes

- **Dependencias de terceros como su propia imagen "fakes" en la red, en vez de un simulador genérico tipo WireMock**: cuando el backend habla con varias APIs externas (pasarela de pago, proveedor de identidad, servicio de verificación), en vez de levantar un stub por dependencia conviene construir una imagen propia que expone un fake de cada una bajo su propio prefijo de ruta, con estado real en memoria en vez de respuestas grabadas — así el fake ejecuta cada operación de verdad (crea, busca, actualiza) en lugar de devolver siempre lo que se le grabó. Compensa cuando hay más de dos o tres dependencias externas que simular y su comportamiento tiene estado; para un backend con una sola dependencia externa sencilla, un contenedor de fake por dependencia es suficiente y más simple.
- **Test explícito de acceso directo a la infraestructura para casos que no se pueden observar por HTTP**: la regla general es "solo HTTP", pero cuando hace falta comprobar algo que la API no expone (que una migración concreta corrió, que un bucket existe), se permite una excepción acotada y explícita — ejecutar un comando dentro del propio contenedor de la dependencia (`psql`, `mc`) en vez de acceder a ella desde el proyecto de tests con una cadena de conexión sacada de la configuración del backend. Mantiene la frontera: el proyecto de aceptación sigue sin saber nada de cómo el backend se conecta a sus dependencias.

## Ejemplos

Visto en tres backends .NET distintos, con la misma forma estructural pero distinta profundidad según cuántas dependencias externas tiene cada uno:

- **[El Baúl](https://github.com/ne2-studio/el-baul)**: Postgres, MinIO y `fake-oidc` como contenedores reales en red aislada; grupos de Smoke, InfrastructureCompatibility (verificación de migraciones y bucket vía `psql`/`mc` dentro del propio contenedor) y CriticalJourneys.
- **[CashClarity](https://github.com/ne2-studio/cashclarity)**: la aplicación más simple de las tres — solo Postgres y `fake-oidc`, sin dependencias externas de negocio que simular.
- Un repo propietario, sin enlace público: el caso más elaborado, con una imagen "fakes" propia que sustituye a varias APIs de terceros (pasarela de pago, verificación de identidad, credit scoring) con estado real en memoria, además de Postgres.
