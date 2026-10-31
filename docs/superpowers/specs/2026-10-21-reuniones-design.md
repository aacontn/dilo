# Dilo — Reuniones (v2): el guion de quién dijo qué, en el Mac

**Fecha:** 2026-10-21 · **Estado:** propuesta para revisión de Alfonso; **compuerta de entrada pendiente** (Fase 0, §Verificación) · **Base:** 0.9.3 (`main` en `6758027`), [spec nativo](2026-09-20-dilo-mac-nativo-design.md) («Notetaker: nada menos que Granola», §5, «Notas para el spec de v2») · **Reemplaza:** el camino en línea de `Dilo/app/docs/superpowers/specs/2026-08-27-reuniones-en-linea-design.md` (repo Tauri, congelado)

**Cambio 2026-10-31:** el guion en vivo y las notas entraron antes que el resto
de sus fases, a pedido de Alfonso («solo graba mi micrófono y no tengo como lo
hace notetaker»): en vivo por pista y sin hablantes, con Silero y el Parakeet
del dictado por tramos, no los trozos de 2 s con estado del decoder de abajo; y
notas ancladas al tiempo en `notas.jsonl`, sin la fusión con el guion de la
Fase 5. La ventana ya no «nunca» toma el teclado: lo toma con el campo de la
nota abierto, sin activar Dilo. El detalle vigente está en `AGENTS.md`,
«Reuniones».

**Cambio 2026-10-21 (2):** Alfonso eligió el modelo de FluidMeet y Wispr Flow
sobre el de Granola («me gusta más el modelo de FluidMeet; creo que es más
parecido también a Wispr Flow con notetaker»). El centro pasa de las notas
mejoradas al **guion con quién dijo qué**, separar voces pasa a ser lo
principal, todo es local y Claude queda **a pedido y apagado de fábrica**, la
libreta de notas sale del corte inicial y los datos viven en el SSD 1. La
versión anterior, centrada en notas al estilo Granola, es el commit `c0cf312`.

## De dónde sale esto

Alfonso vio FluidMeet (<https://www.fluidvoice.com/fluid/blog/fluidmeet>) y
dijo que «era la idea del Dilo original». El spec nativo la tenía escrita como
«dos flujos —mic = Yo, audio del sistema = Ellos—, en vivo local, WAV a disco
desde el primer segundo» (:60-62). Lo que se ve al terminar no es un acta:
es **un guion**, una línea por intervención, con quién la dijo y cuándo:

```
Yo · 12:04 — ¿Cerramos el precio hoy?
Camila · 12:05 — Sí, pero con despacho incluido.
Pedro · 12:05 — Ojo que el despacho a regiones es aparte.
Camila · 12:06 — Ya, entonces sin regiones.
```

Eso es lo que se busca, lo que se copia y lo que se le pasa a un agente.

El Dilo Tauri tuvo reuniones y no rindieron: 13.000 de sus 17.000 líneas
propias eran reuniones, diarización, captura y TTS, y la evaluación fue «el
motor de reuniones es pobre» (spec nativo :7-13). Lo aprendido ahí va en
§Lecciones y manda.

## Las dos referencias

| | FluidMeet (FluidVoice) | Wispr Flow Notetaker |
| --- | --- | --- |
| Lanzado | beta, 2026-09-22 | 2026-08-05, Mac |
| Captura | audio del Mac, sin bot; ScreenCaptureKit (código, `Services/Meeting/MeetingCaptureEngine.swift`) | audio del Mac, sin bot; Zoom, Meet, Teams, Slack, Discord, navegador, y lo que oye el micrófono |
| Quién habló | **Nemotron 3 Diarization**: ~100M, hasta 8 hablantes, streaming desde 80 ms, solapes, Core ML; el «script» pega el hablante a cada palabra con tiempo | nombres desde la invitación del calendario, cada línea con su autor; usa el diccionario personal y apps conectadas para nombres y siglas |
| Durante | píldora de grabación y subtítulos flotantes | transcript en vivo; «¿Qué me perdí?» |
| Al terminar | el script; resúmenes «el próximo mes» | «re-lee la grabación entera con más contexto» para un transcript final mejor; resumen por tema con fechas, decisiones, próximos pasos y quién debe qué |
| Dónde corre | todo en el Mac: «No bots. No cloud. No subscription» | no lo dice la página; en 2026-08 se vio que Wispr manda el audio por WebSocket a su servidor (`Dilo/app/docs/superpowers/specs/2026-08-04-reuniones-en-streaming-design.md:34`) |
| Agentes | un *skill* que instala en Claude Code o Codex | transcripts y notas a Claude o ChatGPT por MCP; preguntas sobre todo el historial con enlace al momento |
| Fuentes | <https://www.fluidvoice.com/fluid/blog/fluidmeet>, `github.com/altic-dev/FluidVoice` (**GPLv3**: sólo ideas) | <https://wisprflow.ai/post/wispr-flow-notetaker>, <https://9to5mac.com/2026/08/05/wispr-flow-takes-on-ai-meeting-assistants-with-notetaker-its-first-product-beyond-dictation/>, <https://www.digitaltrends.com/computing/wispr-flow-launches-an-ai-note-taker-that-works-without-joining-calls/> |

Dilo toma de FluidMeet **dónde corre y cómo separa voces**, y de Wispr **la
forma**: un clic para grabar, transcript en vivo, una segunda pasada al
terminar con todo el contexto (Tus palabras, los nombres del calendario) y la
puerta MCP. Lo que Wispr hace con un modelo en la nube —resumen, «¿qué me
perdí?», preguntas al historial— en Dilo es Claude **cuando lo pides**.

Las demás referencias de la versión anterior siguen valiendo como dato:
**pasrom/meeting-transcriber** (MIT) es la base portable de la captura y la
detección (<https://github.com/pasrom/meeting-transcriber>); **Granola** queda
como referencia para la libreta opcional del final.

## Lo que ya existe y sirve (0.9.3)

| Pieza | Dónde | Para qué sirve aquí |
| --- | --- | --- |
| Parakeet TDT v3 int8 por FluidAudio 0.15.8 | `DiloCore/Sources/DiloEngines/ParakeetEngine.swift:23-30`, `:60-70`; `DiloCore/Package.swift:36-45` | Español (25 idiomas europeos, `FluidAudio/README.md:37`) con tiempos por palabra (`ASR/Parakeet/AsrTypes.swift:95`, `:143-195`). En el M1 de 16 GB, un trozo de 2 s en **124 ms** con el estado del decoder, 6 % de ocupación; 469 MB en disco |
| Diarizadores de la 0.15.8 | `FluidAudio/Sources/FluidAudio/Diarizer/{Sortformer,LS-EEND,Offline}` | Sortformer streaming y offline (4 hablantes, identidades «extremadamente estables», su error típico es perder voz baja), LS-EEND (hasta 10, más falsas alarmas), VBx offline sin tope (`Documentation/Diarization/GettingStarted.md:7-25`) |
| Embeddings de voz | `FluidAudio/Sources/FluidAudio/Speaker/CampPlusEmbedder.swift` | Recordar voces entre reuniones |
| Asientos de la muesca | `Dilo/CoreHUD/AsientosDeLaMuesca.swift:50-65`, `:206-217` | Lo que abre el micrófono **nunca se queda sin asiento** y cede la forma al dictado sin esconderse |
| El estado previsto | `Dilo/CoreHUD/HUDSessionKind.swift:14-29` | `case reunion`, sin superficie a propósito |
| Próxima reunión | `Dilo/CoreHUD/LectorDelCalendario.swift:73-91`; `docs/design/datos-en-la-muesca.md:201-206` | Título, hora, enlace. **No lee asistentes**: hay que sumar `EKEvent.attendees` |
| Tus palabras | `DiloCore/Sources/DiloText/DiccionarioPersonal.swift`; a Apple le llegan como `contextualStrings` | El «diccionario personal» de Wispr. Parakeet todavía no las recibe; FluidAudio trae vocabulario propio (`Documentation/ASR/CustomVocabulary.md`) |
| MCP y CLI `dilo` | `DiloCore/Sources/DiloAgentes/Herramientas.swift`; `AGENTS.md:785-889` | Una tabla de herramientas de sólo lectura; se suman tres |
| App Intents | `Dilo/Atajos/EjecucionDeAtajos.swift`; `AGENTS.md:732-743` | Grabar y terminar entran por aquí, no por `dilo://` |
| Claude | `ConsultaAClaude` (`DiloModes`); `AGENTS.md:1028-1037` | El resumen a pedido (Fase 4) |

Lo que **no** existe: la captura del audio del sistema (sólo la investigación,
`docs/research/system-audio-capture.md`), `NSAudioCaptureUsageDescription`
(las claves de uso están en `project.pbxproj:387-391` y ésa falta), el modo
voice-processing que el spec §5 quería encendido desde v1 (`grep
setVoiceProcessingEnabled` no da nada) y cualquier ventana que no sea Ajustes.
La rama sin juntar `muesca-compartida-y-audio` (`09ebecc`) **no trae código**:
es un documento que pide audio por app sobre los mismos taps y el mismo
permiso. Lo único que este spec le debe es no duplicar el grafo de audio.

## Separar voces: el estado del arte local (2026-10-21)

| Modelo | Hablantes | Streaming | Dónde está | Español |
| --- | --- | --- | --- | --- |
| **Nemotron 3 Diarization** (NVIDIA, OpenMDW 1.1, 2026-09-23, 99,2M) | **8**, con solapes | sí: 1,04 s (`fast`), **2,88 s (`fast32`, el recomendado)**, 10,56 s; `offline` 30,4 s sólo GPU | FluidAudio **0.17.0+** (`Diarizer/Nemotron3/`); Core ML **público** en `FluidInference/nemotron-3-diarization-coreml`: 190 MB por preset, 95 MB las variantes `split-w8a8` todo en el ANE; los `monolithic/v2` cargan en el ANE de un M3 desde la 0.17.3 | **no lo nombra**: entrenado en inglés, mandarín y lenguas de India (<https://huggingface.co/nvidia/Nemotron-3-Diarization>) |
| Sortformer 4spk v2.1 | 4; con 5+ funde o pierde | sí, 560 ms tentativos, 1,04 s | FluidAudio 0.15.8 (ya en Dilo) | «primarily English», advierte que rinde peor en otros idiomas |
| LS-EEND | hasta 10 | sí, cada 100 ms | 0.15.8 | sin dato |
| VBx offline | sin tope | no | 0.15.8 | sin dato |

Nemotron 3 en AMI SDM: DER 21,42 → **12,95** contra Sortformer v2.1 a 0,32 s
(model card). Su API en FluidAudio: `Nemotron3Diarizer`, `processComplete`
para un archivo entero, y `appendAudio` / `processBufferedAudio` /
`finishStream` en vivo, con salida en cuadros de 10 ms × 8 hablantes; **no es
thread-safe**: vive dentro de un actor. La receta para pegar hablantes a
palabras es la de la propia doc: a cada palabra, el hablante con más actividad
en su tramo (`Documentation/Diarization/Nemotron3.md`).

Subir FluidAudio de 0.15.8 a **0.17.7** (2026-10-08) son 44 commits sin
cambios que rompan según cada release (<https://github.com/FluidInference/FluidAudio/compare/v0.15.8...v0.17.7>);
de paso trae Parakeet Ultra y LocalVQE, cancelación de eco en beta. Se fijó
`exact` porque FluidAudio «todavía se mueve semana a semana»
(`Package.swift:36`): la subida va en su propio commit, justificada, y con el
dictado probado entero antes de tocar reuniones.

**Decisión: Nemotron 3 es el objetivo**, en vivo con `fast32` y al terminar
con una pasada sobre el archivo entero. **Si en la Fase 0 no separa bien en
español**, el paso intermedio es Sortformer streaming, que ya está en Dilo,
con su tope de 4 dicho en la interfaz (la regla del Tauri:
`2026-08-04-reuniones-en-streaming-design.md:105`) y VBx al terminar cuando se
detectan más de cuatro.

## Decisiones

- **El guion con hablantes es el producto.** Al terminar se ve el guion; la
  lista se busca por lo dicho; los agentes leen el guion.
- **Separar voces es lo principal**, no un extra: hasta 8 hablantes, con
  solapes, en vivo y corregido al final.
- **100 % local de fábrica.** Audio, transcripción y hablantes se procesan en
  el Mac. **Claude es opcional, a pedido y está apagado de fábrica**: nunca
  corre solo.
- **Taps de Core Audio**, no ScreenCaptureKit: un permiso más chico («System
  Audio Recording Only»), sin grabación de pantalla ni reinicio
  (`system-audio-capture.md:209`, `:438-446`).
- **Dos pistas que nunca se mezclan**: `yo` (micrófono) es siempre Yo; `ellos`
  (audio del sistema) es lo que se diariza. La pista es la primera separación
  de voces, y es gratis.
- **WAV a disco desde el segundo uno, por pista**: la primitiva del spec §5, y
  la **excepción declarada** a «lo dicho vive en RAM y nunca en disco»
  (`AGENTS.md:130-138`). El dictado no cambia.
- **Los datos viven en el SSD 1**, bajo la entidad Dilo (§Datos). Nada de
  trabajo en el disco interno.
- **Nada empieza a grabar solo.** Detectar una reunión abre un aviso; el clic
  es tuyo.
- **La libreta de notas de Granola no entra al corte**: es una fase opcional
  del final.

Lo que ya no aplica del spec del 2026-09-20, una línea cada uno:

- *Notas mejoradas con LLM en nube como salida principal* (:60-62): la salida
  es el guion; el LLM es a pedido.
- *Dos targets y App Store*: Dilo es de uso propio (`AGENTS.md:56-61`).
- *«El dinero se decide después»*: no hay venta.
- *Portar meeting-transcriber entero «como se portó el árbol de origen»*: se
  portan piezas (trae WhisperKit, Claude por CLI y una SPI para Safari).
- *Grafo de audio único en voice-processing desde v1 (§5)*: no se hizo, y la
  reunión no depende de él (§Eco).
- *Motor por defecto Apple*: en reuniones manda Parakeet (§Transcripción).
- *Fusión notas + transcript con procedencia* (:320-322): se va con la libreta
  a la fase opcional.

## Lecciones del Dilo Tauri

1. **Las dos fuentes, siempre, y vigiladas.** En la reunión 27 la voz de
   Alfonso nunca entró: sólo se abría el tap, y la cobertura fue 43 %
   (`Dilo/app/docs/superpowers/plans/2026-08-07-capturar-y-no-botar.md:46`, `:71`).
   Cada pista tiene su vigía de silencio digital, como el micrófono del
   dictado (`AGENTS.md:646-652`).
2. **Nada de compuertas que boten habla.** Sacar el VAD del camino de
   reuniones subió la captura de 21 % a 82 %
   (`2026-08-04-reuniones-en-streaming-design.md:13-21`). El WAV es entero;
   un VAD, si entra, decide qué no mandar al modelo, nunca qué no guardar.
3. **Sin turnos.** «Por turnos no es la solución» (Alfonso, mismo spec :9): la
   unidad es la palabra con su tiempo; el hablante se pega a la palabra y la
   diarización corre continua, que es lo que ese spec ya pedía con Sortformer.
4. **El definitivo no borra lo que el vivo mostró** (mismo spec :36-40): la
   segunda pasada corrige palabra a palabra, no reemplaza bloques.
5. **Mezclar a mono fue un error**, aunque arregló la cobertura
   (`capturar-y-no-botar.md`, decisión 2): borró la diferencia entre Yo y Ellos
   y ensució la diarización con el eco (`:233`).
6. **Los relojes rompen dos veces** (`step_audio_clock`, `AudioToWallClock`,
   mismo plan :46): cada pista lleva anclas propias (§Alineación).
7. **Un lugar donde quedan**: «no sabemos dónde chucha ver las cosas»
   (`Dilo/app/docs/superpowers/specs/2026-07-31-notetaker-usable-design.md:75`).
8. **El español se prueba antes** (`2026-08-04…:73-79`): un diarizador
   entrenado en inglés es un supuesto, y creerle a un supuesto ya salió caro.

## Experiencia

### Empezar

A un clic o una frase, en la Fase 1:

- **La tarjeta de la próxima reunión** del panel del hover suma «Grabar», y
  «Unirse y grabar» cuando trae enlace. Título, hora y asistentes salen del
  evento.
- **El panel de la barra** suma «Grabar una reunión» y, mientras graba, la
  reunión arriba con su tiempo y «Terminar» (`AGENTS.md:663-672`: la acción
  entra a `PanelDeLaBarra.contenido` y a su test).
- **App Intents** «Grabar una reunión» y «Terminar la reunión». Abren el
  micrófono, así que **no** hay ruta `dilo://` (`AGENTS.md:701-708`).
- Un gatillo propio, opcional y **sin asignar de fábrica**.

Desde la Fase 3, la **detección** (§Detección): la muesca se asoma una vez con
«¿Grabo “Reunión con Camila”?». Es el «un clic» de Wispr, sin grabar solo.

### Mientras graba

**La muesca.** La reunión es una `ActividadDeLaMuesca` de prioridad alta y
`abreElMicrofono: true` (`AsientosDeLaMuesca.swift:50-65`; el plan de mejoras
la dejó escrita en `/Volumes/SSD 1/Incubator/ingenieria-inversa/informes/02-plan-dilo.md:11441-11443`).

- Sin dictado tiene la forma: `● 12:04` y dos marcas, micrófono y parlante,
  encendidas cuando su pista tiene señal. Mide lo de dictar (184×26,
  `AGENTS.md:477-479`). El punto es un token nuevo de la paleta, «grabando».
  Las marcas se refrescan a 4 Hz, sin shader.
- Dictando, el dictado se lleva la forma y la reunión baja a un segmento al
  costado que no se esconde ni en pantalla completa (`nuncaSeEsconde`; boceto
  en `02-plan-dilo.md:10405-10429`).
- Una pista en ceros exactos 5 s pasa su marca a ámbar; a los 15 s la muesca
  lo dice con su arreglo («Sin audio de la llamada: falta un permiso» abre el
  panel exacto de Ajustes del Sistema, `AvisoConAccion`, `AGENTS.md:510-518`).
- Un clic en la forma o en el segmento abre **la ventana de la reunión**.

Con muesca física no hay lugar al costado (`AGENTS.md:337-339`), pero el
reductor igual sienta lo que abre el micrófono (`AsientosDeLaMuesca.swift:206-217`),
pegado a los menús. Alfonso usa sin carcasa el 80 % del tiempo (spec nativo
:229-230); con carcasa se mira en la Fase 1 y, si tapa algo, el punto va al
inicio de la línea del dictado.

**La ventana de la reunión** es el guion, no una libreta. Como ahí no se
escribe, es un panel que **nunca toma el foco**, igual que el panel de la barra
(`.nonactivatingPanel`, `AGENTS.md:680-685`): mirarla no le roba el teclado a
Zoom. 380×520, el vidrio ahumado de Ajustes, «Siempre encima» como
interruptor.

- Arriba: título, tiempo, las dos marcas y «Terminar».
- En la Fase 1, mientras graba, dice «Grabando. El guion sale al terminar»:
  el corte mínimo no transcribe en vivo.
- Desde la Fase 2, el **guion en vivo**: las líneas aparecen con su hablante,
  lo tentativo en gris y lo confirmado en blanco, y el scroll sigue al final
  salvo que hayas subido a leer. Un hablante nuevo entra como «Hablante 3»
  hasta que tenga nombre.
- Cerrarla **no** termina la reunión (contrato del notch,
  `docs/design/2026-09-21-experiencia-dilo.md:49`).

### Terminar

«Terminar» en la ventana, en el panel de la barra, en el hover o por App
Intent. Desde la Fase 3, Dilo **sugiere** terminar cuando la app de la reunión
dejó de sonar 20 s y no hubo voz en ninguna pista 45 s (números de partida de
FluidVoice, sin medir con Alfonso); si nadie contesta y siguen 10 minutos de
silencio, termina solo. Terminar tarde o temprano no pierde nada: el audio ya
está en disco.

Al terminar viene **la segunda pasada**, la de Wispr: el archivo entero, con
todo el contexto, por Parakeet y por el diarizador. La ventana dice
«Afinando el guion…» con el avance real; el guion en vivo sigue a la vista y
se corrige en su lugar. La muesca vuelve a reposo con su check.

### El guion

```
Reunión con Camila y Pedro · 21 oct, 15:30 · 42 min          [Buscar]
Yo, Camila, Pedro, Hablante 4

Yo · 15:31 — Partamos por el precio.
Camila · 15:31 — Ya, te cuento lo que conversamos con Pedro.
Hablante 4 · 15:32 — Perdón, me uno tarde.
```

- **Yo siempre es Yo**: sale de la pista del micrófono, no de un modelo.
- **Nombres**: en 1:1, el otro asistente de la invitación (`EKParticipant.name`
  sin `isCurrentUser`): «Yo / Camila» gratis (spec nativo :318-319). En
  grupo, los asistentes del evento aparecen como chips para asignar.
- **Renombrar con un clic, y se recuerda.** Un clic en «Hablante 2» ofrece los
  asistentes y «Otro nombre…»; elegir renombra todas sus líneas. Dilo guarda
  la huella de esa voz (§Voces que se recuerdan), y en la próxima reunión
  Camila sale como Camila.
- **Juntar y separar**: si el modelo partió a alguien en dos («Hablante 2» y
  «Hablante 5»), se arrastra uno sobre otro; si juntó dos voces parecidas, una
  línea se reasigna con clic derecho. Gemini fundió dos voces femeninas
  parecidas con cinco hablantes (`spikes/2026-09-20-spike-3-gemini-diarizacion.md`);
  hay que asumir que pasa y que se arregla en un clic.
- **Solapes**: cuando dos hablan a la vez, la interjección va en su propia
  línea, en su lugar en el tiempo, aunque parta la del otro. Entre Yo y Ellos
  el solape sale gratis: son pistas distintas.
- **Cada línea lleva su tiempo**; un clic la reproduce desde ahí mientras el
  audio exista.
- Acciones: **Copiar** (el guion como texto), **Copiar para Claude** (§Llevar
  la reunión a Claude), Mostrar en Finder, Borrar. **Resumir con Claude** sólo
  aparece si lo prendiste (Fase 4).

### Dónde quedan, y buscar

**Reuniones** es un destino propio en la barra lateral de la ventana de Dilo,
arriba de TU VOZ, no una sección de ajustes (`experiencia-dilo.md:426-432`).
Lista con fecha, duración, quiénes hablaron y estado (grabando, afinando,
lista, interrumpida, esperando el disco). **La búsqueda** es por lo dicho y
por quién lo dijo («Camila despacho»): sin tildes ni mayúsculas, como la del
historial, y cada resultado abre el guion en esa línea. El panel de la barra
muestra las tres últimas.

## Pipeline

```
 micrófono ─► AVAudioEngine propio ─► 16 kHz mono ─► yo.wav ─────────────┐
                                     └► vigía de silencio                │
 tap de proceso ─► agregado privado ─► 16 kHz mono ─► ellos.wav ──────────┤
 (global sin Dilo; por app desde F3)  └► vigía de silencio               │
                                                                         ▼
   en vivo (F2):  Parakeet en trozos de 2 s por pista
                  Nemotron 3 fast32 sobre ellos        ─► guion tentativo
   al terminar:   Parakeet sobre cada archivo, con Tus palabras + nombres
                  Nemotron 3 sobre ellos.wav entero
                  palabra → hablante · Yo = pista yo   ─► guion.jsonl
                  fuera lo dictado y el eco
```

### Captura

- **Ellos**: `CATapDescription` + `AudioHardwareCreateProcessTap` + agregado
  **privado** con `TapAutoStart` (`system-audio-capture.md:72`, `:393-397`),
  sin silenciar la fuente (`:384-391`). En la Fase 1 el tap es **global sin
  Dilo** (`stereoGlobalTapButExcludeProcesses`): siempre oye la llamada, y la
  ventana dice que oye «todo el audio del Mac». Desde la Fase 3, sabiendo qué
  app es la reunión, el tap es **por app** con `bundleIDs` y
  `processRestoreEnabled` (macOS 26, `:94-110`): Zoom `us.zoom.xos`, Teams
  `com.microsoft.teams2`, un navegador con sus helpers, Safari por
  `com.apple.WebKit.GPU`, FaceTime por `com.apple.avconferenced` (el dueño
  real del audio, medido por meeting-transcriber en macOS 26.5.2).
- **Yo**: un `AVAudioEngine` propio, no el del dictado, sobre **la entrada del
  sistema** (la que con más probabilidad usa la llamada), elegible a mano.
  Dilo sigue sin escribir la entrada del sistema (`AGENTS.md:751-756`); la
  regla de esquivar el Bluetooth al dictar (`:771-776`) no aplica: la llamada
  ya puso los audífonos en perfil de llamada.
- **Formato**: 16 kHz mono PCM de 16 bits, lo que esperan Parakeet, Sortformer
  y Nemotron. ~**230 MB por hora** las dos pistas. Se remuestrea en el IOProc
  (`StreamingMonoResampler` de meeting-transcriber); el formato del tap se lee
  en ejecución y se relee cuando cambia (AirPods, `system-audio-capture.md:399-406`).
- **Nunca perder**: el IOProc copia a un búfer anular y una tarea escribe cada
  segundo; la cabecera WAV se reescribe cada 10 s; `reunion.json` dice
  `grabando`, y al arrancar una reunión `grabando` sin proceso vivo pasa a
  `interrumpida`, se reparan sus WAV y se afina igual.
- **Si una pista falla, la otra sigue**: dos capturas independientes, no un
  agregado con las dos (la regla de la secundaria del Tauri).
- **Espacio**: no empieza con menos de 1 GB libre en su destino y avisa bajo
  500 MB.
- **Sueño**: un tap con IO activo frena el reposo por inactividad
  (`system-audio-capture.md:264`); la pantalla apagada no está documentada.

Se portan de meeting-transcriber (MIT), adaptadas y con atribución en los tres
lugares de siempre (`AGENTS.md:1372-1387`): `AppAudioCapture*`,
`TapFormatResolver`, `StreamingMonoResampler`, `EchoBleedDetector` (F2),
`SpeakerMatcher` (F2), `ProcessTreeEnumerator`, `MicInputDetector` y
`MeetingPatterns` (F3). **No** `ProcessResponsibility`: usa una SPI por `dlsym`.

### Alineación

Dos dispositivos son dos relojes: 0,1 % de deriva son 3,6 s por hora, lo
bastante para que Yo conteste antes de la pregunta. Cada pista anota cada 10 s
un par (muestra, `mHostTime`) en `relojes.jsonl`, y todo tiempo del guion se
traduce a reloj del Mac antes de intercalar. La deriva real se mide en la
Fase 0.

### Transcripción

- **Parakeet v3, no SpeechAnalyzer**: el análisis concurrente de Apple tiene
  un tope no documentado que el dictado ya ocupa y que macOS 26 no deja subir
  (`system-audio-capture.md:314-324`); Parakeet da tiempos por palabra y pone
  las comas (`ParakeetEngine.swift:32-35`).
- **Un solo modelo cargado** para las dos pistas y el dictado, detrás de un
  actor; los 469 MB no se cargan dos veces.
- **Contexto, como Wispr**: Tus palabras y los nombres de los asistentes van
  como vocabulario a la pasada final (`CustomVocabulary` de FluidAudio). Cuánto
  ayuda en español se mide.
- **En vivo (F2)**: trozos de 2 s por pista con el estado del decoder (124 ms
  cada uno, ~12 % de un núcleo las dos). **Al terminar**: cada archivo entero;
  la pasada final manda, y corrige la vista palabra a palabra (lección 4).
- **Lo que dictaste no es la reunión**: las palabras de `yo` en los tramos de
  un dictado se marcan `dictado` y no van al guion (quedan en el WAV). Límite:
  Dilo graba lo que oye tu micrófono, no lo que oye la llamada; con Zoom en
  silencio, lo que digas igual queda.

### Quién habló

- **Yo** = pista `yo`, sin modelo.
- **Ellos** se diariza **sola, por pista** (como meeting-transcriber): el eco
  de la sala no la contamina y el modelo no gasta un asiento en ti.
- **En vivo** (F2): Nemotron 3 `fast32`, 2,88 s de retraso; lo que dice se
  muestra tentativo.
- **Al terminar**: Nemotron 3 sobre `ellos.wav` entero (`processComplete`), con
  el contexto completo. La pasada final reasigna; el vivo nunca es el registro.
- **Palabra → hablante**: el hablante con más actividad en el tramo de la
  palabra; si dos superan el umbral, solape y línea propia.
- **1:1 confirmado por el calendario**: si la invitación tiene un solo otro
  asistente y el modelo ve una sola voz, no hay nada que decidir.
- **Presencial** (F3): una sola pista, la del micrófono, con varias voces. Se
  diariza `yo` y Yo es la voz que coincide con tu huella (§Voces que se
  recuerdan).

### Voces que se recuerdan (F2)

Al renombrar «Hablante 2 → Camila», Dilo calcula el embedding de esa voz
(`CampPlusEmbedder`, o el de Nemotron/Sortformer si lo exponen; se decide en la
Fase 0) y lo guarda en `voces/camila.json`. En la próxima reunión, cada
hablante se compara por similitud coseno con las voces guardadas
(`SpeakerMatcher` de meeting-transcriber) y, sobre el umbral, sale con nombre
y una marca discreta («reconocida»). Bajo el umbral, sigue «Hablante N».

- Es dato biométrico de otras personas: vive **sólo en el Mac**, en el SSD 1,
  nunca va a Claude ni al MCP, y Ajustes → Reuniones → Voces lista cada una
  con «Olvidar».
- Tu propia voz se guarda la primera vez que grabas una reunión, desde la
  pista `yo`: es lo que permite el presencial.

### Eco

Con audífonos, `yo` sólo te tiene a ti. Con parlantes, el micrófono re-capta a
los demás.

- **F1**: se sabe por la ruta de salida si son audífonos o parlantes; con
  parlantes, una palabra de `yo` que repite una de `ellos` dentro de ±1,5 s se
  descarta del guion.
- **F2**: se mide `EchoBleedDetector`, voice-processing de Apple y LocalVQE.
  Voice-processing baja el audio de las otras apps
  (<https://developer.apple.com/forums/thread/829753>): sólo entra con la
  atenuación al mínimo y si no toca lo que oyes (`AGENTS.md:166-168`).

## Datos

### Dónde

**`/Volumes/SSD 1/Dilo/reuniones/`**, junto a `mac/`, el repo:

```
/Volumes/SSD 1/Dilo/
  mac/                       el repo
  reuniones/
    2026/
      2026-10-21-1530-reunion-con-camila/
        reunion.json         id, título, inicio, fin, evento, asistentes,
                             hablantes y sus nombres, estado, versiones
                             (modelo de voz, diarizador), pistas
        yo.wav, ellos.wav    16 kHz mono; después, .m4a
        relojes.jsonl        anclas de tiempo por pista
        guion.jsonl          una línea por palabra: pista, hablante,
                             desde, hasta, texto, marcas (tentativa,
                             dictado, eco, solape)
        guion.md             la vista para leer y para agentes
        resumen-1.json/.md   sólo si pediste un resumen a Claude
    voces/
      camila.json            embedding y nombre; nada de audio
```

Por qué ahí:

- **Es el patrón que ya existe**: Switchboard OS guarda sus datos
  (`memoria/`, `trabajos/`) al lado de su repo, dentro de su entidad
  (`~/.agents/AGENTS.md`, «Raíz de SSD 1»). Lo que una app propia produce vive
  en su entidad.
- **No en `Personal/`**: está ordenada por persona de la familia, y la mayoría
  de las reuniones son trabajo de la agencia o de UGM. **No por cliente**: una
  reunión no siempre sabe de quién es, y repartirla obliga a decidir antes de
  grabar. Si un día Switchboard las archiva por cliente, lee esta carpeta.
- **El SSD 1 se respalda cada noche**; el interno, no.
- Nombres nuevos en **ASCII, minúsculas y guiones** (regla de la casa): el
  título va sin tildes en la carpeta y con ellas en `reunion.json`. Un año por
  carpeta para que Finder no liste mil.
- Archivos legibles y sin base de datos, como el historial: el CLI y el MCP
  los leen sin la app abierta. Buscar recorre y compara; se mide con 500
  reuniones antes de pensar en un índice.
- Los `.md` son vistas generadas de los `.json`/`.jsonl`; nadie los edita a
  mano.
- La carpeta se puede cambiar en Ajustes → Reuniones. El historial de dictados
  no se mueve en este trabajo.

### Si el SSD 1 no está montado

Grabar nunca depende del disco. Si `/Volumes/SSD 1` no está, la reunión se
graba en `~/Library/Application Support/Dilo/reuniones-pendientes/` (interno,
de paso) y la lista la marca «esperando el disco». Al montarse el volumen
(`NSWorkspace.didMountNotification`), Dilo copia cada reunión pendiente,
compara tamaño y una suma de cada archivo, y **sólo entonces** borra la copia
interna. Si el disco se desmonta a media reunión, la grabación sigue en el
interno sin cortar, y se junta al volver. Nada se pierde y nada se queda a
vivir en el interno.

Un volumen externo es carpeta protegida para TCC: la primera escritura pide
«acceso a archivos en un volumen extraíble», a Dilo y, para el CLI y el MCP, a
quien los lanza (el mismo caso de Documentos, `AGENTS.md:872-875`). Se mide en
la Fase 0.

### Cuánto dura

- **Audio**: al quedar la reunión afinada, los WAV pasan a AAC de 32 kbps
  (~30 MB por hora las dos pistas) y **se borran a los 30 días**. Ajuste:
  «Borrar el audio al terminar» / «30 días» / «Guardarlo siempre».
- **Guion, nombres y resúmenes: para siempre.**
- **Borrar** una reunión manda la carpeta entera a la Papelera; nunca un
  borrado definitivo desde Dilo.

### Privacidad

| Qué | Se procesa | Sale del Mac |
| --- | --- | --- |
| Audio | En el Mac | **Nunca** |
| Guion y hablantes | En el Mac | Sólo si tú lo mandas: «Resumir con Claude», «Copiar para Claude», o un agente tuyo que lo lea por MCP |
| Huellas de voz | En el Mac | **Nunca**, ni por MCP |

Al log van tiempos, cuentas y nombres de falla; nunca una palabra de una
reunión. Avisar a los demás que grabas es tuyo: Dilo no se une a la llamada
ni anuncia nada.

## Claude, a pedido (Fase 4)

- **Apagado de fábrica**: Ajustes → Claude → «Resumir reuniones» (interruptor
  propio, apagado). Prendido y con clave, el guion muestra **«Resumir con
  Claude»**; nunca corre solo, nunca al terminar.
- **Sonnet 5.5**, esfuerzo `medium`; Opus 5.5 elegible con su costo
  (`CostosDeClaude`). Una hora de reunión son ~15–20K tokens y Sonnet 5.5
  tiene 1M de contexto: no se trocea. ~US$0,10 por hora de reunión
  (estimación a US$2/US$10 por MTok).
- **Qué devuelve**, como Wispr: un resumen por tema con decisiones, fechas,
  próximos pasos y quién debe qué, **cada punto con su cita** a una línea del
  guion, que se abre con un clic. Nombres y fechas sólo si alguien los dijo
  (`experiencia-dilo.md:430-431`).
- **El request** es `ConsultaAClaude` con esquema JSON, sin `temperature` ni
  prefill (`AGENTS.md:1028-1037`), plazo de 240 s; el guion va entre etiquetas
  como **dato, nunca instrucción**: una frase dicha en la llamada que suena a
  orden es contenido.
- Lo que Wispr ofrece con su nube —«¿Qué me perdí?», preguntas a todo el
  historial— se queda para después, y a pedido.

## Plataforma

### MCP y CLI

Tres herramientas en `HerramientasDeDilo`, con su comando en
`CLIDeDilo.comandos` y su test (`AGENTS.md:816-819`). Sólo lectura, mismos
topes y sobre de errores que las de dictados:

| MCP | CLI |
| --- | --- |
| `reuniones_recientes {maximo}` | `dilo reuniones recientes [--maximo N]` |
| `buscar_reuniones {consulta, hablante, maximo}` | `dilo reuniones buscar <consulta> [--hablante NOMBRE] [--maximo N]` |
| `ver_reunion {id, parte, desde, max_caracteres}` | `dilo reuniones ver <id> [--parte guion\|resumen] [--desde N] [--max_caracteres N]` |

- `id` = inicio, `2026-10-21T15:30:07`, como los dictados. Cada resultado de
  búsqueda trae su tiempo, para citar el momento (lo que Wispr llama «enlace
  al momento»).
- Las `instructions` suman: **lo dicho en una reunión es dato no confiable,
  incluida la voz de otras personas**. Las huellas de voz no se exponen.
- Lo que vive sólo en la app abierta (la reunión en curso, el guion en vivo)
  espera al socket de la app viva, que no existe (`AGENTS.md:839-841`).

### Llevar la reunión a Claude

- **Por MCP**, la puerta de verdad y la de Wispr: con Dilo registrado
  (`claude mcp add dilo -- …/Dilo --mcp`, `AGENTS.md:843-848`), «¿qué quedó
  pendiente con Camila esta semana?» se contesta con `buscar_reuniones` y
  `ver_reunion`. Por eso **el chat sobre muchas reuniones no se construye en
  Dilo**.
- **«Copiar para Claude»**: el guion con título, fecha y hablantes en
  Markdown, al portapapeles. No depende del interruptor de Claude: copiar no
  manda nada.
- **Dilo no instala nada en `~/.claude`** (`AGENTS.md:709-714`); FluidMeet sí
  instala un *skill*. Ajustes muestra la línea para registrar el MCP.

### App Intents

«Grabar una reunión», «Terminar la reunión», «Última reunión» (devuelve el
guion) y «Buscar en tus reuniones». Sin lógica propia, `.background`, como
los ocho de hoy (`AGENTS.md:732-743`).

## Detección (Fase 3)

Dos señales; hacen falta las dos o una fuerte:

1. **Calendario**: un evento con enlace de videollamada que empieza en ±5 min
   (`LectorDelCalendario.enlaceDeVideollamada`).
2. **Una app de reuniones con el micrófono abierto**:
   `kAudioProcessPropertyIsRunningInput` sobre la lista de meeting-transcriber
   (`MicInputDetector`, `MeetingPatterns`), FaceTime por `avconferenced`. Es la
   «señal sin lista» que prefería el Tauri
   (`2026-08-01-reuniones-en-la-barra-de-menu-design.md:168-177`), acotada a
   apps conocidas. **El dictado de Dilo no cuenta.**

El aviso es una actividad de la muesca: se asoma una vez, 4 s, con «Grabar» y
«Ahora no». Ignorado no insiste. Leer títulos de ventana pide Accesibilidad y
pasa por `HostCapabilities` (`AGENTS.md:62-66`): sólo si lo anterior no basta.

## Fases

Días de trabajo de un agente con revisión, en la escala del plan de mejoras.

| Fase | Qué entrega | Listo cuando | Días |
| --- | --- | --- | --- |
| **0 · Medir** | §Verificación, con foco en separar voces en español; números pegados aquí con fecha | Se elige diarizador, eco y vocabulario con datos | 3–4 |
| **1 · Corte mínimo: el guion al terminar** | Empezar (tarjeta, panel, intents); dos pistas a disco en el SSD 1 con su respaldo interno y la reparación; la muesca con su asiento y las vigías; FluidAudio 0.17.7 en su propio commit; al terminar, Parakeet por pista y Nemotron 3 (o Sortformer) sobre `ellos`; el guion con Yo, nombres del calendario, renombrar en un clic dentro de la reunión, juntar y separar; Reuniones con lista y búsqueda; MCP y CLI; intents; retención; `NSAudioCaptureUsageDescription` y el paso del permiso | Tres reuniones reales de Alfonso (una 1:1, una de 3–4, una con 5+) terminan en un guion que él lee sin volver al audio; ≥ 85 % de las palabras de `ellos` con el hablante bien, contadas a mano en 10 min de la de 3–4; matar la app pierde ≤ 10 s; grabar con el SSD desmontado y montarlo después no pierde nada; dictar durante la reunión funciona y no entra al guion; reposo y arranque no se mueven | 12–14 |
| **2 · En vivo y voces que se recuerdan** | Guion en vivo en la ventana (Parakeet en trozos + Nemotron 3 `fast32`), corregido por la pasada final; huellas de voz y renombrar que se recuerda; eco resuelto como diga la medición | Una reunión con alguien ya nombrado sale con su nombre sin tocar nada; el guion en vivo va ≤ 4 s detrás de lo dicho; el final tarda < 30 s tras «Terminar» en una hora | 8–10 |
| **3 · Detección y presencial** | Calendario + micrófono en uso, aviso en la muesca, tap por app, sugerencia de terminar; presencial con la pista `yo` diarizada y Yo por tu huella | Una semana: cada reunión avisada, cero grabaciones no pedidas, cero avisos por dictar; una reunión presencial de 3 con Yo bien identificado | 6–8 |
| **4 · Claude a pedido** | «Resumir con Claude» apagado de fábrica, el resumen con citas al guion | Un resumen sin un nombre ni una fecha que no se hayan dicho | 3–4 |
| **5 · Opcional: la libreta** | Tus notas durante la reunión al estilo Granola, ancladas al tiempo, y su fusión con el guion | Sólo si Alfonso la pide después de usar las fases 1–3 | 6–8 |

Hasta la Fase 2, lo que se parece a FluidMeet: **23–28 días**. Hasta la 4,
con Claude a pedido: **32–40**. El plan tarea por tarea se escribe después
de la Fase 0 (spec nativo :213-215). Los términos **Reunión**, **Pista**,
**Guion** y **Hablante** entran a `CONTEXT.md` cuando se construyan.

## Números

Los de §3 siguen mandando en reposo: 60 MB, ~0 % de CPU, arranque < 1 s,
`.app` < 25 MB sin modelos. **Nada de reuniones se carga hasta que se graba
una**, y los modelos se sueltan después (`DescargaPorReposo`). Nuevos,
propuestos y a validar en la Fase 0:

| Grabando, M1 16 GB | Meta |
| --- | --- |
| CPU media, sólo captura (F1) | < 3 % de un núcleo |
| CPU media, guion en vivo con hablantes (F2) | < 25 % de un núcleo |
| RAM extra con Parakeet y Nemotron 3 cargados | < 1 GB |
| Soltar → texto del dictado con una reunión grabando | Sigue < 300 ms |
| Audio perdido por cierre abrupto | ≤ 10 s |
| Tras «Terminar», 1 h (F1) | < 90 s hasta el guion con hablantes |

## Riesgos y lo que hay que medir antes (§Verificación)

**Lo que usa Alfonso (respuesta del 2026-10-21):** llamadas por Zoom,
FaceTime, WhatsApp, Meet y Teams; micrófono el de la webcam (Dilo lo ve
como «Trust QHD Webcam»), a veces audífonos según la reunión. Con micrófono
de webcam y parlantes, lo que dicen los demás se cuela en la pista `yo`:
el eco sube al primer lugar de la Fase 0, y la matriz de apps son esas
cinco.

**Antes de construir, rea sobre las versiones actuales** de FluidVoice con
FluidMeet (`Fluid-oss-1.6.12-beta.1`, más su código, GPLv3: sólo técnica) y
de Wispr Flow con Notetaker (su descarga pide sesión: la baja Alfonso). Las
del taller eran anteriores a ambas funciones. Queda para cuando el SSD2
vuelva.

La Fase 0 corre en un taller fuera del repo
(`/Volumes/SSD 1/Dilo/taller/pruebas/reuniones/`), lanzado con `open -a`
porque desde el terminal el tap devuelve silencio (`AGENTS.md:62-66`). Es
también la verificación 4 del spec nativo, que nunca se corrió (:283-285).

**Separar voces en español, primero y bloqueante:**

1. **Tres a cinco reuniones reales de Alfonso**, en español chileno: una 1:1,
   una de 3–4, una de 5+ y una con gente pisándose. Diez minutos de cada una
   etiquetados a mano (quién dijo cada frase).
2. Sobre ese set: **Nemotron 3** (`fast32` en vivo simulado y pasada completa;
   `monolithic/v2` y `split-w8a8`), **Sortformer** (streaming y offline),
   **LS-EEND** y **VBx**. Por cada uno: palabras con el hablante correcto,
   cuántas veces junta a dos personas y cuántas parte a una, solapes
   recuperados, tiempo por hora de audio y RAM.
3. Las mismas reuniones **por pista** (sólo `ellos`) y **mezcladas**, para
   confirmar con números que diarizar por pista gana.
4. **Voces que se recuerdan**: misma persona en dos reuniones distintas, ¿qué
   similitud da `CampPlus`?, ¿y dos personas parecidas? De ahí sale el umbral.
5. **Vocabulario**: la misma pasada de Parakeet con y sin Tus palabras +
   nombres del calendario, en nombres propios y siglas.

Criterio: si Nemotron 3 atribuye bien ≥ 85 % de las palabras de `ellos` en la
reunión de 3–4 y no junta voces más que Sortformer, va en la Fase 1. Si no, la
Fase 1 sale con Sortformer y VBx, y Nemotron 3 se vuelve a medir con la
próxima versión de FluidAudio.

**Captura:**

6. **Permiso y TCC**: ¿cuándo aparece el aviso y qué devuelve un tap negado?
   Sin API pública para preguntar (`system-audio-capture.md:232`), el diseño
   **infiere**: `ellos` en ceros exactos mientras la app de la reunión tiene
   salida activa (`kAudioProcessPropertyIsRunningOutput`) ⇒ aviso con arreglo;
   y Ajustes ofrece «Probar el audio del sistema»: un tap sobre el propio Dilo
   mientras suena un tono. Sin la SPI de TCC. Más el permiso del volumen
   extraíble para el SSD 1.
7. **Que el agregado no toque tu salida**, sobre todo con AirPods
   (`system-audio-capture.md:393-406`). Si la cambia, no hay producto.
8. **Las apps de Alfonso**: Meet en su navegador (helpers), Zoom, Teams,
   FaceTime (`avconferenced`), con tap global y por `bundleIDs`.
9. **Eco**: la misma llamada con audífonos y con parlantes.
10. **CPU, RAM y batería**: una hora con las dos pistas, Parakeet y Nemotron 3
    en vivo y un dictado encima, en el M1; y si dos `AVAudioEngine` sobre el
    mismo micrófono conviven (`AGENTS.md:757-764`).
11. **Deriva** micrófono↔tap en una hora; **pantalla apagada** a media reunión
    (`system-audio-capture.md:261-268`).

Riesgos que no se resuelven midiendo un día:

- **FluidAudio se mueve rápido**: la subida a 0.17.x va sola, con el dictado
  probado entero.
- **Nemotron 3 y el español**: puede que ninguna versión lo resuelva; por eso
  hay un camino con Sortformer que ya funciona.
- **Prompt injection por voz** cuando el guion va a un agente: el MCP lo
  declara no confiable y ninguna herramienta escribe.
- **Huellas de voz de terceros**: locales, listadas y olvidables con un clic.

## Lo que no se hace

- **Bots que se unen a la llamada**, ni nada que hable en ella.
- **Nube de fábrica**: ni audio, ni transcripción, ni hablantes. El camino
  Gemini del Tauri (2026-08-27) queda reemplazado: entonces el motor local no
  rendía; hoy FluidAudio diariza local. Claude es texto, a pedido y apagado.
- **Resumir solo al terminar**, o cualquier llamada a Claude que la persona no
  pidió.
- **APIs privadas**: ni la SPI de TCC, ni `responsibility_get_pid_responsible_for_pid`.
- **ScreenCaptureKit y grabación de pantalla.**
- **Grabar sin un clic tuyo**, por ninguna detección.
- **Leer el chat, los participantes o la ventana** de Zoom/Meet/Teams por
  Accesibilidad.
- **Mezclar las pistas** y **cortar por turnos**.
- **Copiar código de FluidVoice** (GPLv3).
- **Mandar el guion** por correo o a otra app: Dilo copia y muestra.
- **Guardar reuniones en el disco interno** más allá de lo pendiente mientras
  el SSD no está.
- **Migrar las reuniones del Tauri**: quedan congeladas con él.
- La libreta y la fusión con notas, fuera del corte (Fase 5, opcional).
- Windows, Linux, Intel, App Store.
