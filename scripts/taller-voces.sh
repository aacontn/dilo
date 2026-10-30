#!/usr/bin/env bash
#
# El banco de voces de «Leer en voz alta»: las mismas seis frases chilenas
# con cada motor y cada voz, a WAV, y el WER de transcribirlas de vuelta con
# el Parakeet v3 que ya tiene Dilo.
#
#   ./scripts/taller-voces.sh sintetizar <motor> [voz,voz…]
#   ./scripts/taller-voces.sh wer
#
# Motores: phonon40m-es, phonon40m-multi, phonon40m-es-crudo, pocket-es,
# pocket-es24, pocket-es-crudo, supertonic3, apple. Los «crudo» mandan el texto
# sin `TextoParaLeer`, para medir cuánto ayuda.
#
# Nada suena y no se abre ninguna ventana. Los modelos de prueba viven en
# /Volumes/SSD2/dilo-voces (taller, se puede borrar), y los WAV y las medidas
# en /Volumes/SSD 1/Dilo/taller/voces, para escucharlos. Phonon 40m pide
# aceptar términos en Hugging Face: el banco lo usa desde la caché de
# /Volumes/SSD2/dilo-voces/hf, que se llena una vez con el token del Llavero
# (ver `scripts/instalar-phonon.sh`); el banco no lee el token.

set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
salida="${DILO_VOCES:-/Volumes/SSD 1/Dilo/taller/voces}"
build=/Volumes/SSD2/derived-data/taller-voces

swift build -c release --package-path "$raiz/scripts/taller-voces" --scratch-path "$build" >&2
export HF_HOME=/Volumes/SSD2/dilo-voces/hf

case "${1:-}" in
  sintetizar) "$build/release/taller-voces" sintetizar "$2" "$salida" ${3:+"$3"} ;;
  wer) "$build/release/taller-voces" wer "$salida" ;;
  *) echo "uso: $0 sintetizar <motor> [voces] | wer" >&2; exit 64 ;;
esac
