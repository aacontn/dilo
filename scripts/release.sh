#!/bin/bash
#
# Corta un release de Dilo (el target de **venta directa**): compila Release,
# arma el DMG, publica el release de GitHub con el DMG adjunto y regenera el
# appcast de Sparkle.
#
#   scripts/release.sh 0.4.0            # compila, firma, notariza y publica
#   scripts/release.sh 0.4.0 --dry-run  # compila y empaqueta, no publica nada
#
# La llave pública de actualización se compara contra el último tag antes de
# compilar nada. Cambiarla deja huérfana a cada copia instalada, así que una
# rotación deliberada tiene que decirlo:
#   scripts/release.sh 0.5.0 --confirmar-rotacion-de-llave
#
# **`Dilo-MAS` no pasa por acá.** Ese target va a la App Store y se sube con
# `.github/workflows/release.yml` (job `mas-upload`, manual): App Store Connect
# no acepta un DMG ni notariza nada, y Sparkle no existe en ese binario.
#
# Dos copias del mismo DMG en cada release. `Dilo-vX.Y.Z.dmg` es la que la
# gente baja, para que el archivo en su carpeta Descargas diga qué versión es.
# `Dilo.dmg` es una copia byte a byte que mantiene resolviendo la URL
# github.com/<repo>/releases/latest/download/Dilo.dmg, que es la que apunta el
# README y la landing.
#
# La notarización usa un perfil de llavero de notarytool:
#   NOTARY_PROFILE   nombre del perfil        (por defecto: dilo-notary)
#   SKIP_NOTARIZE=1  firma y empaqueta sin notarizar (sólo pruebas locales)
#
# La identidad y el Team salen del Llavero, o de las variables:
#   DILO_TEAM_ID     Team ID de Apple         (si no, se deduce de la identidad)
#   SIGN_IDENTITY    "Developer ID Application: … (TEAMID)"
#
# El taller es SSD2: nada de artefactos de compilación en el disco interno.

set -euo pipefail

VERSION="${1:-}"
DRY_RUN=false
CONFIRMAR_ROTACION=false
shift || true
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --confirmar-rotacion-de-llave) CONFIRMAR_ROTACION=true ;;
    *) echo "opción desconocida: $arg" >&2; exit 1 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "uso: scripts/release.sh <versión> [--dry-run] [--confirmar-rotacion-de-llave]" >&2
  exit 1
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "la versión tiene que ser semver, por ejemplo 0.4.0 (llegó '$VERSION')" >&2
  exit 1
fi

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ"

# El único lugar, junto con SUFeedURL en Dilo/Info.plist, donde vive el
# nombre del repo. Si el repo cambia de nombre se cambian los dos, y se
# cambian ANTES del primer release: una copia instalada consulta el feed con
# el que se compiló.
REPO="aacontn/dilo"
SITIO="https://dilo-d14.pages.dev"

TAG="v$VERSION"
TALLER="${DILO_TALLER:-/Volumes/SSD2/derived-data}/release"
BUILD_DIR="$TALLER/$VERSION"
ARCHIVE="$BUILD_DIR/Dilo.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
STAGE_DIR="$BUILD_DIR/dmg"
DMG="$BUILD_DIR/Dilo-$TAG.dmg"
# La copia de URL estable, hecha después de firmar, notarizar y grapar.
DMG_ESTABLE="$BUILD_DIR/Dilo.dmg"
# Sparkle necesita un directorio con el ZIP de actualización y nada más.
SPARKLE_DIR="$BUILD_DIR/sparkle"
SPARKLE_ZIP="$SPARKLE_DIR/Dilo-$TAG.zip"
APPCAST="$RAIZ/appcast.xml"
# Notas escritas a mano para esta versión; ganan sobre el log de commits. Son
# el **mismo archivo** que la app muestra en Ajustes → Novedades: viaja dentro
# del bundle, así que lo que se publica y lo que la persona lee ahí adentro no
# se pueden desincronizar.
NOTAS_CURADAS="$RAIZ/Dilo/Resources/NotasDeVersion/$VERSION.md"
ENTITLEMENTS="$RAIZ/Dilo.entitlements"
NOTARY_PROFILE="${NOTARY_PROFILE:-dilo-notary}"
# La cuenta del Llavero donde vive la llave EdDSA de Dilo, separada de la de
# cualquier otra app con Sparkle. Ver scripts/setup-sparkle-keys.sh.
CUENTA_SPARKLE="dilo"

paso() { printf '\n\033[1;33m▸ %s\033[0m\n' "$1"; }
fail() { printf '\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- preflight

paso "Preflight"
command -v xcodebuild >/dev/null || fail "no está xcodebuild"
command -v hdiutil >/dev/null || fail "no está hdiutil"
if ! $DRY_RUN; then
  command -v gh >/dev/null || fail "no está gh — instala el CLI de GitHub"
  gh auth status >/dev/null 2>&1 || fail "gh no está autenticado — corre 'gh auth login'"
fi

# La identidad de firma: la que diga SIGN_IDENTITY, o el primer Developer ID
# Application del Llavero. Sin ninguna no se corta un release: un DMG firmado
# ad-hoc no pasa Gatekeeper y la gente no puede abrirlo.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}' || true)"
fi
[[ -n "$SIGN_IDENTITY" ]] || fail "no hay ninguna identidad 'Developer ID Application' en el Llavero.
  Importa el .p12 (con la intermedia 'Developer ID Certification Authority'
  adentro) o pasa SIGN_IDENTITY a mano. Ver docs/ProjectSettings.md."
# El Team ID va entre paréntesis al final del nombre de la identidad.
TEAM_ID="${DILO_TEAM_ID:-$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$SIGN_IDENTITY")}"
[[ -n "$TEAM_ID" ]] || fail "no se pudo deducir el Team ID de '$SIGN_IDENTITY'; pasa DILO_TEAM_ID"
echo "  identidad: $SIGN_IDENTITY (team $TEAM_ID)"

# Revisa las credenciales de notarización antes de gastar minutos compilando.
if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
  echo "  SKIP_NOTARIZE=1 — el DMG se firma pero NO se notariza"
elif xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "  perfil de notarización '$NOTARY_PROFILE' listo"
else
  fail "no existe el perfil de notarytool '$NOTARY_PROFILE'. Guárdalo una vez con:
    xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\
      --apple-id <apple-id> --team-id $TEAM_ID --password <contraseña-de-app>
  o vuelve a correr con SKIP_NOTARIZE=1 para saltar la notarización."
fi

RAMA="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$RAMA" != "main" ]] && ! $DRY_RUN; then
  fail "los releases se cortan desde main (estás en '$RAMA')"
fi
if [[ -n "$(git status --porcelain)" ]] && ! $DRY_RUN; then
  fail "el árbol de trabajo está sucio — commitea o guarda antes"
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
  fail "el tag $TAG ya existe"
fi
echo "  versión $VERSION, tag $TAG, rama $RAMA"

# La llave pública contra la que cada copia instalada verifica sus
# actualizaciones. Si cambia, esas copias dejan de confiar en lo firmado con
# la nueva; y una llave cambiada por otro la creerían todas las instalaciones
# de acá en adelante. Ninguna de las dos cosas se descubre después de publicar.
leer_llave() {
  /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" /dev/stdin <<<"$1" 2>/dev/null || true
}
LLAVE_ACTUAL="$(leer_llave "$(cat "$RAIZ/Dilo/Info.plist")")"
[[ -n "$LLAVE_ACTUAL" ]] || fail "Dilo/Info.plist no tiene SUPublicEDKey"

TAG_ANTERIOR="$(git tag --list 'v*' --sort=-v:refname | head -1 || true)"
if [[ -z "$TAG_ANTERIOR" ]]; then
  echo "  no hay tag anterior con qué comparar la llave (primer release)"
elif PLIST_ANTERIOR="$(git show "$TAG_ANTERIOR:Dilo/Info.plist" 2>/dev/null)"; then
  LLAVE_ANTERIOR="$(leer_llave "$PLIST_ANTERIOR")"
  if [[ -z "$LLAVE_ANTERIOR" ]]; then
    echo "  $TAG_ANTERIOR no llevaba SUPublicEDKey; nada que comparar"
  elif [[ "$LLAVE_ACTUAL" == "$LLAVE_ANTERIOR" ]]; then
    echo "  la llave de actualización no cambió desde $TAG_ANTERIOR"
  elif $CONFIRMAR_ROTACION; then
    echo "  la llave CAMBIÓ desde $TAG_ANTERIOR, confirmado por bandera"
  else
    fail "SUPublicEDKey cambió desde $TAG_ANTERIOR.
  Cada copia instalada confía en la vieja y va a rechazar lo firmado con la
  nueva. Si la rotación es deliberada, vuelve a correr con
  --confirmar-rotacion-de-llave. Si no lo es, averigua quién la cambió."
  fi
else
  echo "  $TAG_ANTERIOR no tiene Info.plist; nada que comparar"
fi

# ------------------------------------------------------------------- tests

# `xcodebuild test` se cuelga en este Mac antes de "Testing started": el host
# de los tests es la app real y al arrancar levanta su tap de CGEvent, que
# dispara TCC y espera a un humano. La red de seguridad local es `swift test`
# del paquete propio más los dos `xcodebuild build`; la suite completa corre
# en CI (.github/workflows/ci.yml), que es donde TCC deniega solo.
paso "Tests"
(cd DiloCore && swift test --scratch-path "$TALLER/swiftpm" 2>&1 | tail -5)
for esquema in Dilo Dilo-MAS; do
  xcodebuild build \
    -project Dilo.xcodeproj \
    -scheme "$esquema" \
    -configuration Debug \
    -derivedDataPath "$TALLER/xcode" \
    -quiet
  echo "  $esquema compila"
done

# ------------------------------------------------------------------- build

if $DRY_RUN; then
  paso "Sin subir la versión (dry run)"
else
  paso "Fijando la versión en $VERSION"
  # Escrita directo en el proyecto y no con agvtool: desde que el target tiene
  # un Info.plist real por Sparkle, agvtool lee un CFBundleShortVersionString
  # vacío de ahí y deja MARKETING_VERSION como estaba, en silencio.
  BUILD_NUMBER="$(git rev-list --count HEAD)"
  /usr/bin/sed -i '' \
    -e "s/^\([[:space:]]*\)MARKETING_VERSION = .*;$/\1MARKETING_VERSION = $VERSION;/" \
    -e "s/^\([[:space:]]*\)CURRENT_PROJECT_VERSION = .*;$/\1CURRENT_PROJECT_VERSION = $BUILD_NUMBER;/" \
    Dilo.xcodeproj/project.pbxproj

  # Todas las configuraciones tienen que coincidir, o Debug y Release
  # discrepan sobre qué versión está corriendo.
  PUESTAS="$(grep -c "MARKETING_VERSION = $VERSION;" Dilo.xcodeproj/project.pbxproj || true)"
  TOTAL="$(grep -c "MARKETING_VERSION = " Dilo.xcodeproj/project.pbxproj || true)"
  [[ "$PUESTAS" == "$TOTAL" ]] || fail "sólo $PUESTAS de $TOTAL MARKETING_VERSION quedaron en $VERSION"
  echo "  marketing $VERSION, build $BUILD_NUMBER ($TOTAL configuraciones)"
fi

paso "Archivando Release"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
# Hardened Runtime encendido explícitamente: el proyecto lo deja apagado por
# defecto porque la firma del día a día es ad-hoc y con runtime dyld se niega
# a cargar Sparkle.framework. Acá hay Developer ID de verdad, y la
# notarización lo exige. Ver docs/ProjectSettings.md.
xcodebuild archive \
  -project Dilo.xcodeproj \
  -scheme Dilo \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$TALLER/xcode" \
  -destination 'generic/platform=macOS' \
  DILO_HARDENED_RUNTIME=YES \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  -quiet

APP_EN_ARCHIVE="$ARCHIVE/Products/Applications/Dilo.app"
[[ -d "$APP_EN_ARCHIVE" ]] || fail "el archive no tiene Dilo.app"

mkdir -p "$EXPORT_DIR"
cp -R "$APP_EN_ARCHIVE" "$EXPORT_DIR/Dilo.app"
APP="$EXPORT_DIR/Dilo.app"
echo "  archivado, $(du -sh "$APP" | cut -f1)"

if ! $DRY_RUN; then
  CORTA="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
  LARGA="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
    "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
  [[ "$CORTA" == "$VERSION" ]] \
    || fail "la app compilada dice versión '$CORTA', no $VERSION"
  echo "  dice $CORTA ($LARGA)"
fi

# ---------------------------------------------------------------- refirmado

# Sparkle trae helpers precompilados dentro de su framework —Updater.app,
# Autoupdate y dos servicios XPC— y Xcode no refirma el contenido de un
# framework precompilado. Llegan firmados ad-hoc, sin team y sin timestamp
# seguro, que es exactamente lo que el servicio de notarización rechaza.
#
# codesign sella un bundle hasheando su contenido, así que esto va estricto de
# adentro hacia afuera: helpers, después el framework, después la app. Firmar
# la app primero invalidaría su sello apenas cambiara un helper.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  paso "Refirmando los helpers de Sparkle"
  # Los helpers de Sparkle llevan diccionarios de entitlements vacíos, así que
  # se firman sin ninguno.
  for objetivo in \
    "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE/Versions/B/Updater.app" \
    "$SPARKLE/Versions/B/Autoupdate" \
    "$SPARKLE"; do
    [[ -e "$objetivo" ]] || continue
    codesign --force --options runtime --timestamp \
      --sign "$SIGN_IDENTITY" "$objetivo" 2>&1 | sed 's/^/  /'
  done

  # La app TIENE que refirmarse con sus entitlements. `codesign --force`
  # reemplaza la firma entera y bota los entitlements que no le pasen, y bajo
  # Hardened Runtime una app sin com.apple.security.device.audio-input no
  # puede recibir el micrófono nunca: el prompt aparece y el switch no hace
  # nada. El árbol de origen publicó una versión así.
  [[ -f "$ENTITLEMENTS" ]] || fail "falta $ENTITLEMENTS"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" "$APP" 2>&1 | sed 's/^/  /'

  codesign --verify --deep --strict "$APP" || fail "la app refirmada no pasa verificación"

  # La salida se captura en vez de mandarla a grep: con pipefail, grep sale al
  # primer match, mata a codesign con SIGPIPE y el pipeline reporta error por
  # un binario que está bien firmado.
  for anidado in \
    "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE/Versions/B/Updater.app" \
    "$SPARKLE/Versions/B/Autoupdate" \
    "$SPARKLE" \
    "$APP"; do
    [[ -e "$anidado" ]] || continue
    INFO="$(codesign -dvv "$anidado" 2>&1 || true)"
    [[ "$INFO" == *"TeamIdentifier=$TEAM_ID"* ]] \
      || fail "$(basename "$anidado") no está firmado con el team $TEAM_ID"
    [[ "$INFO" == *"runtime"* ]] \
      || fail "$(basename "$anidado") no tiene Hardened Runtime"
  done
  FIRMADOS="$(codesign -d --entitlements :- "$APP" 2>/dev/null || true)"
  [[ "$FIRMADOS" == *"com.apple.security.device.audio-input"* ]] \
    || fail "la app firmada no tiene el entitlement de micrófono — el dictado no funcionaría"
  echo "  helpers, framework y app firmados con $TEAM_ID, entitlements intactos"
fi

# --------------------------------------------------------------------- dmg

paso "Armando el DMG"
rm -rf "$STAGE_DIR" "$DMG"
mkdir -p "$STAGE_DIR"
cp -R "$APP" "$STAGE_DIR/Dilo.app"
ln -s /Applications "$STAGE_DIR/Applications"
# hdiutil contesta "Resource busy" si el bundle recién copiado todavía se está
# indexando, así que se le dan varios intentos.
for intento in 1 2 3 4 5; do
  if hdiutil create \
      -volname "Dilo $VERSION" \
      -srcfolder "$STAGE_DIR" \
      -ov -format UDZO \
      "$DMG" >/dev/null 2>&1; then
    break
  fi
  [[ $intento == 5 ]] && fail "hdiutil no pudo crear el DMG"
  echo "  hdiutil ocupado, reintentando ($intento)"
  sleep 3
done
hdiutil verify "$DMG" >/dev/null 2>&1 || fail "el DMG no pasa verificación"

# Firmar también el contenedor, para que Gatekeeper responda por el DMG y no
# sólo por la app de adentro. Esto va ANTES de notarizar: firmar un DMG ya
# grapado lo reescribe y bota el ticket.
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
echo "  contenedor firmado"

# ------------------------------------------------------------- notarización

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
  paso "Notarización saltada (SKIP_NOTARIZE=1)"
  echo "  Este DMG está firmado pero NO notarizado: Gatekeeper se va a negar"
  echo "  a abrirlo. Sirve para probar localmente, no para publicar."
else
  paso "Notarizando con el perfil '$NOTARY_PROFILE'"
  # El fallo del 14-sep-2026 en el repo Tauri fue **red sondeando el estado**,
  # no la firma: notarytool sube bien y después se cae esperando. Por eso se
  # reintenta el submit completo antes de dar el release por perdido.
  for intento in 1 2 3; do
    if xcrun notarytool submit "$DMG" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait --timeout 30m; then
      break
    fi
    [[ $intento == 3 ]] && fail "la notarización falló tres veces; mira el log con
    xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"
    echo "  reintento $intento tras un fallo de notarytool (suele ser red)"
    sleep 30
  done
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | sed 's/^/  /'
  echo "  notarizado y grapado"
fi

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "  $DMG ($(du -h "$DMG" | cut -f1))"
echo "  sha256 $SHA"

# Copiado después de firmar, notarizar y grapar, para que el asset de URL
# estable sean los mismos bytes con el mismo ticket.
cp "$DMG" "$DMG_ESTABLE"
echo "  $DMG_ESTABLE (copia para la URL latest/download)"

# ----------------------------------------------------------------- sparkle

# Sparkle actualiza desde un ZIP, no desde el DMG: es lo que esperan
# BinaryDelta y generate_appcast, y se desempaqueta sin montar nada.
#
# Notarizar el DMG notariza la app de adentro, así que la app se puede grapar
# directo contra los registros de Apple: ni segundo envío ni segunda espera.
# Una app grapada valida sin red, que es lo que importa en un laptop que
# despierta, se actualiza y relanza antes de que vuelva el wifi.
paso "Armando la actualización de Sparkle"
if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  xcrun stapler staple "$APP" && echo "  app grapada"
fi

rm -rf "$SPARKLE_DIR"
mkdir -p "$SPARKLE_DIR"
# ditto conserva los symlinks y los resource forks del bundle; `zip` no, y un
# bundle mutilado no pasa su chequeo de firma después de actualizarse.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$SPARKLE_ZIP"
echo "  $(basename "$SPARKLE_ZIP") ($(du -h "$SPARKLE_ZIP" | cut -f1))"

SPARKLE_BIN="$(find "${DILO_TALLER:-/Volumes/SSD2/derived-data}" \
  "$HOME/Library/Developer/Xcode/DerivedData" \
  -path '*/artifacts/sparkle/Sparkle/bin/generate_appcast' 2>/dev/null | head -1 || true)"
[[ -n "$SPARKLE_BIN" ]] || fail "no están las herramientas de Sparkle. Compila una vez para que Xcode baje el paquete."

# La privada vive en el Llavero, en la cuenta 'dilo' (ver
# scripts/setup-sparkle-keys.sh), así que las herramientas la encuentran sin
# ningún archivo de llave en disco. El Llavero VA a pedir permiso la primera
# vez y se queda esperando: elige "Permitir siempre" para que los releases
# siguientes corran solos. Hasta entonces este paso no se puede correr sin
# alguien mirando.
# En SPARKLE_DIR está sólo el ZIP: generate_appcast se niega a dos archivos
# que reporten la misma versión de bundle, que es lo que pasaría con el DMG.
"$SPARKLE_BIN" \
  --account "$CUENTA_SPARKLE" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "$SITIO" \
  --full-release-notes-url "https://github.com/$REPO/releases" \
  --maximum-versions 5 \
  -o "$APPCAST" \
  "$SPARKLE_DIR"

[[ -s "$APPCAST" ]] || fail "generate_appcast no produjo appcast"
grep -q "sparkle:edSignature" "$APPCAST" || fail "el appcast no tiene firma EdDSA"
echo "  appcast escrito, firma presente"

if $DRY_RUN; then
  paso "Dry run — no se publicó nada"
  echo "  DMG:   $DMG"
  echo "  copia: $DMG_ESTABLE"
  echo "  ZIP:   $SPARKLE_ZIP"
  echo "  appcast: $APPCAST (sin commitear)"
  exit 0
fi

# ----------------------------------------------------------------- publicar

paso "Commiteando y etiquetando"
for ruta in Dilo.xcodeproj/project.pbxproj Dilo/Info.plist appcast.xml; do
  [[ -e "$ruta" ]] && git add "$ruta"
done
if git diff --cached --quiet; then
  echo "  nada que commitear — la versión ya coincide"
else
  git commit -q -m "chore(release): $VERSION"
  echo "  commiteado $(git diff --name-only HEAD~1 HEAD | tr '\n' ' ')"
fi
git tag -a "$TAG" -m "Dilo $VERSION"
git push -q origin main
git push -q origin "$TAG"
echo "  $TAG empujado"

paso "Publicando el release de GitHub"
NOTAS="$BUILD_DIR/notas.md"
TAG_PREVIO="$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)"
{
  echo "## Instalar"
  echo
  echo "Baja **Dilo.dmg** de acá abajo. Necesita macOS 26 en Apple Silicon."
  echo
  echo "## Qué cambió"
  echo
  # Las notas escritas ganan cuando existen: un log de commits dice qué
  # cambió en el código, que no es lo mismo que qué cambió para quien lee.
  if [[ -f "$NOTAS_CURADAS" ]]; then
    cat "$NOTAS_CURADAS"
  elif [[ -n "$TAG_PREVIO" ]]; then
    git log --no-merges --pretty='- %s' "$TAG_PREVIO..$TAG"
  else
    git log --no-merges --pretty='- %s' -20 "$TAG"
  fi
} > "$NOTAS"

# El ZIP sube junto al DMG porque el enclosure del appcast apunta a él. Sin
# eso, cada copia instalada sondearía un 404 para siempre.
#
# appcast.xml sube también, como copia inmutable de lo que publicó este tag.
# El SUFeedURL en vivo sigue leyendo el de main, que cualquiera con permiso de
# escritura podría reescribir; este asset es contra qué se comprueba.
gh release create "$TAG" "$DMG" "$DMG_ESTABLE" "$SPARKLE_ZIP" "$APPCAST" \
  -R "$REPO" \
  --title "Dilo $VERSION" \
  --notes-file "$NOTAS"

# El feed recién está vivo cuando el appcast de main nombra un release que
# existe, así que se consulta la URL que Sparkle va a sondear de verdad.
paso "Verificando el feed de actualización"
FEED="https://raw.githubusercontent.com/$REPO/main/appcast.xml"
if curl -fsS "$FEED" | grep -q "$TAG"; then
  echo "  $FEED sirve $TAG"
else
  echo "  OJO: $FEED todavía no menciona $TAG."
  echo "  raw.githubusercontent.com cachea unos minutos; vuelve a mirar antes"
  echo "  de anunciar, y confirma que appcast.xml se empujó a main."
fi
ENCLOSURE="$(grep -o 'url="[^"]*\.zip"' "$APPCAST" | head -1 | cut -d'"' -f2 || true)"
if [[ -n "$ENCLOSURE" ]] && curl -fsSI "$ENCLOSURE" >/dev/null 2>&1; then
  echo "  enclosure alcanzable"
else
  echo "  OJO: el enclosure del appcast no se alcanza: $ENCLOSURE"
fi

paso "Listo"
echo "  release:  $(gh release view "$TAG" -R "$REPO" --json url -q .url)"
echo "  descarga: https://github.com/$REPO/releases/latest/download/Dilo.dmg"
echo "  feed:     $FEED"
echo
echo "  Dilo-MAS no salió de acá: para la App Store, despacha el job"
echo "  'mas-upload' de .github/workflows/release.yml."
