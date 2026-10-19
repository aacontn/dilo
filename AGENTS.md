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

- **Un solo target: `Dilo`** (Developer ID, Sparkle,
  `cl.espaciodigital.dilo`). **Dilo es para uso propio y no va a la App
  Store** (Alfonso, 2026-10-15: «el Dilo MAS olvidémoslo, ya no vale la pena
  meterle cabeza para regalarlo, lo hacemos para nosotros»). El target
  `Dilo-MAS`, su esquema, sus entitlements, la condición `DILO_MAS` y los
  jobs de App Store en CI se sacaron ese día; no los vuelvas a armar.
- **`HostCapabilities` se queda** aunque ya no haya target con sandbox:
  todo lo que dependa de la API de Accesibilidad hacia otras apps pasa por
  ahí, y lo que el anfitrión no puede hacer **se esconde**, no falla. Se
  prueba lanzando con `open -a`, **nunca desde el terminal**: TCC
  atribuye el permiso al proceso padre y el tap de audio devuelve silencio.
  Qué anfitrión resolvió una copia lo dice ella misma al arrancar:
  `log show --predicate 'subsystem == "cl.espaciodigital.dilo"' --last 5m`,
  categoría `capacidades`. Antes de buscar por qué "no aparece" algo, mira
  esa línea: lista lo que está escondido.
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
- **Toda tecla que Dilo aprieta por la persona pasa por `AtajoSimulado`.**
  ⌘ baja y sube como evento propio, con el bit de su lado, desde la fuente
  del teclado físico, y el último evento deja exactamente los modificadores
  que la persona sostiene. Mandar sólo la V con el flag de ⌘ dejaba ⌘
  colgada y el siguiente espacio abría Spotlight; un ⌘ sin bit de lado se lee
  como ⌘ derecha, el gatillo de fábrica de traducir. Los eventos llevan una
  marca para que el tap de Dilo no los tome por un gatillo. El tecleo del
  reintento también: ⇧ baja y sube como tecla propia en cada salto de línea.
- **Un atajo, dos gestos, y el Esc entero** (2026-10-14). Mantener es
  hablar y un toque corto traba; el umbral vive con nombre, origen y rango
  en `GestoDelGatillo` y se fija en reposo (`fijarGesto`): cambiarlo a media
  sesión aplica a la siguiente. El Esc que cancela se traga entero en el tap
  —keyDown, autorrepetición y keyUp, aunque la captura se apague entre
  medio—. Con voz, el Esc no tira lo dicho: `DictationSessionMachine`
  retiene (`retenerParaDeshacer`) y la muesca ofrece «Deshacer» 5 s; lo
  retenido vive en RAM (`CancelacionRetenida`), nunca en el historial, y
  apretar el gatillo otra vez lo suelta.
- **El pegado sabe si entró, y lo que no entró no se pierde.** El dictado se
  promete en el portapapeles (`TextoPrometido`, marca propia por pegado,
  `.currentHostOnly`) y la lectura de la app de destino es el acuse; con
  Accesibilidad además se mira el campo y, si el ⌘V no lo movió, se teclea
  **una** vez —nunca en una terminal—. Lo que no se confirma vuelve como
  `ResultadoDeEntrega.retenido` y termina en la tarjeta del notch. Los
  tiempos y las decisiones viven puros en `DiloCapabilities`
  (`PoliticaDeEntrega`, `VigiaDelPegado`, `DecisionTrasLaSenal`): un
  número nuevo se cambia ahí y se prueba con `swift test`. **fn no detiene
  un ⌘V** (`LecturasDelTeclado`, 2026-10-14): no cambia lo que pega, y su bit
  queda marcado en el estado del HID después de soltar F13–F20 o una flecha
  —con el gatillo F19 cada dictado esperaba 2 s y caía en la tarjeta—. Para
  teclear sí estorba, mirada por su tecla y no por el bit. Cuando la
  compuerta se rinde, el log de `delivery` dice a nivel notice qué vio.
- **Dos trozos de dictado se pegan en un solo lugar: `DiloText.Union`.**
  Ningún motor, ni el HUD, ni el controlador juntan texto con `+`. Cada trozo
  llega recortado y sin saber qué vino antes, así que el espacio lo pone quien
  los junta; con `+=` la última palabra de un trozo salía pegada a la primera
  del siguiente ("es rápidoAhora habría"). `Union` decide **sólo el espacio**:
  no inventa puntos ni cambia mayúsculas. La costura de las ventanas de
  Parakeet se corta antes, en `CosturaDeTrozos`, con los tiempos de cada
  token como evidencia — nunca partiendo una palabra por su forma.
- **Lo dicho vive en RAM hasta que hay texto, y nunca en disco.** El
  micrófono deja una copia a 16 kHz en `GrabadoraEnRAM` y la sesión habla con
  `MotorConRespaldo`, que envuelve al router sin cambiarle el contrato: lo
  que sale de un motor pasa por `RevisionDeToma` (tokens, firma de Amara,
  fantasmas sobre silencio, bucles), y si no queda texto con voz en la toma,
  el otro motor transcribe el mismo audio. Si tampoco sale, queda **una**
  toma en RAM diez minutos, se dice en la muesca y se reintenta desde el panel
  de la barra. Los umbrales son de Ocelli e imnot, sin medir todavía en
  español: son constantes con nombre, y se calibran ahí.
- **El contexto de la app es material de consulta, vive en RAM y no sale del
  Mac sin permiso.** Al empezar un dictado `CapturaDeContexto` lee, en
  paralelo con el micrófono y sin que nadie lo espere al soltar, la app y su
  categoría (`CategoriaDeApp`) y —sólo si la persona lo prende en Modos— el
  texto alrededor del cursor, la selección y el sitio del navegador. Va al
  modelo dentro del sobre como `contexto_no_confiable`, recortado para que el
  dictado quepa en los 4.096 tokens del chip
  (`PromptDeLimpieza.topeDeContexto`), y una salida que copia una frase de
  ahí se rechaza (`copioElContexto`). Nunca va al historial ni a un log; a un
  proveedor en línea viaja sólo con su propio interruptor, apagado de
  fábrica. Lo que lee otra app (`contextoDelCampo`, `sitioDelNavegador`,
  `vigiaDeCorrecciones`) se esconde en sandbox. El OCR de la pantalla no existe
  todavía.
- **Dilo nunca aprende solo; ordenar aplica solo sólo lo seguro, y con
  deshacer.** Tras pegar, `VigiaDeCorrecciones` mira el
  campo hasta 30 s (cada 500 ms, calma de 1,5 s, nunca con entrada segura) y
  `AprendizajeDeCorrecciones` saca pares «oído → correcto» que sean
  vocabulario y que el motor haya oído así. Con clave de Anthropic, Claude
  Haiku 5.5 los revisa antes de la oferta (ver «Aprender con Claude»). La
  muesca los ofrece en un
  segmento al costado y con deshacer; aceptar es lo mismo que agregarlos a
  mano en Tus palabras y en «Cuando digo…» (`Reemplazo.aprendido`), y lo que
  nadie acepta vence y no se vuelve a ofrecer. El ancla del campo se toma
  antes del `sessionEnded`, que deja `focusedTarget` en nil. El orden del
  diccionario con Claude no agrega palabras nuevas: junta, corrige grafías y
  saca; aplica solo lo que no pierde nada escrito a mano, propone lo demás,
  y todo queda en un registro con deshacer.
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
| `DiloText` | unión de trozos, muletillas del español, diccionario personal, notas de versión, filtro de artefactos, frases fantasma, bucles, validador de la limpieza, números hablados, comandos de formato, reemplazos; el aprendizaje de correcciones y, con Claude, la revisión y el orden del diccionario (prompts, lectura, qué es seguro, deshacer, cuándo ordenar) | 5, 9 |
| `DiloEngines` | `SpeechEngine` + Apple + Parakeet (FluidAudio), toma en RAM, recorte de bordes, revisión de la toma, micrófono muerto, plan de micrófono y lectura de la HAL, vigencia del motor tibio, guardia de reconstrucciones del motor de audio | 3 |
| `DiloModes` | `Mode`, `Provider`, `Decider` por reglas; los modelos de Anthropic, la traducción con Claude (prompt, request, fallas, quién traduce) y la consulta con forma que usa el aprendizaje (`ConsultaAClaude`) | 4 |
| `DiloCapabilities` | `HostCapabilities` completa y sandbox, `Permiso`, las reglas puras del pegado (ancla del foco, compuertas, entrega, veredicto del campo, tecleo) | 2, 9 |
| `DiloMetrics` | reposo, arranque, latencia soltar→texto | 7 (la app **no** lo enlaza: es taller) |
| `DiloAgentes` | servidor MCP (JSON-RPC por stdio), CLI `dilo`, la tabla de herramientas que comparten, `ModoDeArranque` | fase 5 |
| `DiloPlataforma` | el URL scheme (`EnlaceDeDilo`), los agentes que avisan por su *hook* (`EventoDeAgente`, `RegistroDeAgentes`), las líneas para pegar en cada agente (`LineasDeLosHooks`) y el aviso de «Mostrar en la muesca» (`AvisoDeAfuera`) | fase 5 |

**El acento de la app es Glaciar** (decisión de Alfonso del 2026-10-14: «el
color naranja ya no me gusta»): azul `#0A84FF` a celeste `#64D2FF` sobre
negro, con el acuse en menta pálida `#7DF9C4`. **Grafito** —blanco y gris,
color sólo para lo que salió bien o mal— se elige en Ajustes → Apariencia →
Color, y se guarda en `diloPaleta`. El mango y la menta salieron como
opciones de la interfaz.

**Los colores de la interfaz salen de `PaletaDeDilo`**, no de `DiloBrand`:
la muesca, Ajustes, los Primeros pasos y el ícono de la barra piden
`PaletaDeDilo.actual` y el token de lo que dibujan —`cursor`, `acuse`,
`puntoDeReposo`, `acentoDeAjustes`, `acentoDeLaBarra`…—, y qué color es cada
uno vive en una sola tabla. Una vista nueva no escribe un color de `DiloBrand` ni
un `Color(red:…)`: pide el token, o lo agrega a la paleta. El `AccentColor`
del catálogo es el azul de Glaciar. Fuera de la paleta, a propósito: las del
Edge Glow, que elige la persona.

**Colores de marca** (`DiloBrand`, `Dilo/Settings/Components/SettingsTheme.swift`):
tinta `#0D1117`, celeste `#64D2FF` (el caret) y azul `#0A84FF` (la onda).
Son los del ícono y de `brand/`, regenerados para Glaciar el 2026-10-14;
ninguna vista los usa. Los activos están en `brand/`; el `.icns` se regenera con
`rsvg-convert` + `iconutil` desde `brand/dilo-icon.svg` y queda en
`brand/generado/`.

Cuando un módulo nuevo entre, se agrega al `Package.swift`, al
`packageProductDependencies` de **los dos** targets, y a esta tabla.
`DiloMetrics` es la excepción: mide la app desde afuera, así que vive en el
paquete pero no se enlaza a ningún target, y por eso no toca `project.pbxproj`.
Se construye y se corre desde `scripts/metrics.sh`.

**Excepción vigente:** `DiloModes` —y con él `DiloConsumo`, `DiloAgentes` y
`DiloPlataforma`— viaja dentro del producto `DiloText` en vez de tener el
suyo. Un producto nuevo obliga a tocar `project.pbxproj`, y ese
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
  observa los atajos; `StatusItemController` es el ícono de la barra y su
  panel (ver «El ícono de la barra de menús»);
  `AppSettings.swift` es la única fuente persistida de preferencias. **Las
  claves y los `rawValue` cargan peso** (picks guardados, prefijos de nombres
  de sonidos): no los renombres.
- `Input/` — el tap global de CGEvent (`GlobalKeyEventMonitor`) y el modelo
  `KeyBinding`, compartido por dictado, Ajustes y el panel de la barra.
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
- `Agentes/` — el mismo binario sin ventanas: `ArranqueParaAgentes` decide en
  `AppDelegate.main()` si es servidor MCP o CLI, y `FuenteDelHistorial` les
  da el historial y Tus palabras (ver «Agentes: servidor MCP y CLI»); y los
  agentes de código en la muesca por el URL scheme (ver «Lo que entra de
  afuera»).
- `Atajos/` — los App Intents (Atajos, Spotlight, Siri) y el puente a la app
  viva.

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
  (`HUDNotchGeometry.filletSize`). Son lo que funde la silueta con el borde de
  la pantalla; sin ellas queda un rectángulo. La píldora sigue sin llevarlas:
  flota separada y no toca ningún borde.
- **La muesca tiene asientos: la forma y hasta dos segmentos al costado**
  (`AsientosDeLaMuesca`, reductor puro con sus reglas y motivos de cesión;
  2026-10-13). `MaquinaDelNotch` no cambia: la sesión del contrato entra a
  los asientos mientras no hay reposo y exige la forma, así que **dictando la
  principal es siempre el dictado**. Las ocupantes de hoy son dos cosas que
  ya existían: la toma guardada para reintentar (derecha, en el acento; un clic
  la reintenta, como el panel de la barra) y una tarjeta de un dictado sin
  pegar que otra sesión tapó (`TarjetaDeRespaldo.tapada`, izquierda; un clic
  la copia; no vence mientras dura una sesión y se va un minuto después de
  volver a reposo). Sólo el notch simulado tiene lugar
  (`HUDNotchGeometry.lugaresAlCostado`): al lado de una carcasa real hay
  menús y status items. Desde el 2026-10-15 también se sientan los agentes de código y
el aviso de un atajo, como segmentos «de afuera» (`HUDStage.publicarDeAfuera`,
ver «Lo que entra de afuera»). Las reuniones todavía no son actividades.
- **Un segmento al costado es la misma silueta, estirada** (variante elegida
  por Alfonso el 2026-10-13; la píldora negra separada y la de vidrio se
  descartaron). `SiluetaDeLaMuesca.costados` estira el negro hacia el lado
  del segmento con las alas en los extremos nuevos: una pieza, sin hueco, y
  sin estirar nada la muesca es la de siempre. `HUDSegmentosAlCostado` sólo
  pone el ícono y la palabra y recibe el clic, con la acción entera en la
  etiqueta de accesibilidad y en el tooltip. **Encogido mide 26 pt, el
  ícono**; entra diciendo su palabra («Reintentar», «No se pegó», medida en su
  letra, techo `anchoMaximoDeSegmento`) y a los 3 s se encoge, y con el
  puntero encima la vuelve a decir (`PalabraDeLosSegmentos`, puro y con
  turno). Se anima con el resorte de apertura del estilo; con Reducir
  movimiento es un corte. **El segmento no es silueta para
  `IntencionDelPuntero`**: posarse en él devuelve la palabra y nunca abre el
  panel del hover. La ventana en reposo reserva lo que un segmento puede
  estirarse con su palabra (`HUDScreenSnapshot.llevaSegmentos`), crece antes
  de que entre y se encoge después de que se va; la zona del mouse se estira
  lo que se estira el negro. Con el panel del hover abierto se esconden.
- **Un segmento ocupa el lugar del dato de su costado** (`ReglaDeLosCostados`):
  el dato (CPU, RAM, Claude, Codex) se esconde mientras el segmento está y
  vuelve cuando se va, y la silueta se estira sólo lo que el segmento pide de
  más sobre los `anchoDeUnLado` del dato. Lo escondido y lo que vuelve se
  anota en el log de la muesca (`dato=cpu lado=derecha escondido por
  segmento=toma`); en el panel del hover el detalle de los datos sigue
  entero.
- **La silueta es una sola pieza** (`SiluetaDeLaMuesca`, 2026-10-13): cuerpo,
  alas y esquinas en un `Shape`, la misma para notch real, simulado
  (`.muesca`) y píldora (`.isla`), con los dos radios animables. Las alas se
  dibujan **fuera** del marco del cuerpo, como antes, así que el layout y la
  ventana en reposo no cambian; son las piezas exactas de antes
  (`NotchFilletShape`) sumadas a la trayectoria, no unidas: la unión
  booleana de `Path` corre el antialias del borde. El render de la muesca
  usa la misma silueta; cambiarla y no comparar los PNG con los de antes es
  cambiarla a ciegas.
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
  de tres puntos en el color de la paleta abajo al centro (`HUDMarcaDeReposo`). Ni texto, ni
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
  la onda de brasas de nueve barras (`HUDOndaDeBrasas`, el estilo de
  fábrica), la cursiva de quince puntos del transcript y el cursor que
  parpadea mientras el micrófono está abierto (`HUDCursorDeDictado`). Desde
  el 2026-10-14 van en Glaciar —la onda de azul a celeste, el cursor
  celeste, el check en menta pálida— y no en el mango→rojo de Tauri. Los
  números salen de `src/overlay/RecordingOverlay.css` del repo congelado y
  están anotados ahí donde se usan. Lo que **no** se trajo —el vidrio dentro
  de la muesca, el botón de cancelar, el cronómetro, las cuatro anchuras— y
  por qué está en `docs/design/2026-09-21-experiencia-dilo.md`.
- **El vidrio está permitido fuera del núcleo negro** (Alfonso, 2026-10-14;
  no lo trates como prohibido). La cabecera —la silueta en reposo— es negra
  siempre; lo que cuelga hacia el escritorio puede ser vidrio. El primero es
  el panel del hover al estilo Dynamic Glass (`PanelDeVidrio`,
  `FondoDeLaMuesca`). **El panel abierto es vidrio ahumado, oscuro y
  parejo** (Alfonso, 2026-10-15, al ver la apertura cuadro a cuadro: «el de
  vidrio ahumado se ve choro»): vidrio tintado de negro (`tinte` 0,45) con
  un velo negro encima (`negroEncima` 0,55), que en la pantalla queda en un
  carbón de #2C2C2C a #3B3B3B tanto sobre blanco como sobre un escritorio
  oscuro. Al abrir, un reflejo cruza el canto de abajo y se apaga; queda un
  filo blanco tenue en la curva. Cerrado —reposo, dictando— no hay vidrio
  montado. Lo que no vuelve: el vidrio claro de la 0.4.5 (letra blanca
  sobre gris claro) y el vidrio sólo en el último ~30 % de la 0.4.6 (una
  mancha bajo los modos). **Encendido de fábrica** (`hudPanelDeVidrio`,
  interruptor «Panel con vidrio» en Apariencia; apagado, negro puro sin
  vidrio ni filo). «Reducir transparencia» le gana y lo deja negro;
  «Reducir movimiento» quita el reflejo. No sale en PNG: la lámina lo imita
  con el carbón medido (`grisDeLaLamina`) y el de verdad se mira en la
  pantalla con las escenas `hover-vidrio` y `hover-completo-vidrio` del
  arnés.
- **El panel del hover tiene la jerarquía y la densidad de Droppy**
  (2026-10-15, `PiezasDelPanel.swift`): letra de 10,5 a 12,5. Lo último
  dictado en 12,5 semibold, con qué es y cuándo en gris debajo; los
  recientes anteriores en una línea gris; **los modos en un solo botón**
  —el elegido en una píldora gris de 20 con una flecha—, y «Traducir»
  (globo y «EN») y «Nota» como íconos sin fondo a la derecha. Apretar el
  botón despliega todos los modos como las pestañas de la bandeja de
  Droppy, con el resorte de apertura y la píldora viajando al elegido
  (`matchedGeometryEffect`); elegir uno lo deja puesto y la fila se pliega.
  El alto no cambia al desplegar. Alfonso, 2026-10-15: «en vez de que me
  muestre todos los modos de una, el botón de modo, que si lo aprietas
  aparecen dinámicamente los otros». Antes: todos los modos a la vista, y
  antes aún, en botones de 24 con el elegido en blanco lleno: «muy
  grandes». El color, sólo en un detalle chico —el ícono del último, el
  ✓ de copiado, la reunión que empieza—. Las piezas toman valores sueltos para que el render de la
  muesca dibuje las mismas vistas y no una copia.
- **La forma abierta es la de Droppy; el reposo y dictar no cambian**
  (`FormaAbierta`, 2026-10-14). El panel del hover —con vidrio o en negro—
  abre con hombros grandes (los 32 de Droppy, acotados a lo que la ventana
  abierta deja para las alas y su sombra: 29 en un 1080p) y 32 abajo —40
  hasta la 0.4.5; 32 es lo que mide el cuadro de Droppy contra el ancho de
  su panel—; el aviso, con el borde
  de abajo redondo entero (28 de Droppy, o la mitad del alto). Los dos radios
  se achican juntos si no caben uno sobre otro (`SiluetaDeLaMuesca`), y el
  hover y el paso al aviso usan los resortes de Droppy (`CurvaDeLaMuesca`).
  160×24 con alas de 9 en reposo y 184×26 dictando siguen iguales.
- **El color se ve en el canto, no en el cuerpo** (2026-10-14: «no le veo
  mucho cambio a los colores en el notch»). El negro sigue negro; la forma
  abierta lleva un filo de luz en el borde de abajo (`FiloDeLaMuesca`, token
  `filo`) que dice en qué está sin palabras: acento dictando, menta en el
  acuse, coral en un error, ámbar con el micrófono muerto; con el panel
  abierto, ninguno (el vidrio lleva su filo blanco y, sin vidrio, el panel
  es negro puro). Es estático —no anima, no cuesta CPU— y en reposo no existe.
  Además la onda reparte su degradado por la fila (`coloresDeLaBarra`), el
  check lleva disco y luz, el aviso un ícono de color con la frase en blanco
  y el modo elegido del panel va en el degradado de la onda. Con Grafito todo
  eso es blanco y gris, y sólo el acuse y el error llevan color.
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
  `altoMaximoDelHover`. **El aviso tampoco es dictar**: un resultado con
  palabras —error, tarjeta sin pegar, arreglo con un clic, «Copiado»— abre
  `tamañoDelAviso` (304×38 con la barra de 24, `EstadoDelNotch.abreElAviso`),
  una línea con ícono y, si lo hay, el botón; el acuse sigue en 184×26.
- **El final del dictado no abre nada.** El camino feliz acusa con un check
  donde estaba la onda —el `.scheck` del overlay de Tauri, punto por punto, en
  menta— y vuelve a reposo en 700 ms (`HUDCheckDeAcuse`,
  `MaquinaDelNotch.duracionDelAcuse`). El estado Resultado quedó **sólo para
  el camino del error**: que el pegado falló, que falta un permiso, un aviso,
  y eso sí se dice con palabras porque perder un dictado en silencio está
  prohibido. «Copiar el último dictado» vive en el panel de la barra y en el
  panel del hover, no en una franja de 400×50 que dura dos segundos y medio.
- **La tarjeta de un dictado que no se pegó es la única excepción a «el
  resultado no toma el mouse»** (`ResultadoDelNotch.retenido`,
  `TarjetaDeRespaldo`). Dice en una línea qué pasó, un clic copia el texto y
  arrastrarla lo lleva a donde iba; dura lo que el dictado se queda en el
  portapapeles (8 s) para que ⌘V también sirva. No bloquea el dictado
  siguiente: lo que empieza la tapa, y el texto sigue en «Copiar el último
  dictado».
- **La otra excepción es un aviso que se arregla con un clic**
  (`ResultadoDelNotch.accionable`, `AvisoConAccion`, 2026-10-14). Lo que
  impide dictar se mira **antes** de abrir el micrófono —permisos, entrada de
  audio, motor, campo, traducción— en `EstadoParaDictar` (puro, en
  `DiloCapabilities`), y la muesca dice el primer `BloqueoDelDictado` en una
  línea de unos treinta caracteres. Si el arreglo es una casilla de Ajustes
  del Sistema, el clic abre su panel exacto (`Permiso.panelDeAjustes`); en
  la línea no cabe también la ruta. Dar el permiso y volver a apretar basta:
  la preparación que paró en él vuelve a correr desde el gatillo.
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
- **Cuándo se abre lo decide `IntencionDelPuntero`, no un retardo fijo**
  (2026-10-13). Quién avisa sigue siendo el área de seguimiento; la
  intención recibe cada muestra con su instante y devuelve abrir, cerrar o
  cuándo volver a preguntarle, y `HUDStage` programa ese plazo con su reloj.
  Quieto (o lento) encima abre a los 160 ms; subiendo rápido hacia la barra
  no cuenta como frenarse; al salir cierra tras una gracia de 250 ms y no
  tras el retardo entero. El retardo de Ajustes sigue mandando: subirlo
  alarga la permanencia en proporción. Los umbrales son de partida, sin medir
  con Alfonso. La red de seguridad de 4 s se queda.
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
- **En un Debug abierto, cada estado se pide por su nombre**
  (`EscenaDeMuestra`, `scripts/muesca.sh mostrar todas --segundos 4`,
  `scripts/muesca.sh lista`). Dibuja en la ventana real y en la pantalla real,
  que es lo que ni el PNG ni el canvas muestran, y llega por una notificación
  distribuida con el bundle id de la copia (`DILO_ID=…prueba` para la de
  prueba). Mueve la forma con las mismas puertas que una sesión —`claim`,
  `recibir(_:)`— y nunca toca el dictado: no suena, los botones quedan
  apagados, un resultado no vence (`ControlDelNotch.congelado`) y un dictado
  de verdad le gana en su `claim`. En Release no existe. Una escena nueva de
  la muesca entra al enum y a su test (`ArnesDeLaMuescaTests`), no a una
  lista aparte.
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
  `DetectorDeMicMuerto` cuenta segundos de audio en cero exacto —una sala
  callada nunca es cero digital—: reabre el motor una vez al segundo si nunca
  sonó, avisa a los 5 s y escala a los 15 s. Los ceros no publican nivel, así
  que el watchdog del HUD pasa la onda a ámbar; a los 5 s la muesca lo dice en
  «preparando», y el corte por falta de voz dice por qué corta. Los avisos
  viajan por `MicrofonoDeLaSesion`, no por el contrato de los motores.

## El ícono de la barra de menús

- **Clic izquierdo abre Dilo; clic derecho (o ⌃clic), el panel de la barra**
  (Alfonso, 2026-10-15: «con botón izquierdo que abra la app de Dilo, con
  botón derecho alguna ventana como la de ahora pero que sea linda, así como
  la de Switchboard»). La app es la ventana de Ajustes, la única que Dilo
  tiene. Qué abre cada clic lo decide `ClicEnLaBarra` (puro); un clic sin
  evento de mouse —Accesibilidad— abre el panel, que es lo que antes abría el
  menú.
- **El panel reemplaza al `NSMenu` gris y ofrece todo lo que ofrecía**:
  `PanelDeLaBarra.contenido` arma el panel en palabras y
  `PanelDeLaBarraTests.nadaDelMenuGrisSePierde` lo vigila. De arriba abajo:
  Dilo con su estado (listo / dictando / leyendo / transcribiendo) y el
  gatillo como tecla, «Abrir»; la toma que no salió, en ámbar, con
  Reintentar y ✕; lo último dictado con copiar y, sólo cuando son otra cosa,
  lo dicho sin el modo y lo que el modo propuso; las acciones; el modo del
  atajo general (el mismo `hudModoDelAtajoGeneral` del panel de la muesca);
  y al pie Primeros pasos, Novedades, Actualizaciones y Salir. Una acción
  nueva entra al modelo y a ese test, no sólo a la vista.
- **Se ve como el panel de la muesca**: vidrio ahumado con la receta de
  `PanelDeVidrio` (o negro, con «Panel con vidrio» apagado o «Reducir
  transparencia»), letra de 10,5 a 12,5 y las piezas compartidas
  (`HUDUltimoDelPanel`, `HUDChipDelPanel`). De Switchboard toma la forma de
  panel de barra —tarjeta flotante bajo el ícono, filas que se iluminan,
  vínculos al pie—, sin la punta. Se revisa en PNG con
  `scripts/render-panel-de-la-barra.sh` (claro y oscuro, vidrio imitado).
- **El panel nunca toma el teclado ni activa a Dilo**
  (`VentanaDelPanelDeLaBarra.canBecomeKey == false`, `.nonactivatingPanel`).
  «Empezar a dictar» y «Leer lo seleccionado» trabajan sobre el foco de
  otra app; una ventana de Dilo que se volviera key se lo quitaría justo
  antes. Por eso no hay Tab ni ⌘Q adentro, y Escape lo cierra con un
  monitor global que no se traga la tecla.
- **Se cierra como un menú** (`ControlDelPanelDeLaBarra`): clic afuera,
  Escape, otro clic en lo que lo abrió, o elegir algo. Copiar se queda
  650 ms con el ✓ y elegir un modo no cierra (`PanelDeLaBarra.Accion.cierre`).
  El clic en la silueta de la muesca en reposo abre **este mismo panel**,
  centrado bajo ella (`HUDStage.siluetaDeAcciones`), y mientras está abierto
  el hover de la muesca no abre el suyo encima
  (`HUDStage.panelDeLaBarraAbierto`): el menú era modal y no chocaban.
- Técnica observada en Switchboard (`StatusItemController`, `BarPanels`,
  `BarPanelController`, `BarPanelModel`); el código es propio.

## Lo que entra de afuera: URL scheme, agentes y App Intents

Fase 5, pasos 1 y 2 (2026-10-15). El detalle, las líneas para pegar y lo
que sólo se prueba a mano están en `docs/design/agentes-en-la-muesca.md`.

- **Dos puertas, con reglas distintas.** El URL scheme `dilo://`
  (`CFBundleURLTypes` en `Dilo/Info.plist`) lo abre cualquiera —un *hook*,
  pero también una página web—, así que **sólo muestra**: hoy su única ruta
  es `dilo://agente?de=…&fase=…&proyecto=…`, y `EnlaceDeDilo`
  (`DiloPlataforma`, con tests) rechaza todo lo demás. Lo que abre el
  micrófono, escribe Ajustes o toca el portapapeles va **sólo** por App
  Intents, que arma la persona. No agregues rutas que hagan algo: agrega un
  intent.
- **El agente avisa; Dilo no espía.** Nada de leer los JSONL de `~/.claude`,
  los rollouts de Codex ni la base de Cursor para seguir a un agente, ni sus
  tokens. La persona pega en su agente la línea que muestra Ajustes → Datos
  en la muesca → Agentes, que corre `Dilo/Resources/dilo-agente.sh` (viaja
  en el `.app`). Dilo **nunca escribe** en `~/.claude` ni en `~/.codex`. El
  script codifica la carpeta, no lanza Dilo si no está corriendo, manda la
  URL por bundle id (`DILO_ID`, por defecto `cl.espaciodigital.dilo`: cada
  Debug y cada corrida de tests registra `dilo://`) y nunca falla ni
  imprime. `DILO_SOLO_IMPRIMIR=1` imprime la URL sin abrir nada; así lo
  prueba `swift test`.
- **Qué agente existe lo decide `RegistroDeAgentes`** (puro): `listo` 30 s,
  `error` 2 min, 15 min sin noticias y se olvida, la misma fase no vuelve a
  sentar, tope de 8 sesiones. `AgentesEnLaMuesca` duerme hasta el próximo
  vencimiento —nada de sondeo— y el clic en el segmento lo quita. La
  palabra del segmento es el nombre del agente; la fase va en el ícono (la
  mano en el acento cuando te espera) y la frase con el proyecto en el
  tooltip. Interruptor `hudAgentes`, encendido de fábrica. En el arnés,
  `agente-esperando`; en PNG, `reposo-agente-espera` y `reposo-dos-agentes`
  de `scripts/render-muesca.sh`.
- **Lo de afuera nunca es la forma.** `HUDStage.publicarDeAfuera` fuerza
  `puedeSerPrincipal = false` y nunca exige el principal ni dice abrir el
  micrófono, lo pida quien lo pida. Un segmento que cambia su contenido bajo
  el mismo id vuelve a decir su palabra.
- **Los App Intents no tienen lógica propia** (`Dilo/Atajos/`). Ocho:
  Dictar (con modo opcional, «Sin modo» incluido), Dictar una nota, Elegir el
  modo de Dilo, Último dictado, Copiar el último dictado, Transcribir un
  archivo, Buscar en el historial de Dilo y Mostrar en la muesca. Lo que hace
  cada uno vive en `EjecucionDeAtajos`, que recibe la app como protocolo
  (`AccionesParaAtajos`) y se prueba con un doble; `AccionesDeDiloEnVivo`
  llama a lo mismo que el menú y el panel del hover
  (`DirectDictationController.dictarDesdeUnAtajo`, `hudModoDelAtajoGeneral`,
  `copiarAlPortapapeles`…). `AppDelegate` llena `PuenteDeAtajos.actual` al
  arrancar. Todos corren con `supportedModes = .background`: traer Dilo al
  frente le roba el foco a la app donde se va a pegar. Las frases nombran la
  app; su inglés está en `Dilo/AppShortcuts.xcstrings`.
- **Lo que entra se anota** en la categoría `plataforma` del log: qué URL se
  rechazó y por qué (`log show --predicate 'subsystem ==
  "cl.espaciodigital.dilo" && category == "plataforma"'`). El nombre del
  proyecto va privado; el texto de un dictado, nunca.

## El micrófono

- **Dilo nunca escribe la entrada del sistema** (ni ningún ajuste de audio
  del sistema). Elige su micrófono por dictado con `PlanDeMicrofono` (puro,
  `DiloEngines`) y lo fija sólo en su `AVAudioEngine`
  (`AVAudioEngine.fijarEntrada`), antes de leer el formato del bus; una
  reconstrucción por cambio de ruta lo vuelve a fijar, y si ya no está sigue
  con el del sistema.
- **Fijar y arrancar un motor hace que ese mismo motor avise un cambio de
  ruta, sin detenerse.** Reconstruir por ese aviso era un bucle cada ~300 ms
  sin un búfer (la webcam, 0.4.4). Un aviso con el motor corriendo y la misma
  huella —dispositivo, tasa, canales, tomada antes de `start()`— se ignora
  (`GuardiaDeReconstruccion`), y más de cuatro reconstrucciones en 5 s sueltan
  el micrófono fijado y siguen con la entrada del sistema, con una línea en el
  log de `audio`. Se reproduce sin abrir Dilo con el programa de prueba de
  `/Volumes/SSD 1/Dilo/taller/pruebas/bucle-del-microfono/` (fuera del repo).
- **Un Bluetooth tarda en despertar**: el WH-CH720N entrega su primera
  muestra 1,2–1,6 s después de `start()`, con 0,8–1 s de ceros exactos
  (medido el 2026-10-14). Lo dicho entonces no existe para nadie, así que una
  toma sin texto con medio segundo de ceros no dice «No te escuché» sino que
  el micrófono tardó (`MedidaDeToma.microfonoDormido`), y sin texto basta una
  décima de voz para pedir la segunda opinión.
- **Automático, de fábrica:** la entrada del sistema, salvo que sea
  Bluetooth —abrir su micrófono baja los audífonos al perfil de llamada—; ahí,
  el micrófono del Mac (no con la tapa cerrada) y después uno con cable. Un
  iPhone por Continuity nunca se elige solo. Ajustes → Dictado → Micrófono
  ofrece Automático, El del sistema o uno por nombre, guardado por UID con el
  nombre de respaldo (`diloMicrofonoElegidoUID`, `diloMicrofonoElegidoNombre`).
- **Avisar antes de grabar que el micrófono elegido no está** se pregunta a
  `PlanDeMicrofono.Decision.avisoAntesDeGrabar`; no se repite la regla.
- **El motor tibio está apagado de fábrica** (`diloMotorDeAudioTibio`): un
  motor preparado sin `start()`, sólo cableado, 30 min como tope, vencido con
  cualquier cambio de dispositivos. No se prende para todos hasta medir el
  reposo con y sin él (`scripts/metrics.sh`) y comparar «primer búfer a N ms
  de abrir (motor tibio: sí/no)» en el log, categoría `audio`.

## Agentes: servidor MCP y CLI

Desde el 2026-10-15 (plan, fase 5 paso 3) **el mismo binario de Dilo** es
también un servidor MCP por stdio y un CLI para scripts. No hay target ni
ejecutable aparte: `ArranqueParaAgentes.correrSinVentanasSiCorresponde()` es
la primera línea de `AppDelegate.main()` y decide con `ModoDeArranque` (puro,
en `DiloAgentes`, con tests) mirando sólo `argv`:

- `--mcp` en cualquier lugar → servidor MCP;
- `argv[0]` que se llama exactamente `dilo` (el enlace) → CLI;
- primer argumento `spec`, `dictados`, `palabras`, `ayuda`, `help`, `--help`
  o `-h` → CLI;
- cualquier otra cosa → la app de siempre. Los argumentos de un guion
  (`-NSDocumentRevisionsDebugMode YES`, `-psn_…`) nunca deciden el modo, y el
  ejecutable `Dilo` con mayúscula **no** es el CLI: compararlo sin distinguir
  mayúsculas dejaría a la persona sin app.

En modo MCP o CLI **no se crea `NSApplication`**: no hay muesca, ni ícono en
la barra, ni tap, ni micrófono, ni Sparkle. Lo único que se lee son las
claves de `UserDefaults` que `AppSettings.lecturaParaAgentes` expone (sin
crear `AppSettings`, cuyo `init` migra y escribe) y los archivos del
historial con `DictationHistoryStore.entradas(in:)`.

Reglas:

- **stdout es el protocolo.** Nada en ese camino escribe con `print`; los
  avisos van a `AppLog.agentes` o a stderr. `ServidorMCPDelBinarioTests`
  lanza el binario con `--mcp` y falla si una línea de stdout no es JSON.
- **Todo es de sólo lectura**, y lo dictado se declara dato no confiable en
  las `instructions` del `initialize`: un dictado escrito como orden no es
  una orden para el agente.
- **Una sola tabla.** `HerramientasDeDilo` define las herramientas; el
  `tools/list`, la validación de argumentos, `dilo spec` y `dilo --help`
  salen de ahí. Una herramienta nueva se agrega a esa tabla y a
  `CLIDeDilo.comandos`, con su test.
- **Errores que dicen qué hacer.** Un fallo de herramienta va con `isError`
  y una frase de arreglo; el CLI responde siempre el mismo sobre
  `{ok, comando, datos | error{codigo, mensaje, arreglo}, meta}` y sale con
  0 ok, 3 historial apagado o ilegible, 4 uso, 5 no encontrado.

Herramientas (MCP) y comandos (CLI), las cuatro del plan:

| MCP | CLI |
| --- | --- |
| `dictados_recientes {maximo}` | `dilo dictados recientes [--maximo N]` |
| `buscar_dictados {consulta, maximo}` | `dilo dictados buscar <consulta> [--maximo N]` |
| `ver_dictado {id, desde, max_caracteres}` | `dilo dictados ver <id> [--desde N] [--max_caracteres N]` |
| `tus_palabras` | `dilo palabras` |

Topes: `maximo` 10 (hasta 50), extractos de 280 caracteres con `recortado`,
páginas de 20.000 caracteres (hasta 100.000). El id para agentes es
`2026-10-12T09:41:07`, con `#2` si hubo dos en el mismo segundo
(`IdsDeDictados`). **Con el historial apagado —el de fábrica— no hay dictados
que leer** y las herramientas lo dicen; `tus_palabras` funciona igual. Lo
que vive sólo en la app abierta (el último dictado sin historial, un dictado
pedido por un agente con confirmación en la muesca) espera a un socket de la
app viva; no existe todavía.

**Cómo se registra en un cliente** (sólo documentado; nadie lo registra por
la persona). Con la app instalada en `/Applications`:

```sh
claude mcp add dilo -- /Applications/Dilo.app/Contents/MacOS/Dilo --mcp
```

```toml
# ~/.codex/config.toml
[mcp_servers.dilo]
command = "/Applications/Dilo.app/Contents/MacOS/Dilo"
args = ["--mcp"]
```

```json
{
  "mcpServers": {
    "dilo": { "command": "/Applications/Dilo.app/Contents/MacOS/Dilo", "args": ["--mcp"] }
  }
}
```

El JSON sirve para `.mcp.json` de un proyecto y para los clientes que leen
`mcpServers`. El comando `dilo` es un enlace al mismo ejecutable:
`ln -s /Applications/Dilo.app/Contents/MacOS/Dilo ~/.local/bin/dilo`. Por el
enlace Foundation no ve el bundle, así que `ArranqueParaAgentes.bundleDeLaApp`
sigue el enlace hasta el `.app` para leer sus ajustes y su versión. Ajustes
todavía no tiene el botón «Instalar el comando `dilo`» del plan.

**TCC.** El historial vive de fábrica en `~/Documents/Dilo/`, y Documentos es
una carpeta protegida: la primera vez que un agente lee dictados, macOS le
pregunta a la persona si deja que **quien lanzó el proceso** (el terminal, o
el cliente del agente) lea Documentos. Es una vez y es correcto que pregunte.

**Probarlo sin ventanas y sin tocar los datos de Alfonso.** El binario de un
DerivedData tiene el bundle id de la app instalada y lee sus ajustes; para
no leer el historial real (ni disparar ese diálogo), pisa las claves por la
línea de comandos —`NSArgumentDomain`, no escribe nada—:

```sh
BIN=…/Build/Products/Debug/Dilo.app/Contents/MacOS/Dilo
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | "$BIN" --mcp -dictationHistoryFolder /private/tmp/historial-de-prueba -diloPalabrasPropias '("Prueba")'
"$BIN" --help
"$BIN" dictados recientes -dictationHistoryEnabled NO   # sale con 3
```

## Traducir con Claude

Alfonso, 2026-10-19: «Las traducciones son malísimas. Hagamos un modo de
traducción más pro […] de español a inglés y de español a chino […] que se
vea como inglés nativo […] que lo haga Haiku 5.5». La tecla de traducir
puede traducir con **Claude Haiku 5.5** por la API de Anthropic o con el
traductor de **Apple**, en el Mac.

- **Quién traduce lo decide `MotorDeTraduccion`** (puro, `DiloModes`, con
  tests). Se elige en Ajustes → Idioma → «Traducir con»
  (`diloMotorDeTraduccion`); sin elegir, Claude si hay clave de Anthropic y
  Apple si no. Claude traduce **desde el español** y **hacia inglés (EE. UU.)
  o chino simplificado** (`DestinoDeTraduccion`, guardados como `en` y `zh`,
  los mismos códigos que la fila de Apple); cualquier otro par sigue con
  Apple. Claude elegido a mano sin clave no cae a Apple: la tecla se niega y
  la muesca dice «Falta la clave de Anthropic» (`traduccionSinClave`).
- **Se resuelve al apretar la tecla y la sesión lo congela** (ADR-0004):
  `estadoDeLaTraduccion()` pregunta al Llavero sólo con la tecla de traducir y
  sólo si la respuesta cambia algo, y lo resuelto viaja en
  `DictationSessionSettings.motorDeTraduccion`. Con Claude no hace falta que
  el modelo de Apple esté listo.
- **Una sola clave de Anthropic**: la del proveedor Anthropic de los modos
  (Llavero, servicio `cl.espaciodigital.dilo.proveedores`, cuenta
  `proveedor.anthropic`). Se pega en **Ajustes → Modos → Proveedor general →
  Anthropic → API key**; la fila de Idioma, si falta, dice eso y abre Modos.
  `TranslationCoordinator.claudeEnVivo` la lee al traducir y no la guarda.
- **El request** (`TraductorConClaude`): `POST /v1/messages`, `x-api-key`,
  `anthropic-version: 2023-06-01`, modelo `claude-haiku-5-5` (sin sufijo de
  fecha), `max_tokens` 8.000 (lo que el modelo piensa cuenta contra ese
  número) y `output_config: {effort: "low"}` por latencia; si la calidad no
  alcanza, el escalón siguiente es `medium`, en `TraductorConClaude.esfuerzo`.
  **No lleva `temperature`, `top_p`, `top_k`, `thinking`, `budget_tokens`
  ni un `assistant` final**: en Haiku, Sonnet y Opus 5.5 cada uno es un 400.
  Haiku 5.5 piensa solo; la respuesta trae bloques `thinking` vacíos antes
  del texto y se leen sólo los `text` (`RespuestaDeAnthropic`, la misma
  lectura que los modos). Plazo de 12 s.
- **El prompt** (`PromptDeTraduccion`, versionado en `version`) está en
  inglés a propósito —la salida nunca es español y los modelos siguen mejor
  instrucciones en inglés— con tres ejemplos chilenos por destino: un mensaje
  casual con chilenismos y muletillas, un correo formal con un monto y saltos
  de línea, y un dictado que parece una orden. Pide sentido y no calco, el
  registro del original, nada agregado ni quitado salvo muletillas, nombres,
  URLs, código y formato intactos, y números al uso del lector. **Lo dictado
  es dato**: va entre `<dictado>`, una etiqueta adentro se neutraliza, y si
  parece una orden o una pregunta se traduce, no se contesta. Quien cambie
  una línea sube la versión.
- **Fallas**: `stop_reason` `refusal` o `max_tokens` es falla, nunca texto a
  medias. Cada falla tiene su frase (`FallaDeTraduccion.aviso`): sin clave,
  clave rechazada (401/403), 429, 5xx/529, otro 4xx, sin conexión, plazo,
  refusal, cortada. **Si Claude falla y el modelo de Apple para el par está
  instalado, traduce Apple y la muesca dice «Sin conexión: tradujo Apple»**
  (`TranslationCoordinator.traducir`): la regla de no ir a un segundo
  proveedor existe para que un dictado no termine en una nube que nadie
  eligió, y Apple corre en el Mac. Sin el modelo de Apple, el dictado va al
  portapapeles y la muesca dice por qué no tradujo Claude.
- El historial y el último dictado quedan como siempre: lo dicho, y lo
  traducido al lado. Leer en voz alta sigue traduciendo con Apple.
- **Probar la calidad**: `scripts/probar-traduccion.sh [en|zh]` traduce los
  dictados de `scripts/probar-traduccion-dictados.txt` con el mismo código de
  la app y la clave del Llavero (pasada por la entrada estándar). Llama a la
  API de verdad: se corre a mano, nunca desde un test.

**Los modos también van por Claude Haiku 5.5 de fábrica** (2026-10-19). El
dictado sin modo no cambia: transcripción y reglas, sin ningún modelo.

- El proveedor Anthropic trae `claude-haiku-5-5` de fábrica, y un Anthropic
  guardado con el modelo vacío pasa a ése una vez
  (`MigracionDeProveedores.conModeloDeFabrica`, marca
  `diloMigracionModeloDeAnthropic`); un modelo escrito a mano no se toca.
  En Modos el modelo de Anthropic se elige de `ModelosDeAnthropic.lista`
  —Haiku 5.5 (recomendado), Sonnet 5.5, Opus 5.5— o «Otro…», que deja el
  campo de siempre.
- **El general pasa a Anthropic una sola vez** si sigue en el modelo de
  Apple, nadie lo cambió desde esta regla y hay clave
  (`MigracionDeProveedores.generalConClave`, al arrancar en `AppDelegate`).
  Cualquier cambio del general anota `diloProveedorGeneralDecidido`, así que
  quien vuelve al de Apple se queda ahí.
- A un modelo de la lista los modos le mandan `output_config.effort` `low` y
  `max_tokens` 8.000 (`ModelosDeAnthropic.opciones`); a un modelo escrito a
  mano, lo de antes y nada más (Haiku 4.5 rechaza `effort`). **A Anthropic
  nunca va `temperature`**, ni con forma: antes `conForma` mandaba
  `temperature: 0`, los modelos 5.5 contestaban 400 y cada modo gastaba un
  viaje antes del reintento.

## Aprender con Claude

Alfonso, 2026-10-19: que el aprendizaje lo haga Claude, **prendido de
fábrica** («déjalo, sí lo vamos a usar»), con la misma clave de Anthropic y
con un selector de modelo propio. Dos usos, dos modelos:

- **Revisar cada corrección → Claude Haiku 5.5.** Lo determinista sigue
  siendo el primer filtro (`AprendizajeDeCorrecciones`, `soloDelMotor`, lo
  rechazado y lo ya sabido); lo que pasa se le pregunta a Claude antes de la
  oferta (`RevisionDeCorrecciones`, puro, `DiloText`): ¿es un `termino` para
  Tus palabras, un `reemplazo` «oído → correcto», o `nada` (reformulación,
  cambio de idea, ortografía común)? `nada` no se ofrece y queda rechazado
  por la sesión. Un `termino` que Tus palabras arregla sola
  (`DiccionarioPersonal.aplicar`) no deja regla en «Cuando digo…»; si no
  alcanza —«cuba netes» no empieza con la K—, la deja igual. El modelo elige
  por número entre los candidatos: no puede meter una palabra que el filtro
  no propuso. Pregunta frecuente y barata: esfuerzo `low`, 4.000 tokens,
  **plazo de 7 s**. Sin clave, sin red, fuera de plazo o con respuesta
  ilegible, se ofrece lo determinista como antes. Un dictado nuevo cancela la
  revisión pendiente (`CorreccionesDelDictado.detener`).
- **Ordenar el diccionario → Claude Sonnet 5.5** de fábrica; Haiku 5.5 y Opus
  5.5 elegibles. Una pasada en segundo plano (`OrdenDelDiccionario`, puro;
  `OrdenadorDelDiccionario`, la app) con cuatro acciones: `unir` variantes
  («Kubernetes»/«kubernetes»), fijar la `grafia` de un nombre conocido,
  `quitar` lo que entró por error y resolver un `conflicto` entre reglas que
  se pisan. Un error ahí se queda pegado y empeora todos los dictados, por
  eso el modelo más capaz que no es Opus; Opus si Sonnet se equivoca seguido.
  Esfuerzo `medium`, 16.000 tokens, plazo de 120 s.
  - **Cuándo** (`CuandoOrdenar`, puro): diez entradas aprendidas desde la
    última pasada, una semana, o nunca ordenado; nunca con el mismo
    diccionario que la última vez (firma FNV de las dos listas) y nunca dos
    intentos en menos de seis horas. Se mira a los dos minutos de arrancar,
    cada seis horas y después de aceptar algo en la muesca. **Nunca empieza
    durante un dictado** (`hayDictadoEnCurso`, que lee
    `SettingsRuntimeState.isDictating`): espera un minuto y vuelve a mirar.
    «Ordenar ahora» en Ajustes se salta el calendario, no el dictado.
  - **Qué aplica solo**: lo que no pierde nada escrito a mano. Unir o
    corregir grafías que sólo difieren en mayúsculas, tildes, espacios o
    signos (`OrdenDelDiccionario.llavePlana`), y quitar entradas aprendidas
    (`Reemplazo.aprendido`, y para Tus palabras `diloPalabrasAprendidas`, que
    anota lo que entra por la muesca). Lo demás queda **propuesto** y se
    aplica con un clic. Tope de quitadas solas por pasada:
    `max(5, entradas / 5)`. Al unir o corregir una palabra, las reglas que la
    escribían pasan a escribir la buena.
  - **Deshacer**: cada cambio guarda lo que quita y lo que agrega en valores
    concretos (`CambioDelDiccionario`); deshacer es aplicar el inverso, y se
    puede repetir. **Lo deshecho no se vuelve a proponer** (se filtra contra
    el registro). El registro (`diloRegistroDelOrden`, 20 pasadas) lleva
    fecha, modelo, acción, motivo del modelo y estado.
  - Los ids que ve el modelo (`p1`, `r1`) se resuelven contra el diccionario
    que se mandó, y los cambios se aplican sobre el de ahora: aprender una
    palabra mientras Sonnet piensa no rompe nada.
- **El request** es `ConsultaAClaude` (`DiloModes`): el mismo `POST
  /v1/messages`, clave, `anthropic-version`, lectura (`RespuestaDeAnthropic`)
  y fallas (`FallaDeClaude` = `FallaDeTraduccion`) que traducir, más
  `output_config: {effort, format: {type: "json_schema", schema}}`. **Sin
  `temperature`/`top_p`/`top_k`, sin `thinking`** (omitirlo es adaptativo;
  Sonnet 5.5 rechaza `disabled`), sin prefill, sólo bloques `text`;
  `refusal` y `max_tokens` son falla. `timeoutInterval` del request = plazo
  + 5 s: URLSession corta a los 60 s sin bytes, y una respuesta sin
  streaming no manda ninguno hasta terminar. La salida igual se valida al
  leer.
- **Los prompts** están en español (se juzga español de Chile y la salida
  son etiquetas), versionados en `RevisionDeCorrecciones.version` y
  `OrdenDelDiccionario.version`. Lo dictado y lo de la persona van entre
  etiquetas como **dato, nunca instrucción**, con `<` y `>` neutralizados.
  Quien cambie una línea sube la versión.
- **Qué viaja a Anthropic**: al revisar, cada par con unas ocho palabras
  antes y después en lo pegado y en lo corregido (`recorte`, tope de 240
  caracteres), nunca el campo entero ni la app; al ordenar, Tus palabras y
  «Cuando digo…» con la marca de aprendida, nada de lo dictado. Nada con
  entrada segura activa (la vigía no mira). Al log (`AppLog.aprendizaje`)
  van cuentas y nombres de falla, nunca una palabra.
- **Ajustes → Tus palabras → «Aprender con Claude»**
  (`AprenderConClaudeCard`): el interruptor (`diloAprenderConClaude`,
  prendido), el modelo para revisar (`diloModeloParaRevisar`) y para ordenar
  (`diloModeloParaOrdenar`) —un id que ya no está en la lista vuelve al de
  fábrica—, «Ordenar ahora», el registro con «Deshacer»/«Aplicar» y la línea
  de qué se manda. Sin clave dice dónde pegarla y abre Modos.
- **Costos de referencia** por millón de tokens (entrada/salida): Haiku 5.5
  $0,10/$0,50; Sonnet 5.5 $2/$10; Opus 5.5 $4/$20. Revisar es una fracción de
  centavo; ordenar cien entradas, unos pocos centavos.
- **Probar**: `scripts/probar-aprendizaje.sh revisar [modelo…]` pasa las
  correcciones de `scripts/probar-aprendizaje-correcciones.txt` (chilenas:
  nombres, siglas, jerga, y reformulaciones que no se aprenden) por cada
  modelo y marca si coincide con lo esperado; `ordenar` ordena un
  diccionario de ejemplo. Por defecto compara Haiku 5.5 con Sonnet 5.5.
  Llama a la API de verdad: se corre a mano, nunca desde un test.

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
# La app, limpio
xcodebuild -project Dilo.xcodeproj -scheme Dilo -configuration Debug \
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

Para medir "soltar → texto" el `.app` tiene que ser un build **Debug**: la
medición inyecta un WAV y dispara la sesión con una notificación distribuida.
El gancho es la variable de entorno **`DILO_METRICS_WAV`**, que
`MicrophoneInput` respeta sólo bajo `#if DEBUG`
(`Dilo/Dictation/MicrophoneInput+MetricasWAV.swift`): con ella apuntando a un
WAV, la sesión escucha ese archivo en vez del micrófono, al ritmo real, y anota
en `<wav>.soltado` el instante en que el controlador manda a parar. Con la
misma variable puesta, `DisparadorDeMetricas` escucha
`<bundle id>.debug.metricas` para empezar y parar —la puerta del viejo ítem
«Empezar a dictar»— y deja en `<wav>.estado` si hay sesión. **Hasta la 0.4.8
se apretaba el menú de la barra por AppleScript** y el terminal necesitaba
Accesibilidad; el menú pasó a ser un panel de SwiftUI (2026-10-15) y apuntarle
un AppleScript a sus botones era apostar a cómo SwiftUI los expone. En
release no existe nada de esto: los dos archivos están dentro de un
`#if DEBUG`.

**Y adentro, cada dictado se mide por fases** (`RelojDeFases`,
`Dilo/Dictation/LatenciaPorFase.swift`, 2026-10-14): gatillo → micrófono,
soltar → texto del motor, la revisión de la toma (`MotorConRespaldo` la
mide), limpieza, modo, traducción, preparar el pegado y ⌘V → acuse. Se
guardan las últimas 500 sesiones en `Application Support/Dilo/latencias.json`,
**sin texto ni apps**, y se ven y exportan en Ajustes → Historial →
Actividad de dictado. El «total» de adentro no incluye el pintado de la app
de destino: no reemplaza al número de `metrics.sh`, dice dónde se van sus
milisegundos. Los hitos también salen como `os_signpost` (categoría
`latencia`) para Instruments.

El `xcodebuild build`, `swift test` y la suite de la app tienen que pasar
antes de devolver el trabajo. Para probar permisos en runtime: `open -a`,
nunca el binario desde el terminal.

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

**Con la 0.9.0 instalada y abierta, la suite también se cuelga** (2026-10-19):
*"the test runner hung before establishing connection"*, en cualquier rama y
con cualquier bundle id, antes de que corra una línea de Dilo. Cerrando la
copia instalada corre entera; con la 0.4.8 abierta no pasaba. La causa exacta
no se aisló (desde la 0.4.9 la copia instalada registra App Intents y el
esquema `dilo://`, que la de tests también declara). Mientras tanto: cerrar Dilo antes de la suite —avisándole a
Alfonso, que lo está usando— y abrirlo de nuevo al terminar.

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
Detalle en `docs/ProjectSettings.md`.

**`DILO_SUFIJO_ID` corre los bundle ids de una corrida.** Vacío por defecto;
con `DILO_SUFIJO_ID=.ci` la app pasa a `cl.espaciodigital.dilo.ci` y el bundle
de tests a `…dilo.tests.ci`, los dos a la vez. Es lo que usa CI para que un
build automático nunca herede ni ensucie los permisos de TCC de la app de
verdad, y sirve igual para probar algo local sin pisar los propios.

## Primeros pasos y notas de versión

- **El onboarding vive en `Dilo/Onboarding/`** y se abre solo la primera
  vez; después, desde el panel de la barra (**Primeros pasos**). Son cuatro
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
- **Los secrets que espera CI** —`APPLE_CERTIFICATE`,
  `APPLE_CERTIFICATE_PASSWORD`, `KEYCHAIN_PASSWORD`, `APPLE_API_ISSUER`,
  `APPLE_API_KEY` y `APPLE_API_KEY_P8`— están
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
