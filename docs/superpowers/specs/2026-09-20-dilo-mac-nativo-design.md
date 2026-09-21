# Dilo — App nativa para Mac (dirección y v1: dictado que parece terminado)

**Fecha:** 2026-09-20 · **Estado:** dirección aprobada por Alfonso en conversación; **compuerta de entrada pendiente** (ver §Verificación) · **Base:** [2026-07-22 Plataforma conversacional abierta](2026-07-22-dilo-plataforma-conversacional-abierta.md), [2026-08-27 Reuniones en línea](2026-08-27-reuniones-en-linea-design.md), [2026-07-31 Conversación por voz](2026-07-31-conversacion-por-voz-design.md) · **Reemplaza:** la premisa "núcleo Rust intacto, nada de reescritura" del [rebrand](2026-07-12-dilo-rebrand-design.md)

## El problema

Dilo tiene 46.004 líneas de Rust; Handy tiene 28.992. De las 17.000 propias,
**13.000 son reuniones, diarización, captura de audio del sistema y TTS** — las
tres cosas que nunca rindieron (evaluación de Alfonso: "el motor de reuniones
es pobre"; "la parte hablada tampoco funcionó nunca bien"). En Tauri esas
piezas se cablearon a mano contra ONNX y `cpal`; en Mac nativo vienen hechas
y mantenidas por otros (SpeechAnalyzer, FluidAudio, taps de Core Audio,
`AVAudioEngine` con cancelación de eco).

Además, Handy (`upstream`) reescribió su historia: el merge-base cayó a
febrero de 2025 y `git cherry` da 295 commits propios contra 662 duplicados.
Ya no existe el "merge barato" que justificaba mantener el núcleo cerca de
upstream. Y macOS 27 impone Liquid Glass a toda app recompilada con Xcode 27;
una UI en WKWebView no lo hereda.

Tracción real a la fecha: 16 ⭐, ~70 descargas acumuladas. El cuello no es
la app: es que no parece un producto terminado.

## Lo que se midió antes de decidir (2026-09-20)

| Dato | Valor |
| --- | --- |
| Rust propio que no rinde | `meeting.rs` 6.485 + diarización 4.400 + `system_audio/macos.rs` 1.510 + TTS 1.850 líneas |
| Handy hoy | v0.9.7, 31.9k ⭐; resolvió solo el Dock (`launch as accessory`), audio de cola, micrófono real-time |
| SpeechAnalyzer (macOS 26+) | español, parciales en streaming, 0 MB, ~2× más rápido que Whisper turbo; sin diarización |
| FluidAudio (Swift, Apache 2.0) | Parakeet v3 batch, Silero, diarización streaming (Sortformer 4 / LS-EEND 10), PocketTTS en español. Streaming ASR sólo inglés |
| El árbol de origen (MIT, 554 ⭐, un autor, release semanal) | Swift 6, SpeechAnalyzer + FoundationModels, notch propio en `CoreHUD/`, pegado por AX/CGEvent/pasteboard, reducer testeable, ~11k líneas, única dependencia Sparkle |
| Yap (MIT) | dictado Mac con SpeechAnalyzer en ~3k líneas, 4 MB, 60 MB en reposo |
| Granola (referencia de notetaker) | transcript **Me/Them** (mic vs sistema), sin diarización en escritorio, **manda el audio a su proveedor**, no guarda audio, no acepta grabaciones |
| El campo "dictado + reuniones en Mac, local" (visto 2026-09-20) | **Aside** (heyaside.com, cerrado, un autor, macOS 26+, Whisper local, hablantes al terminar + nombres desde la invitación del calendario, notas en Markdown, servidor MCP, US$8/mes o US$79 de por vida) es la referencia de posicionamiento y diseño. Abiertos y **MIT**: **meeting-transcriber** (Swift 6.2, 178 ⭐, 1.782 commits, CI/E2E; detecta Teams/Zoom/Webex/Meet por título de ventana + uso del micrófono, `CATapDescription`, WhisperKit o Parakeet v3, diarización por pista con FluidAudio, español, macOS 14.2+), **Humla** (Tauri + sidecars Swift, 287 ⭐, **noruego-primero**: el mismo playbook que Dilo con el español; fusiona notas escritas + transcript con etiquetas de procedencia; FTS5 + embeddings para "pregúntale a tus notas"), **Hark** (Swift + Rust por UniFFI, Parakeet en ANE, MCP). **AGPL, solo mirar:** next-notes (Swift 6, SpeechAnalyzer por defecto + Parakeet, tarjeta en el notch y cápsula bajo la barra en otros monitores, panel no activante) |
| Sandbox App Store | bloquea la API de Accesibilidad hacia otras apps "sin importar lo concedido"; pegar (pasteboard + Cmd+V sintético) y atajos (`CGEventTap` + Input Monitoring) sí funcionan. Precedente: TypeMeIt, dos builds |
| Nube de voz | Gemini 3.8 Live ≈ US$0,01–0,02/min; OpenAI realtime 4–5×; Gemini 3.5 Transcribe US$0,005/min, diariza 8 |
| Jev (TypeSafe AI, Diogo Almeida ex-OpenAI, lanzado 2026-09-15) | modelo "System One": texto → decisión tipada (`choice` hasta 255 opciones, `score` 2–10 niveles, `noul` sí/no) con probabilidades calibradas; 70–500 ms; US$0,042/MTok entrada, salida gratis; **solo nube, solo texto, acceso anticipado con lista de espera, español sin confirmar**; REST `POST /v1/systemone`, SDKs Python/JS, no Swift |
| Réplicas libres de Jev (todas de la semana del 15-sep) | **Laya** (Convai, Apache 2.0): encoder no autorregresivo, checkpoint **multilingüe mmBERT 322M / 647 MB, 100+ idiomas**, notebook de fine-tuning; **laya-coreml** (Apache 2.0, 204 ⭐): puerto validado a Core ML, **~5 ms P50 en el Neural Engine de un M3 Max**, macOS 15+, variante ANE limitada a 96 tokens, invocación solo desde Python por ahora. Otras: von (395M, inglés, 18 ms en Metal), Decider (Qwen3.5-2B, inglés), Open Jev (150M ModernBERT, inglés, se entrena en 30 min), Foq (8B ternario, 2,2 GB). Precedentes de uso: `typesafe-assist` (Home Assistant: orden hablada → intent), `computer-use-jev` (maneja apps de macOS por Accesibilidad) |

## Decisiones tomadas (con Alfonso)

- **Dilo se reescribe nativo en Swift, sólo Mac** (Apple Silicon, macOS 26+).
  No se planea portar: Swift no exporta. Superwhisper y VoiceInk son sólo Mac.
- **Base: fork del árbol de origen** (`docs/historia/`), en `/Volumes/SSD 1/Dilo/mac/`, con remote
  `upstream`. `CoreHUD/`, `Dictation/` e `Input/` se mantienen cerca del
  original para que los merges sean baratos; lo de Dilo va en módulos aparte.
  Se conserva el copyright MIT del árbol de origen y se añade el propio, como se hizo
  con Handy.
- **De Handy/Dilo-Tauri se porta el producto, no el código**: modos con
  atajo y proveedor, palabras propias, historial, onboarding, proveedores de
  post-proceso, limpieza de muletillas del español, copy. Se reescribe en
  Swift leyendo los specs, no los `.rs`.
- **El Tauri (`Dilo/app`) se congela en 0.3.2.** No se borra: README apunta
  al nativo, releases quedan. Cero horas más ahí.
- **Meta: la mejor, la más rápida y la más liviana.** En números (§3).
- **El notch es la identidad**, no un adorno: tres estados (dictando, en
  reunión, conversando) en el mismo lugar. Píldora idéntica cuando no hay
  notch (Mac mini, monitores externos).
- **Notetaker: nada menos que Granola** (spec propio, v2). Dos flujos —mic =
  Yo, audio del sistema = Ellos—, en vivo local, WAV a disco desde el primer
  segundo, notas escritas + transcript → notas mejoradas con LLM en nube.
- **Venta directa desde el inicio; App Store es aspiración a hacer realidad.**
  Dos targets desde el día uno (`Dilo`, `Dilo-MAS`); si el sandbox bloquea
  el tap de audio, App Store queda con una versión sólo-dictado.
- **El dinero se decide después.** El código ya es MIT; se parte con
  donaciones + binario gratis y se cobra recién con el notetaker a nivel
  Granola. Si App Store es "mucho webeo", donaciones y punto.
- **Fases, cada una vendible sola:** v1 dictado que parece terminado → v2
  notetaker híbrido → v3 conversación. La voz **se diseña en v1 y no se
  construye en v1**.

## Diseño

### 1 · Qué se toma del árbol de origen y qué se agrega

| Módulo heredado | Se usa | Dilo agrega |
| --- | --- | --- |
| `CoreHUD/` (notch, placement, shaders) | tal cual | estados reunión/conversación; nivel de ventana sobre pantalla completa (issue #84 del árbol de origen; Handy lo resuelve) |
| `Dictation/` (SpeechAnalyzer, sesión, pegado) | tal cual | motor doble (§2), limpieza de muletillas es, historial serio, diccionario personal |
| `Input/` (atajos, hold/latch, fn) | tal cual | **atajo por modo** (spec 2026-08-05) |
| `PromptShaping` (FoundationModels on-device) | tal cual | **modos** con proveedor (on-device, Gemini, Claude vía FoundationModels server, OpenAI) — spec 2026-07-29 |
| `DropTranscription/` | tal cual | base del "arrastrar una grabación" del notetaker |
| `ReadAloud/` (`AVSpeechSynthesizer`) | tal cual | queda como TTS de v1; PocketTTS entra en v3 |
| `Translation/`, `Insights/`, `Updates/` (Sparkle) | tal cual | Sparkle sólo en target directo |

### 2 · Motor doble

- **Apple** (`SpeechTranscriber`): por defecto. 0 MB, español, parciales.
- **Parakeet v3 vía FluidAudio**: segundo motor, para quien prefiera
  consistencia entre máquinas o esté bajo macOS 26 (si se decide bajar el
  mínimo; hoy no). Se descarga a pedido como en Handy.
- Contrato `SpeechEngine` mínimo: `start(locale)`, flujo de parciales,
  `finish() -> texto`. Nada del resto de la app sabe cuál corre.
- **Gemini 3.5 Transcribe** como tercer motor EN LÍNEA (se porta el diseño del
  2026-08-27), con la misma honestidad LOCAL / EN LÍNEA de la tarjeta.

### 3 · Los números no negociables

| Métrica | Meta | Por qué |
| --- | --- | --- |
| RAM en reposo | **< 60 MB** | Yap lo logra con el mismo motor |
| CPU en reposo | **~0 %** | el tap de teclado no puede costar |
| Texto en pantalla tras soltar la tecla | **< 300 ms** | con parciales, el texto ya está cuando sueltas; es la ventaja contra Wispr (nube) |
| Arranque en frío | **< 1 s** | |
| Descarga | **< 25 MB** sin modelos | FluidAudio pesa ~12 MB y es el precio de Parakeet local; en v2 también diariza |
| Micrófono Bluetooth | **aviso visible** mientras abre (issue #130 del árbol de origen) y *lazy close* como Handy | |

Se miden en CI con un script, no a ojo. Si un cambio rompe un número, no
entra.

### 4 · Capa de capacidades (sandbox desde el día uno)

Todo lo que dependa de la API de Accesibilidad hacia otras apps —foco antes
de pegar, releer lo pegado, título de la ventana, "pegado directo"— va detrás
de un protocolo `HostCapabilities` con dos implementaciones: completa (target
directo) y sandbox (App Store). En sandbox la app **esconde lo que no puede
hacer** (patrón TypeMeIt), nunca falla. El árbol de origen usa AX en 17 puntos; se
inventarían en la primera tarea del plan.

### 5 · Cimientos para v2 y v3 que se ponen en v1

- **Grafo de audio único** con `AVAudioEngine` en modo voice-processing
  (cancelación de eco del sistema): sin eso no hay interrupción a media frase
  en v3. Se enciende desde v1 aunque v1 sólo grabe.
- **Máquina de sesión** con tres modos (dictado, reunión, conversación) y un
  solo escenario (el notch). Dictado es el único modo implementado en v1.
- **Contrato de proveedor S2S** ya definido en el spec de conversación: se
  declara la interfaz, no se implementa.
- **WAV a disco** como primitiva de la sesión, no de reuniones.

### 6 · Español primero

Se conserva todo lo que ya es de Dilo: locale `es` escrito a mano (tuteo,
directo, cero relleno), muletillas del español, voseo y modismos, Spanglish
técnico intacto. Es lo único que ningún fork de Handy ni del árbol de origen tiene.

### 7 · Decisiones tipadas — contrato `Decider`

Hay puntos de Dilo que son una **decisión**, no una generación: qué modo
aplica a este dictado, si esto es texto para pegar o una orden para Dilo, si
la persona terminó de hablar, si esta frase de la reunión es un compromiso y
de quién. Hoy todo eso o lo decide el atajo que apretaste o no existe.

- Contrato `Decider`: recibe texto (+ contexto: app al frente, modo activo,
  últimas líneas) y una pregunta tipada (`choice` / `score` / `noul`);
  devuelve la respuesta con probabilidad. Nada más.
- **Implementación 0, por defecto y sin modelo: reglas.** La app al frente
  decide el modo; palabras clave desempatan. Medido 2026-09-20: acierta el
  100 % del set de evaluación con la app y el 85 % sin ella, en 0,013 ms.
  Cualquier modelo tiene que ganarle a esto para justificar su costo.
- **Implementación 1, sin descarga: FoundationModels con generación guiada**
  (`@Generable` sobre un enum). Sin medir todavía; entra cuando las reglas
  no alcancen (texto ambiguo, app desconocida).
- **Laya multilingüe en Core ML: no entra hoy.** Medido 2026-09-20
  (§Verificación 5): 65 % de acierto en español con la app al frente, 42,5 %
  sin ella; confunde `codigo` con `terminal` y `correo` con `nota`. La
  integración Swift sí funciona (38 ms, deriva 0,00005 contra PyTorch), pero
  el modelo no distingue lo que Dilo necesita distinguir. Se reabre solo con
  **fine-tuning sobre dictados reales del usuario** (el notebook existe; la
  prueba fue zero-shot) y contra una base de reglas que no sea trivial.
- **Implementación 2, opcional: Jev** u otra nube compatible con
  `/v1/systemone` (el formato ya es un estándar de facto: Decider, kev y
  openjev-sglang lo hablan). Entra como proveedor EN LÍNEA con la misma
  honestidad de tarjeta que Gemini: el texto del dictado sale a un tercero
  para decidir. Vale la pena solo si la nube demuestra ser más precisa que
  Laya en español; hoy los benchmarks propios de Laya dicen lo contrario.
- **Primer uso (v1.5): "un atajo, Dilo decide".** Un solo atajo y el modo se
  elige por app + contenido, como hace Wispr con el formato. Los atajos por
  modo se quedan para quien los prefiera.
- **Segundo uso (v3): la puerta de comandos.** `noul`: ¿esto es una orden
  para Dilo o texto? Es lo que hace que la voz actúe sin pasar cada frase
  por un LLM lento.
- Lo que Jev **no** es: no genera, no oye audio, no reemplaza al cerebro de
  la conversación, no sirve para wake word ni diarización.

### 8 · Lo que enseñó la primera prueba de la app de origen (2026-09-20)

Alfonso dictó diez minutos con la app de origen en un Mac sin notch, teclado
latinoamericano. Tres reglas de v1 salen de ahí:

1. **El gatillo nunca es una tecla que en teclado latino escriba
   símbolos.** El segundo idioma de la app de origen se dispara con ⌥ derecha, que en
   ISO-LatAm es AltGr (`@ # \ | { } [ ]`): dictando prompts arrancaba una
   sesión en inglés a cada rato y el resultado salía mezclado. Defaults de
   Dilo: `fn`/🌐 o una combinación con ⌘; nunca un modificador solo.
2. **La píldora sin notch no tapa la barra de menús ni se parece al HUD del
   sistema.** La app de origen la dibuja encima de los status items
   (`HUDNotchGeometry.swift`, `hudClearsMenuBar = 0`, issue #83) en la misma
   franja donde macOS 27 pone el HUD de volumen. Dilo: debajo de la barra,
   con mango, forma de onda y texto parcial — identidad propia.
3. **Nunca tocar el volumen maestro del usuario.** "Duck other audio" baja la
   salida al 20 % por Core Audio y macOS muestra su HUD de volumen cada vez.
   Si algún día se silencia la música al dictar, se pausa la reproducción;
   el volumen no se toca.

Además: `es_CL`, `es_ES`, `es_MX` y `es_US` existen en SpeechAnalyzer y
vienen instaladas; no hay es-419. La calidad del español con el idioma bien
puesto **queda pendiente de la segunda prueba** (§Verificación 1).

## Alcance de v1

Dictado con motor doble, modos con atajo y proveedor, palabras propias,
historial, onboarding en español, notch con estado de dictado y píldora sin
notch, firmado y notarizado, updater (directo), target MAS compilando aunque
no se publique. Nada de reuniones ni de voz más allá de los cimientos de §5.

## Restricciones transversales

- Nada de nombres de backend ni reglas de negocio en el núcleo (spec
  plataforma abierta). Los proveedores entran por contrato.
- Credenciales en Llavero, nunca en `UserDefaults` ni en texto plano.
- Todo copy visible en español autoría propia; inglés como segunda locale.
- Cada feature nueva pasa por spec con medición previa. Es la regla que este
  proyecto ya pagó dos veces por saltarse.

## Riesgos, nombrados

1. **SpeechAnalyzer en español chileno.** Si no rinde en el audio real de
   Alfonso, el motor por defecto pasa a Parakeet v3 y se pierde el "0 MB".
   Se sabe en diez minutos (§Verificación 1).
2. **El árbol de origen tiene un solo autor y seis semanas de vida.** Mitigación: es un
   fork, no una dependencia; si upstream muere, el código queda.
3. ~~**El sandbox y el tap de audio del sistema.** Plausible, no confirmado.~~
   **Confirmado 2026-09-20: funciona.** El riesgo que queda es el pegado y
   el atajo en sandbox, pendientes del clic de Alfonso en TCC.
4. **Dos targets es trabajo real** (dos licencias, dos updaters). Se paga una
   vez al inicio; retrofitear después cuesta meses.
5. **Mac mini / monitores externos sin notch** son el 80 % del uso de
   Alfonso: la píldora tiene que sentirse igual de bien que el notch.
6. **Intel queda fuera.** Se acepta; el Tauri 0.3.2 sigue disponible para
   ellos, congelado.
7. **Todo el ecosistema "System One" tiene cinco días.** Jev está en lista
   de espera; las réplicas libres publican benchmarks propios, sin auditoría.
   Lo que no es hype: un encoder de 322M en Core ML es un clasificador
   calibrado, técnica madura con etiqueta nueva. Por eso el contrato tiene
   tres implementaciones y la de Apple no depende de nadie: si Laya o Jev
   desaparecen, Dilo sigue decidiendo, más lento.

## Verificación pendiente (compuerta de entrada del plan)

Ninguna tarea del plan se ejecuta hasta tener estos cuatro números:

1. **La app de origen en español, sin tocar código.** Instalar, poner `es`, dictar diez
   minutos de uso real (prompts, terminal, Slack). Veredicto: ¿mejor, igual o
   peor que Dilo 0.3.2 con Parakeet v3?
2. **Build sandboxed de la app de origen.** Activar App Sandbox en el target, firmar,
   y probar: ¿pega en Cursor y en el terminal? ¿el atajo global responde?
   ¿`AudioHardwareCreateProcessTap` entrega audio del sistema con el
   entitlement `audio-input`? Tres sí/no. **Hecho 2026-09-20 (parcial):**
   - **Tap de audio del sistema en sandbox: SÍ.** Con `app-sandbox` +
     `device.audio-input` entrega audio real (239.104 frames, pico 0,59;
     control en silencio 0,0), idéntico al build sin sandbox, **sin prompt de
     TCC**. Esto **tumba el supuesto** de que App Store quedaría sólo-dictado:
     el notetaker puede ir al App Store. Trampa: el tap devuelve silencio si
     el binario se lanza desde el terminal (TCC atribuye al proceso
     responsable); con `open -a` entrega audio.
   - **Pegar y atajo global: pendiente de clic de Alfonso.** El portapapeles
     funciona en sandbox; el Cmd+V sintético y `CGEvent.tapCreate` fallan
     igual con y sin sandbox porque faltan Accesibilidad e Input Monitoring,
     que solo un humano concede. `origen-sandboxed.app` (bundle
     `<id-de-origen>.sandboxed`) queda en `/Volumes/SSD2/scratch/origen/`
     para aprobarlos y probar pegado en Cursor y terminal.
   - Dato que sí distingue al sandbox: AX hacia otra app devuelve `-25204
     CannotComplete` sandboxed vs `-25211 APIDisabled` sin sandbox. El
     sandbox **no rompe la compilación de una línea** del árbol de origen: todo lo que
     se cae, se cae en ejecución — por eso la capa de capacidades (§4) tiene
     que probarse en runtime, no confiar en el compilador.
   - Inventario de los usos de AX/CGEvent/pasteboard, archivo:línea, en
     `docs/superpowers/spikes/2026-09-20-spike-1-2-sandbox-de-origen.md`.
3. **Repetir el probe de diarización de Gemini** (quedó en 503 el
   2026-08-27). **Hecho 2026-09-20 13:31** con `scripts/probes/gc-probe.py`
   (port a Python; la key vive en el Llavero). Resultado: **compuerta
   abierta.** Diarización estructural, no en el texto: una `part` por turno
   con `audioTranscription {text, speakerLabel:"spk:N", words[{word,
   startOffset, endOffset}]}`, timestamps por palabra. `audio/wav` aceptado,
   200 en 3–3,6 s por 20 s de audio. Con 2 voces: 2 hablantes exactos, texto
   perfecto. Con 5 voces: detectó **4** — fundió dos voces femeninas
   parecidas. **Trampa nueva:** requests de WAV sobre ~654–688 KB devuelven
   **403 `SERVICE_DISABLED`** (culpa al proyecto, pero es tamaño): el plan de
   v2 tiene que trocear el audio y asumir que voces parecidas se funden.
   Detalle en `docs/superpowers/spikes/2026-09-20-spike-3-gemini-diarizacion.md`.
4. **Una reunión real de Alfonso por dos flujos** (mic + tap), con WAV a
   disco, transcrita por SpeechAnalyzer flujo por flujo. ¿Se pierde algo?
   ¿Cuánto tarda el parcial en aparecer?

5. **Laya multilingüe en español, desde Swift.** (a) 30 dictados reales en
   español con la app al frente, pregunta `choice` "¿qué modo aplica?" contra
   los modos de Alfonso, con `laya-multilingual` en Python: acierto y
   latencia. (b) El mismo `.mlpackage` de `laya-coreml` cargado desde un
   Swift de 50 líneas con el tokenizador de mmBERT: ¿mismo resultado?
   ¿5 ms de verdad? (c) FoundationModels guiado como base de comparación.
   Jev solo si Alfonso consigue acceso y quiere el cuarto número. Si Laya no
   entiende español, la implementación por defecto se queda en Apple. No
   bloquea v1 (bloquea v1.5). **Hecho 2026-09-20: Laya no entra.** 40
   dictados chilenos, 5 modos: **65 %** con app al frente (p media 0,62),
   **42,5 %** sin ella; en inglés la misma pregunta sube a 77,5 %, así que
   parte es el prompt en español, pero `codigo`→`terminal` cae igual.
   Latencia M1: 138 ms CPU / 66 ms MPS en Python; **Swift + Core ML 38 ms,
   40/40 idénticos** (deriva 0,00005). El bundle ANE da 7 ms pero topa en 96
   tokens y su grafo recibe embeddings, no `input_ids`: 1–2 días para usarlo
   desde Swift. Base trivial: **la app al frente acierta el 100 %** del set;
   keywords 85 % sin app. Trampa: `swift-transformers` 0.1.24 ignora
   `prepend_scheme: "always"` de Metaspace (deriva 0,196 sin parche). Set y
   detalle en `docs/superpowers/spikes/2026-09-20-spike-5-laya-espanol.md`.
   Limitación del set: es sintético y cada dictado trae su app "correcta";
   sobreestima a las reglas. Aun así, Laya zero-shot no compite.

Los resultados se pegan aquí, con fecha, antes de escribir el plan.

## Notas para el spec de v2 (reuniones), a raíz del campo

- **Base MIT para reuniones: `pasrom/meeting-transcriber`.** Detección de
  reunión (título de ventana + micrófono en uso), captura por
  `CATapDescription` en dos pistas, diarización por pista con FluidAudio.
  Son 1.782 commits de casos borde ya pagados; se porta al fork como se
  portó el árbol de origen, con atribución. No reinventar.
- **Nombres sin diarizar:** en 1:1, el otro nombre sale de la invitación del
  calendario (truco de Aside). "Yo / Ellos" pasa a "Yo / Camila" gratis.
- **Fusión notas + transcript** con etiquetas de procedencia (`[Notas]`
  escritas por la persona, `[Transcript]` automático), como Humla: es lo que
  hace que la salida sea *tus* notas y no un transcript.
- **Servidor MCP de solo lectura** sobre reuniones y dictados: Aside, Hark y
  Humla lo traen; encaja con el spec de plataforma abierta (Dilo como
  interfaz para agentes) y cuesta poco.
- **Nadie tiene la capa hablada.** Es lo único del mapa que sigue vacío.

## Fuera de alcance

Windows y Linux (se congelan con el Tauri), Intel, reuniones (spec propio
tras la verificación 3 y 4), conversación y wake word (spec propio tras v2),
migración de datos desde el Tauri (se evalúa en el plan; probablemente sólo
historial y palabras propias), cualquier cambio en `Dilo/app` que no sea
el README de congelamiento.
