#!/usr/bin/env bash
#
# Traduce dictados chilenos de ejemplo con Claude, con el mismo prompt y el
# mismo request que usa Dilo, para juzgar la calidad a ojo.
#
#   ./scripts/probar-traduccion.sh [en|zh] [archivo de dictados]
#
# Por defecto traduce al inglés los de `scripts/probar-traduccion-dictados.txt`
# (uno por bloque, separados por una línea con `---`).
#
# **Llama a la API de Anthropic de verdad**: gasta saldo (centavos con Haiku
# 5.5) y manda esos dictados a Anthropic. Los de ejemplo son inventados; si
# pones dictados tuyos, saben a dónde van.
#
# La clave es la que Dilo guarda en el Llavero (servicio
# `cl.espaciodigital.dilo.proveedores`, cuenta `proveedor.anthropic`, la que se
# pega en Ajustes → Modos → Proveedor general → Anthropic → API key). La lee
# `security` y la pasa por la entrada estándar: nunca queda en un argumento,
# en una variable de entorno ni en pantalla. macOS puede preguntar si dejas
# que `security` la lea; es una vez.
#
# Compila `PromptDeTraduccion.swift`, `TraductorConClaude.swift` y
# `ModelosDeAnthropic.swift` de `DiloCore` junto con el driver: lo que se
# prueba es el código de la app, no una copia.

set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destino="${1:-en}"
dictados="${2:-$raiz/scripts/probar-traduccion-dictados.txt}"
taller="$(mktemp -d)"
trap 'rm -rf "$taller"' EXIT

case "$destino" in
  en | zh) ;;
  *)
    echo "Destino: en o zh (no «${destino}»)." >&2
    exit 64
    ;;
esac

swiftc -O -parse-as-library \
  "$raiz/DiloCore/Sources/DiloModes/PromptDeTraduccion.swift" \
  "$raiz/DiloCore/Sources/DiloModes/TraductorConClaude.swift" \
  "$raiz/DiloCore/Sources/DiloModes/ModelosDeAnthropic.swift" \
  "$raiz/scripts/probar-traduccion.swift" \
  -o "$taller/probar-traduccion"

# Sin `-w` sólo mira si el ítem existe: no lee la clave ni pide permiso.
if ! security find-generic-password \
  -s cl.espaciodigital.dilo.proveedores -a proveedor.anthropic >/dev/null 2>&1; then
  echo "No hay clave de Anthropic en el Llavero de Dilo." >&2
  echo "Pégala en Ajustes → Modos → Proveedor general → Anthropic → API key." >&2
  exit 1
fi

security find-generic-password \
  -s cl.espaciodigital.dilo.proveedores -a proveedor.anthropic -w \
  | "$taller/probar-traduccion" "$destino" "$dictados"
