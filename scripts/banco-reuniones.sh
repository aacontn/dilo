#!/usr/bin/env bash
#
# El banco de la Fase 0 de Reuniones: mide los diarizadores sobre reuniones de
# verdad y deja la tabla en <carpeta>/banco-resultados/resumen.md.
#
#   ./scripts/banco-reuniones.sh <carpeta> [diarizador …]
#
# En <carpeta> van las reuniones, por pista o mezcladas, con sus etiquetas a
# mano opcionales:
#
#   reunion-1.ellos.wav       el audio de la llamada (lo que diariza Dilo)
#   reunion-1.yo.wav          tu micrófono, si lo tienes aparte
#   reunion-1.etiquetas.tsv   desde<TAB>hasta<TAB>hablante, una línea por
#                             intervención; segundos o m:ss; «Yo» es tu pista
#   reunion-2.wav             una reunión ya mezclada en un archivo
#
# Con las dos pistas, el banco mide además la mezcla de ambas, para confirmar
# con números que diarizar por pista gana (spec, «Verificación», punto 3). Sin
# etiquetas mide tiempo, RAM y cuántas voces ve, pero no cuántas acierta.
#
# Corre un proceso por diarizador para que el pico de RAM sea el de ese modelo.
# Los modelos se bajan a /Volumes/SSD2/dilo-modelos (DILO_MODELOS para otra
# carpeta); Parakeet se toma del que Dilo ya bajó. La primera carga de cada
# modelo en un M1 compila para el Neural Engine y tarda minutos: eso va en la
# columna «Carga», no en la de tiempo por hora. Nada suena por los parlantes.
#
# Para probar el banco sin grabar a nadie:
#   ./scripts/banco-reuniones.sh --generar /Volumes/SSD2/dilo-banco-prueba
set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
modelos="${DILO_MODELOS:-/Volumes/SSD2/dilo-modelos}"

generar=0
if [[ "${1:-}" == "--generar" ]]; then
  generar=1
  shift
fi
carpeta="${1:?uso: banco-reuniones.sh [--generar] <carpeta> [diarizador …]}"
shift || true

todos=(nemotron3-fast32 nemotron3-fast32-split-w8a8 nemotron3-c128-split-w8a8 nemotron3-offline sortformer-v2.1 ls-eend-dihard3 vbx)
if [[ $# -gt 0 ]]; then diarizadores=("$@"); else diarizadores=("${todos[@]}"); fi

cd "$raiz/DiloCore"
swift build -c release --product dilo-banco-reuniones >&2
banco="$(swift build -c release --product dilo-banco-reuniones --show-bin-path)/dilo-banco-reuniones"

if [[ $generar == 1 ]]; then
  "$banco" generar "$carpeta"
fi

"$banco" transcribir "$carpeta" --modelos "$modelos"
for diarizador in "${diarizadores[@]}"; do
  # Un diarizador que falla no corta el resto: su falla queda en la tabla.
  "$banco" medir "$carpeta" --diarizador "$diarizador" --modelos "$modelos" || echo "falló $diarizador" >&2
done
"$banco" huellas "$carpeta" --modelos "$modelos" || echo "fallaron las huellas" >&2
"$banco" resumen "$carpeta"
