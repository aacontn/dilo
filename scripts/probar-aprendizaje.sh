#!/usr/bin/env bash
#
# Prueba el aprendizaje con Claude con el mismo prompt y el mismo request que
# usa Dilo, para comparar modelos a ojo (Haiku 5.5 contra Sonnet 5.5).
#
#   ./scripts/probar-aprendizaje.sh revisar [modelo…]
#   ./scripts/probar-aprendizaje.sh ordenar [modelo…]
#
# `revisar` pasa cada corrección de `scripts/probar-aprendizaje-correcciones.txt`
# por el filtro determinista y después por el revisor, con cada modelo, y
# muestra qué esperaba la línea, qué dijo cada uno, su motivo y cuánto tardó.
# Lo que el filtro ya descarta se manda igual, marcado: es la prueba de que el
# modelo tampoco lo aprende.
#
# `ordenar` ordena un diccionario de ejemplo (en `probar-aprendizaje.swift`,
# con variantes, grafías malas, palabras comunes aprendidas por error y reglas
# que se pisan) y muestra qué aplicaría solo y qué dejaría propuesto.
#
# Sin modelos, compara `claude-haiku-5-5` y `claude-sonnet-5-5`.
#
# **Llama a la API de Anthropic de verdad**: gasta saldo (centavos) y manda
# esas correcciones y ese diccionario a Anthropic. Los de ejemplo son
# inventados; si pones los tuyos, saben a dónde van.
#
# La clave es la que Dilo guarda en el Llavero (servicio
# `cl.espaciodigital.dilo.proveedores`, cuenta `proveedor.anthropic`, la que se
# pega en Ajustes → Modos → Proveedor general → Anthropic → API key). La lee
# `security` y la pasa por la entrada estándar: nunca queda en un argumento,
# en una variable de entorno ni en pantalla.
#
# Compila los prompts y el cliente de `DiloCore` junto con el driver: lo que
# se prueba es el código de la app, no una copia.

set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
modo="${1:-revisar}"
shift || true
taller="$(mktemp -d)"
trap 'rm -rf "$taller"' EXIT

case "$modo" in
  revisar | ordenar) ;;
  *)
    echo "Modo: revisar u ordenar (no «${modo}»)." >&2
    exit 64
    ;;
esac

modos="$raiz/DiloCore/Sources/DiloModes"
texto="$raiz/DiloCore/Sources/DiloText"
swiftc -O -parse-as-library \
  "$modos/PromptDeTraduccion.swift" \
  "$modos/TraductorConClaude.swift" \
  "$modos/ModelosDeAnthropic.swift" \
  "$modos/ConsultaAClaude.swift" \
  "$texto/AprendizajeDeCorrecciones.swift" \
  "$texto/Reemplazos.swift" \
  "$texto/DiccionarioPersonal.swift" \
  "$texto/RevisionDeCorrecciones.swift" \
  "$texto/OrdenDelDiccionario.swift" \
  "$raiz/scripts/probar-aprendizaje.swift" \
  -o "$taller/probar-aprendizaje"

# Sin `-w` sólo mira si el ítem existe: no lee la clave ni pide permiso.
if ! security find-generic-password \
  -s cl.espaciodigital.dilo.proveedores -a proveedor.anthropic >/dev/null 2>&1; then
  echo "No hay clave de Anthropic en el Llavero de Dilo." >&2
  echo "Pégala en Ajustes → Modos → Proveedor general → Anthropic → API key." >&2
  exit 1
fi

security find-generic-password \
  -s cl.espaciodigital.dilo.proveedores -a proveedor.anthropic -w \
  | "$taller/probar-aprendizaje" "$modo" "$raiz/scripts/probar-aprendizaje-correcciones.txt" "$@"
