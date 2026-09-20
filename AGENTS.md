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
- **Ningún gatillo por defecto escribe símbolos** en teclado latino. Nada de
  ⌥ derecha sola: en ISO-LatAm es AltGr y escribe `@ # \ | { } [ ]`. Default
  `fn`/🌐 sostenido; alternativa ⌃⌥Espacio.
- **Nunca se toca el volumen maestro.** El "Duck other audio" de Talkify está
  apagado y escondido. Si algún día se silencia la música al dictar, se
  **pausa la reproducción**; el volumen es del usuario.
- **La píldora sin notch va debajo de la barra de menús**, con identidad Dilo.
  Nunca tapa los status items ni imita el HUD de volumen del sistema.
- **Los números del spec §3 se miden, no se prometen**: 60 MB en reposo, ~0 %
  de CPU, arranque en frío < 1 s, soltar→texto < 300 ms, `.app` < 20 MB sin
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
| `DiloText` | muletillas del español, diccionario personal | 5 (hoy: un esqueleto) |
| `DiloEngines` | `SpeechEngine` + Apple + Parakeet (FluidAudio) | 3 |
| `DiloModes` | `Mode`, `Provider`, `Decider` por reglas | 4 |
| `DiloCapabilities` | `HostCapabilities` completa y sandbox | 2 |
| `DiloMetrics` | reposo, arranque, latencia soltar→texto | 7 |

Cuando un módulo nuevo entre, se agrega al `Package.swift`, al
`packageProductDependencies` de **los dos** targets, y a esta tabla.

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
./scripts/metrics.sh        # llega en la Tarea 7
```

Los dos `xcodebuild` y `swift test` tienen que pasar antes de devolver el
trabajo. Para probar el sandbox en runtime: `open -a`, nunca el binario desde
el terminal.

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
