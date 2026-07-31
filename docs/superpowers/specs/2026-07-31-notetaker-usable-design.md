# Dilo — Notetaker usable: ventana propia, transcript vivo y dónde quedan las reuniones

**Fecha:** 2026-07-31 · **Estado:** diseño aprobado por Alfonso tras probar la Historia 1 en vivo · **Base:** [spec del notetaker](../../../specs/001-meeting-notetaker/spec.md) y su plan de tareas

## De dónde sale esto

Alfonso probó la Historia 1 en una reunión real: **transcribe y separa voces**. La parte difícil funciona. Lo que no funciona es todo lo demás alrededor:

> "Grabar reuniones debería abrir una ventana nueva, ultra mega liviana. Tenemos que tener un lugar donde se guardan las reuniones, porque si no, no sabemos dónde ver las cosas. Y el transcript en vivo tiene que ser tipo streaming, que se vaya viendo cómo se va agregando."

Cuatro cosas, dos de ellas ya previstas en el plan original (el hub es Historia 4, la reunión virtual es Historia 2) y dos nuevas (la ventana flotante y el streaming). Este documento cubre las cuatro como un solo cambio, porque juntas son "que la feature se pueda usar".

## 1 · El módulo de reuniones vive en su propia ventana

**Corrección de Alfonso (2026-07-31), después de leer el primer diseño:** no es
una ventanita flotante con el botón de detener. Es **el módulo completo en una
segunda ventana**, como hace Wispr Flow: la app con su configuración por un
lado, y los transcripts y las reuniones por otro. Grabar, ver el transcript en
vivo, nombrar hablantes y revisar reuniones pasadas: todo eso deja de vivir
dentro del panel de ajustes de Dilo.

Es mejor que lo que este documento proponía antes, y de paso resuelve un
problema que apareció al revisar el registro: con todo en el mismo panel, al
abrir una reunión pasada seguías viendo arriba "Graba tu próxima reunión" y un
transcript en vivo vacío. Ese ruido desaparece solo cuando cada cosa está en su
ventana.

### Cómo se construye

Dilo ya tiene una segunda ventana —el overlay— y el camino está trillado:
entrada propia en Vite (`src/overlay/index.html`) y creación desde Rust con
`WebviewWindowBuilder`. La de reuniones repite ese patrón con su propia entrada.

**Diferencia importante con el overlay:** el overlay es un NSPanel flotante sin
foco, y de ahí viene la regla de "crear perezosamente una vez y **jamás**
destruir" (destruir una ventana convertida a NSPanel revienta la app; costó una
tarde entera en la v0.1.4). La de reuniones es una **ventana normal**:
redimensionable, con foco, en el Dock, que el usuario puede cerrar y reabrir.
Esa regla no aplica, pero sí la de reusar la ventana si ya está abierta en vez
de crear una segunda.

### Qué queda en el panel principal

La sección Reuniones del sidebar deja de ser una pantalla y pasa a ser el
**lanzador** de la ventana. Los ajustes del notetaker que existan a futuro sí
viven en el panel; la actividad vive en su ventana.

## 1b · Lo que el primer diseño decía de la ventana flotante

**El problema:** hoy grabar una reunión vive dentro del panel de ajustes de Dilo. Eso es un error de encuadre: configurar la app y grabar una reunión no son la misma actividad. Mientras grabas estás trabajando en otra ventana, y la de Dilo te estorba.

**El diseño:** una ventana propia, chica y siempre visible, con lo mínimo — estado, tiempo, y el botón de detener. Sin barra de título, arrastrable, recordando dónde la dejaste. Se abre al empezar a grabar y se cierra al terminar.

**Lo que NO es:** no es el overlay del dictado. Ese es una pastilla efímera que aparece y desaparece; esta acompaña durante toda la reunión y tiene controles. Son dos superficies distintas con ciclos de vida distintos.

**Precedente y trampa conocida:** Dilo ya tiene una ventana secundaria (el overlay). De ahí salen dos lecciones que aplican tal cual: en macOS el panel **se crea perezosamente una vez y jamás se destruye** (destruir una ventana convertida a NSPanel revienta), y el arrastre nativo tiene que cubrir toda la barra superior, no una franja de 36 px.

## 2 · El transcript vivo

**El problema:** hoy el texto aparece de golpe cuando terminas de hablar. Se ve muerto.

**El hallazgo:** el catálogo curado tiene exactamente un modelo con streaming real —`nemotron-3.5-asr-streaming-0.6b`— y es el que se descartó para dictado por verse entrecortado. Para un transcript de reunión eso deja de ser defecto: el texto que aparece y se corrige en pantalla es justamente la sensación de vivo. Nadie pega ese texto en su editor; lo lee.

**El diseño — doble vía:**

- **Tentativo:** el modelo con streaming alimenta el texto que se ve crecer mientras alguien habla.
- **Comprometido:** cuando el turno cierra, el modelo bueno (el que el usuario tenga elegido) transcribe el turno completo y **reemplaza** el tentativo. Ese es el que se persiste y el que se diariza.

La infraestructura ya existe: `StreamTextEvent { committed, tentative }` es exactamente este modelo de datos, y hoy la usa el overlay del dictado.

**El costo, dicho de frente:** son dos modelos STT cargados a la vez. En una máquina de 16 GB eso compite por memoria — el mismo problema que degradó el experimento de voz de 0,3 s a 18 s. Por eso el streaming es **opcional y apagable**, y hay que medir el consumo con las dos vías activas antes de encenderlo por defecto.

## 3 · Dónde quedan las reuniones

**El problema, en palabras de Alfonso:** "no sabemos dónde chucha ver las cosas". Grabas, y el transcript se va a una base de datos que ninguna pantalla lee.

**El diseño:** la sección Reuniones del panel deja de ser "grabar" y pasa a ser **el registro**: lista de reuniones pasadas con fecha, duración y estado (incluida la marca de interrumpida que ya persiste el backend), y al abrir una, su transcript completo con los hablantes.

Esto es la Historia 4 del plan original, adelantada: sin ella la Historia 1 no se puede usar, así que su prioridad relativa estaba mal.

**Alcance acotado:** listar, abrir y leer. La búsqueda, las preguntas al transcript y el resumen por IA quedan donde estaban, más adelante.

## 4 · La reunión virtual

Historia 2 del plan original, sin cambios de diseño — pero con una confirmación de campo: Alfonso observó que Wispr, en reuniones online, **graba el audio que sale del computador y no el micrófono**. En videollamada el micrófono sólo captura tu voz más un eco pobre de los parlantes; la señal de los demás viaja por el sistema. Confirma que hay que mezclar micrófono + audio de sistema, y que la captura de sistema en macOS (ScreenCaptureKit, con su permiso propio) es la pieza dura.

## Orden

1. **El registro de reuniones** — sin esto se graba al vacío.
2. **La ventana flotante** — sin esto estorba mientras trabajas.
3. **El transcript vivo** — sin esto se ve muerto.
4. **La reunión virtual** — sin esto sólo sirve presencial.

Los cuatro son independientes y cada uno deja algo usable.

## Restricciones transversales

- **El dictado no cambia.** Todo es aditivo.
- **Copy es-first**, autoral, tuteo chileno; claves en los 21 idiomas.
- **Sin dependencias nuevas.**
- La ventana flotante respeta `prefers-reduced-motion` como el resto.

## Verificación

- El registro: grabar dos reuniones, cerrar Dilo, reabrir, y encontrar las dos con su transcript.
- La ventana: que no estorbe mientras trabajas en otra app, que se pueda arrastrar entera, y que sobreviva a cerrar y reabrir.
- El streaming: ver el texto crecer mientras se habla, y que al cerrar el turno lo reemplace la versión buena. Medir memoria con las dos vías activas.
- La virtual: transcribir una videollamada de prueba y confirmar que aparecen las dos partes de la conversación.
