# Spikes 1 y 2 — Talkify en sandbox (compuerta de entrada del plan nativo)

**Fecha:** 2026-09-20 · **Máquina:** M1 16 GB, macOS 27, Xcode 27 / Swift 6.4, sin notch · **Repo:** `/Volumes/SSD 1/Dilo/mac`, rama `spike/sandbox` · **Spec:** [Dilo Mac nativo](../specs/2026-09-20-dilo-mac-nativo-design.md) §4 y §Verificación 1–2

## Los tres sí/no

| Capacidad en sandbox | Veredicto | Evidencia |
| --- | --- | --- |
| Tap de audio del sistema (`AudioHardwareCreateProcessTap`) | **SÍ** | `tapspike-sandboxed.app`: 239.104 frames, pico 0,592, 1.916.928 bytes con `afplay` sonando; control en silencio: mismos frames, pico 0,0. Idéntico al no-sandboxed (pico 0,591). Sin prompt de TCC: el entitlement `device.audio-input` bastó. |
| Pegar (pasteboard + Cmd+V sintético) | **pendiente de clic de Alfonso** | `NSPasteboard.general` escribe y relee dentro del sandbox: sí, probado. `CGPreflightPostEventAccess` = false en ambos builds porque Accesibilidad no está concedida a ningún binario del spike. |
| Atajo global (`CGEventTap` + Input Monitoring) | **pendiente de clic de Alfonso** | `CGEvent.tapCreate` = nil en ambos builds, sandboxed y no. Es falta de Input Monitoring, no el sandbox: la llamada se comporta igual con y sin `app-sandbox`. |

Lo que sí distingue al sandbox, y es lo que importa para §4: leer Accesibilidad **de otra app**
devuelve `-25204 kAXErrorCannotComplete` desde el sandboxed y `-25211 kAXErrorAPIDisabled` desde
el no-sandboxed. El sandboxed no dice "falta permiso", dice "no puedo". Confirmación dura tras el
clic de Alfonso.

**Trampa que costó media hora:** el tap entrega **silencio** (frames sí, pico 0,0) si el binario
se corre desde el terminal: TCC atribuye la captura al proceso responsable, no al bundle. Con
`open -a` el mismo binario entrega audio real. Audio del sistema se prueba con `open`.

## Inventario de Accesibilidad y entrada (base de `HostCapabilities`)

Rutas relativas a `/Volumes/SSD 1/Dilo/mac/Talkify/`. **Accesibilidad hacia otras apps — lo que el sandbox rompe:**

| Sitio | Para qué |
| --- | --- |
| `Dictation/PermissionService.swift:7,19,27` | `AXIsProcessTrusted` / `…WithOptions`: la compuerta y el único prompt del sistema, una vez por lanzamiento |
| `Dictation/TextInsertionService.swift:218-219` | `AXUIElementCreateSystemWide` + `kAXFocusedUIElement`: **capturar el foco antes de dictar** |
| `Dictation/TextInsertionService.swift:137` | `AXUIElementGetPid`: de qué app es el foco, para nombrarla en el historial |
| `Dictation/TextInsertionService.swift:222-232` | `kAXSubrole` = `kAXSecureTextFieldSubrole`: **rechazar campos de contraseña** |
| `Dictation/TextInsertionService.swift:235-273` | `kAXWindow` + `kAXPosition`/`kAXSize`: en qué pantalla dibujar el HUD |
| `Dictation/TextInsertionService.swift:293-307` | `isStillFocused`: **revalidar el foco justo antes de pegar** |
| `ReadAloud/FocusedSelectionReader.swift:34-35,48-53` | `kAXSubrole` + `kAXSelectedText` sobre el foco de la app al frente: **releer la selección** para Leer en voz alta |

**Entrada sintética y tap de teclado — TCC, no sandbox:**

| Sitio | Para qué |
| --- | --- |
| `Input/GlobalKeyEventMonitor.swift:93-135,230-235` | `CGEvent.tapCreate` en `.cgSessionEventTap`, `tapEnable` y el rearme tras `tapDisabledByTimeout`: **el atajo global** (dictado, cancelar, Leer en voz alta). Necesita Input Monitoring |
| `Dictation/TextInsertionService.swift:407-419` | `CGEvent(keyboardEventSource:)` + `post(tap:.cghidEventTap)`: **Cmd+V para pegar** (virtualKey 9) y **Cmd+C para releer la selección** (virtualKey 8). Necesita Accesibilidad |
| `Input/KeyBindings.swift`, `Input/ShortcutAssignment.swift`, `Settings/Components/KeyRecorderView.swift:116` | `CGEventFlags` como modelo de modificadores. Puro |

**Portapapeles — funciona en sandbox:**

| Sitio | Para qué |
| --- | --- |
| `Dictation/TextInsertionService.swift:61,92-106` | `NSPasteboard.general` como destino del pegado, leído en cola serial con lease |
| `Dictation/TextInsertionService+Clipboard.swift:44-80,190-260` | fotografiar y restaurar el portapapeles del usuario, con los tipos transitorios de nspasteboard.com |
| `DropTranscription/TranscriptOffer.swift:106-107`, `HUD/TranscriptDragView.swift:109-111` | copiar y arrastrar el transcript de un archivo |

**Monitores de eventos:**

| Sitio | Para qué |
| --- | --- |
| `DropTranscription/DragWatcher.swift:34-41` | `NSEvent.addGlobalMonitorForEvents([.leftMouseDragged,.leftMouseUp])`: detectar que arrastran un archivo hacia el notch. Necesita Accesibilidad |
| `DropTranscription/DragWatcher.swift:26,92-100` | `NSPasteboard(name: .drag)`: qué archivo se arrastra. **En sandbox no hay extensión de sandbox para ese archivo**: se ve el URL, no se puede abrir |
| `Settings/Components/KeyRecorderView.swift:54` | `addLocalMonitorForEvents`, solo dentro de Ajustes. No necesita permiso |

## Qué compiló y qué quedó inerte

Ambos builds: `BUILD SUCCEEDED`, cero errores, 3 avisos preexistentes. **El sandbox no rompe la
compilación de una sola línea de Talkify** — lo que se cae, se cae en ejecución. Sparkle 2.9.5
conserva sus `Downloader.xpc` e `Installer.xpc` dentro del bundle, así que con `network.client`
debería seguir actualizándose; no se probó una actualización real. Lo que hay que envolver en
`HostCapabilities` (§4), en orden de dolor:

1. **Captura y revalidación de foco** (218, 293). Sin AX no hay "pegar donde estabas": en sandbox
   degrada a "copiado al portapapeles" y lo dice.
2. **Campo seguro** (222). Sin AX no se sabe si el destino es una contraseña: no ofrecer pegado
   directo, no adivinar. **Pantalla del HUD** (235) degrada a la del mouse; cosmético.
3. **Leer en voz alta entero** (`FocusedSelectionReader`): 100 % AX hacia otra app. En sandbox el
   menú no aparece (patrón TypeMeIt).
4. **Arrastre al notch** (`DragWatcher`): el monitor global necesita AX y el archivo necesita una
   extensión de sandbox que un monitor de mouse no otorga. Se reemplaza por un panel de abrir.
5. **Cmd+V sintético y el tap del atajo** siguen siendo legales en sandbox (precedente TypeMeIt)
   pero cuelgan de TCC: misma capa, estado concedido/no concedido, no un booleano de sandbox.

## Lo que falta y es un clic de Alfonso

1. Abrir `/Volumes/SSD2/scratch/talkify/Talkify.app` (spike 1: dictar diez minutos en español).
   Pedirá **Micrófono**, **Reconocimiento de voz**, **Accesibilidad** (diálogo propio de Talkify
   y después el del sistema) e **Input Monitoring** al primer uso del atajo, todos en Ajustes del
   Sistema → Privacidad y seguridad, como `Talkify` / `com.tgomareli.Talkify`.
2. Abrir `Talkify-sandboxed.app` y conceder lo mismo: es una entrada **distinta** en Ajustes,
   `com.tgomareli.Talkify.sandboxed`. Con permisos, probar y anotar acá: pegar en Cursor y en el
   terminal (foco, pegado, restauración del portapapeles); que el atajo responda con otra app al
   frente; que Leer en voz alta encuentre una selección — si no la encuentra, es la prueba dura
   de que el sandbox corta AX hacia otras apps.
3. Con Accesibilidad concedida, volver a correr `axprobe`: si el no-sandboxed devuelve 0 y el sandboxed sigue en −25204, §4 queda cerrado sin depender de Talkify.

## Rutas

- `/Volumes/SSD2/scratch/talkify/Talkify.app` (normal) y `Talkify-sandboxed.app`, ad-hoc, 20 MB cada uno; sus logs de build al lado
- `/Volumes/SSD2/scratch/tap-spike/` — paquete Swift, `tapspike-{plain,sandboxed}.app`, `axprobe-{plain,sandboxed}.app`
- WAV del tap sandboxed: `~/Library/Containers/com.dilo.tapspike.sandboxed/Data/tap.wav`
- En `spike/sandbox`: `Talkify-Sandboxed.entitlements` y el `Debug` del target con `ENABLE_APP_SANDBOX = YES`. `Release` queda intacto y sin sandbox.

## Idioma y píldora sin notch

**No fue el motor: fue el segundo gatillo.** `defaults read com.tgomareli.Talkify` da
`recognitionLocale = es_CL` y `recognitionLocaleSecondary = en_US`. El segundo idioma viene apagado
de fábrica, así que lo encendió él, y su gatillo por defecto es `KeyBindings.rightOptionTrigger`
(`Input/KeyBindings.swift:94`, keyCode 61, **⌥ derecha**) — que en teclado latinoamericano es AltGr,
la tecla de `@ # \ | { } [ ]`. Dictando prompts y terminal se aprieta a cada rato, y cada vez arranca
una sesión **en inglés**. Eso es "mitad en inglés"; el resto lo transcribe es_CL, ya instalado.

**Idioma por defecto:** `recognitionLocale` vacío → `defaultLocale()` (`SpeechRecognitionService.swift:400-415`)
resuelve `supportedLocale(equivalentTo: .current)`, con en-US de respaldo. Acá `Locale.current = es_CL`, así
que el default ya era español. No hay detección automática: Apple Speech transcribe **un idioma por sesión**.

**Variantes en esta máquina** (`/Volumes/SSD2/scratch/speech-locales/` imprime `supportedLocales`
e `installedLocales`): de 45 locales soportados, en español hay **es_CL, es_ES, es_MX, es_US — las
cuatro ya instaladas**. No existe es-419 (`equivalentTo: es-419` cae en es_CL). `DictationTranscriber`
ofrece las mismas cuatro. **No hay nada que descargar**: `AssetInventory` no va a pedir un asset.

**Arreglo, un solo gatillo:** Ajustes → *Language* → "Dictation language" = *Spanish (Chile)*;
"Second language" = la primera opción vacía (**Off**). Si quiere conservar inglés, mover el
"Second language trigger" a algo que no sea ⌥ derecha.

**Píldora sin notch:** `CoreHUD/HUDNotchGeometry.swift:14,123-126,136-147`. Sin notch medido la
píldora es un rectángulo negro de 185×32 centrado en `screen.frame.midX` y pegado al borde
superior, **dibujado encima de la barra de menús** mientras `hudClearsMenuBar` sea false — y en
los defaults de Alfonso vale 0. Tapa los status items que le queden debajo, el propio de Talkify
incluido (issue #83 de upstream). El HUD de volumen de macOS 26+ también es una píldora en esa
franja pero a la derecha: no se superponen, solo comparten franja y lenguaje visual. Se baja con
Ajustes → *Appearance* → "Clear the menu bar on other displays". Para Dilo es decisión de diseño,
no bug: el spec pide "píldora idéntica cuando no hay notch", y con dos 1080p sin notch ese es el caso normal.

## Reproducir

Xcode 27 recién instalado pide `xcodebuild -runFirstLaunch` y `xcodebuild -downloadComponent
MetalToolchain` antes de compilar nada; sin el segundo, los `.metal` de `CoreHUD/` no compilan.

```sh
cd "/Volumes/SSD 1/Dilo/mac" && git switch spike/sandbox
SIGN='CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER='
# normal (Release no lleva sandbox) / sandboxed (Debug sí, con bundle id propio)
xcodebuild -project Talkify.xcodeproj -scheme Talkify -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /Volumes/SSD2/derived-data/talkify-spike $SIGN build
xcodebuild -project Talkify.xcodeproj -scheme Talkify -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /Volumes/SSD2/derived-data/talkify-sandboxed \
  $SIGN PRODUCT_BUNDLE_IDENTIFIER=com.tgomareli.Talkify.sandboxed build

cd /Volumes/SSD2/scratch/tap-spike
swift build -c release --scratch-path /Volumes/SSD2/derived-data/tap-spike
say -v Eddy -o prueba.aiff "Probando el tap de audio del sistema."
afplay prueba.aiff & open -a ./tapspike-sandboxed.app --args tap.wav   # con open, NO ./binario
cat ~/Library/Containers/com.dilo.tapspike.sandboxed/Data/tap-spike.log
open -a ./axprobe-sandboxed.app && cat ~/Library/Containers/com.dilo.axprobe.sandboxed/Data/ax-probe.log
```
