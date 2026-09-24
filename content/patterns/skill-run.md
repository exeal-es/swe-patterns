---
title: "Skill Run"
description: "Hacer reproducible para un agente la ejecución local de una aplicación."
date: 2026-09-24
tags:
  - agentes
  - devex
maturity: trial
---

## Problema

Cuando pido a Claude que levante un proyecto en local, suele liarse: no sabe qué variables de entorno necesita, en qué orden arrancar los servicios, o qué comando exacto usar. Cada vez que lo hace, redescubre el mismo proceso a base de prueba y error.

## Contexto

Aparece en proyectos donde levantar el entorno local no es un único comando obvio: hay varios pasos, dependencias externas, o configuración que no está documentada en ningún sitio salvo en mi cabeza.

## Solución

Separar dos cosas:

1. Un `run.sh` determinista que levanta el proyecto siempre de la misma forma, sin ambigüedad.
2. Una skill de Claude Code que explica al agente cuándo y cómo usar ese script, y qué hacer si algo falla.

El script es la fuente de verdad del "cómo". La skill es la fuente de verdad del "cuándo" y del contexto que el script no puede expresar por sí solo.

## Implementación

`run.sh` en la raíz del repo, sin parámetros, que deja el proyecto arrancado y listo:

```bash
#!/usr/bin/env bash
set -euo pipefail

docker compose up -d db
npm install
npm run dev
```

Una skill (`.claude/skills/run/SKILL.md`) que le dice al agente que use ese script en vez de intentar deducir el arranque por su cuenta, y qué comprobar si el arranque falla.

## Ejemplos

En El Baúl, y en fase de adopción en otros repos.

## Alternativas

- `README` con instrucciones manuales: más fácil de dejar desactualizado, y el agente tiene que interpretarlo en vez de ejecutarlo.
- `Makefile`/`justfile` sin skill asociada: el agente puede no saber que existe o cuándo usarlo.
