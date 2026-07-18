#!/bin/sh
# Instalador CLI de Dilo — dictado por voz offline, en español.
#
#   curl -fsSL https://raw.githubusercontent.com/aacontn/dilo/main/install.sh | sh
#
# Detecta tu sistema, baja el último release desde GitHub, lo instala y lo deja
# listo para usar (en macOS incluye quitarle la cuarentena de Gatekeeper, que
# es lo que produce el aviso de "app dañada" mientras Dilo no tenga firma de
# Apple). Correrlo de nuevo actualiza a la última versión.
set -eu

REPO="aacontn/dilo"
API="https://api.github.com/repos/$REPO/releases/latest"

say() { printf '%s\n' "$*"; }
die() { printf 'dilo: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "necesito curl y no está instalado"

release_json=$(curl -fsSL "$API") || die "no pude consultar el último release de GitHub"
tag=$(printf '%s' "$release_json" | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
[ -n "$tag" ] || die "no pude leer la versión del último release"

os=$(uname -s)
arch=$(uname -m)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

case "$os" in
  Darwin)
    case "$arch" in
      arm64) asset="Dilo_Mac-AppleSilicon.app.tar.gz" ;;
      x86_64) asset="Dilo_Mac-Intel.app.tar.gz" ;;
      *) die "arquitectura Mac no soportada: $arch" ;;
    esac

    say "⬇️  Bajando Dilo $tag para tu Mac ($arch)..."
    curl -fL --progress-bar "https://github.com/$REPO/releases/download/$tag/$asset" \
      -o "$tmp/dilo.tar.gz"
    tar -xzf "$tmp/dilo.tar.gz" -C "$tmp"
    [ -d "$tmp/Dilo.app" ] || die "el paquete descargado no trae Dilo.app"

    if pgrep -x dilo >/dev/null 2>&1; then
      say "🛑 Cerrando el Dilo que está corriendo..."
      pkill -x dilo 2>/dev/null || true
      sleep 1
    fi

    say "📦 Instalando en /Applications..."
    if ! { rm -rf /Applications/Dilo.app && cp -R "$tmp/Dilo.app" /Applications/; } 2>/dev/null; then
      say "   (necesito permisos de administrador para escribir en /Applications)"
      sudo rm -rf /Applications/Dilo.app
      sudo cp -R "$tmp/Dilo.app" /Applications/
    fi

    # Sin firma de Apple, Gatekeeper marca la descarga como "dañada".
    # Quitar la cuarentena aquí evita ese aviso. (Se elimina cuando Dilo
    # tenga certificado Developer ID.)
    xattr -dr com.apple.quarantine /Applications/Dilo.app 2>/dev/null || \
      sudo xattr -dr com.apple.quarantine /Applications/Dilo.app 2>/dev/null || true

    say "✅ Dilo $tag instalado. Abriendo..."
    open /Applications/Dilo.app
    say ""
    say "Dicta con tu atajo de siempre. Para actualizar, corre este mismo comando."
    ;;

  Linux)
    case "$arch" in
      x86_64) suffix="amd64.AppImage" ;;
      aarch64|arm64) suffix="aarch64.AppImage" ;;
      *) die "arquitectura Linux no soportada: $arch" ;;
    esac
    asset=$(printf '%s' "$release_json" | grep -o "\"Dilo_[^\"]*_$suffix\"" | head -1 | tr -d '"')
    [ -n "$asset" ] || die "no encontré un AppImage $suffix en el release $tag"

    dest="${XDG_DATA_HOME:-$HOME/.local}/bin"
    mkdir -p "$dest"
    say "⬇️  Bajando Dilo $tag para Linux ($arch)..."
    curl -fL --progress-bar "https://github.com/$REPO/releases/download/$tag/$asset" \
      -o "$tmp/dilo.AppImage"
    chmod +x "$tmp/dilo.AppImage"
    mv "$tmp/dilo.AppImage" "$dest/dilo"

    say "✅ Dilo $tag instalado en $dest/dilo"
    case ":$PATH:" in
      *":$dest:"*) say "Córrelo con: dilo" ;;
      *) say "Agrega $dest a tu PATH y córrelo con: dilo" ;;
    esac
    ;;

  *)
    die "este instalador cubre macOS y Linux. En Windows, baja el instalador desde https://github.com/$REPO/releases/latest"
    ;;
esac
