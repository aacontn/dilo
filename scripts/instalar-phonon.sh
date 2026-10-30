#!/usr/bin/env bash
#
# Instala el modelo de Phonon 40m en español donde Dilo lo busca, para que
# «Leer en voz alta» lea con Phonon.
#
#   ./scripts/instalar-phonon.sh
#
# Dilo baja solo el motor (`ptts`) y las voces, que son públicos. El modelo
# no: `gradium/phonon-40m-es` pide aceptar sus términos en Hugging Face
# (licencia CC BY-NC 4.0, uso personal y no comercial) y responde 401 sin el
# token de quien los aceptó. La app no lleva ni pide ese token; este script lo
# lee del Llavero de quien lo corre y lo pasa sólo a `curl`, por la entrada
# estándar: nunca queda en un argumento, en una variable de entorno ni en
# pantalla.
#
# El token va en el Llavero con servicio `huggingface` y cuenta `HF_TOKEN`:
#   security add-generic-password -s huggingface -a HF_TOKEN -T /usr/bin/security -w
#
# Baja la revisión fija y revisa el SHA-256 de cada archivo contra el que
# conoce `InstalacionDePhonon`: lo que no calza no se instala.

set -euo pipefail

revision="e5e052b26e31abd5918ade71d3135e69d51a66f8"
destino="$HOME/Library/Application Support/Dilo/models/phonon/phonon-40m-es"
taller="$(mktemp -d)"
trap 'rm -rf "$taller"' EXIT

archivos=(
  "config.json 353a6153d9bfacdfe9bd2426e4ae1d1c055c86a17cdb172ca3eacd1dfb454a22"
  "tokenizer.json e6a00cd1a15986fa1e79ba338fa8174a2dd8c6c4630a66bf9c36237b2ebc4a15"
  "model.q8.gguf b90d5897e5e663c56a8975a8b2d6f7db557b9bad59ad82a82361ac56614c2a5c"
  "default-voice.safetensors be8c5f329070f40c39007bea13cee9503fe71599704cfe55c67d6eb51f5e6eb2"
)

if ! security find-generic-password -s huggingface -a HF_TOKEN >/dev/null 2>&1; then
  echo "Falta el token de Hugging Face en el Llavero (servicio huggingface, cuenta HF_TOKEN)." >&2
  echo "Acepta los términos en https://huggingface.co/gradium/phonon-40m-es y guárdalo con:" >&2
  echo "  security add-generic-password -s huggingface -a HF_TOKEN -T /usr/bin/security -w" >&2
  exit 1
fi

for entrada in "${archivos[@]}"; do
  nombre="${entrada%% *}"
  esperado="${entrada##* }"
  echo "Bajando ${nombre}…"
  security find-generic-password -s huggingface -a HF_TOKEN -w \
    | sed 's/^/Authorization: Bearer /' \
    | curl -fL --progress-bar -H @- -o "$taller/$nombre" \
      "https://huggingface.co/gradium/phonon-40m-es/resolve/$revision/$nombre"
  calculado="$(shasum -a 256 "$taller/$nombre" | cut -d' ' -f1)"
  if [[ "$calculado" != "$esperado" ]]; then
    echo "El SHA-256 de $nombre no calza ($calculado). No se instaló nada." >&2
    exit 1
  fi
done

mkdir -p "$destino"
for entrada in "${archivos[@]}"; do
  nombre="${entrada%% *}"
  mv -f "$taller/$nombre" "$destino/$nombre"
done
echo "Phonon 40m quedó en $destino."
echo "En Dilo: Ajustes → General → Leer en voz alta. El motor y la voz se bajan desde ahí."
