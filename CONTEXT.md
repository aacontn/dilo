# CONTEXT.md — el dominio de Dilo Mac

El modelo de dominio y su vocabulario. **Los términos de abajo son
vinculantes**: úsalos en identificadores, comentarios, copy y mensajes de
commit, y evita los que dicen _evitar_.

Este archivo desciende del `CONTEXT.md` del árbol de origen 0.8.3. Lo que
sigue siendo cierto se conserva traducido al vocabulario de Dilo; de dónde
viene ese árbol y por qué el original ya no se archiva acá está en
`docs/historia/README.md`.

## Qué es Dilo

Dilo es una app de voz nativa de macOS, en español, para hablarle a las apps
que ya usas. Apunta a macOS 26 en Apple Silicon; **no hay binario Intel**.
Vive en la barra de menús, sin ícono permanente en el Dock, y ofrece
"Abrir al iniciar sesión" apagado por defecto (`SMAppService`).

**Dictado** es el centro de la app. La **Conversación** se dibuja desde el
2026-10-29, y **Reuniones** también (spec `2026-10-21-reuniones-design.md`):
graban, afinan y escriben el **Guion**, con su superficie en la muesca y su
ventana.

Dos cosas en Dilo son modelos y **no son lo mismo**. Un **Motor de voz**
convierte voz en texto. Un **Modelo de texto** reescribe texto que ya existe,
y sólo con permiso explícito de la persona.

## Arquitectura

- Dilo compila desde un `Dilo.xcodeproj` versionado, sin Tuist ni
  generación de proyecto.
- **Dos targets:** `Dilo` (venta directa, Sparkle) y `Dilo-MAS` (App Sandbox,
  sin Sparkle). Comparten todo el código; los separa un entitlement y una
  condición de compilación (`DILO_MAS`).
- AppKit es el caparazón: ciclo de vida, status item, paneles que no activan.
- SwiftUI dibuja la UI con ventana (Ajustes, onboarding) hospedada en AppKit.
- Swift 6 con concurrencia estricta completa.
- Frameworks de Apple, con dos excepciones declaradas: **Sparkle** (sólo
  target `Dilo`, encerrado en `Dilo/Updates/`) y **FluidAudio** cuando
  entre el motor Parakeet.
- `FoundationModels` es donde corre la transformación de texto on-device: es
  un framework del sistema con un modelo del sistema, así que la promesa de
  "no sale nada de este Mac" se sostiene con un LLM dentro de la app — no hay
  key, ni cuenta, ni request.
- Lo propio de Dilo vive en el paquete local `DiloCore/`, un módulo por tema.

## Vocabulario

**Dictado** ·
Una sesión que convierte la voz del micrófono en texto para el control que
tenía el foco. _Evitar_: transcripción, voice typing, modo dictado.

**Gatillo** ·
La tecla o el botón configurado que controla el **Dictado** por apretar,
soltar y tocar. _Evitar_: hotkey, atajo, shortcut.

**Modo** ·
Un nombre + un prompt + un proveedor + un gatillo opcional. Decide qué se
hace con lo dictado antes de pegarlo (Literal, Limpio, Prompt, Mensaje,
Correo, Código). _Evitar_: preset, plantilla, post-proceso.

**Proveedor** ·
Quién ejecuta la transformación de un **Modo**: on-device (FoundationModels)
o en línea (OpenAI, Gemini, Anthropic por API compatible). La tarjeta siempre
dice **LOCAL** o **EN LÍNEA**. _Evitar_: backend, la IA, la nube.

**Motor de voz** ·
Lo que convierte voz en texto detrás del contrato `SpeechEngine`: Apple
(`SpeechTranscriber`, 0 MB) o Parakeet (FluidAudio, se descarga a pedido, en
dos variantes: v3 y Ultra, la recomendada). Nada del resto de la app sabe
cuál corre. _Evitar_: modelo, Whisper, ASR.

**Modelo de texto** ·
El modelo del sistema que reescribe texto que ya existe. Distinto de un
**Motor de voz**. _Evitar_: la IA, el LLM, nuestro modelo.

**Decider** ·
El contrato de decisiones tipadas: recibe texto más contexto (app al frente,
modo activo, últimas líneas) y una pregunta (`choice` / `score` / `noul`), y
devuelve la respuesta con probabilidad. **La implementación por defecto es
reglas, sin modelo.** _Evitar_: clasificador, router, intent engine.

**Conversación** ·
Hablarle a Dilo y que conteste en voz alta, como una llamada. La voz se
transcribe en el Mac con el **Motor de voz**, Claude contesta en línea y una
voz del Mac dice la respuesta: sólo viaja texto. Lo conversado vive en RAM y
se olvida al colgar. _Evitar_: chat, asistente de voz, modo voz.

**Agente** ·
A quién se le habla en la **Conversación**: un nombre que sirve para
llamarlo («Dilo», «Claude Code», «Switchboard») y un **Destino** que
contesta. Se le habla diciendo su nombre al principio o eligiéndolo en la
barra de llamada. _Evitar_: bot, asistente, persona.

**Destino** ·
Quien contesta los **Turno**s de un **Agente**: Claude con herramientas,
una sesión de Claude Code, un servidor MCP. Lo que quiere hacer y cambia algo
lo pide con una aprobación, que se decide con un clic y nunca con la voz.
_Evitar_: backend, proveedor (eso es otra cosa: el de los **Modo**s).

**Turno** ·
Lo que dice una de las dos partes de la **Conversación** antes de que hable la
otra: el de la persona termina por silencio o al soltar el **Gatillo**, y el
de Dilo cuando termina de decir la respuesta. Se habla de a uno (half
duplex). _Evitar_: mensaje, prompt, ronda.

**Tus palabras** ·
El diccionario personal: nombres, proyectos, siglas y términos técnicos que
Dilo tiene que respetar. Se quedan sólo en esta compu. _Evitar_: vocabulario
personalizado, custom words.

**Contexto de la app** ·
Lo que rodeaba al dictado al empezar —la app y, si la persona lo prende, el
texto alrededor del cursor, la selección y el sitio— que un **Modo** usa
como referencia para escribir bien los nombres. Nunca es una orden ni texto
para pegar, y nunca se guarda. _Evitar_: screen context, contexto de
pantalla.

**Frase disparadora** ·
Una frase dicha al principio o al final del dictado («como correo») que
elige el **Modo** y se va del texto. Distinta de las palabras clave, que
desempatan y se quedan. _Evitar_: trigger word, comando de voz.

**Aprender de las correcciones** ·
Ofrecer en la muesca agregar a **Tus palabras** lo que la persona corrigió a
mano después de pegar. Nunca sin que lo acepte. _Evitar_: autoaprendizaje,
learning.

**Muletillas** ·
Las palabras de relleno del español hablado que la limpieza saca. El
spanglish técnico **no** es muletilla y queda intacto. _Evitar_: filler
words, ruido.

**Píldora** ·
La superficie del HUD en una pantalla sin notch: **debajo** de la barra de
menús, con el acento de Dilo, forma de onda y texto parcial. _Evitar_: overlay, banner,
notch simulado.

**Notch** ·
La misma superficie descolgando de la carcasa física en un MacBook con
recorte. Píldora y notch son el mismo HUD; sólo cambia la medida.

**Historial** ·
Los dictados guardados en esta compu, con búsqueda, copiar, borrar y el
**Modo** con que se dictó. _Evitar_: log, transcripciones.

**Arrastrar una grabación** ·
Texto producido desde un archivo de audio o video soltado sobre el HUD. Es la
primitiva sobre la que se construye el notetaker de v2. _Evitar_: importar,
transcripción por lotes.

**Capacidad** ·
Una cosa que la app puede o no puede hacer según dónde corra, detrás de
`HostCapabilities`: foco antes de pegar, releer lo pegado, título de la
ventana, pegado directo, atajo global, tap de audio. En sandbox lo que no se
puede **se esconde**, nunca falla. _Evitar_: feature flag, permiso.

**Reunión** ·
Una conversación grabada en esta compu, sin bot y sin nube: dos **Pistas** a
disco desde el primer segundo y, al terminar, su **Guion**. Vive en
`/Volumes/SSD 1/Dilo/reuniones/AAAA/<carpeta>/` (o en el respaldo interno
mientras el SSD no está). Nunca empieza sola: el clic es de la persona.
_Evitar_: meeting, llamada, sesión, notetaker.

**Pista** ·
Una de las dos fuentes de una **Reunión**, que nunca se mezclan: `yo` (el
micrófono, siempre Yo) y `ellos` (el audio del sistema por el tap de Core
Audio, lo que se diariza). Cada una tiene su WAV, sus anclas de reloj y su
vigía de silencio. _Evitar_: canal, track, stream, fuente.

**Guion** ·
Lo que sale de una **Reunión**: una línea por intervención, con quién la dijo
y cuándo (`Camila · 15:31 — …`). En disco son palabras con su tiempo y su
**Hablante** (`guion.jsonl`) y su vista para leer (`guion.md`). Es el
producto: lo que se busca, se copia y se le pasa a un agente. _Evitar_:
transcript, acta, minuta, transcripción.

**Hablante** ·
Una voz del **Guion**. Yo sale de la pista `yo`, sin modelo; los de `ellos`
entran como «Hablante 2», «Hablante 3»… por orden de llegada hasta que
alguien les pone nombre. _Evitar_: speaker, participante, asistente (el
asistente es del calendario; el hablante, del audio).

**Sección de Ajustes** ·
Una categoría navegable de preferencias persistidas con un propósito visible.
No se registra una sección vacía ni deshabilitada.

## Relaciones que cargan peso

### Dictado

- Apretar el **Gatillo** arranca el **Dictado** de inmediato.
- El **Gatillo** por defecto es `fn`/🌐 sostenido. **Nunca un modificador
  suelto que escriba símbolos en teclado latino**, y nunca ⌥ derecha.
- Soltar un **Gatillo** sostenido termina el **Dictado** e inserta el texto.
- Soltar antes de 250 ms cuenta como toque corto y deja el **Dictado**
  trabado hasta el siguiente apretón. Los 250 son el de fábrica
  (`GestoDelGatillo`); la persona lo mueve entre 150 y 600 en Atajos.
- Esc cancela el **Dictado** y la tecla no llega a la app, ni al apretar ni
  al soltar. Si hubo voz, lo dicho se puede deshacer durante 5 s con un clic
  en la muesca; vive en RAM ese rato y nunca va al historial.
- El texto que se inserta son los resultados finalizados más el último
  parcial si el reconocimiento terminó sin finalizarlo.
- El **Segundo idioma** viene **apagado** por defecto, y su gatillo nunca es
  ⌥ derecha.
- El **Dictado** **nunca baja el volumen maestro**. Si algún día se silencia
  la música, se pausa la reproducción.

### El HUD

- El HUD baja siempre desde el centro superior de su pantalla; nunca abajo.
- Con carcasa física: fillets contra el recorte. Sin notch: **píldora debajo
  de la barra de menús**, que no tapa status items y no imita el HUD de
  volumen del sistema.
- La píldora lleva **onda del micrófono y texto parcial** en los colores de
  Dilo: la identidad de Dilo, no un HUD del sistema. Desde el 2026-10-14 el
  acento es Glaciar (azul a celeste; Grafito se elige en Ajustes) y no mango;
  vale también con notch.
- El HUD aparece sobre apps en pantalla completa y en todos los Espacios, y se
  reordena al frente en cada cambio de espacio activo.
- La máquina del HUD prevé **tres estados** —dictando, reunión, conversando—
  y dibuja dictando y conversando (la barra de llamada). La reunión existe
  como caso explícito sin UI; un estado que no dibuja nada no abre el
  escenario.
- Durante el **Dictado** el HUD es sólo visual: los clics lo atraviesan y
  nunca toma el foco. Acepta el mouse sólo cuando recibe un archivo,
  sostiene una transcripción terminada o un dictado sin pegar, o dice un
  aviso que se arregla con un clic (abrir el panel de un permiso, deshacer
  un Esc). La barra de llamada de la **Conversación** toma el mouse en toda
  su silueta mientras dura: sus botones son lo único que tiene.
- La pantalla del HUD se fija al arrancar la sesión; si se desconecta a
  media sesión, se va a la pantalla del puntero.
- El HUD es la única superficie para el estado y los errores del dictado, y
  se despejan solos a los ~2 segundos.
- **El silencio y un micrófono muerto tienen que verse distinto**: un
  watchdog pasa el visual a un ámbar estático.
- La espera entre la última palabra y el texto reconocido es silenciosa:
  ninguna etiqueta la rellena.
- Los shaders se compilan al arrancar, para que el costo no caiga en los
  primeros cuadros de la sesión.

### Ajustes

- `AppSettings` es la única fuente persistida de preferencias. Los cambios
  aplican en vivo y se guardan al instante: Ajustes no tiene botón Guardar.
- El controlador de dictado congela una foto de los ajustes al arrancar la
  sesión; cambiar Ajustes a media sesión no la altera.
- Las secciones se registran en código con IDs tipados; no hay secciones
  remotas ni por plugin.
- La ventana de Ajustes es modal, oscura, de tamaño fijo con scroll interno,
  se mueve arrastrando su cabecera y se cierra con su control o Escape.
- Ajustes respeta Reducir movimiento y Aumentar contraste del sistema sin
  duplicar los interruptores dentro de la app.

### Sandbox y capacidades

- El App Sandbox **no rompe la compilación de una sola línea**: todo lo que
  se cae, se cae en ejecución. Por eso las capacidades se prueban en runtime.
- Con `app-sandbox` + `device.audio-input`, el tap de audio del sistema
  entrega audio real **sin prompt de TCC** — pero devuelve silencio si el
  binario se lanza desde el terminal, porque TCC atribuye el permiso al
  proceso responsable. **Siempre `open -a`.**
- La API de Accesibilidad hacia otra app devuelve `-25204 CannotComplete` en
  sandbox y `-25211 APIDisabled` sin sandbox: es el dato que los distingue.
- El portapapeles funciona en sandbox. El Cmd+V sintético y
  `CGEvent.tapCreate` dependen de Accesibilidad e Input Monitoring, que sólo
  concede una persona.

## Los números no negociables

| Métrica | Meta |
| --- | --- |
| RAM en reposo (60 s) | < 60 MB |
| CPU en reposo (60 s) | ~0 % |
| Texto en pantalla tras soltar | < 300 ms |
| Arranque en frío | < 1 s |
| Tamaño del `.app` sin modelos | < 25 MB |

Se miden con `DiloMetrics` y `scripts/metrics.sh`, no a ojo. Si un cambio
rompe un número, no entra.

## Ambigüedades marcadas

- **Motor por defecto.** El spec pone Parakeet v3 por defecto, pendiente de
  la segunda prueba de Alfonso con SpeechAnalyzer en `es_CL`. Si gana Apple,
  el default es una constante que cambia y nada más.
- **Píldora en el Mac mini.** Es el 80 % del uso real: tiene que sentirse
  igual de bien que el notch, y todavía no está medida.
- **App Store.** El target `Dilo-MAS` compila y se firma; publicarlo es una
  decisión aparte que no se toma en v1.
