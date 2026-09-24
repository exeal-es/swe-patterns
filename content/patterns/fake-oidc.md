---
title: "Fake OIDC"
description: "Un proveedor OIDC de mentira, que habla el subconjunto real del protocolo, para desarrollo local y tests de aceptación deterministas contra una API que exige autenticación real."
date: 2026-09-24
tags:
  - testing
  - devex
  - auth
maturity: adopt
---

## Problema

Una API que autentica con OIDC no se puede levantar en local ni ejercitar en tests de aceptación sin resolver antes "¿contra qué me autentico?". Apuntar a un proveedor OIDC real de verdad (Zitadel, Auth0, lo que sea) para desarrollo local o para CI trae credenciales que gestionar, usuarios de prueba que crear y mantener a mano en una consola externa, y dependencia de red contra un servicio que no controlas. La alternativa fácil — saltarse la autenticación en local con un middleware que la desactiva, o mockear el token a mano — hace que ni el pipeline de auth real ni el contrato HTTP real se ejerciten nunca fuera de producción, así que un bug de autenticación no aparece hasta que ya está desplegado.

## Contexto

Aparece en cualquier API que valida JWT contra un proveedor OIDC externo (JWKS, issuer, audience) y que necesita dos cosas a la vez: que alguien pueda iniciar sesión en local sin depender del proveedor real, y que una suite de tests de aceptación/Playwright pueda obtener un token válido sin pasar por un navegador ni por credenciales reales. Se vuelve necesario en cuanto el patrón [API Lite](/patterns/api-lite) entra en juego: el host Lite sigue validando JWT reales (no salta la autenticación con un mock trivial), así que necesita algo que hable OIDC de verdad para emitir esos tokens.

## Solución

Una pieza de infra propia — `fake-oidc` — que implementa el subconjunto de OIDC que una API cliente necesita para autenticar (`/authorize`, `/token`, `/.well-known/jwks.json`, `/oidc/v1/userinfo`) y nada más: sin registro de usuarios, sin gestión de contraseñas, sin flujos que nadie usa. Se configura por variables de entorno con una lista fija de clientes (`OIDC_CLIENTS`, con `clientId` y `redirectUris`) y una lista fija de usuarios hardcodeados (`OIDC_USERS`, cada uno con `sub`, `email`, `name` y `roles`) — sin base de datos ni persistencia entre reinicios.

Para desarrollo, en vez de un formulario de login, `/authorize` presenta una pantalla con un botón por cada usuario configurado: seleccionar uno emite el código de autorización para ese usuario directamente, sin contraseña. Eso permite ver el flujo de login real completo (redirect, callback, intercambio de código por token) sin tener que recordar ni gestionar credenciales.

Para tests de aceptación, ese mismo mecanismo se puede ejercitar sin navegador: un cliente HTTP llama directamente a `GET /authorize/select?response_type=code&client_id=...&redirect_uri=...&user=<key>` (lo mismo que dispara el botón de la pantalla de login), sigue el `302` hasta obtener el `code` de la query del `Location`, y lo canjea con `POST /token` (`grant_type=authorization_code`). El resultado es un access token real, firmado por `fake-oidc`, que la API valida contra su JWKS real — sin mockear nada del lado de la API bajo test.

Se distribuye como imagen de contenedor (`ghcr.io/ne2-studio/fake-oidc:latest`) y se levanta como un servicio más en `docker-compose`, igual que Postgres o cualquier otra dependencia de infra.

## Implementación

Ejemplo de configuración en `docker-compose.yaml` (El Baúl):

```yaml
fake-oidc:
  image: ghcr.io/ne2-studio/fake-oidc:latest
  environment:
    OIDC_ISSUER: "http://localhost:${FAKE_OIDC_PORT:-5000}"
    OIDC_CLIENTS: >-
      [{"clientId":"el-baul-app","redirectUris":["http://localhost:3000/callback","http://localhost:5173/callback"],"postLogoutRedirectUris":[...]},
      {"clientId":"el-baul-admin","redirectUris":["http://localhost:3001/callback"]}]
    OIDC_USERS: >-
      [{"key":"admin","sub":"admin-user","email":"admin@test.local","name":"Admin User","roles":["admin"]},
      {"key":"user","sub":"normal-user","email":"user@test.local","name":"Normal User","roles":["user"]}]
    OIDC_DEFAULT_USER: "admin"
  ports:
    - "${FAKE_OIDC_PORT:-5000}:5000"
```

La API apunta su validación de JWT a este contenedor exactamente igual que apuntaría a un proveedor real:

```yaml
Auth__JwksUri: "http://fake-oidc:5000/.well-known/jwks.json"
Auth__ValidIssuer: "http://localhost:5000"
Auth__Audience: "el-baul-app"
Auth__UserInfoEndpoint: "http://fake-oidc:5000/oidc/v1/userinfo"
```

Se usa igual en los cuatro repos donde está adoptado (Ne2Studio, El Baúl, CashClarity y un repo propietario, sin enlace): mismo servicio, misma imagen, misma configuración por `OIDC_CLIENTS`/`OIDC_USERS`, con clientes y usuarios distintos según lo que cada API necesite. En el repo propietario, además, convive con un fake de autenticación distinto y más simple (una implementación propia en el host de fakes de esa API, usada solo por tests de aceptación para mintar un token de forma no interactiva) — `fake-oidc` sigue siendo el único de los dos pensado para que una persona inicie sesión de verdad desde un navegador.

## Alternativas

- **Desactivar la autenticación en local con un middleware ad-hoc**: nadie ejercita el pipeline de auth real fuera de producción, así que un bug ahí no se detecta hasta desplegar.
- **Proveedor OIDC real (Zitadel, Auth0...) también en local/CI**: exige gestionar credenciales y usuarios de prueba en un servicio externo, y añade dependencia de red donde no hace falta.
- **Mockear el token a mano (firmarlo tú mismo con una clave de test)**: funciona para tests, pero no da una pantalla de login real para desarrollo, y dos implementaciones (una para local, otra para tests) tienden a divergir.
