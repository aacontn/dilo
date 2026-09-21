#!/bin/sh
# Dilo — instalador.
#
# Este repo es la app nativa de Mac (Swift). Mientras no tenga su primer
# release, este script reenvía al instalador de la versión anterior (Tauri),
# que sigue disponible para macOS, Windows y Linux en aacontn/dilo-tauri.
# Así el one-liner que circula por ahí no deja a nadie sin Dilo.
set -e
echo "Dilo nativo para Mac todavía no tiene release público."
echo "Instalando la versión anterior (Dilo 0.3.2, Tauri) desde aacontn/dilo-tauri…"
echo "Cuando salga la nativa: https://github.com/aacontn/dilo/releases"
echo
curl -fsSL https://raw.githubusercontent.com/aacontn/dilo-tauri/main/install.sh | sh
