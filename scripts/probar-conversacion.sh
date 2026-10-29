#!/usr/bin/env bash
#
# Prueba la Conversación sin abrir Dilo: el router con frases de ejemplo y,
# con `--llamar`, un par de turnos de verdad en streaming con Claude Haiku 5.5.
#
#   ./scripts/probar-conversacion.sh            # sólo el router, sin red
#   ./scripts/probar-conversacion.sh --llamar   # más dos turnos con Haiku
#
# El router no llama a nadie: decide con reglas (`RouterDeModelos`) y se
# imprime qué modelo contestaría cada frase y por qué.
#
# **`--llamar` usa la API de Anthropic de verdad**: dos turnos con Haiku 5.5
# (fracciones de centavo) y las frases de ejemplo de este script viajan a
# Anthropic. Imprime cuánto tardó el primer pedazo de texto, la primera
# oración completa —que es cuando la voz empezaría a hablar—, los tokens y
# lo que costó. Se corre a mano, nunca desde un test.
#
# La clave es la que Dilo guarda en el Llavero (servicio
# `cl.espaciodigital.dilo.proveedores`, cuenta `proveedor.anthropic`). La lee
# `security` y la pasa por la entrada estándar: nunca queda en un argumento,
# en una variable de entorno ni en pantalla.
#
# Compila los archivos de `DiloCore` que usa la app junto con el driver: lo
# que se prueba es el código de la app, no una copia.

set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
taller="$(mktemp -d)"
trap 'rm -rf "$taller"' EXIT

modos="$raiz/DiloCore/Sources/DiloModes"
swiftc -O -parse-as-library \
  "$modos/ModelosDeAnthropic.swift" \
  "$modos/CostosDeClaude.swift" \
  "$modos/PromptDeTraduccion.swift" \
  "$modos/TraductorConClaude.swift" \
  "$modos/ConsultaAClaude.swift" \
  "$modos/ConversacionConClaude.swift" \
  "$modos/RouterDeModelos.swift" \
  "$modos/TrozosParaDecir.swift" \
  "$raiz/scripts/probar-conversacion.swift" \
  -o "$taller/probar-conversacion"

if [[ "${1:-}" != "--llamar" ]]; then
  "$taller/probar-conversacion" router
  exit 0
fi

# Sin `-w` sólo mira si el ítem existe: no lee la clave ni pide permiso.
if ! security find-generic-password \
  -s cl.espaciodigital.dilo.proveedores -a proveedor.anthropic >/dev/null 2>&1; then
  echo "No hay clave de Anthropic en el Llavero de Dilo." >&2
  echo "Pégala en Ajustes → Claude." >&2
  exit 1
fi

security find-generic-password \
  -s cl.espaciodigital.dilo.proveedores -a proveedor.anthropic -w \
  | "$taller/probar-conversacion" llamar
