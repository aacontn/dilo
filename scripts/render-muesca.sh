#!/usr/bin/env bash
#
# La muesca en PNG, sin abrir una ventana.
#
#   ./scripts/render-muesca.sh [carpeta de salida] [--paletas]
#
# Con `--paletas` deja sólo las láminas del makeover: `paletas.png` (cada
# paleta de `PaletaDeDilo` en una columna, estado por estado, sobre barra
# clara y oscura) y `barra-de-menus.png` (el ícono de la barra con cada una).
#
# Con `--antes-despues` deja sólo `antes-despues.png`: el panel del hover de
# la 0.4.5 contra el nuevo —negro, en su estado quieto—, sobre una
# página blanca y un escritorio oscuro, con el vidrio en imitación
# (`render-antes-despues.swift`). Con `--referencia <ruta>` suma al lado el
# cuadro de Droppy.
#
# Compila la geometría de verdad del HUD junto con `render-muesca.swift` y
# rasteriza con `ImageRenderer` fuera de pantalla. No lanza la app, no abre
# ventanas y no toca el escritorio: es lo que hace que la forma se pueda
# revisar desde una sesión que no puede usar la GUI.
#
# Con `--conversacion` deja sólo la barra de llamada de la Conversación:
# `conversacion-<escena>.png` y `conversacion-todas.png`, la vista de verdad
# (`BarraDeLlamada`) en la ventana simulada.
#
# Deja, entre otros, `apertura-1..4.png`: cuatro cortes de la revelación al
# 0 %, 33 %, 66 % y 100 % del tiempo. Son lo único que deja juzgar la animación
# desde una sesión que no puede mirar la pantalla.
#
# Por defecto deja los PNG en /Volumes/SSD2/scratch/dilo-mac/muesca, que es
# taller: no se respalda y se puede borrar entero.

set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
salida="${1:-/Volumes/SSD2/scratch/dilo-mac/muesca-sobria}"
taller="$(mktemp -d)"
trap 'rm -rf "$taller"' EXIT

swiftc -O \
  "$raiz/Dilo/CoreHUD/HUDScreenSnapshot.swift" \
  "$raiz/Dilo/CoreHUD/HUDEstiloSinNotch.swift" \
  "$raiz/Dilo/CoreHUD/HUDNotchGeometry.swift" \
  "$raiz/Dilo/CoreHUD/HUDRevealStyle.swift" \
  "$raiz/Dilo/CoreHUD/NotchFilletShape.swift" \
  "$raiz/Dilo/CoreHUD/SiluetaDeLaMuesca.swift" \
  "$raiz/Dilo/CoreHUD/AsientosDeLaMuesca.swift" \
  "$raiz/Dilo/CoreHUD/HUDSegmentoAlCostado.swift" \
  "$raiz/Dilo/CoreHUD/HUDReunionEnLaMuesca.swift" \
  "$raiz/Dilo/Dictation/HUD/Visuals/HUDVoiceVisualStyle.swift" \
  "$raiz/Dilo/CoreHUD/HUDMetrics.swift" \
  "$raiz/Dilo/CoreHUD/VidrioDeLaMuesca.swift" \
  "$raiz/Dilo/CoreHUD/PiezasDelPanel.swift" \
  "$raiz/Dilo/Settings/Components/PaletaDeDilo.swift" \
  "$raiz/Dilo/Dictation/HUD/Visuals/HUDCheckDeAcuse.swift" \
  "$raiz/scripts/render-muesca.swift" \
  "$raiz/scripts/render-paletas.swift" \
  "$raiz/scripts/render-antes-despues.swift" \
  "$raiz/Dilo/Conversacion/BarraDeLlamada.swift" \
  "$raiz/scripts/render-conversacion.swift" \
  -o "$taller/render-muesca"

# Lo que viene después de la carpeta (`--paletas`) pasa tal cual. Con
# `${1+"$@"}` y no `"${@:2}"`: el bash 3.2 de macOS con `set -u` se queja de
# una lista vacía.
[[ $# -gt 0 ]] && shift
"$taller/render-muesca" "$salida" ${1+"$@"}
