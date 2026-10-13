#!/usr/bin/env bash
#
# Las variantes de la píldora de los asientos, en PNG y en una lámina para
# comparar, sin abrir una ventana.
#
#   ./scripts/render-variantes-pildora.sh [carpeta de salida]
#
# Compila la misma geometría y las mismas vistas que `render-muesca.sh`. La
# variante de vidrio es una aproximación: el Liquid Glass no se dibuja fuera
# de pantalla (ver el encabezado de `render-variantes-pildora.swift`).

set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
salida="${1:-/Volumes/SSD2/scratch/ingenieria-inversa/notch-png/variantes}"
taller="$(mktemp -d)"
trap 'rm -rf "$taller"' EXIT

swiftc -O -parse-as-library \
  "$raiz/Dilo/CoreHUD/HUDScreenSnapshot.swift" \
  "$raiz/Dilo/CoreHUD/HUDEstiloSinNotch.swift" \
  "$raiz/Dilo/CoreHUD/HUDNotchGeometry.swift" \
  "$raiz/Dilo/CoreHUD/HUDRevealStyle.swift" \
  "$raiz/Dilo/CoreHUD/NotchFilletShape.swift" \
  "$raiz/Dilo/CoreHUD/SiluetaDeLaMuesca.swift" \
  "$raiz/Dilo/CoreHUD/AsientosDeLaMuesca.swift" \
  "$raiz/Dilo/CoreHUD/HUDPildora.swift" \
  "$raiz/Dilo/Dictation/HUD/Visuals/HUDVoiceVisualStyle.swift" \
  "$raiz/Dilo/CoreHUD/HUDMetrics.swift" \
  "$raiz/scripts/render-variantes-pildora.swift" \
  -o "$taller/render-variantes"

"$taller/render-variantes" "$salida"
