#!/usr/bin/env bash
#
# La ventana de Ajustes en PNG, sección por sección y con la búsqueda
# abierta, sin abrir la app.
#
#   ./scripts/render-ajustes.sh [carpeta de salida]
#
# Como `render-datos-de-la-muesca.sh`: compila con `build-for-testing` y
# enlaza el render contra el `Dilo.debug.dylib` de ese build, con
# `@testable import Dilo`. El binario de la app no se lanza, no se abre
# ninguna ventana visible y no se toca el escritorio, el Llavero ni el
# historial: las claves van fijadas en memoria y el uso es de ejemplo.
#
# Por cada sección deja `ventana-<sección>.png` (la ventana tal cual, 900×640)
# y `entera-<sección>.png` (la sección completa, sin cortar por el alto de la
# ventana), y `busqueda-*.png` con la búsqueda abierta.
#
# DerivedData vive en SSD2, que es taller; la salida, por defecto, en la
# carpeta de taller de Dilo.

set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
salida="${1:-/Volumes/SSD 1/Dilo/taller/ajustes}"
dd="${DILO_DERIVED_DATA:-/Volumes/SSD2/derived-data/ajustes-render}"
taller="$(mktemp -d)"
trap 'rm -rf "$taller"' EXIT

xcodebuild -project "$raiz/Dilo.xcodeproj" -scheme Dilo -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$dd" \
  DILO_SUFIJO_ID=.render build-for-testing > "$taller/build.log" 2>&1 \
  || { tail -40 "$taller/build.log"; exit 1; }

productos="$dd/Build/Products/Debug"
fuentes="$dd/SourcePackages/checkouts/FluidAudio/Sources"
swiftc -parse-as-library "$raiz/scripts/render-ajustes.swift" \
  -I "$productos" -F "$productos" \
  -I "$fuentes/MachTaskSelfWrapper/include" -I "$fuentes/FastClusterWrapper/include" \
  -Xlinker "$productos/Dilo.app/Contents/MacOS/Dilo.debug.dylib" \
  -Xlinker -rpath -Xlinker "$productos/Dilo.app/Contents/MacOS" \
  -Xlinker -rpath -Xlinker "$productos/Dilo.app/Contents/Frameworks" \
  -o "$taller/render-ajustes"

"$taller/render-ajustes" "$salida"
