---
title: "Home repo y skills compartidas entre repos"
description: "En una empresa con varios repositorios, un agente lanzado dentro de uno no sabe nada de los demás ni del negocio, y las skills que necesitaría en todos acaban viviendo en uno solo. La solución es un home repo que los conoce a todos: guarda el conocimiento que no pertenece a ningún repo, enlaza al resto sin copiar sus hechos y publica las skills comunes como plugins que cada repo activa con el mismo bloque de configuración."
date: 2026-11-12
tags:
  - agentes
  - devex
maturity: trial
---

## Problema

Cuando lanzo un agente dentro de un repo, su mundo es ese repo: su `CLAUDE.md` y su código. En una empresa con varios repos eso se queda corto en cuanto la tarea toca una frontera:

- **No sabe qué más existe.** Ni qué repos hay, ni de qué es dueño cada uno, ni qué contrato rompe si cambia una API o el orden de un release.
- **El conocimiento que no es de ningún repo no tiene casa.** Cómo gana dinero la empresa, qué corre dónde y por qué, qué incidentes ha habido, cómo se opera producción, con qué criterio se prioriza. Acaba siendo criterio que aplico yo a mano en cada conversación.
- **Las skills que harían falta en todos los repos viven en uno.** La skill para consultar la base de datos de producción estaba en el `.claude/skills/` del backend principal; un agente trabajando en otro repo no llegaba a ella.
- **Copiar no lo arregla.** Los hechos copiados de un repo a otro se pudren: uno de los repos seguía describiendo ficheros de infraestructura que ya no existían.

Aparece cuando hay varios repos con stacks y ciclos de vida distintos (backends, workers, infraestructura como código, configuración de máquinas, código heredado de terceros), agentes trabajando en todos, y el mapa de cómo encaja todo en la cabeza de una o dos personas.

## Solución

Un repo hace de casa y conoce a todos los demás. Cumple tres papeles: es el **mapa** (qué repos hay, de qué es dueño cada uno, dónde mirar), es el **hogar del conocimiento sin dueño** (lo que cruza repos o no pertenece a ninguno) y es el **punto de distribución** de las skills, las herramientas y la identidad que necesita un agente en cualquier repo. Lo sostiene una sola regla: cada hecho tiene una casa, y en el resto de sitios se enlaza.

### 1. Todos los repos, lado a lado

Un directorio de workspace fijo, con el home como un repo más:

```
~/work/acme/
  home/      # el home repo
  api/
  worker/
  infra/
```

De esta convención cuelga todo lo demás: los enlaces entre repos son relativos (`../api/docs/orders.md#statuses`) y los scripts del home recorren los repos hermanos.

### 2. El `AGENTS.md` del home es el mapa

Es un [CLAUDE.md finito](/patterns/claude-md-finito/) aplicado a la empresa entera. `CLAUDE.md` es una sola línea, `@AGENTS.md`.

```markdown
# Acme technical docs

Platform-level knowledge: how the systems fit together, what runs where, the contracts between
repos, known gaps, and the runbooks for operating it all. Repo internals live in each repo;
this repo links to them and does not copy their facts.

## Repos

All repos are checked out side by side under `~/work/acme/`; links between them are relative.

| Repo | Owns |
|---|---|
| `home` | This: platform docs, runbooks, the `acme-ops` and `acme-tools` plugins (`skills/`) |
| `api` | The main backend: public API, admin, background jobs |
| `infra` | Infrastructure as code for every environment, secrets tooling |
| `legacy-vendor-app` | Third-party app, to be retired. Before touching the box: [its hand-made state](docs/platform/infrastructure.md#the-legacy-box) |

## Where to look

- **Platform overview** (business, components, who owns what): [business overview](docs/platform/business-overview.md), [system map](docs/platform/system-map.md)
- **Cross-repo contracts** (APIs, release order): [contracts](docs/platform/contracts.md)
- **Architecture decisions**: before a change to structure, boundaries, integrations or a repo-wide convention, run `~/work/acme/home/scripts/adr-index` and follow every applicable accepted ADR
- **Operating production**: [runbooks](docs/runbooks/README.md) for actions, [operations](docs/operations/) for incidents
- **Known problems** before proposing work: issues tagged `gap` in the tracker ([gaps](docs/gaps/README.md))

## Writing here

- Write for an agent: facts it cannot find by looking, linked to the source of truth in the
  owning repo. Leave values the environment holds (IPs, crontabs, env vars) in that environment
  and link to it.
- One meaning in one place. Update the doc that owns a fact instead of restating it elsewhere.
```

### 3. Qué vive en el home

| Qué consigo | Cómo lo hago |
|---|---|
| Que el agente sepa qué repos hay y de qué es dueño cada uno | Tabla `Repos` del `AGENTS.md`. Incluye el código heredado de terceros, con su aviso («antes de tocar esa máquina, lee esto»). |
| Que lea solo lo que toca | Lista `Where to look`: tema, cuándo leerlo y enlace. No explica el contenido. |
| Que entienda el negocio y el producto | `docs/platform/business-overview.md`, `system-map.md` y un doc de dónde vienen los ingresos (un snapshot fechado de producción que se reemplaza entero, no se le añade). Un doc por área de dominio que atraviesa varios repos. |
| Que no rompa una frontera entre repos | `contracts.md`: una entrada por contrato productor → consumidor, con sus invariantes y el orden de release. Cada repo sigue siendo canónico de su lado; el home tiene el resumen cruzado. |
| Que sepa qué corre dónde y por qué | `current-state.md` e `infrastructure.md` nombran cada pieza y enlazan a donde vive su configuración. Un inventario de integraciones de terceros: para qué sirve cada una, evidencia de uso y dónde está su código. |
| Que sepa cómo se accede a cada cosa | `access.md` (roles cloud, VPN, usuarios de base de datos, consolas de terceros) y `observability.md` (dónde están los logs y cómo seguir un caso). |
| Que respete las decisiones de arquitectura de todos los repos | Cada ADR vive en el `docs/adrs/` del repo dueño; los que cruzan repos, en el home. `scripts/adr-index` recorre los repos hermanos y devuelve una tabla (repo, título, estado, resumen, ruta) para abrir solo los que aplican. La skill `write-adr` es dueña del test de admisión y de la plantilla. |
| Que opere producción igual desde cualquier repo | Los runbooks son skills: `skills/<name>/SKILL.md` es la única copia, la ejecuta el agente y la lee la persona. Front matter con `risk` (read, reversible, mutating, destructive) y `environments`; secciones Gate, Preconditions, Steps con «Done when», Verify, Rollback y Log. `docs/runbooks/README.md` es solo el índice: riesgo, cuándo usarla y si se ha ejercitado alguna vez. Las destructivas llevan `disable-model-invocation: true`. |
| Que haya memoria de incidentes | `docs/operations/incidents/YYYY-MM-DD-slug.md` con un registro fijo (síntoma, impacto en cliente, impacto económico, punto de entrada, primera vez visto) y un doc con el proceso de gestión. |
| Que depure un caso real de producción | Una guía de heurísticas (qué campo, tabla o grupo de logs responde a cada síntoma) que enlaza al repo dueño para la semántica, más las skills `read-db` y `read-logs`: solo lectura y con `--env` obligatorio, para que leer producción sea siempre explícito. |
| Que priorice como lo haría yo | `prioritisation.md`: rúbrica impacto × coste, qué cambia cada banda y ejemplos trabajados de «esto no merece la pena» sacados de conversaciones reales. Detalle en [Gestión del backlog con skills](/patterns/gestion-del-backlog-con-skills/). |
| Que conozca los problemas conocidos antes de proponer trabajo | Issues con la etiqueta `gap` en el issue tracker. En el home quedan el proceso y la plantilla, con un bloque «Check» de solo lectura que se puede volver a ejecutar. |
| Que use el issue tracker como el resto del equipo | `issue-tracking.md` (proyectos, campos, workflow), el MCP del tracker declarado en cada repo, una skill REST para lo que el MCP no cubre y skills para escribir y refinar issues. Detalle en [Issue tracker como fuente única del estado del trabajo](/patterns/tracker-fuente-unica-del-estado-del-trabajo/). |
| Que diseñe proyectos que cruzan repos | `docs/projects/<slug>/tech-spec.md` con una línea `Status:` y otra `Tracking:` al epic. El diseño vive en la spec; el desglose y el estado, en el tracker. `docs/roadmap/` guarda direcciones sin fecha ni compromiso. El proceso completo está en [De iniciativa a slices ejecutables](/patterns/de-iniciativa-a-slices-ejecutables/). |
| Convenciones comunes sin repetirlas | `engineering-conventions.md` una vez; cada repo enlaza a la sección que necesita. |
| Las mismas skills en todos los repos | Marketplace de plugins en el propio home (paso 5). |
| Que el agente actúe en GitHub con identidad propia | Una GitHub App. Un hook `SessionStart` del plugin pone autor de bot en los commits y antepone al `PATH` un wrapper de `gh` que pide un token de la app de una hora, limitado al repo. Los PR del agente no son míos, así que puedo aprobarlos. |
| Que use credenciales sin poder leerlas | Ficheros `~/.config/acme/*.env` que los scripts cargan dentro del mismo comando, y un `permissions.deny` de `Read` sobre ese directorio en cada repo. |
| Automatización que cruza repos | Scripts del home lanzados por timers de systemd enlazados desde el checkout, así un `git pull` los actualiza. El script hace la parte mecánica; si hace falta juicio, lo pone una skill. |
| Que los enlaces entre repos no se pudran | `bin/check-docs` en pre-commit y CI (paso 7). |

### 4. Qué no vive en el home

- **Los internos de un repo** (stack, comandos, tests, despliegue): en su `CLAUDE.md` y su `docs/`. El home enlaza, a veces a un encabezado concreto.
- **Los valores que ya tiene el entorno** (IPs, tamaños, crontabs, variables): en la infraestructura como código o en la máquina. El home nombra la pieza y enlaza a su configuración.
- **El estado del trabajo**: en el issue tracker. Los gaps empezaron como un fichero por gap, con una cola ordenada y un check que la validaba; acabaron migrados a issues (84 abiertos y 16 cerrados) y los ficheros borrados. Las specs de proyecto perdieron sus checkboxes y marcas de «hecho». El modelo completo está en [Issue tracker como fuente única del estado del trabajo](/patterns/tracker-fuente-unica-del-estado-del-trabajo/).
- **La lógica determinista**: en un script del repo dueño del sistema. La skill del home lo llama y se queda con el juicio: cuándo, con qué permiso, cómo verificar y cómo deshacer.

### 5. Las skills se publican como plugins desde el propio home

Una carpeta plana `skills/` y un `.claude-plugin/marketplace.json` que reparte las skills en dos plugins, sin `plugin.json`:

```json
{
  "name": "acme",
  "owner": { "name": "Acme" },
  "plugins": [
    {
      "name": "acme-ops",
      "source": "./",
      "strict": false,
      "description": "Runbooks that change dev or production, as skills.",
      "skills": ["./skills/release-prod", "./skills/restore-prod-database"]
    },
    {
      "name": "acme-tools",
      "source": "./",
      "strict": false,
      "description": "Everyday tools for agents in any repo: read-only data and logs, issue tracker, ADRs.",
      "skills": ["./skills/read-db", "./skills/read-logs", "./skills/write-adr"],
      "hooks": {
        "SessionStart": [
          { "matcher": "startup",
            "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/bin/update-plugins", "timeout": 60 }] },
          { "hooks": [{ "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}\"/bin/agent-session-env", "timeout": 10 }] }
        ]
      }
    }
  ]
}
```

Las decisiones que hay detrás:

- **Dos plugins, un criterio.** `acme-tools` lleva lo que necesita un agente en cualquier repo (leer datos y logs, el issue tracker, los ADRs). `acme-ops` lleva los runbooks que cambian dev o producción. Un repo que no opera nada activa solo el primero.
- **`source: "./"`.** A la caché de plugins viaja el repo entero, no solo `skills/`, así que una skill puede enlazar a `../../docs/platform/access.md` y el enlace resuelve también allí.
- **Sin `version`.** La versión es el commit: lo que se sube a `main` es lo que reciben los agentes.
- **Los hooks van en el plugin.** Cualquier repo que lo active recibe la actualización de plugins y la identidad de agente sin cablear nada más.
- **El home también consume sus plugins desde GitHub.** Lo que ejecutan los agentes es lo publicado, no lo que haya en el working tree.

### 6. Cablear cada repo

Tres piezas, iguales en todos. El `.claude/settings.json` del repo:

```json
{
  "permissions": { "deny": ["Read(~/.config/acme/**)"] },
  "enabledPlugins": { "acme-ops@acme": true, "acme-tools@acme": true },
  "extraKnownMarketplaces": {
    "acme": { "source": { "source": "github", "repo": "acme/home" } }
  },
  "enabledMcpjsonServers": ["issue-tracker"]
}
```

Un `.mcp.json` con el servidor MCP del issue tracker. Y dos líneas en el `CLAUDE.md` del repo:

```markdown
- **Architecture decisions**: Before a change to structure, boundaries, integrations or a repo-wide
  convention, run `~/work/acme/home/scripts/adr-index` and follow every applicable accepted ADR;
  a change that contradicts one proposes superseding it with `acme-tools:write-adr`.
- **Platform-level, cross-repo context** (system map, contracts, infrastructure, runbooks, gaps)
  lives in home's [`AGENTS.md`](https://github.com/acme/home/blob/main/AGENTS.md)
  (`../home/AGENTS.md` when checked out side by side).
```

El resto del `CLAUDE.md` sigue siendo del repo: qué es, cómo se ejecuta y se verifica (sus propias skills [run](/patterns/skill-run/) y [verify](/patterns/skill-verify/)), dónde van los worktrees, cómo se despliega.

Con esto el contexto llega por capas, y ninguna copia a otra:

1. **Siempre**: el `CLAUDE.md` del repo, las descripciones de las skills (las locales y las de los plugins) y lo que dejan los hooks de arranque.
2. **Cuando la tarea sale del repo**: el puntero lleva al `AGENTS.md` del home, y este al doc concreto.
3. **Antes de un cambio estructural**: `adr-index`, y solo los ADRs que aplican.
4. **Cuando la tarea coincide con una skill**: se carga la skill, que enlaza a los docs del home que necesita.

### 7. Dos guardarraíles

`bin/check-docs` comprueba todos los enlaces relativos de los `.md` del home, anclas incluidas, y también los que apuntan a repos hermanos cuando están clonados al lado. Corre en pre-commit y en CI.

`bin/update-plugins`, el hook `SessionStart` del plugin, mantiene las skills al día:

```bash
marketplace_dir="$HOME/.claude/plugins/marketplaces/acme"
stamp="${XDG_STATE_HOME:-$HOME/.local/state}/acme/plugin-update.stamp"
loaded="$(basename "$CLAUDE_PLUGIN_ROOT")"   # el commit que cargó esta sesión

# refresca el clon del marketplace como mucho una vez por hora
if [[ -z "$(find "$stamp" -mmin -60 2>/dev/null)" ]]; then
  claude plugin marketplace update acme >/dev/null 2>&1 && touch "$stamp"
fi

latest="$(git -C "$marketplace_dir" rev-parse --short=12 HEAD 2>/dev/null)" || exit 0
[[ -n "$latest" && "$loaded" != "$latest" ]] || exit 0

for plugin in acme-ops@acme acme-tools@acme; do
  claude plugin update "$plugin" >/dev/null 2>&1 || exit 0
done

echo "acme plugins: this session loaded ${loaded}; updated to ${latest} for the next session. Until a restart, read a skill from ~/work/acme/home/skills/<name>/SKILL.md (pull main first) rather than the loaded copy."
```

Nunca bloquea la sesión: cualquier fallo sale con 0 y sin salida. La línea del `echo` entra en el contexto de la sesión.

Cómo se sabe que quedó bien aplicado: cablear un repo son dos commits (el puntero y el `settings.json`), y el despliegue inicial fue exactamente eso, en un solo barrido. Mover una skill al home la borra del repo donde vivía, y el script que ejecuta se queda allí. Y el `AGENTS.md` del home crece por filas, no por prosa: pasó de 41 a 51 líneas en un mes mientras se añadían repos, docs y skills.

### Gotchas

- **La caché de plugins caduca en silencio.** Cada repo instala los plugins por proyecto y el auto-update viene apagado para un marketplace propio. Una sesión cargó un runbook de deploy desde una caché de nueve días que todavía nombraba un script ya retirado. De ahí el hook del paso 7.
- **La actualización no entra en la sesión en curso.** El hook solo puede dejarla lista para la siguiente; por eso le dice al agente que lea la skill del checkout hasta que se reinicie.
- **Cada proyecto va a su ritmo.** El mismo día, en la misma máquina, tres repos tenían tres commits distintos del mismo plugin. El hook solo actualiza el proyecto donde arranca la sesión.
- **Un `version` fijo congela a todo el mundo.** Con `version` en el manifiesto, los commits nuevos no llegan hasta que alguien lo sube. Se quitó.
- **`../home` no resuelve desde un worktree.** Ni anidado (`.claude/worktrees/<x>/`) ni fuera del workspace. Lo que el agente tiene que ejecutar va con ruta absoluta, que funciona desde cualquier sitio.
- **El CI no tiene repos hermanos.** En el CI de un repo consumidor `../home` no existe: el puntero lleva la URL de GitHub y, entre paréntesis, la ruta relativa. En el home, `check-docs` se salta sin avisar los enlaces a un repo que no está clonado, así que los cerca de 190 enlaces a otros repos solo se verifican en local.
- **Las skills dan por hecho el layout.** Dentro de un `SKILL.md`, un enlace a `docs/` resuelve en la caché, pero uno a un repo hermano no, y los ejecutables se invocan con la ruta absoluta del workspace. Funciona mientras todas las máquinas tengan el mismo layout.
- **La skill y la herramienta que conduce viven en repos distintos.** Renombrar el script en el repo dueño obligó a renombrar dos skills en el home: los cambios de nombre hay que coordinarlos entre los dos repos.
- **El estado duradero no puede vivir en la crónica de un incidente.** Las protecciones puestas a mano durante un incidente solo estaban en su relato, y un plan de deploy estuvo a punto de pasarlas por alto. Se movieron al doc de infraestructura; el incidente y el mapa enlazan allí.
- **Un registro sin verificar miente.** Al comprobar los gaps contra el estado real, varios se descartaron por inválidos. Por eso cada gap lleva su «Check» reejecutable.
- **Lo que sale al tracker deja de verse sin MCP.** La regla escrita: un agente sin el MCP no ve los gaps y tiene que decirlo, no adivinar.
- **Los agentes sobreproducen.** Los issues solo los creo yo; los agentes escriben sus hallazgos como filas de un digest semanal ([Gestión del backlog con skills](/patterns/gestion-del-backlog-con-skills/)).
- **El MCP del tracker no llega a todo.** No quita un enlace, no ejecuta un comando sobre muchos issues, no toca administración, y alguna respuesta engaña (devuelve solo el número de enlaces, o `{}` tanto si el comando funcionó como si no). De ahí la skill REST, con su propio `GOTCHAS.md`. La lista entera está en [Issue tracker como fuente única del estado del trabajo](/patterns/tracker-fuente-unica-del-estado-del-trabajo/).
- **El wrapper de `gh` cae al login humano** si la app no está instalada en ese repo, con una nota en stderr: el PR sale a mi nombre. Hay que instalarla en todos. Es una GitHub App y no un usuario bot porque un miembro no puede añadir un colaborador a la organización, pero un admin del repo sí puede instalar una app que no pide permisos de organización.
- **El cableado deriva y nada lo comprueba.** La tabla de «agent setup» del propio home lista seis de los diez repos y dice que todos activan los dos plugins, cuando tres activan solo uno. Dos repos no tienen la línea de ADRs y cuatro no tienen fichero de instrucciones.

## Variantes

- **Monorepo.** Si todo cabe en un repo no hace falta home: el `CLAUDE.md` raíz hace de mapa, uno por servicio hace de puntero ([CLAUDE.md finito](/patterns/claude-md-finito/)) y las skills viven en el `.claude/skills/` del propio repo.
- **Auto-update nativo en lugar del hook.** Claude Code puede actualizar un marketplace en segundo plano, pero viene apagado para uno propio: lo activa cada persona en `/plugin` → Marketplaces, o un admin con `autoUpdate` en managed settings. Con managed settings repartidos a todas las máquinas sustituye al hook; sin ellos depende de que cada persona lo active.
- **Marketplace desde un directorio local.** Registrado desde una ruta en vez de desde GitHub, los plugins se leen en el sitio: sin caché y sin paso de actualización. A cambio, los agentes ejecutan lo que haya en ese working tree y no lo publicado en `main`, y la ruta tiene que existir igual en cada máquina.

## Ejemplos

- **Un conjunto de repos propietarios (sin enlace)**: nueve repos más el home. Un `AGENTS.md` de 51 líneas, 16 docs de plataforma, 5 registros de incidente, 21 skills en dos plugins (12 de operaciones y 9 de herramientas), 9 ADRs indexados en tres repos y unos 190 enlaces del home hacia los demás. El `settings.json` es idéntico byte a byte en cinco de los repos. El home existía desde hacía meses como repo de documentación con un índice en el README; lleva un mes en esta forma.

## Recursos

- [Create a marketplace](https://code.claude.com/docs/en/plugin-marketplaces): formato de `marketplace.json` y cómo validarlo.
- [Host and maintain a marketplace](https://code.claude.com/docs/en/plugins/host-marketplace): versiones, auto-update y acceso a un marketplace privado.
- [Hooks reference](https://code.claude.com/docs/en/hooks): `SessionStart` y `${CLAUDE_PLUGIN_ROOT}`.
- [CLAUDE.md finito](/patterns/claude-md-finito/), [Skill Run](/patterns/skill-run/) y [Skill Verify](/patterns/skill-verify/): lo que se queda en cada repo.
- [Issue tracker como fuente única del estado del trabajo](/patterns/tracker-fuente-unica-del-estado-del-trabajo/): el estado del trabajo que sale del home y cómo lo leen los agentes.
- [Gestión del backlog con skills](/patterns/gestion-del-backlog-con-skills/): la rúbrica y las skills de triaje y refinamiento que viven en el home.
- [De iniciativa a slices ejecutables](/patterns/de-iniciativa-a-slices-ejecutables/): cómo se diseña y se trocea una iniciativa, incluidas las que cruzan repos.
