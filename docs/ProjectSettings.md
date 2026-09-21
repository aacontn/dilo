# Valores de proyecto

Los valores que hay que reponer a mano si alguna vez se vuelve a armar
`Talkify.xcodeproj` desde cero. Desciende del documento homónimo de Talkify
(Tornike Gomareli, MIT), actualizado a Dilo.

## Identidad — dos targets

| | `Dilo` | `Dilo-MAS` |
| --- | --- | --- |
| Bundle ID | `cl.espaciodigital.dilo` | `cl.espaciodigital.dilo.mas` |
| Producto | `Dilo.app` | `Dilo-MAS.app` (nombre visible: Dilo) |
| App Sandbox | NO | SÍ |
| Sparkle | sí | no (condición `DILO_MAS`) |
| Entitlements | `Dilo.entitlements` | `Dilo-MAS.entitlements` |
| Para qué | venta directa | App Store |

Comunes: app de macOS, deployment target 26.0, sólo `arm64`, categoría
`public.app-category.productivity`, versión de marketing `0.4.0`, build `400`.

El target de tests se llama `DiloTests` y su bundle es
`cl.espaciodigital.dilo.tests`. Las carpetas siguen llamándose `Talkify/` y
`TalkifyTests/` a propósito: renombrarlas convertiría cada
`git merge upstream/main` en un campo de conflictos de rename.

## Claves de Info.plist que importan

- `LSUIElement` = true (sólo barra de menús, sin ícono en el Dock)
- `NSMicrophoneUsageDescription` = "Dilo usa el micrófono para transcribir lo
  que dictas, en esta compu."
- `NSSpeechRecognitionUsageDescription` = "Dilo convierte tu voz en texto en
  esta compu."
- `NSPrincipalClass` = `NSApplication`
- `NSHighResolutionCapable` no se pone: viene en true para apps enlazadas
  contra SDKs modernos y el Info.plist generado de Xcode no tiene un
  `INFOPLIST_KEY_` para él.

### Claves de Sparkle (`Talkify/Info.plist`, sólo target `Dilo`)

El target mantiene `GENERATE_INFOPLIST_FILE = YES` **y** además apunta
`INFOPLIST_FILE = Talkify/Info.plist`; Xcode fusiona las claves generadas en
ese archivo. El plist existe sólo porque Sparkle lee `SUPublicEDKey` directo
del bundle y el passthrough `INFOPLIST_KEY_<nombre>` de Xcode descarta en
silencio las claves que no conoce. (Razón heredada de Talkify, sigue siendo
cierta.)

- `SUFeedURL` = `https://raw.githubusercontent.com/aacontn/dilo/main/appcast.xml`.
  **Una copia instalada consulta el feed con el que se compiló**: esta URL hay
  que dejarla definitiva antes del primer release. Si el repo termina
  llamándose distinto, esta clave y la constante `REPO` de
  `scripts/release.sh` son los dos únicos lugares que cambian.
- `SUPublicEDKey` = la llave EdDSA **de Dilo**, generada en el Mac de Alfonso
  con `scripts/setup-sparkle-keys.sh`. La privada vive en el Llavero, en la
  **cuenta `dilo`** (no en la global, para no mezclarla con la de ninguna otra
  app con Sparkle) y nunca en el repo. Si se pierde, ninguna copia instalada
  vuelve a actualizarse: exportarla una vez con `--export` y guardarla.
- `SUEnableAutomaticChecks` = **true** desde la Tarea 8. Estuvo en false
  mientras el feed y la llave eran los de Talkify, porque así Dilo se habría
  ofrecido Talkify 0.8.3 como actualización de sí mismo, verificada y todo.
- `SUScheduledCheckInterval` = 86400 (una vez al día)
- `SUAllowsAutomaticUpdates` = true (bajar solo sigue apagado por defecto)

**No edites este plist con PlistBuddy**: reescribe el archivo entero y se
lleva los comentarios que explican cada clave. A mano o con `sed`.

`Dilo-MAS` no tiene `INFOPLIST_FILE`: su plist se genera entero y no lleva
ninguna clave de Sparkle.

## Entitlements

`Dilo.entitlements` — App Sandbox apagado; hace falta para el tap de CGEvent
y la inserción por Accesibilidad. (Hardened Runtime: ver Firma, más abajo.)

```xml
<key>com.apple.security.device.audio-input</key><true/>
```

`Dilo-MAS.entitlements` — App Sandbox encendido:

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.device.audio-input</key><true/>
<key>com.apple.security.network.client</key><true/>
```

**Lo que no llevan, y por qué.** La Tarea 8 revisó los dos archivos contra lo
que la Tarea 2 midió en ejecución:

- `com.apple.security.automation.apple-events` no va en `Dilo`: el único
  `osascript` del repo está en `DiloCore/Sources/DiloMetrics/`, que es taller y
  no se enlaza a ningún target. Entra el día que la app misma hable con otra
  app por Apple Events, junto con su `NSAppleEventsUsageDescription`.
- `com.apple.security.cs.disable-library-validation` tampoco: los helpers de
  Sparkle se refirman con el mismo Team en `scripts/release.sh` y en el
  workflow de release, así que la validación de librerías pasa sola.
- `com.apple.security.files.user-selected.read-only` **se sacó de
  `Dilo-MAS`**: estaba por el arrastre de una grabación al notch, y esa es una
  de las capacidades que `SandboxedHost` no ofrece —`DropTranscriptionController`
  se devuelve antes de instalar el destino de arrastre—. Un entitlement que no
  habilita ninguna función es una pregunta más en la revisión de App Store.
- Accesibilidad, Input Monitoring y captura de audio no son entitlements sino
  servicios de TCC: no hay nada que declarar por ellos.

## Firma

**El día a día firma "Sign to Run Locally"**: `CODE_SIGN_IDENTITY = "-"`,
`CODE_SIGN_STYLE = Manual`, `DEVELOPMENT_TEAM` vacío, en Debug y en Release.
Este Mac no tiene ninguna identidad de firma (`security find-identity -v -p
codesigning` devuelve cero), así que todo lo de abajo está escrito y
verificado con firma ad-hoc, y listo para cuando haya identidad.

**`ENABLE_HARDENED_RUNTIME` del target `Dilo` es `$(DILO_HARDENED_RUNTIME)`, y
el proyecto define ese interruptor en `NO`.** Con Hardened Runtime encendido y
firma ad-hoc, dyld se niega a cargar `Sparkle.framework` —*"mapping process and
mapped file (non-platform) have different Team IDs"*— y la app no arranca. Las
dos salidas eran apagar el runtime o agregar
`com.apple.security.cs.disable-library-validation`; se eligió la primera porque
es un build setting que se revierte junto con la firma, y la segunda es un
entitlement que se podría publicar por accidente.

Quien firma de verdad enciende el runtime en la línea de comandos:

```bash
xcodebuild archive … DILO_HARDENED_RUNTIME=YES CODE_SIGN_IDENTITY="Developer ID Application: … (TEAMID)"
```

Eso hacen `scripts/release.sh` y el job `dilo` de `.github/workflows/release.yml`,
que además —igual que el `build.yml` del repo Tauri— sólo encienden el runtime
si la identidad importada es **"Developer ID Application"**. Sobre cualquier
otra, runtime NO y notarización tampoco. `Dilo-MAS` se queda en `NO`: la App
Store no lo pide y ese binario no lleva Sparkle.

### Firmar en este Mac

Cuando Alfonso importe el `.p12`:

```bash
# 1. El certificado, con la intermedia "Developer ID Certification Authority"
#    adentro o find-identity no lo da por válido.
security import dilo-developer-id.p12 -k ~/Library/Keychains/login.keychain-db \
  -T /usr/bin/codesign
security find-identity -v -p codesigning     # tiene que listar el Developer ID

# 2. El perfil de notarytool que espera scripts/release.sh
xcrun notarytool store-credentials dilo-notary \
  --apple-id <apple-id> --team-id <TEAMID> --password <contraseña-de-app>

# 3. Cortar el release
scripts/release.sh 0.4.0 --dry-run    # compila, firma, notariza, no publica
scripts/release.sh 0.4.0              # publica el release de GitHub
```

`scripts/release.sh` deduce la identidad y el Team ID solos del Llavero;
`SIGN_IDENTITY` y `DILO_TEAM_ID` los fuerzan, `NOTARY_PROFILE` cambia el
perfil y `SKIP_NOTARIZE=1` firma sin notarizar (sólo para probar local).

La **primera** vez que corra `generate_appcast`, el Llavero va a pedir permiso
para leer la llave privada de Sparkle y se queda esperando: hay que elegir
"Permitir siempre" o los releases siguientes tampoco corren solos.

### Lo que CI espera

`.github/workflows/release.yml` es manual (`workflow_dispatch`) y lee estos
secrets. Los seis primeros ya existen en `aacontn/dilo` (el repo del Dilo
Tauri); los tres de App Store son nuevos. **Sin ellos el workflow no falla**:
compila, firma ad-hoc y avisa, para poder probar la cañería antes de tener
identidad.

| Secret | Qué es |
| --- | --- |
| `APPLE_CERTIFICATE` | `.p12` del Developer ID Application, en base64 |
| `APPLE_CERTIFICATE_PASSWORD` | contraseña de ese `.p12` |
| `KEYCHAIN_PASSWORD` | contraseña del llavero temporal del runner |
| `APPLE_API_ISSUER` | issuer de la Team key de App Store Connect |
| `APPLE_API_KEY` | id de esa key (el de `AuthKey_XXXX.p8`) |
| `APPLE_API_KEY_P8` | contenido del `.p8` |
| `APPLE_MAS_APP_CERTIFICATE` | `.p12` de "Apple Distribution" |
| `APPLE_MAS_INSTALLER_CERTIFICATE` | `.p12` de "3rd Party Mac Developer Installer" |
| `APPLE_MAS_CERTIFICATE_PASSWORD` | contraseña de esos dos |

Y el `.p12` del Developer ID tiene que llevar la intermedia adentro: en el
runner, `find-identity` sólo marca válido el Developer ID si la cadena ancla.

### Cómo se publica

- **Venta directa:** `scripts/release.sh <versión>` desde `main` limpio, en el
  Mac de Alfonso. Compila Release con runtime, refirma los helpers de Sparkle
  de adentro hacia afuera, arma y firma el DMG, notariza con reintentos, grapa,
  arma el ZIP de Sparkle, regenera `appcast.xml` firmado y publica el release
  de GitHub con el DMG, su copia de URL estable, el ZIP y el appcast. El
  workflow `release.yml` hace lo mismo hasta el ZIP, pero **no** el appcast: la
  llave privada de Sparkle vive en el Llavero y no sube a ningún runner.
- **App Store:** despachar `release.yml`. El job `dilo-mas` firma y deja el
  `.pkg` como artefacto; la subida a App Store Connect es el job `mas-upload`,
  que sólo corre si el despacho marca la casilla, porque una build subida queda
  en el historial del app record y no se borra.
- **Cambiar de "Dilo Signing" ad-hoc a Developer ID cambia la identidad de
  TCC**: quien ya tenga Dilo instalado va a tener que volver a conceder
  Accesibilidad y micrófono una vez.

## Build settings

Base: `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`,
`DEAD_CODE_STRIPPING = YES`, `ONLY_ACTIVE_ARCH = NO`.

Desvíos deliberados respecto de la plantilla de Xcode:
`SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated` y
`SWIFT_APPROACHABLE_CONCURRENCY = NO`. Los componentes heredados fueron
escritos para concurrencia estricta clásica con `@MainActor` explícito; el
aislamiento MainActor por defecto cambiaría el de sus clases sin anotar (por
ejemplo los callbacks del hilo de audio en `MicrophoneInput`).

`Dilo-MAS` agrega `DILO_MAS` a `SWIFT_ACTIVE_COMPILATION_CONDITIONS`. Es lo
que deja Sparkle fuera de ese binario y esconde el panel Actualizaciones.

Dos interruptores propios, definidos a nivel de proyecto y pensados para
pasarse en la línea de comandos:

| Ajuste | Por defecto | Para qué |
| --- | --- | --- |
| `DILO_HARDENED_RUNTIME` | `NO` | lo lee `ENABLE_HARDENED_RUNTIME` del target `Dilo`; se pasa `YES` cuando hay Developer ID |
| `DILO_SUFIJO_ID` | vacío | se pega al final de los tres `PRODUCT_BUNDLE_IDENTIFIER` (app, tests y MAS) |

`DILO_SUFIJO_ID=.ci` es lo que usa `.github/workflows/ci.yml`: corre los bundle
ids de la corrida a `cl.espaciodigital.dilo.ci` y `…dilo.tests.ci`, para que un
build de CI —o una prueba local— nunca herede ni ensucie los permisos de TCC
concedidos a la app de verdad. El sufijo mueve los tres a la vez, así que
siguen siendo distintos entre sí, que es lo que `xcodebuild test` necesita.

## Paquete local

`DiloCore/` entra como `XCLocalSwiftPackageReference` y sus productos se
enlazan en **los dos** targets. Cuando nazca un módulo nuevo hay que agregarlo
al `Package.swift`, al `packageProductDependencies` de los dos targets y a la
tabla de `AGENTS.md`.

## Idiomas

`developmentRegion = es`, `knownRegions = (es, en, Base)`. El español es el
idioma en que se escribe el copy; el inglés se traduce desde ahí, nunca al
revés.

El catálogo `Talkify/Localizable.xcstrings` **sí traduce en runtime**: los
componentes de Ajustes reciben `LocalizedStringKey`, no `String`, así que
`Text` pasa por el catálogo. Lo que es valor y no copy —una ruta, el nombre de
un modo, lo que dictaste— se envuelve en `"\(valor)"` para que salga tal cual,
y lo que se arma por pedazos (la frase de un atajo, el aviso de un modelo de
traducción) usa `String(localized:)` en cada pedazo. La deuda que dejó la
Tarea 1 quedó saldada.

`STRING_CATALOG_GENERATE_SYMBOLS` sigue en `NO`: el generador de símbolos
colapsa "Borrar" y "Borrar…" en el mismo identificador y falla la compilación.

## Tests de la app en este Mac

`xcodebuild test` se colgaba antes de "Testing started": el host de los tests
es la app real y al arrancar levanta su tap de CGEvent, que dispara TCC contra
la entrada de la copia instalada y espera a un humano. Con un bundle id propio
la entrada de TCC es otra y la suite corre sola:

```bash
xcodebuild -project Talkify.xcodeproj -scheme Dilo \
  -derivedDataPath /Volumes/SSD2/derived-data \
  PRODUCT_BUNDLE_IDENTIFIER=cl.espaciodigital.dilo.deuda test
```

El id puede ser cualquiera bajo `cl.espaciodigital.dilo`: `DiloTests` compara
el host por prefijo justamente para que este truco no rompa la suite.

El `-derivedDataPath` de la suite no puede ser el mismo desde el que lanzas la
app a mano con `open -a`: el `.app` queda registrado en LaunchServices con el
bundle id de esa build, y la corrida siguiente muere con *"the test runner hung
before establishing connection"* aunque el código esté bien. Un directorio para
probar a mano y otro para la suite, y listo.
