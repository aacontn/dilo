#!/usr/bin/env bash
#
# El banco de comparación de motores, sin ventanas: transcribe cada WAV de una
# carpeta con Parakeet v3 y con Parakeet Ultra —con el mismo código que dicta
# en la app (`ParakeetEngine.transcribirSinSesion`: recorte de bordes, pasada
# final y costura de trozos)— y dice el tiempo de cada archivo. Si al lado de
# `nombre.wav` hay un `nombre.txt` con lo que se dijo, saca el WER de cada
# archivo y el del corpus.
#
#   ./scripts/comparar-motores.sh <carpeta> [opciones]
#
# Opciones que se pasan tal cual a dilo-comparar-motores:
#   --motores v3,ultra,nemotron  cuáles correr (por defecto v3,ultra). Nemotron
#                       Unified multilingüe con el prompt de español es sólo
#                       para medir: la app no lo ofrece
#   --modelos <carpeta> de dónde leer los modelos (por defecto los de la app,
#                       ~/Library/Application Support/Dilo/models)
#   --bajar             baja lo que falte a --modelos; sin esto, lo que no
#                       está se salta y se dice
#   --tus-palabras "A,B" corre cada Parakeet también con la segunda pasada de
#                       Tus palabras (`v3+tp`); el CTC vive en la carpeta de
#                       FluidAudio: con CFFIXED_USER_HOME=/Volumes/SSD2/… se
#                       baja fuera del disco interno
#   --csv <archivo>     deja cada fila en un CSV
#   --sin-textos        no imprime lo transcrito
#
# Es de taller, como metrics.sh: la app no lo enlaza y no corre en CI. Los WAV
# son la voz de quien lo corre: no se versionan. Lee los modelos de la app
# sin escribir nada en su carpeta, salvo con --bajar sin --modelos.
#
# Para bajar Ultra sin tocar el disco interno, con el v3 de la app enlazado:
#   mkdir -p /Volumes/SSD2/dilo-taller/modelos
#   ln -s ~/Library/Application\ Support/Dilo/models/parakeet-tdt-0.6b-v3 /Volumes/SSD2/dilo-taller/modelos/
#   ./scripts/comparar-motores.sh <carpeta> --modelos /Volumes/SSD2/dilo-taller/modelos --bajar
set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -lt 1 || ! -d "$1" ]]; then
  echo "uso: $0 <carpeta con WAV> [--motores v3,ultra[,nemotron]] [--modelos <carpeta>] [--bajar] [--tus-palabras \"A,B\"] [--csv <archivo>] [--sin-textos]" >&2
  exit 2
fi

# El taller es SSD2: nada de artefactos de compilación en el disco interno.
if [[ -n "${DILO_TALLER:-}" ]]; then
  taller="$DILO_TALLER/dilo-comparar"
elif [[ -d /Volumes/SSD2/derived-data ]]; then
  taller="/Volumes/SSD2/derived-data/dilo-comparar"
else
  taller="${TMPDIR:-/tmp}/dilo-comparar"
fi

echo "→ construyendo dilo-comparar-motores"
swift build \
  --package-path "$raiz/DiloCore" \
  --scratch-path "$taller" \
  --configuration release \
  --product dilo-comparar-motores >/dev/null

exec "$taller/release/dilo-comparar-motores" "$@"
