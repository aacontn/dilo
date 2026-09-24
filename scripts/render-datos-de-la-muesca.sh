#!/usr/bin/env bash
#
# La sección «Datos en la muesca» de Ajustes y el hover con detalle, en PNG,
# sin abrir la app.
#
#   ./scripts/render-datos-de-la-muesca.sh [carpeta de salida]
#
# A diferencia de `render-muesca.sh`, que compila sólo la geometría, esto
# necesita la app entera: la sección usa `AppSettings`, los componentes de
# Ajustes y la vista de la muesca de verdad. Así que compila con
# `build-for-testing` y enlaza el render contra el `Dilo.debug.dylib` que deja
# ese build, con `@testable import Dilo`. El binario de la app no se lanza,
# no se abre ninguna ventana visible y no se toca el escritorio.
#
# Dibuja con `NSHostingView` y no con `ImageRenderer`: los interruptores y los
# selectores de Ajustes son de AppKit, e `ImageRenderer` los cambia por un
# cartel amarillo.
#
# DerivedData y salida viven en SSD2, que es taller.

set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
salida="${1:-/Volumes/SSD2/scratch/dilo-mac/datos-muesca}"
dd="${DILO_DERIVED_DATA:-/Volumes/SSD2/derived-data/datos-render}"
taller="$(mktemp -d)"
trap 'rm -rf "$taller"' EXIT

xcodebuild -project "$raiz/Dilo.xcodeproj" -scheme Dilo -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$dd" \
  DILO_SUFIJO_ID=.render build-for-testing > "$taller/build.log" 2>&1 \
  || { tail -40 "$taller/build.log"; exit 1; }

productos="$dd/Build/Products/Debug"
fuentes="$dd/SourcePackages/checkouts/FluidAudio/Sources"
swiftc -parse-as-library "$raiz/scripts/render-datos-de-la-muesca.swift" \
  -I "$productos" -F "$productos" \
  -I "$fuentes/MachTaskSelfWrapper/include" -I "$fuentes/FastClusterWrapper/include" \
  -Xlinker "$productos/Dilo.app/Contents/MacOS/Dilo.debug.dylib" \
  -Xlinker -rpath -Xlinker "$productos/Dilo.app/Contents/MacOS" \
  -Xlinker -rpath -Xlinker "$productos/Dilo.app/Contents/Frameworks" \
  -o "$taller/render-datos"

"$taller/render-datos" "$salida"
