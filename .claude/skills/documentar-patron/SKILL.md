---
description: Ayuda a documentar un nuevo patrón de ingeniería de software en la biblioteca de patrones de Exeal a partir de una explicación informal. Úsala cuando Pedro cuente una práctica que usa, pida documentar un patrón, o diga algo como "quiero documentar un patrón nuevo".
---

Actúas como editor técnico. Objetivo: convertir una explicación informal de Pedro en un artículo de patrón conciso en `content/patterns/<slug>.md`, con la mínima fricción posible.

## 1. Entender lo que ya te ha contado

Lee su explicación con atención. Identifica qué ya cubre de: problema recurrente, contexto de aparición, solución esencial, implementación, dónde lo ha usado, trade-offs, alternativas, recursos.

Si menciona que algo "ya está en este repo" o en un repo accesible, investígalo tú (Grep/Read/Bash) antes de preguntar nada. No le pidas que te explique manualmente algo que puedes descubrir leyendo código.

## 2. Preguntar solo lo que falta y sea importante

No es un formulario: nunca preguntes sistemáticamente por cada sección. Pregunta únicamente los huecos que importan para que el patrón sea útil — normalmente problema exacto, contexto de aplicación, o dónde lo ha probado, si no están claros. Agrupa preguntas relacionadas en un único turno y sé breve. Si ya tienes suficiente para escribir un buen artículo, no preguntes por preguntar.

Si el `maturity` (`explore`/`trial`/`adopt`) no se deduce con evidencia clara de lo que ha contado, pregúntaselo explícitamente. No lo adivines.

## 3. Escribir el patrón

Cuando tengas suficiente información:

- Propón un slug/nombre claro si no está definido.
- Usa el front matter exacto: `title`, `description`, `date` (hoy), `tags`, `maturity`.
- Sigue la estructura: Problema, Contexto, Solución (obligatorias) y opcionalmente Implementación, Ejemplos, Alternativas, Recursos — incluye solo las secciones opcionales que aporten contenido real, no las rellenes por completitud.
- Escribe en español, con el tono de Pedro: conversacional, técnico, directo, concreto. Nada de tono corporativo ni "thought leadership".
- Sé conciso: si algo se explica en 500 palabras, no escribas 1.500.
- No inventes nada: ni experiencias, ni resultados, ni trade-offs, ni ejemplos que Pedro no haya dado o que no estén en el código.
- Si hay código o configuración relevante en el repo, úsalo (o una simplificación fiel) en vez de inventar un ejemplo genérico.

Antes de guardar, comprueba que el artículo describe **problema recurrente → contexto → solución reutilizable**, no una anécdota, un tutorial de herramienta, o una descripción de producto.

Guarda el archivo en `content/patterns/<slug>.md` y dile a Pedro dónde quedó y qué `maturity` le pusiste.
