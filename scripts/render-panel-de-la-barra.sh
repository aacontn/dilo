#!/usr/bin/env bash
#
# El panel del clic derecho en el ícono de la barra, en PNG, sin abrir una
# ventana.
#
#   ./scripts/render-panel-de-la-barra.sh [carpeta de salida]
#
# Compila el panel de verdad —el modelo (`PanelDeLaBarra.swift`), la vista
# (`VistaDelPanelDeLaBarra.swift`) y las piezas que comparte con el panel de
# la muesca— junto con `render-panel-de-la-barra.swift`, y rasteriza con
# `ImageRenderer` fuera de pantalla. No lanza la app, no abre ventanas y no
# toca el escritorio.
#
# Deja cada escena sobre una página clara y sobre un escritorio oscuro, con
# una barra de menús simulada de la que cuelga. El vidrio no sale en PNG: la
# lámina lo imita con el carbón medido en la pantalla (`grisDeLaLamina`),
# como la de la muesca.
#
# Por defecto deja los PNG en /Volumes/SSD2/scratch/dilo-mac/barra, que es
# taller. El binario se compila en /private/tmp y se borra al salir: es lo
# único que toca el disco interno.

set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
salida="${1:-/Volumes/SSD2/scratch/dilo-mac/barra}"
taller="$(mktemp -d /private/tmp/dilo-render-barra.XXXXXX)"
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
  "$raiz/Dilo/Dictation/HUD/Visuals/HUDVoiceVisualStyle.swift" \
  "$raiz/Dilo/CoreHUD/HUDMetrics.swift" \
  "$raiz/Dilo/CoreHUD/VidrioDeLaMuesca.swift" \
  "$raiz/Dilo/CoreHUD/PiezasDelPanel.swift" \
  "$raiz/Dilo/Settings/Components/PaletaDeDilo.swift" \
  "$raiz/Dilo/App/PanelDeLaBarra.swift" \
  "$raiz/Dilo/App/VistaDelPanelDeLaBarra.swift" \
  "$raiz/scripts/render-panel-de-la-barra.swift" \
  -o "$taller/render-panel-de-la-barra"

"$taller/render-panel-de-la-barra" "$salida" "$raiz"
