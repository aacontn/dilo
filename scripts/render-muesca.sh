#!/usr/bin/env bash
#
# La muesca en PNG, sin abrir una ventana.
#
#   ./scripts/render-muesca.sh [carpeta de salida]
#
# Compila la geometría de verdad del HUD junto con `render-muesca.swift` y
# rasteriza con `ImageRenderer` fuera de pantalla. No lanza la app, no abre
# ventanas y no toca el escritorio: es lo que hace que la forma se pueda
# revisar desde una sesión que no puede usar la GUI.
#
# Deja, entre otros, `apertura-1..4.png`: cuatro cortes de la revelación al
# 0 %, 33 %, 66 % y 100 % del tiempo. Son lo único que deja juzgar la animación
# desde una sesión que no puede mirar la pantalla.
#
# Por defecto deja los PNG en /Volumes/SSD2/scratch/dilo-mac/muesca, que es
# taller: no se respalda y se puede borrar entero.

set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
salida="${1:-/Volumes/SSD2/scratch/dilo-mac/muesca}"
taller="$(mktemp -d)"
trap 'rm -rf "$taller"' EXIT

swiftc -O \
  "$raiz/Dilo/CoreHUD/HUDScreenSnapshot.swift" \
  "$raiz/Dilo/CoreHUD/HUDEstiloSinNotch.swift" \
  "$raiz/Dilo/CoreHUD/HUDNotchGeometry.swift" \
  "$raiz/Dilo/CoreHUD/HUDRevealStyle.swift" \
  "$raiz/Dilo/CoreHUD/NotchFilletShape.swift" \
  "$raiz/Dilo/Dictation/HUD/Visuals/HUDVoiceVisualStyle.swift" \
  "$raiz/Dilo/CoreHUD/HUDMetrics.swift" \
  "$raiz/scripts/render-muesca.swift" \
  -o "$taller/render-muesca"

"$taller/render-muesca" "$salida"
