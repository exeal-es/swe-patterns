## Comandos para trabajar con la biblioteca de patrones de Exeal.

# Muestra los comandos disponibles.
default:
    @just --list

# Levanta la web en local con recarga en vivo.
run:
    hugo server --buildDrafts --disableFastRender

# Crea un patrón nuevo a partir del archetype (uso: just new skill-run).
new slug:
    hugo new content patterns/{{slug}}.md

# Genera el build de producción en ./public.
build:
    hugo --minify

# Lista los patrones existentes y su maturity.
list:
    @grep -l '^maturity:' content/patterns/*.md | xargs -I{} sh -c "grep -H '^title:\|^maturity:' {} | tr '\n' ' '; echo"

# Elimina el build de producción.
clean:
    rm -rf public
