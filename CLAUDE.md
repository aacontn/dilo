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
Silicon, macOS 26+, viviendo en la barra de menús y en el notch. **Se presenta
como producto propio.** El árbol de la app nació de un fork (remote `upstream`)
del que vienen el HUD, la sesión de dictado y el tap de teclado; de dónde
exactamente, y dónde se cumple su licencia, está en `docs/historia/README.md`.
Ese archivo y el `LICENSE` son los únicos dos lugares del repo que nombran el
origen: no lo repitas en ningún otro.

El repo Tauri (`/Volumes/SSD 1/Dilo/app`) está **congelado en 0.3.2**. De ahí
se porta el **producto, no el código**: los specs de modos, español,
proveedores, historial y palabras propias se leen y se reescriben en Swift.
Nunca se copia Rust.

Idioma: **todo el copy visible es español de autoría propia** (tuteo, directo,
cero relleno corporativo); inglés como segunda locale, traducido desde el
español. Los comentarios y los mensajes de commit también van en español.

## Documentos que mandan

1. **`docs/superpowers/specs/2026-09-20-dilo-mac-nativo-design.md`** — la
   dirección. Qué se toma del árbol de origen, el motor doble, los números no
   negociables, la capa de capacidades, las tres lecciones de la primera
   prueba en español.
2. **`docs/superpowers/plans/2026-09-20-dilo-mac-v1.md`** — el plan de v1,
   tarea por tarea. Una tarea por agente, en orden de dependencias.
3. **`docs/superpowers/spikes/`** — los tres reportes que abrieron la
   compuerta: el sandbox del árbol de origen, diarización de Gemini, Laya en
   español.
4. **`CONTEXT.md`** — el modelo de dominio y su vocabulario. Los términos que
   lista son vinculantes en identificadores, comentarios y commits.
5. **`docs/adr/`** — las decisiones de arquitectura heredadas.
   Si tu cambio contradice una, dilo; no la pises en silencio.

La dirección de experiencia más reciente está en
`docs/design/2026-09-21-experiencia-dilo.md`: notch para interacción inmediata,
ventana para resultados y depuración del core antes de reuniones y asistente.
Distingue propuesta, implementación y deuda pendiente.

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
- **Cualquier tecla física que no escriba sirve de gatillo sola**: `fn`/🌐,
  F13–F20, esc, flechas, § de un teclado ISO, Clear e Intro del numérico. Lo
  único que se rechaza es ⌥ pelada, el volumen y el brillo, y una tecla que
  escribe usada sin ningún modificador —sostener la L para hablar llena el
  documento de eles—. La misma tecla con ⌃ o ⌘ encima vuelve a servir, y eso
  es lo que dice el mensaje de rechazo. La regla vive **sólo** en
  `ValidadorDeGatillos`, y las dos pantallas que asignan teclas (Atajos y
  Modos) la consultan; ninguna decide por su cuenta. Lo que cada grabador
  **deja llegar** al validador —un modificador solo, un botón del mouse— vive
  al lado, en `PoliticaDeGrabador`: Modos y Atajos nombran la misma política y
  un test puro compara las dos listas. Modos tenía su propia copia y por eso
  `fn` sola, el gatillo de fábrica, no se le podía dar a un modo.
- **Toda tecla tiene nombre.** `NombresDeTecla` (en `DiloModes`) nombra de F1
  a F20, el numérico y la navegación; si no la conoce escribe `Tecla 0x4F`,
  nunca vacío. AppKit manda las teclas de función como caracteres del área de
  uso privado (`U+F700`–`U+F8FF`) que no dibujan nada: una fila de ajustes en
  blanco es lo que hace creer que el atajo no se guardó.
- **Dos trozos de dictado se pegan en un solo lugar: `DiloText.Union`.**
  Ningún motor, ni el HUD, ni el controlador juntan texto con `+`. Cada trozo
  llega recortado y sin saber qué vino antes, así que el espacio lo pone quien
  los junta; con `+=` la última palabra de un trozo salía pegada a la primera
  del siguiente ("es rápidoAhora habría"). `Union` decide **sólo el espacio**:
  no inventa puntos ni cambia mayúsculas. La costura de las ventanas de
  Parakeet se corta antes, en `CosturaDeTrozos`, con los tiempos de cada
  token como evidencia — nunca partiendo una palabra por su forma.
- **Nunca se toca el volumen maestro.** El "Duck other audio" heredado está
  apagado y escondido. Si algún día se silencia la música al dictar, se
  **pausa la reproducción**; el volumen es del usuario.
- **El notch es el escenario permanente, y en una pantalla sin carcasa el
  default es el notch simulado** (cambió el 2026-09-21; antes era la píldora).
  La forma no aparece al dictar: está siempre, en reposo, y lo que cambia es
  su tamaño y su estado. Sigue sin tapar un status item, porque sólo ocupa la
  franja del centro de la barra, que macOS deja vacía. La píldora bajo la
  barra se queda como elección a mano en Ajustes → Apariencia, «En pantallas
  sin notch».
- **Los cinco estados del contrato son `EstadoDelNotch`**, y las transiciones
  viven en `MaquinaDelNotch` (pura) con sus tiempos en `ControlDelNotch`
  (reloj inyectable). Reposo no captura y reposo no anima: las dos reglas
  están afirmadas por estado, no por costumbre. Nadie escribe el estado a
  mano — se manda un evento a `HUDStage.recibir(_:)`.
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
  Dilo/                      la app, por feature (ver abajo)
  Dilo/Onboarding/           los Primeros pasos
  Dilo/Resources/NotasDeVersion/  las notas de cada versión, en español
  DiloTests/                 tests de la app
  DiloCore/                  el paquete propio: un módulo por tema
  docs/superpowers/          spec, plan y spikes de Dilo
  docs/historia/             de dónde viene el código, y la atribución
  docs/adr/, docs/design/    heredados, siguen vigentes
  brand/                     ícono, wordmarks e íconos de barra de Dilo
  scripts/                   release, llaves de Sparkle, métricas
```

**Las carpetas se renombraron a `Dilo/` y `DiloTests/` el 2026-09-21.** Antes
conservaban el nombre heredado para abaratar `git merge upstream/main`; el
árbol dejó de seguir a `upstream`, así que ese precio ya no compra nada. Lo que
**no** se renombra, y no se va a renombrar: los bundle ids
(`cl.espaciodigital.dilo`, `.mas`) y toda clave de `UserDefaults`. Renombrar
una borra la preferencia de quien ya tiene la app instalada, en silencio —
`AppSettingsTests` lo vigila. Dentro de `Dilo/`, `CoreHUD/`, `Dictation/` e
`Input/` se mantienen cerca del original y **todo lo de Dilo vive en
`DiloCore/`**.

### `DiloCore/` — el paquete propio

Un Swift Package local, con un módulo por tema, testeable con `swift test`
sin abrir Xcode. La app lo enlaza una sola vez (Tarea 0); después nadie toca
`project.pbxproj` salvo la Tarea 8.

| Módulo | Qué contiene | Tarea |
| --- | --- | --- |
| `DiloText` | unión de trozos, muletillas del español, diccionario personal, notas de versión | 5, 9 |
| `DiloEngines` | `SpeechEngine` + Apple + Parakeet (FluidAudio) | 3 |
| `DiloModes` | `Mode`, `Provider`, `Decider` por reglas | 4 |
| `DiloCapabilities` | `HostCapabilities` completa y sandbox, `Permiso` | 2, 9 |
| `DiloMetrics` | reposo, arranque, latencia soltar→texto | 7 (la app **no** lo enlaza: es taller) |

**Colores de marca:** tinta `#0D1117`, mango `#FF9E1B`, menta `#2EE6A8`, en
`DiloBrand` (`Dilo/Settings/Components/SettingsTheme.swift`), una sola vez
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

### `Dilo/` — el mapa de la app

Lo que sigue es el mapa del árbol de origen 0.8.3, resumido de sus propios
documentos (`docs/historia/README.md` dice cuáles y dónde están), y sigue
siendo cierto:

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

### Reglas del HUD que siguen mordiendo (heredadas)

- Ventana anfitriona de tamaño fijo: el origen se mueve, nunca se
  redimensiona.
- `NSWindow.Level.mainMenu + 3`, sin APIs privadas.
- **La muesca simulada se mide desde la pantalla, no se le copia a un
  MacBook** (cambió el 2026-09-21; enmienda ADR-0001). Su alto es el de la
  barra de menús de esa pantalla —`frame.maxY - visibleFrame.maxY`, con el
  piso de `menuBarClearanceFloor` para cuando se autooculta— y su ancho son
  los `anchoDeLaMuescaSimulada` puntos de una muesca. Los 185×32 prestados
  daban «un cuadrado terrible feo» en un 1080p sin carcasa: un bloque apoyado
  encima de la barra en vez de un recorte del borde.
- **Las dos curvas cóncavas de arriba también van en la muesca simulada**
  (`HUDNotchGeometry.filletSize`, `NotchFilletShape`). Son lo que funde la
  silueta con el borde de la pantalla; sin ellas queda un rectángulo. La
  píldora sigue sin llevarlas: flota separada y no toca ningún borde.
- **En una pantalla sin notch hay dos formas, y las elige la persona**
  (`HUDEstiloSinNotch`, guardado en `hudEstiloSinNotch`): *Notch simulado*
  —el default—, que se pega a `y = 0` centrado, con el tope recto entre sus
  dos curvas, y *Píldora bajo la barra*. El estilo viaja dentro de
  `HUDScreenSnapshot` y no como parámetro suelto: la ventana anfitriona, el
  contorno y el relleno de arriba tienen que estar de acuerdo. Con notch real
  el ajuste no se mira.
- **El notch simulado tapa la franja central de la barra de menús.** Es la
  zona que macOS deja vacía —menús a la izquierda, status items a la
  derecha—, y es el ancho de la muesca en reposo o el del HUD abierto. Si
  alguien tiene tantos menús que llegan al centro, esa parte queda tapada
  mientras dura el dictado: el arreglo es elegir la píldora, no ensanchar ni
  angostar la forma.
- **En reposo la muesca no dice nada**: la silueta y, a lo sumo, un punto
  mango de tres puntos abajo al centro (`HUDMarcaDeReposo`). Ni texto, ni
  onda, ni etiqueta; eso aparece cuando la forma crece. El único dato que
  puede llegar a decir es el nombre del modo activo, en 9 pt gris y **apagado
  de fábrica** (`hudModoEnReposo`); nunca los dos a la vez.
- **El reposo se esconde en pantalla completa; los estados activos no**
  (`HUDNotchGeometry.reposoSeEsconde`). Sin barra de menús no hay franja de la
  que la muesca cuelgue, y una forma negra flotando sobre el borde de un
  Keynote es lo contrario de «la barra que ya estaba ahí». Se mide por la
  barra y no por una API de pantalla completa: quien tiene la barra en
  «ocultar automáticamente» pidió lo mismo. Se esconde con `alphaValue`, no
  con `orderOut`: la ventana se queda montada y no hay que pelear otra vez por
  el orden al volver.
- **La forma crece hacia abajo desde la muesca, con la curva del estilo
  elegido.** El anclaje es `.top` y la cabecera de la forma abierta **es** la
  silueta en reposo, así que el rebote sólo empuja hacia el escritorio y nunca
  abre una rendija contra el borde. Cada `HUDRevealStyle` abre con la suya
  (`apertura`/`cierre`): un resorte único para los cuatro era el ajuste sin
  efecto. La base de los que no rebotan es la curva del overlay de Dilo-Tauri,
  `cubic-bezier(0,22 1 0,36 1)` en 460 ms (`aperturaDeTauri`). Con Reducir
  movimiento es un corte de 120 ms.
- **Lo que la forma abierta lleva adentro es el overlay de Tauri traducido**:
  la onda de brasas de nueve barras mango→rojo (`HUDOndaDeBrasas`, el estilo de
  fábrica), la cursiva de quince puntos del transcript y el cursor mango que
  parpadea mientras el micrófono está abierto (`HUDCursorDeDictado`). Los
  números salen de `src/overlay/RecordingOverlay.css` del repo congelado y
  están anotados ahí donde se usan. Lo que **no** se trajo —el vidrio, el botón
  de cancelar, el cronómetro, las cuatro anchuras— y por qué está en
  `docs/design/2026-09-21-experiencia-dilo.md`.
- **Y dictar apenas la agranda: 184×26 donde la barra mide 24**
  (`HUDNotchGeometry.tamañoDictando` — el alto de la barra más un décimo, un
  15 % más de ancho que el reposo). Todo lo que dice comparte **una línea**:
  la onda de brasas encogida a cinco barras y el parcial avanzando, recortado
  por la izquierda para que nunca se pierda el final (`HUDLineaSobria`). Sin
  chip de modo —ni fila propia ni prefijo: se come las palabras que se vienen
  a leer— y sin frase de estado: «Te escucho…» se fue el 2026-09-22, porque la
  onda ya dice que el micrófono está abierto. 400×88 y 540×146 son lo que ya
  se rechazó dos veces. **Contra una carcasa real no aplica**: ahí los
  primeros puntos del borde son el recorte físico y el contenido tiene que
  colgar por debajo, así que esa pantalla sigue apilando bandas
  (`HUDNotchGeometry.contentSize`). El panel del hover mide 400 y **sí** puede
  ser más alto que la muesca de dictado —ahí el mouse está encima a propósito,
  y es donde van a vivir las acciones que no son el dictado—, con techo en
  `altoMaximoDelHover`.
- **El final del dictado no abre nada.** El camino feliz acusa con un check
  donde estaba la onda —el `.scheck` del overlay de Tauri, punto por punto, en
  menta— y vuelve a reposo en 700 ms (`HUDCheckDeAcuse`,
  `MaquinaDelNotch.duracionDelAcuse`). El estado Resultado quedó **sólo para
  el camino del error**: que el pegado falló, que falta un permiso, un aviso,
  y eso sí se dice con palabras porque perder un dictado en silencio está
  prohibido. «Copiar el último dictado» vive en el menú de la barra y en el
  panel del hover, no en una franja de 400×50 que dura dos segundos y medio.
- **Tres cosas del escenario son ajustes, no constantes** (Apariencia): el
  retardo del hover (`hudRetardoDeHover`, medio segundo de fábrica), en qué
  pantalla vive la muesca (`hudPantalla`, vacío = automática) y si dice el
  modo en reposo. La pantalla se guarda **por nombre** y no por
  `CGDirectDisplayID`: el id se reparte de nuevo en cada arranque y la
  elección aterrizaría sola en otro monitor.
- **La forma se revisa en PNG, no en pantalla.** `scripts/render-muesca.sh`
  compila la geometría de verdad y rasteriza fuera de pantalla con
  `ImageRenderer`: sin ventanas, sin foco y sin captura de pantalla, que es
  lo que hace que un agente pueda cambiar la silueta y mostrarla. **Dibuja cada
  estado dentro de una ventana simulada del tamaño real** —el marco punteado
  del PNG— y con la misma cadena de layout de `HUDSurface`; rasterizar la
  silueta suelta con su `frame(width:height:)` daba PNG que no podían fallar
  nunca, y por eso nadie vio el bloque negro. También deja `apertura-1..3.png`:
  tres cortes de la revelación repartidos por avance —no por tiempo, que la
  curva está tan cargada al principio que salían tres veces el mismo PNG—, que
  son lo único que deja juzgar la animación sin mirar la pantalla.
- **La forma no se va de la pantalla: se encoge.** `HUDSurface.tamañoEnReposo`
  es lo que la vuelve un escenario permanente en vez de una notificación. La
  cabecera de la forma abierta **es** la silueta en reposo
  (`HUDNotchGeometry.alturaDeCabecera`), así que crece desde donde descansaba.
- **La ventana grande no es la forma.** La forma mide lo que mide su estado
  —160×24 en reposo, 184×26 dictando—, anclada arriba y al centro, con el resto
  de la ventana transparente. Nada adentro de `HUDSurface` pide
  `maxHeight: .infinity`: el `frame(minHeight:)` le ofrece al contenido el alto
  entero de la ventana y un hijo goloso se lo queda con el fondo negro detrás.
  Así se veía la muesca en un monitor externo, como un bloque de 160×190
  colgando de la barra, mientras la geometría decía 24 y los PNG salían bien.
  Cada cambio de estado deja una línea con los dos tamaños en
  `log show --predicate 'subsystem == "cl.espaciodigital.dilo"'`, categoría
  `muesca`, más una línea al arrancar (`RegistroDeLaMuesca`). En Release hay que
  encenderlo, y con un ajuste y no sólo con la variable de entorno: una app
  abierta desde el Finder no hereda el entorno de ningún terminal —
  `defaults write cl.espaciodigital.dilo DILO_LOG_MUESCA -bool YES`.
- **Y la ventana tampoco es siempre la misma.** `HUDNotchGeometry.EncuadreDeLaVentana`
  tiene dos tamaños por pantalla: en reposo la anfitriona **es** la silueta
  —178×24 en un 1080p sin carcasa: la muesca más lo que las alas cóncavas
  cuelgan a los lados, y ni un punto de alto de más— y sólo crece al estado más
  alto —el panel del hover, 488×90— mientras la forma está abierta. En reposo no hay sombra que
  alojar: la muesca quieta es hardware y no tiñe lo que tiene debajo
  (`HUDSurface.proyectaSombra`). Crece
  **antes** de que la animación arranque y se encoge **después** de que
  termine, con la holgura que el rebote del resorte necesita
  (`HUDRevealStyle.sobrepaso`). Una ventana grande en reposo es pantalla
  muerta: macOS le entrega todos los clics de su rectángulo aunque no dibuje
  nada (ADR-0001, enmienda del 2026-09-22).
- **La ventana no ignora el mouse mientras la forma recibe algo, y ésa es la
  clave del hover.** `HUDPanel` pone `ignoresMouseEvents = true` sólo cuando
  no hay `zonaInteractiva` —dictando, por ejemplo—; con zona, quién se queda con un
  clic lo decide `HUDHostingView.hitTest`, que devuelve nil fuera de
  `HUDNotchGeometry.zonaInteractiva` —y un punto que ninguna vista reclama
  sobre un panel transparente deja el clic en la app de abajo—. Es el patrón
  de NotchDrop y boring.notch. **No se copió código de ninguna**, así que el
  `LICENSE` no cambia; el día que se adapte algo de NotchDrop (MIT), la
  atribución entra antes que el código.
- **Quién sabe que el puntero está encima es un `NSTrackingArea`.** En la
  vista de hospedaje, `.activeAlways` + `.mouseEnteredAndExited` +
  `.mouseMoved` + `.inVisibleRect`, alimentando `HUDStage.punteroSeMovio` y
  `punteroSalio`; el escenario aplica el retardo. Fallaron dos intentos antes:
  con `ignoresMouseEvents = true` la ventana no recibe `mouseEntered`, y un
  monitor global de `.mouseMoved` **no ve los eventos que caen sobre nuestra
  propia ventana**, así que el aviso llegaba por un sondeo de 80 ms —tarde— o
  no llegaba. El `onHover` de SwiftUI tampoco sirve: manda una salida falsa
  cuando la ventana cambia de tamaño, que es justo lo que el hover hace al
  abrirse. Y el panel siempre tiene algo que decir
  (`DictationHUDContent.contextoVisible`): exigir `contexto`, que sólo existe
  después del primer dictado, dejaba el hover mudo en una app recién
  instalada. Un hover revela contexto y **nunca** arranca una captura.
- **El alto de la forma no lo impone el contenido.** `HUDSurface` la mide con
  `MarcoDeLaForma`, un `Layout` que anima ancho, alto y apertura juntos; el
  contenido abierto entra a su alto final en el acto, y con `fixedSize` +
  `frame(minHeight:)` el negro saltaba a ese alto antes de ensancharse
  (2026-09-23, «al agrandar se ve trancado»). El hover se abre con la curva de
  apertura del estilo, no con la de cierre.
- **Los costados de la muesca llevan datos elegidos en Ajustes** (consumo de
  Claude y Codex, CPU, RAM; `docs/design/datos-en-la-muesca.md`). Se eligen
  en su propia sección, **Datos en la muesca**, con una tarjeta por fuente:
  estado detectado en vivo, interruptor, costado, qué se lee y de dónde.
  Apariencia se queda sólo con lo visual. Lo que la sección calcula —qué va
  en cada costado y qué no cabe (`DisposicionDeLaMuesca`), si hay de dónde
  leer (`DeteccionDeFuentes`, con el disco inyectado), el detalle del hover
  (`DetalleDelDato`)— vive en `DiloCore/Sources/DiloConsumo` con los lectores
  y se prueba con `swift test`. **Lo que no cabe se dice en la tarjeta, no se
  recorta en silencio.** Si un proveedor pide la sesión del usuario, es
  opcional, apagado de fábrica, se lee en cada consulta sin guardarse ni
  registrarse, y nunca se renueva un token ajeno.
- **Ajustes también se revisa en PNG.** `scripts/render-datos-de-la-muesca.sh`
  compila con `build-for-testing` y enlaza un render contra el
  `Dilo.debug.dylib` con `@testable import Dilo`, sin lanzar la app. Dibuja con
  `NSHostingView` y no con `ImageRenderer`, que cambia los interruptores y
  selectores de AppKit por un cartel amarillo.
- **El panel del hover tiene secciones** (`HUDPanelDelHover`): recientes
  —dictados y portapapeles, sólo en memoria, sin lo que un gestor de
  contraseñas marca como secreto—, el detalle de los datos, la próxima
  reunión del calendario (apagada de fábrica; pide permiso al encenderla) y
  los modos para el atajo general. Alto fijo por sección; la ventana abierta
  se dimensiona por lo encendido, no por todo lo posible.
- El rebote de la revelación vive sólo en la escala anclada arriba, nunca en
  la posición: un exceso de posición abre una rendija contra el borde.
- **Los sonidos de empezar y terminar son de la transición, no del micrófono.**
  Los toca el escenario en `HUDStage.sonarPor`: reposo→dictando es Begin,
  dictando→lo que sea es End, uno de cada por sesión. Colgados del primer búfer
  de audio —que es de donde colgaban— una sesión podía empezar muda. El
  reproductor entra por el inicializador (`ReproductorDeSonidos`) para que un
  test lo afirme sin tocar el audio de nadie.
- **El silencio y un micrófono muerto tienen que verse distinto.**

## Idioma, copy y el catálogo

El **español es el idioma en que se escribe** (`developmentRegion = es`); el
inglés se traduce desde ahí y vive en `Dilo/Localizable.xcstrings`. Nunca al
revés: una frase pensada en inglés y traducida suena a manual, y eso es
exactamente lo que Dilo no es.

Voz: tuteo, directo, cero relleno corporativo. "Aprieta, habla, suelta." Los
términos técnicos van sin traducir (commit, prompt, sandbox). La referencia es
el locale `es` del repo Tauri (`app/src/i18n/locales/es/translation.json`),
escrito a mano.

**Ajustes traduce en runtime.** Los componentes (`SettingsRow`,
`SettingsCard`, `SettingsPickerRow`, `SettingsPreviewStage`, `ShortcutRow`…)
reciben `LocalizedStringKey` y no `String`, porque `Text(String)` **no** pasa
por el catálogo y `Text("literal")` sí. Tres reglas al escribir un call site:

- **Copy** → literal directo: `title: "Guardar lo que dictas"`. Nunca partido
  en pedazos con `+`: una clave del catálogo es una frase entera.
- **Valor** (una ruta, el nombre de un modo, lo que dictaste) → `"\(valor)"`.
  Sale tal cual y no ensucia el catálogo con claves que nadie traduce.
- **Frase armada por pedazos** (la de un atajo, la de un modelo de traducción)
  → `String(localized:)` en cada pedazo, y se pegan después. Ojo con meter una
  interpolación en un `String(localized:)` que además lleve un `%@` literal:
  el idioma se cuela en el hueco equivocado. Ahí van huecos posicionales
  (`%1$@`, `%2$@`), como en `ShortcutsSettingsView`.

Lo mismo vale fuera de Ajustes: un `var title: String` de enum que se muestra
en un picker devuelve `String(localized:)`.

`STRING_CATALOG_GENERATE_SYMBOLS` está en `NO` a propósito: el generador de
símbolos colapsa "Borrar" y "Borrar…" en el mismo identificador y falla la
compilación. Nada usa esos símbolos.

**Un test no compara copy contra el literal en español.** `title` y compañía
pasan por el catálogo, así que hablan el idioma del Mac: en el runner de CI,
que corre en inglés, `SettingsSection.updates.title` vale "Updates". Compara
contra `String(localized: "Actualizaciones")` —la misma clave, resuelta igual—
y, si quieres afirmar que el original en español sigue ahí, pregúntale a
`es.lproj` directo, con un centinela: `localizedString` devuelve la clave
cuando no encuentra la entrada, y entonces una traducción borrada pasaría
como buena (`UpdatesTests.copiaEnEspanol`).

**Enums persistidos:** un `rawValue` guardado en `UserDefaults` no se traduce
nunca — renombrarlo borra la elección de la persona en silencio. El nombre
visible va en un `var title: String` aparte, y el picker muestra `title`, no
`rawValue`.

## Cómo se compila y se prueba

DerivedData vive en `/Volumes/SSD2/derived-data` (disco de taller, se puede
borrar entero). Nunca en el disco interno.

```bash
# Los dos targets, limpio
xcodebuild -project Dilo.xcodeproj -scheme Dilo -configuration Debug \
  -derivedDataPath /Volumes/SSD2/derived-data build
xcodebuild -project Dilo.xcodeproj -scheme Dilo-MAS -configuration Debug \
  -derivedDataPath /Volumes/SSD2/derived-data build

# El paquete propio, sin abrir Xcode
cd DiloCore && swift test

# Los tests de la app (el bundle id aparte evita el cuelgue por TCC, ver abajo)
xcodebuild -project Dilo.xcodeproj -scheme Dilo \
  -derivedDataPath /Volumes/SSD2/derived-data \
  PRODUCT_BUNDLE_IDENTIFIER=cl.espaciodigital.dilo.deuda test

# Los números del spec §3 contra el .app ya compilado. La latencia y el reposo
# se miden contra el Debug; el tamaño, contra el Release, que es lo que se
# descarga.
./scripts/metrics.sh /ruta/Debug/Dilo.app --tamano-de /ruta/Release/Dilo.app
./scripts/metrics.sh /ruta/Release/Dilo.app --sin-latencia   # sin el gancho Debug
```

`scripts/metrics.sh` deja el reporte en `docs/metricas/ultima-medicion.json`
—que **se versiona**, porque `swift test` lo lee y falla si un número se
rompe— y termina con código ≠ 0 si un umbral no se cumple o si una métrica no
se pudo medir. Tarda unos tres minutos: la ventana de reposo sola son 60 s.

**El tamaño se mide contra el `.app` Release.** Un Debug de Xcode 26 saca todo
el código de la app a un `Dilo.debug.dylib` aparte —doce megas que nadie
descarga— y medir ahí daba 34 MB contra un umbral de 25: era medir otra app.
Si le pasas un Debug, `dilo-metrics` no lo mide y te dice que compiles Release
y se lo des con `--tamano-de`; sin medir sigue siendo un fallo.

**Qué se mide dónde.** En un Mac se miden los cinco números y lo que no se
pudo medir es un fallo, sin excepciones. En CI, `--ci` (o `GITHUB_ACTIONS`)
cambia sólo una cosa: lo que ese entorno no puede medir se anota con su razón,
sale en la tabla como "no medible acá" y no tumba la corrida. Hoy es una sola
métrica: **soltar → texto**, porque disparar el dictado pide Accesibilidad y
una sesión gráfica, y un runner no las tiene ni las va a tener; se mide a mano
antes de cortar un release. Los otros cuatro —RAM, CPU, arranque y tamaño— se
miden en CI igual que acá, contra el `.app` Release, y rompen la corrida si se
pasan. Un número medido que no cumple falla siempre: `--ci` excusa lo que no
se pudo medir, nunca lo que salió mal.

Para medir "soltar → texto" el `.app` tiene que ser un build **Debug** y el
terminal necesita Accesibilidad: la medición inyecta un WAV y dispara la sesión
apretando el menú de la barra. El gancho es la variable de entorno
**`DILO_METRICS_WAV`**, que `MicrophoneInput` respeta sólo bajo `#if DEBUG`
(`Dilo/Dictation/MicrophoneInput+MetricasWAV.swift`): con ella apuntando a un
WAV, la sesión escucha ese archivo en vez del micrófono, al ritmo real, y anota
en `<wav>.soltado` el instante en que el controlador manda a parar. En release
no existe: el archivo entero está dentro de un `#if DEBUG`.

Los dos `xcodebuild`, `swift test` y la suite de la app tienen que pasar antes
de devolver el trabajo. Para probar el sandbox en runtime: `open -a`, nunca el binario desde
el terminal.

**`xcodebuild test` se colgaba en este Mac** antes de "Testing started": el
host de los tests es la app real, y al arrancar levanta su tap de CGEvent, que
dispara TCC contra la entrada de la copia instalada y espera a un humano. Con
un bundle id propio la entrada de TCC es otra y la suite corre sola:

```bash
xcodebuild -project Dilo.xcodeproj -scheme Dilo \
  -derivedDataPath /Volumes/SSD2/derived-data \
  PRODUCT_BUNDLE_IDENTIFIER=cl.espaciodigital.dilo.deuda test
```

El id puede ser cualquiera bajo `cl.espaciodigital.dilo`: `DiloTests` compara
el host por prefijo para que el truco no rompa la suite.

**Los tests quieren un `-derivedDataPath` propio.** Si lanzas a mano con
`open -a` el `.app` que está en el mismo DerivedData, LaunchServices se queda
con esa copia y la siguiente corrida muere en *"the test runner hung before
establishing connection"*. Un directorio para probar a mano y otro para la
suite. Detalle en `docs/ProjectSettings.md`.

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

- **El onboarding vive en `Dilo/Onboarding/`** y se abre solo la primera
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
  `Dilo/Resources/NotasDeVersion/`**, y son un solo archivo para dos usos:
  la app las muestra en Ajustes → Novedades (leídas del bundle, parseadas por
  `NotasDeVersion` de `DiloText`) y `scripts/release.sh` publica ese mismo
  archivo en el release. El árbol de origen traía su changelog de GitHub; Dilo
  no depende de internet para contar qué cambió, ni deja que el release y la
  app digan cosas distintas. **Las notas no llevan atribución**: eso vive en el
  `LICENSE` y en Acerca de, y un test lo vigila.

## Firma, actualizaciones y cómo se publica

- **Hoy no hay identidad de firma en el Mac de Alfonso** (`security
  find-identity -v -p codesigning` devuelve cero) ni perfil de `notarytool`.
  Todo lo de firma está escrito y verificado con firma ad-hoc, y listo para
  cuando exista.
- **Sparkle: llave y feed propios.** La mitad privada EdDSA vive en el Llavero
  de Alfonso, en la cuenta `dilo`; la pública está en `Dilo/Info.plist` y se
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
  cuatro. (Regla heredada que se conserva; ver `CONTRIBUTING.md`.)
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
- Las correcciones que también le sirvan al árbol de origen idealmente se
  contribuyen allá y vuelven por `git fetch upstream && git merge upstream/main`.
  El remote `upstream` se queda: un remote no es un archivo del proyecto.

## Licencia y atribución

MIT, con los copyright de quienes escribieron el código heredado intactos y el
propio arriba de ellos. La atribución se cumple en **tres lugares y sólo tres**,
y cada uno dice lo suyo una vez:

- **`LICENSE`** — las líneas de copyright. Es lo que la licencia MIT exige.
- **Ajustes → Acerca de → Licencias de terceros** — dentro de la app.
  `UpdatesTests` falla si la sección desaparece.
- **El final del `README.md`** («Agradecimientos») y `docs/historia/README.md`,
  que es donde vive la genealogía completa.

**Dilo no se presenta como fork** en la portada del README, en la app ni en las
notas de versión: es un producto propio que reconoce de dónde viene. Si vas a
escribir el nombre del origen en un archivo nuevo, no lo hagas: ya está escrito
donde corresponde, y una cuarta copia es una que se va a desincronizar.

Dos activos heredados no eran publicables y **ya se sacaron**
(2026-09-21): el set de sonidos Pop (CC-BY-NC) y la obra del orbe Siri de
`Assets.xcassets/Siri/` (sin licencia, imitaba a Apple). Todo lo que queda en
el bundle es CC0, MIT o propio. Si vuelve un activo ajeno, su licencia va en
`LICENSE-SOUNDS.txt` o en un `LICENSE-ARTWORK.txt` antes que el archivo.
