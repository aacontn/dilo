#!/bin/sh
# dilo-agente.sh — un agente de código le avisa a la muesca de Dilo en qué
# está, desde su propio hook (2026-10-15; docs/design/agentes-en-la-muesca.md).
#
#   sh dilo-agente.sh <agente> <fase>
#
#   agente  claude | codex | cursor | cowork  (otro nombre se muestra como «Agente»)
#   fase    trabajando | espera | listo | error | fin
#
# El proyecto es el nombre de la carpeta: $DILO_PROYECTO si está, si no
# $CLAUDE_PROJECT_DIR (Claude Code), si no la carpeta actual. Sólo el nombre,
# nunca la ruta, el prompt ni la herramienta: la URL queda en el registro de
# LaunchServices.
#
# Lo que este script NO hace, a propósito:
#   - No lee lo que el agente le pasa por stdin ni sus argumentos de más.
#     Codex agrega como último argumento un JSON con la conversación; se
#     ignora entero.
#   - No abre Dilo si no está corriendo (`open` lo lanzaría): sin Dilo
#     abierto no hay muesca que avisar.
#   - No falla nunca ni escribe nada: un hook que sale con error o imprime
#     algo le cambia el comportamiento al agente (Claude Code agrega lo que
#     imprime UserPromptSubmit al contexto).
#
# La URL va a Dilo por su bundle id y no a «quien tenga el esquema»: cada
# build de Debug y cada corrida de los tests registra `dilo://` en
# LaunchServices, y sin el id una URL podía lanzar una copia vieja de
# DerivedData mientras la de verdad seguía abierta.
#
# Variables para probar:
#   DILO_ID=cl.espaciodigital.dilo.prueba   manda la URL a esa copia (por
#                                           defecto, cl.espaciodigital.dilo).
#   DILO_SOLO_IMPRIMIR=1                    imprime la URL y no abre nada
#                                           (lo usan los tests).

agente=${1:-otro}
fase=${2:-}
carpeta=${DILO_PROYECTO:-${CLAUDE_PROJECT_DIR:-$PWD}}
proyecto=$(basename -- "$carpeta" 2>/dev/null)

# Letras y números ASCII, `-`, `.` y `_` tal cual; cualquier otro byte en
# %XX, así una carpeta «Mi café & co» no rompe la URL y en `log show` se
# sigue leyendo «claude» y «espera». Sin python ni jq, que no vienen con
# macOS; `od` sí.
codificar() {
  for byte in $(printf '%s' "$1" | od -An -v -tx1); do
    case $byte in
      2d | 2e | 5f | 3[0-9] | 4[1-9a-f] | 5[0-9a] | 6[1-9a-f] | 7[0-9a])
        # shellcheck disable=SC2059
        printf "\\$(printf '%03o' "0x$byte")" ;;
      *) printf '%%%s' "$byte" ;;
    esac
  done
}

url="dilo://agente?de=$(codificar "$agente")&fase=$(codificar "$fase")&proyecto=$(codificar "$proyecto")"

if [ -n "$DILO_SOLO_IMPRIMIR" ]; then
  printf '%s\n' "$url"
  exit 0
fi

# Sólo si hay un Dilo corriendo, y en el fondo: el agente no espera a
# LaunchServices en cada herramienta que usa.
if pgrep -xq Dilo 2>/dev/null; then
  (open -g -b "${DILO_ID:-cl.espaciodigital.dilo}" "$url" >/dev/null 2>&1 &)
fi
exit 0
