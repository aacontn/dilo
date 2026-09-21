#!/bin/bash
#
# Imprime la llave pública EdDSA con la que este Mac firma las actualizaciones
# de Dilo, y la genera la primera vez.
#
#   scripts/setup-sparkle-keys.sh          # muestra la llave pública
#   scripts/setup-sparkle-keys.sh --export # escribe la privada a un archivo
#
# Sparkle guarda la mitad privada en el Llavero de inicio de sesión. Dilo usa
# una **cuenta propia** del Llavero (`dilo`, la variable CUENTA de abajo) en vez
# de la global: así la llave de Dilo no se mezcla con la de ninguna otra app
# que use Sparkle en este Mac, y exportar una no expone la otra. La mitad
# pública va en Dilo/Info.plist bajo SUPublicEDKey y es segura de commitear.
#
# Perder la privada significa que ninguna copia instalada vuelve a
# actualizarse: cada una sólo confía en la llave con la que se compiló.
# Expórtala una vez y guárdala donde la sigas teniendo en un año.
#
# Las herramientas de Sparkle salen del DerivedData del taller (SSD2). Si
# todavía no están, compila una vez para que Xcode baje el paquete.

set -euo pipefail

# generate_keys -x crea el archivo con el umask del proceso, antes de que el
# chmod de abajo alcance a cerrarlo. Se cierra antes, para que nunca sea
# legible por el grupo ni por el mundo, ni siquiera un instante.
umask 077

CUENTA="dilo"

fail() { echo "error: $*" >&2; exit 1; }

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST="$RAIZ/Dilo/Info.plist"
TALLER="${DILO_TALLER:-/Volumes/SSD2/derived-data}"

# El `|| true` no es decorativo: con `pipefail`, `head -1` cierra la tubería
# apenas tiene su línea, `find` muere de SIGPIPE y el pipeline entero da error
# aunque haya encontrado lo que buscaba.
HERRAMIENTAS="$(find "$TALLER" "$HOME/Library/Developer/Xcode/DerivedData" \
  -path '*/artifacts/sparkle/Sparkle/bin/generate_keys' 2>/dev/null | head -1 || true)"
[[ -n "$HERRAMIENTAS" ]] \
  || fail "no están las herramientas de Sparkle. Compila Dilo una vez para que Xcode baje el paquete."

if [[ "${1:-}" == "--export" ]]; then
  SALIDA="$HOME/dilo-sparkle-llave-privada.txt"
  [[ -e "$SALIDA" ]] && fail "$SALIDA ya existe; muévelo antes"
  "$HERRAMIENTAS" --account "$CUENTA" -x "$SALIDA"
  chmod 600 "$SALIDA"
  echo "Llave privada escrita en $SALIDA"
  echo "Guárdala en tu gestor de contraseñas y después borra el archivo."
  exit 0
fi

# -p imprime la pública y nunca pisa una privada existente. El Llavero puede
# pedir permiso la primera vez.
PUBLICA="$("$HERRAMIENTAS" --account "$CUENTA" -p 2>/dev/null || true)"

if [[ -z "$PUBLICA" ]]; then
  echo "No hay llave de firma en la cuenta '$CUENTA'. Generando una en el Llavero…"
  "$HERRAMIENTAS" --account "$CUENTA" >/dev/null
  PUBLICA="$("$HERRAMIENTAS" --account "$CUENTA" -p)"
fi

echo "Llave pública: $PUBLICA"

EN_PLIST="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$PLIST" 2>/dev/null || true)"
if [[ "$EN_PLIST" == "$PUBLICA" ]]; then
  echo "Dilo/Info.plist ya lleva esta llave."
else
  echo
  echo "Dilo/Info.plist tiene: ${EN_PLIST:-<nada>}"
  echo "Cámbialo a mano para que coincidan, o las actualizaciones no van a"
  echo "pasar la verificación. **No uses PlistBuddy**: reescribe el plist"
  echo "entero y se lleva los comentarios que explican cada clave."
  exit 1
fi
