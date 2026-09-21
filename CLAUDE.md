# AGENTS.md / CLAUDE.md — Dilo Mac

Instrucciones para cualquier asistente que escriba código en este repo.

> **`AGENTS.md` es la fuente de verdad y `CLAUDE.md` es su copia byte a byte.**
> Existen dos archivos porque cada familia de herramientas busca un nombre
> distinto (Claude Code lee `CLAUDE.md`, Codex lee `AGENTS.md`). Son copias
> completas y no un puntero `@AGENTS.md` porque no toda herramienta resuelve
> esa referencia, y la que no la resuelve se queda sin ninguna instrucción.
> **Edita `AGENTS.md` y cópialo sobre `CLAUDE.md`** —
> `DiloCore/Tests/DiloTextTests/InstruccionesDeAgenteTests.swift` falla si se
> separan.

## Qué es este repo

**Dilo Mac** es la app nativa de Mac de Dilo: dictado en español, sólo Apple
Silicon, macOS 26+, viviendo en la barra de menús y en el notch. Es un **fork
de [Talkify](https://github.com/tornikegomareli/Talkify)** (Tornike Gomareli,
MIT), remote `upstream`. Dilo es un fork con cariño de Talkify: el HUD, la
sesión de dictado y el tap de teclado vienen de ahí y se conserva su
copyright junto al propio.

El repo Tauri (`/Volumes/SSD 1/Dilo/app`) está **congelado en 0.3.2**. De ahí
se porta el **producto, no el código**: los specs de modos, español,
proveedores, historial y palabras propias se leen y se reescriben en Swift.
Nunca se copia Rust.

Idioma: **todo el copy visible es español de autoría propia** (tuteo, directo,
cero relleno corporativo); inglés como segunda locale, traducido desde el
español. Los comentarios y los mensajes de commit también van en español.

## Documentos que mandan

1. **`docs/superpowers/specs/2026-09-20-dilo-mac-nativo-design.md`** — la
   dirección. Qué se toma de Talkify, el motor doble, los números no
   negociables, la capa de capacidades, las tres lecciones de la primera
   prueba en español.
2. **`docs/superpowers/plans/2026-09-20-dilo-mac-v1.md`** — el plan de v1,
   tarea por tarea. Una tarea por agente, en orden de dependencias.
3. **`docs/superpowers/spikes/`** — los tres reportes que abrieron la
   compuerta: sandbox de Talkify, diarización de Gemini, Laya en español.
4. **`CONTEXT.md`** — el modelo de dominio y su vocabulario. Los términos que
   lista son vinculantes en identificadores, comentarios y commits.
5. **`docs/adr/`** — las decisiones de arquitectura heredadas de Talkify.
   Si tu cambio contradice una, dilo; no la pises en silencio.

## Restricciones que no se negocian

- **Dos targets, desde el día uno.** `Dilo` (venta directa, Sparkle,
  `cl.espaciodigital.dilo`) y `Dilo-MAS` (App Sandbox, sin Sparkle,
  `cl.espaciodigital.dilo.mas`). Retrofitear el sandbox después cuesta meses.
- **El sandbox no rompe la compilación: se cae en ejecución.** Todo lo que
  dependa de la API de Accesibilidad hacia otras apps pasa por
  `HostCapabilities` (Tarea 2). Lo que no se puede hacer **se esconde**, no
  falla. Se prueba lanzando con `open -a`, **nunca desde el terminal**: TCC
  atribuye el permiso al proceso padre y el tap de audio devuelve silencio.
  Qué anfitrión resolvió una copia lo dice ella misma al arrancar:
  `log show --predicate 'subsystem == "cl.espaciodigital.dilo"' --last 5m`,
  categoría `capacidades`. Antes de buscar por qué "no aparece" algo en el
  build de App Store, mira esa línea: lista lo que está escondido.
- **Ningún gatillo por defecto escribe símbolos** en teclado latino. Nada de
  ⌥ derecha sola: en ISO-LatAm es AltGr y escribe `@ # \ | { } [ ]`. Default
  `fn`/🌐 sostenido; alternativa ⌃⌥Espacio.
- **Nunca se toca el volumen maestro.** El "Duck other audio" de Talkify está
  apagado y escondido. Si algún día se silencia la música al dictar, se
  **pausa la reproducción**; el volumen es del usuario.
- **La píldora sin notch va debajo de la barra de menús**, con identidad Dilo.
  Nunca tapa los status items ni imita el HUD de volumen del sistema.
- **Los números del spec §3 se miden, no se prometen**: 60 MB en reposo, ~0 %
  de CPU, arranque en frío < 1 s, soltar→texto < 300 ms, `.app` < 25 MB sin
  modelos. Si un cambio empeora uno, no entra.
- **Nada de secretos en el repo.** Las credenciales viven en el Llavero. El
  `AGENTS.md` está versionado y se empuja a GitHub: lo que escribas acá queda
  visible para siempre.
- **Una dependencia nueva se justifica en el commit.** Hoy: Sparkle (sólo
  `Dilo`) y FluidAudio cuando llegue el motor Parakeet.

## Dónde va cada cosa

```
mac/
  AGENTS.md, CLAUDE.md       instrucciones (copias byte-idénticas)
  CONTEXT.md                 modelo de dominio y vocabulario
  Talkify/                   el árbol que viene de upstream (ver abajo)
  Talkify/Onboarding/        los Primeros pasos (propio de Dilo)
  Talkify/Resources/NotasDeVersion/  las notas de cada versión, en español
  TalkifyTests/              tests de la app
  DiloCore/                  el paquete propio: un módulo por tema
  docs/superpowers/          spec, plan y spikes de Dilo
  docs/talkify/              lo de Talkify que se archiva con atribución
  docs/adr/, docs/design/    heredados de Talkify, siguen vigentes
  brand/                     ícono, wordmarks e íconos de barra de Dilo
  scripts/                   release, llaves de Sparkle, métricas
```

**`Talkify/` y `TalkifyTests/` conservan su nombre a propósito.** Renombrar
esas carpetas convertiría cada `git merge upstream/main` en un campo de
conflictos de rename. El **target** y el **producto** sí se llaman `Dilo`; la
carpeta no. Lo mismo vale para `CoreHUD/`, `Dictation/` e `Input/`: se
mantienen lo más cerca posible del original y **todo lo de Dilo vive en
`DiloCore/`**.

### `DiloCore/` — el paquete propio

Un Swift Package local, con un módulo por tema, testeable con `swift test`
sin abrir Xcode. La app lo enlaza una sola vez (Tarea 0); después nadie toca
`project.pbxproj` salvo la Tarea 8.

| Módulo | Qué contiene | Tarea |
| --- | --- | --- |
| `DiloText` | muletillas del español, diccionario personal, notas de versión | 5, 9 |
| `DiloEngines` | `SpeechEngine` + Apple + Parakeet (FluidAudio) | 3 |
| `DiloModes` | `Mode`, `Provider`, `Decider` por reglas | 4 |
| `DiloCapabilities` | `HostCapabilities` completa y sandbox, `Permiso` | 2, 9 |
| `DiloMetrics` | reposo, arranque, latencia soltar→texto | 7 (la app **no** lo enlaza: es taller) |

**Colores de marca:** tinta `#0D1117`, mango `#FF9E1B`, menta `#2EE6A8`, en
`DiloBrand` (`Talkify/Settings/Components/SettingsTheme.swift`), una sola vez
para SwiftUI y para los `NSImage`. El acento de la app es **mango**. Los
activos están en `brand/`; el `.icns` se regenera con `rsvg-convert` +
`iconutil` desde `brand/dilo-icon.svg` y queda en `brand/generado/`.

Cuando un módulo nuevo entre, se agrega al `Package.swift`, al
`packageProductDependencies` de **los dos** targets, y a esta tabla.
`DiloMetrics` es la excepción: mide la app desde afuera, así que vive en el
paquete pero no se enlaza a ningún target, y por eso no toca `project.pbxproj`.
Se construye y se corre desde `scripts/metrics.sh`.

**Excepción vigente:** `DiloModes` viaja dentro del producto `DiloText` en vez
de tener el suyo. Un producto nuevo obliga a tocar `project.pbxproj`, y ese
archivo estuvo congelado mientras corrían cinco ramas en paralelo. El módulo,
su carpeta y sus tests sí son propios; lo único compartido es la línea del
producto. Cuando alguien vuelva a abrir el `.pbxproj` —Tarea 8— se separa en
`.library(name: "DiloModes", targets: ["DiloModes"])` y se agrega a los dos
targets.

### `Talkify/` — el mapa que viene de upstream

Lo que sigue es el mapa de Talkify 0.8.3 resumido de su `CLAUDE.md` y su
`CONTEXT.md` (original completo en `docs/talkify/`), y sigue siendo cierto:

- `App/` — la raíz de composición: `AppDelegate` cablea cada controlador y
  observa los atajos; `StatusItemController` es el menú de la barra;
  `AppSettings.swift` es la única fuente persistida de preferencias. **Las
  claves y los `rawValue` cargan peso** (picks guardados, prefijos de nombres
  de sonidos): no los renombres.
- `Input/` — el tap global de CGEvent (`GlobalKeyEventMonitor`) y el modelo
  `KeyBinding`, compartido por dictado, Ajustes y el menú.
- `Dictation/` — el núcleo de la sesión. `DictationSessionMachine` es el
  reducer puro con todas las transiciones (idle/starting/recording/finishing/
  cancelling, sostenido vs. trabado), cubierto por tests;
  `DirectDictationController` corre las guardas y ejecuta los efectos
  (ADR-0005: MV + reducers locales, nada de MVVM ni TCA). `HUD/` es lo que
  sólo el dictado dibuja.
- `CoreHUD/` — **sólo lo que comparten todas las features**: `HUDStage` posee
  el único panel y arbitra quién tiene la forma; `HUDSurface` dibuja la forma
  negra; más los sonidos, la geometría pura (`HUDPlacement`,
  `HUDNotchGeometry`, con tests) y `Shaders/` (ADR-0002).
- `DropTranscription/` — arrastrar un archivo al notch. Es la base del
  "arrastra una grabación" del notetaker de v2.
- `Translation/`, `ReadAloud/`, `Insights/`, `Updates/` — traducción,
  lectura en voz alta, métricas locales de uso y Sparkle. `Updates/` es el
  único lugar que puede escribir `import Sparkle`, y un test lo vigila.
- `Settings/` — la ventana de Ajustes sin barra de título: `SettingsView` es
  el marco, `SettingsSections` la navegación, `Sections/` un archivo por
  panel, `Components/` el sistema de diseño reutilizable.

### Reglas del HUD que siguen mordiendo (de Talkify)

- Ventana anfitriona de tamaño fijo: el origen se mueve, nunca se
  redimensiona.
- Fillets sólo contra una carcasa real; notch simulado (185×32) en el resto.
  `NSWindow.Level.mainMenu + 3`, sin APIs privadas.
- El rebote de la revelación vive sólo en la escala anclada arriba, nunca en
  la posición: un exceso de posición abre una rendija contra el borde.
- **El silencio y un micrófono muerto tienen que verse distinto.**

## Idioma, copy y el catálogo

El **español es el idioma en que se escribe** (`developmentRegion = es`); el
inglés se traduce desde ahí y vive en `Talkify/Localizable.xcstrings`. Nunca al
revés: una frase pensada en inglés y traducida suena a manual, y eso es
exactamente lo que Dilo no es.

Voz: tuteo, directo, cero relleno corporativo. "Aprieta, habla, suelta." Los
términos técnicos van sin traducir (commit, prompt, sandbox). La referencia es
el locale `es` del repo Tauri (`app/src/i18n/locales/es/translation.json`),
escrito a mano.

**Agujero conocido, hoy:** los componentes de Ajustes reciben `String`
(`SettingsRow.title`, `SettingsCard.title`, `description`…), y `Text(String)`
**no** pasa por el catálogo — sólo `Text("literal")` lo hace. Así que hoy el
catálogo es contenido correcto y revisable, pero cambiar el Mac a inglés no
traduce la mayoría de Ajustes. Arreglarlo es convertir esos parámetros a
`LocalizedStringKey` y resolver los call sites que pasan un `String` calculado
(los de `LanguageSettingsView` sobre todo). No se hizo en la Tarea 1 porque es
un refactor de los componentes, no del copy.

`STRING_CATALOG_GENERATE_SYMBOLS` está en `NO` a propósito: el generador de
símbolos colapsa "Borrar" y "Borrar…" en el mismo identificador y falla la
compilación. Nada usa esos símbolos.

**Enums persistidos:** un `rawValue` guardado en `UserDefaults` no se traduce
nunca — renombrarlo borra la elección de la persona en silencio. El nombre
visible va en un `var title: String` aparte, y el picker muestra `title`, no
`rawValue`.

## Cómo se compila y se prueba

DerivedData vive en `/Volumes/SSD2/derived-data` (disco de taller, se puede
borrar entero). Nunca en el disco interno.

```bash
# Los dos targets, limpio
xcodebuild -project Talkify.xcodeproj -scheme Dilo -configuration Debug \
  -derivedDataPath /Volumes/SSD2/derived-data build
xcodebuild -project Talkify.xcodeproj -scheme Dilo-MAS -configuration Debug \
  -derivedDataPath /Volumes/SSD2/derived-data build

# El paquete propio, sin abrir Xcode
cd DiloCore && swift test

# Los tests de la app
xcodebuild -project Talkify.xcodeproj -scheme Dilo \
  -derivedDataPath /Volumes/SSD2/derived-data test

# Los números del spec §3 contra el .app ya compilado
./scripts/metrics.sh /ruta/a/Dilo.app
./scripts/metrics.sh /ruta/a/Dilo.app --sin-latencia   # sin el gancho Debug
```

`scripts/metrics.sh` deja el reporte en `docs/metricas/ultima-medicion.json`
—que **se versiona**, porque `swift test` lo lee y falla si un número se
rompe— y termina con código ≠ 0 si un umbral no se cumple o si una métrica no
se pudo medir. Tarda unos tres minutos: la ventana de reposo sola son 60 s.

Para medir "soltar → texto" el `.app` tiene que ser un build **Debug** y el
terminal necesita Accesibilidad: la medición inyecta un WAV y dispara la sesión
apretando el menú de la barra. El gancho es la variable de entorno
**`DILO_METRICS_WAV`**, que `MicrophoneInput` respeta sólo bajo `#if DEBUG`
(`Talkify/Dictation/MicrophoneInput+MetricasWAV.swift`): con ella apuntando a un
WAV, la sesión escucha ese archivo en vez del micrófono, al ritmo real, y anota
en `<wav>.soltado` el instante en que el controlador manda a parar. En release
no existe: el archivo entero está dentro de un `#if DEBUG`.

Los dos `xcodebuild` y `swift test` tienen que pasar antes de devolver el
trabajo. Para probar el sandbox en runtime: `open -a`, nunca el binario desde
el terminal.

**`xcodebuild test` se cuelga en este Mac** antes de "Testing started": el host
de los tests es la app real, y al arrancar levanta su tap de CGEvent, que
dispara TCC y espera a un humano. En CI pasa igual pero ahí TCC deniega solo y
la suite corre. Mientras tanto, la red de seguridad local es `swift test` en
`DiloCore/` más los dos `xcodebuild build`.

**Hardened Runtime apagado mientras la firma sea local.** Con firma ad-hoc y
Hardened Runtime encendido, dyld se niega a cargar `Sparkle.framework` y la app
no arranca. El target `Dilo` lee `$(DILO_HARDENED_RUNTIME)`, que el proyecto
define en `NO`: quien firma con Developer ID pasa `DILO_HARDENED_RUNTIME=YES`
en la línea de comandos y nadie tiene que acordarse de un switch en Xcode.
`Dilo-MAS` se queda en `NO`. Detalle en `docs/ProjectSettings.md`.

**`DILO_SUFIJO_ID` corre los bundle ids de una corrida.** Vacío por defecto;
con `DILO_SUFIJO_ID=.ci` la app pasa a `cl.espaciodigital.dilo.ci` y el bundle
de tests a `…dilo.tests.ci`, los dos a la vez. Es lo que usa CI para que un
build automático nunca herede ni ensucie los permisos de TCC de la app de
verdad, y sirve igual para probar algo local sin pisar los propios.

## Primeros pasos y notas de versión

- **El onboarding vive en `Talkify/Onboarding/`** y se abre solo la primera
  vez; después, desde el menú de la barra (**Primeros pasos…**). Son cuatro
  pantallas: bienvenida con el gatillo real, permisos uno por uno con su
  porqué, elegir motor y un dictado de prueba en un campo de la propia ventana.
- **Qué permiso se pide lo decide `Permiso.pasos(anfitrion:motorEsApple:)`**,
  en `DiloCapabilities` y con tests: lo que el anfitrión esconde no se pide, y
  el Reconocimiento de voz sólo aparece con el motor de Apple elegido. Si algún
  día el sandbox pierde el pegado o el tap, esa pantalla se ajusta sola.
- **El estado de cada permiso se lee en vivo**, una vez por segundo mientras la
  pantalla está abierta: TCC cambia por fuera del proceso y una foto tomada al
  abrir envejece mientras la persona está en Ajustes del Sistema.
- **Las notas de versión son un `.md` por versión en
  `Talkify/Resources/NotasDeVersion/`**, y son un solo archivo para dos usos:
  la app las muestra en Ajustes → Novedades (leídas del bundle, parseadas por
  `NotasDeVersion` de `DiloText`) y `scripts/release.sh` publica ese mismo
  archivo en el release. Talkify traía su changelog de GitHub; Dilo no depende
  de internet para contar qué cambió, ni deja que el release y la app digan
  cosas distintas. Las notas viejas de Talkify quedan archivadas en
  `docs/release-notes/`.

## Firma, actualizaciones y cómo se publica

- **Hoy no hay identidad de firma en el Mac de Alfonso** (`security
  find-identity -v -p codesigning` devuelve cero) ni perfil de `notarytool`.
  Todo lo de firma está escrito y verificado con firma ad-hoc, y listo para
  cuando exista.
- **Sparkle: llave y feed propios.** La mitad privada EdDSA vive en el Llavero
  de Alfonso, en la cuenta `dilo`; la pública está en `Talkify/Info.plist` y se
  commitea. `scripts/setup-sparkle-keys.sh` la consulta y la genera la primera
  vez. Perderla deja a cada copia instalada sin poder actualizarse nunca más.
  **No edites ese plist con PlistBuddy**: reescribe el archivo y se lleva los
  comentarios.
- **Una copia instalada consulta el `SUFeedURL` con el que se compiló.** Esa
  URL y la constante `REPO` de `scripts/release.sh` son los dos únicos lugares
  donde vive el nombre del repo, y hay que dejarlos definitivos **antes del
  primer release**.
- **Venta directa:** `scripts/release.sh <versión>` desde `main` limpio. Firma,
  refirma los helpers de Sparkle, arma el DMG, notariza con el perfil
  `dilo-notary` (con reintentos: el fallo del 14-sep en el repo Tauri fue red
  sondeando el estado, no la firma), grapa, regenera el appcast firmado y
  publica el release.
- **App Store:** despachar `.github/workflows/release.yml`. El job `dilo-mas`
  deja el `.pkg` firmado como artefacto; subirlo a App Store Connect es el job
  `mas-upload`, que sólo corre si el despacho marca la casilla.
- **Los secrets que espera CI** —`APPLE_CERTIFICATE`,
  `APPLE_CERTIFICATE_PASSWORD`, `KEYCHAIN_PASSWORD`, `APPLE_API_ISSUER`,
  `APPLE_API_KEY`, `APPLE_API_KEY_P8`, más `APPLE_MAS_APP_CERTIFICATE`,
  `APPLE_MAS_INSTALLER_CERTIFICATE` y `APPLE_MAS_CERTIFICATE_PASSWORD`— están
  en `docs/ProjectSettings.md`, con qué es cada uno y cómo firmar local. Acá
  van los **nombres**; los valores, jamás.

## Estilo

- **Dos espacios de indentación**, en Swift y en Metal. Nunca reformatear a
  cuatro. (Regla de Talkify que se conserva; ver `CONTRIBUTING.md`.)
- **Nada de comentarios `// MARK:`.** Un archivo que necesita separadores
  necesita partirse.
- Los comentarios explican el **porqué**, no el qué. En español.
- Prueba las costuras puras: el reducer, la geometría, las reglas de texto,
  el `Decider`. Cuando un bug vive en código impuro, la solución suele ser
  mover la regla a un value type y testear eso, no simular el mundo.

## Git

- Commits en **español, en imperativo**, explicando el porqué (el diff ya
  dice el qué). Prefijos convencionales: `feat:`, `fix:`, `docs:`,
  `refactor:`, `chore:`, `test:`, `ci:`.
- Terminan con `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- **Sin `push`** salvo que Alfonso lo pida; hoy no hay `origin`.
- Si estás en la rama principal y el trabajo es grande, crea una rama antes.
- Las correcciones que también aplican a Talkify idealmente se contribuyen
  allá y vuelven por `git fetch upstream && git merge upstream/main`.

## Licencia y atribución

MIT, con el copyright de Tornike Gomareli intacto y el propio agregado. La
atribución **"Dilo es un fork con cariño de Talkify (Tornike Gomareli, MIT)"**
aparece en el README y en la ventana Acerca de. No se quita.

Dos activos heredados de Talkify **no son publicables**: el set de sonidos Pop
(CC-BY-NC, `LICENSE-SOUNDS.txt`) y la obra del orbe Siri en
`Assets.xcassets/Siri/` (sin licencia, imita a Apple, `LICENSE-ARTWORK.txt`).
Hay que reemplazarlos o sacarlos antes de cualquier release.
