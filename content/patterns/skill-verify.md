---
title: "Skill Verify"
description: "Convertir la verificación de un cambio en una decisión basada en riesgo, no en una sensación de \"parece correcto\"."
date: 2026-09-24
tags:
  - agentes
  - devex
maturity: adopt
---

## Problema

Cuando un agente termina de implementar algo, tiende a declarar la tarea hecha en cuanto el diff "tiene buena pinta". Eso no es evidencia: un diff que compila y parece razonable puede romper una migración, dejar sin cubrir un caso de error, o cambiar un contrato HTTP sin que ningún test lo note. Y el problema inverso es igual de real: sin un criterio explícito, el agente también puede sobre-verificar, lanzando la suite completa (incluida infraestructura real) para un cambio interno que un test unitario ya cubre de sobra. Ninguno de los dos extremos es barato: uno deja bugs pasar, el otro quema tiempo y contenedores por nada.

Aparece en cualquier repo con más de una capa de riesgo real: lógica de dominio, persistencia con un ORM, contrato HTTP público, wiring que solo se manifiesta en la imagen construida, comportamiento visual. Un solo comando `test` no basta porque distintos riesgos piden distinta evidencia — una función pura se cubre con un test unitario, un cambio de migración necesita aplicarse contra un Postgres real, un cambio visual necesita inspección real del layout. Se vuelve crítico en cuanto un agente (no un humano revisando con criterio) es quien decide cuándo algo está "verificado".

## Solución

Igual que en [Skill Run](/patterns/skill-run/), separar cómo de cuándo:

1. Un script (`scripts/verify`) que expone comandos deterministas por área — `backend`, `backend-acceptance`, `frontend`, `admin`, `e2e`, `all` — cada uno documentado en `docs/architecture/testing.md` con lo que cubre exactamente.
2. Una skill (`.claude/skills/verify/SKILL.md`) que no enseña a ejecutar el script, sino a **elegir qué comando(s)** hacen falta: una matriz de riesgo que mapea cada tipo de cambio observable (lógica de dominio, persistencia, contrato HTTP, infra/CI, comportamiento visual...) a la evidencia mínima que lo cubre, y a cuándo escalar de un test unitario a infraestructura real.

La matriz es la pieza que hace el patrón útil: no dice "corre todos los tests", dice "identifica qué comportamiento observable cambió y elige el check más estrecho que lo cubre, sube de nivel solo si el riesgo lo pide". Es también la parte cara de escribir del patrón, y la que más vale: un script con comandos es trivial; decidir y documentar qué evidencia cubre cada tipo de riesgo real del proyecto (y cuándo escalar a infra real) es el trabajo de fondo. Consistente en los tres repos:

| Riesgo | Evidencia | Escalar a infra real cuando... |
|---|---|---|
| Lógica de dominio | Test unitario: camino de éxito + de fallo | Toca traducción a BD, storage, tokens de auth |
| Persistencia y ORM | Unit + acceptance contra Postgres real | Entidades, queries, índices, transacciones, SQL crudo |
| Migraciones | Review + acceptance aplicando la imagen construida | Siempre |
| Contrato HTTP | Test de controller o acceptance de caja negra | Imagen construida, auth, middleware, serialización |
| Infra/CI/entorno | Test o smoke probando env vars, arranque, salud | Dockerfile, compose, workflow, env contract |
| Comportamiento visual | Aserciones funcionales + screenshot inspeccionado | Layout de navegador, build, responsive |

Al igual que con `run`, esto no es solo convención entre archivos de un mismo repo: un orquestador de agentes que opera sobre un backlog de tickets puede formalizarlo como **capability** obligatoria en su contrato de entorno — sin `verify`, el repo no puede ser conducido por el orquestador. El contrato define la interfaz exacta: entrada (un diff + una o dos frases de intención), salida (los riesgos del diff y, por riesgo, el check más estrecho: qué suite, si hace falta añadir un test, cuándo escalar), y la garantía de que es risk-based — "parece correcto" nunca es evidencia.

El script y la skill hacen roles distintos y no se pisan:

- **El script decide el "cómo".** Solo se ejecuta a través de `./scripts/verify`, nunca invocando `dotnet test` o `vitest` a pelo — así CI y el agente corren exactamente lo mismo.
- **La skill decide el "qué".** El agente lee el diff, identifica el comportamiento observable que cambió, lo clasifica con la matriz, y elige el comando más estrecho — o `all` cuando el cambio cruza varias áreas.
- **`--changed` es el punto donde el patrón admite sus propios límites.** Un flag global reduce cada comando a los checks afectados por el diff cuando el runner subyacente lo soporta de forma fiable (`vitest --changed`, `playwright --only-changed`). Para el backend .NET no hay forma fiable de mapear ficheros cambiados a proyectos de test afectados sin heurísticas frágiles o un sistema real de Test Impact Analysis — así que bajo `--changed` los comandos de backend siguen ejecutando la suite completa, con un aviso explícito de por qué: un falso negativo ahí sale más caro que el tiempo ahorrado. La skill deja claro que `--changed` es una optimización de feedback rápido durante desarrollo, nunca lo que corre CI ni sustituto de la evidencia de la suite completa.
- **El agente que verifica no es el que implementó.** Un agente dedicado (modelo pequeño, herramientas mínimas: `Bash`, `Read`, `Grep`, `Glob`, `Skill`) cuyo único trabajo es coger un diff + una frase de intención, delegar en la skill `verify` qué evidencia hace falta, ejecutarla, y devolver el resultado en un formato de handoff fijo. Verificar "desde fuera" — sin haber visto la implementación paso a paso — es intencional: evita que el sesgo de "yo sé que esto funciona porque lo acabo de escribir" contamine el juicio sobre qué contar como evidencia. Por eso el agente es expresamente pequeño: su trabajo no es razonar sobre el diseño, es ejecutar lo que la skill decide y reportar en un formato fijo.
- **Reporte estructurado, no un "todo verde".** El resultado siempre sigue el mismo formato — comportamientos verificados, evidencia automática, evidencia manual, tests añadidos, riesgos sin verificar — y si `Unverified risks` no es `None`, el trabajo no se da por terminado: hay que decir exactamente qué evidencia falta o por qué está genuinamente bloqueado, nunca devolver un hueco sin explicar. Obligar a listar ese campo explícitamente evita que un hueco de cobertura se disuelva en un resumen ambiguo tipo "todo verificado correctamente".

## Variantes

- Un solo comando `npm test` / `dotnet test` para todo: no distingue riesgo, así que o se corre siempre la suite completa (lento) o el agente decide a ojo qué correr (inconsistente).
- Dejar que el propio agente que implementó decida si está verificado: sin el reparto run/verify y sin un verificador externo, el mismo sesgo que escribió el código decide si el código está bien.
- CI como única red de seguridad: verifica después del hecho, no antes de que el agente declare la tarea terminada — más lento en dar feedback y no ayuda al agente a elegir qué comando correr durante el desarrollo.

## Ejemplos

- **[El Baúl](https://github.com/ne2-studio/el-baul)**: primer repo con el patrón (`scripts/verify` con comandos canónicos), y origen del flag `--changed` con su límite documentado para dotnet. Su matriz añade una fila propia — "full-stack wiring" — para cambios que solo se manifiestan con login real contra el compose completo (API, imgproxy, OIDC, Postgres, MinIO).
- **[CashClarity](https://github.com/ne2-studio/cashclarity)**: matriz de riesgo idéntica en estructura a la de El Baúl, con menos suites porque la superficie del proyecto es menor (`backend`, `backend-persistence`, `backend-acceptance`, `frontend`, `frontend-acceptance`, `all`).
- **Un repo propietario (sin enlace)**: la matriz aquí no es genérica — nombra directamente las piezas de dominio del proyecto, lo que confirma que la matriz no es una plantilla a copiar tal cual sino algo que cada repo redacta contra su propio riesgo real.
- **[ne2-factory](https://github.com/ne2-studio/ne2-factory)**: no tiene `scripts/verify` propio (no es una aplicación), pero formaliza `verify` como capability obligatoria en el contrato de entorno, y añade el agente `verifier` que la consume desde fuera del contexto de implementación.
