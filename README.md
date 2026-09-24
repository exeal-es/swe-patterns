# Patrones — Exeal

Biblioteca pública de patrones de ingeniería de software de Exeal.

> Un patrón documenta una solución reutilizable a un problema que he encontrado en la práctica. No tiene que ser original ni universalmente aplicable.

Esta biblioteca representa conocimiento extraído de experiencia real, no una colección de supuestas "best practices".

## Stack

- [Hugo](https://gohugo.io) como generador de sitio estático, sin tema externo (layouts propios en `layouts/`).
- Markdown en `content/patterns/` como contenido.
- Git como source of truth.
- [`just`](https://github.com/casey/just) como interfaz de comandos.
- GitHub Actions para publicar en GitHub Pages.

## Uso

```bash
just --list    # ver todos los comandos disponibles
just run       # levantar la web en local
just new <slug> # crear un patrón nuevo (content/patterns/<slug>.md)
just build     # build de producción en ./public
```

## Modelo de un patrón

Cada patrón es un Markdown en `content/patterns/` con este front matter:

```yaml
---
title: "Skill Run"
description: "Hacer reproducible para un agente la ejecución local de una aplicación."
date: 2026-09-24
tags:
  - agentes
  - devex
maturity: trial
---
```

`maturity` admite tres valores:

- `explore`: idea que estoy investigando o empezando a probar.
- `trial`: la he utilizado de verdad y parece útil, pero sigo validándola.
- `adopt`: la he utilizado repetidamente y forma parte de mi forma habitual de trabajar.

La estructura del artículo (ver `archetypes/patterns.md`) tiene tres secciones esenciales — Problema, Contexto, Solución — y cuatro opcionales que solo se incluyen si aportan algo: Implementación, Ejemplos, Alternativas, Recursos.

## Escribir un patrón con Claude Code

El repo incluye la skill `documentar-patron` (`.claude/skills/documentar-patron/`). Basta con pedirle a Claude, dentro de este repo, algo como "quiero documentar un patrón nuevo" y contarle informalmente la práctica que estás usando. La skill identifica los huecos importantes, investiga el código cuando puede en vez de preguntar, y escribe el artículo final.

## Deployment

La web se publica en `patterns.exeal.com` vía GitHub Pages, desplegada automáticamente en cada push a `main` (`.github/workflows/deploy.yml`).

Pendiente de configurar (fuera del repo):

- Activar GitHub Pages con origen "GitHub Actions" en la configuración del repo.
- Apuntar el DNS de `patterns.exeal.com` (registro `CNAME`) al dominio de GitHub Pages del repo. El archivo `static/CNAME` ya deja fijado el dominio custom para cuando el DNS esté listo.
