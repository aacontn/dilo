#!/bin/bash
# Compila Dilo en Release, la firma con el Developer ID del Llavero (Hardened
# Runtime, helpers de Sparkle firmados de adentro hacia afuera), la notariza,
# le pega el ticket y la deja en /Applications/Dilo.app reemplazando la anterior.
# No la relanza: eso lo decide Alfonso.
#
# Por qué existe: la copia de uso diario vive en /Applications con una firma
# estable para que macOS no vuelva a pedir permisos en cada build. Un
# `xcodebuild` pelado no re-firma los helpers de Sparkle y Apple rechaza la
# notarización ("not signed with a valid Developer ID certificate").
#
# Uso: scripts/instalar-local.sh [--sin-notarizar]
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
IDENTIDAD="${DILO_IDENTIDAD:-Developer ID Application}"
EQUIPO="${DILO_TEAM:-73C2LQG2QK}"
PERFIL_NOTARY="${DILO_NOTARY_PROFILE:-dilo-notary}"
LLAVERO="$HOME/Library/Keychains/login.keychain-db"
TALLER="${DILO_TALLER:-/Volumes/SSD2/derived-data}/instalar-local"
DESTINO="/Applications/Dilo.app"
NOTARIZAR=1
[[ "${1:-}" == "--sin-notarizar" ]] && NOTARIZAR=0

echo "→ compilando Release firmada"
xcodebuild -project "$RAIZ/Dilo.xcodeproj" -scheme Dilo -configuration Release \
  -derivedDataPath "$TALLER" CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTIDAD" DEVELOPMENT_TEAM="$EQUIPO" \
  DILO_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" build \
  | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | sort -u

APP="$TALLER/Build/Products/Release/Dilo.app"
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"

echo "→ firmando helpers de Sparkle de adentro hacia afuera"
for objetivo in "$SP/XPCServices/Installer.xpc" "$SP/XPCServices/Downloader.xpc" \
                "$SP/Autoupdate" "$SP/Updater.app" \
                "$APP/Contents/Frameworks/Sparkle.framework"; do
  codesign -f -s "$IDENTIDAD" -o runtime --timestamp "$objetivo" 2>&1 | grep -v "replacing existing" || true
done
codesign -f -s "$IDENTIDAD" -o runtime --timestamp \
  --entitlements "$RAIZ/Dilo.entitlements" "$APP" 2>&1 | grep -v "replacing existing" || true
codesign --verify --deep --strict "$APP"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "device.audio-input"
echo "  firma y entitlements OK"

if [[ $NOTARIZAR == 1 ]]; then
  echo "→ notarizando (puede tardar varios minutos)"
  ZIP="$TALLER/Dilo-notary.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  RESULTADO="$(xcrun notarytool submit "$ZIP" --keychain-profile "$PERFIL_NOTARY" --keychain "$LLAVERO" --wait 2>&1)"
  rm -f "$ZIP"
  if ! grep -q "status: Accepted" <<<"$RESULTADO"; then
    ID_ENVIO="$(grep -oE 'id: [0-9a-f-]{36}' <<<"$RESULTADO" | head -1 | cut -d' ' -f2)"
    echo "✗ Apple rechazó la notarización ($ID_ENVIO):"
    xcrun notarytool log "$ID_ENVIO" --keychain-profile "$PERFIL_NOTARY" --keychain "$LLAVERO" 2>&1 \
      | python3 -c 'import sys,json
d=json.load(sys.stdin)
for i in (d.get("issues") or [])[:10]:
    print("  -", i.get("path","").split("/Contents/",1)[-1][:80], "|", i.get("message"))'
    exit 1
  fi
  xcrun stapler staple "$APP" | tail -1
  spctl -a -vv -t exec "$APP" 2>&1 | grep source
fi

echo "→ instalando en $DESTINO (sin relanzar)"
rm -rf "$DESTINO"
cp -R "$APP" "$DESTINO"
echo "✓ $DESTINO desde $(git -C "$RAIZ" rev-parse --short HEAD)"
