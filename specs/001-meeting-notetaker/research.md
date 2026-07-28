# Phase 0 Research: Notetaker de Reuniones

Resuelve los `NEEDS CLARIFICATION` del Technical Context de `plan.md`. Por el
Principio VI de la constitución (Sin Atajos de Alcance), la diarización no se
trata como "investigar después" — es la pregunta central de esta fase.

## 1. Diarización local/offline con número de hablantes desconocido

**Decision**: usar un pipeline de diarización basado en ONNX Runtime —
modelo de segmentación con detección de habla superpuesta (overlap-aware,
estilo pyannote) + extracción de embeddings de hablante + clustering
espectral para determinar el número de hablantes sin conocerlo de antemano.
Concretamente, el proyecto **sherpa-onnx** (k2-fsa) ya empaqueta este
pipeline completo (`OfflineSpeakerDiarization`) como modelos ONNX
descargables + bindings de Rust oficiales, siguiendo el mismo patrón que
Dilo ya usa para Silero VAD y los motores de transcripción ONNX
(transcribe-rs).

**Rationale**:
- Encaja con la arquitectura existente: Dilo ya embebe modelos ONNX locales
  (Silero VAD, Parakeet/Moonshine/SenseVoice vía transcribe-rs) — agregar un
  modelo de diarización ONNX más sigue el mismo patrón de
  descarga-y-ejecución local, no introduce un runtime nuevo (ej. no hace
  falta empotrar Python/PyTorch).
- El clustering espectral no requiere saber cuántos hablantes hay de
  antemano — cumple FR-003 directamente.
- El modelo de segmentación tipo pyannote detecta habla superpuesta como
  parte de su salida nativa (múltiples activaciones de hablante por frame),
  no como un caso especial — es la base técnica más razonable para el
  requisito de FR-004 (marcar segmentos inciertos en vez de adivinar).
- Rust nativo vía bindings oficiales evita añadir un sidecar en otro
  lenguaje, consistente con el resto del backend.

**Revisión (implementación, T002)**: `src-tauri/Cargo.toml` ya depende de
`ort = "=2.0.0-rc.12"` (bindings ONNX Runtime en Rust), usado hoy para
Parakeet/Moonshine/SenseVoice. En vez de sumar el crate/binding completo de
sherpa-onnx como dependencia nueva, evaluar correr los mismos modelos ONNX
que sherpa-onnx publica (segmentación + embeddings de hablante) directamente
sobre el `ort` ya integrado — mismo enfoque técnico de research.md §1, sin
duplicar bindings de ONNX Runtime en el binario. Si el empaquetado de esos
modelos específicos hace inviable evitar la dependencia de sherpa-onnx,
usarla igual está permitido — es una preferencia de consistencia, no un
bloqueo.

**Resultado (T002)**: confirmado — Ruta A. `ort = "=2.0.0-rc.12"` alcanza
tal cual, `Cargo.toml` no necesita ninguna dependencia nueva para los
modelos ONNX en sí. Verificado leyendo el código fuente C++ de sherpa-onnx
(`k2-fsa/sherpa-onnx`, rama `master`):
`sherpa-onnx/csrc/offline-speaker-segmentation-pyannote-model.cc` y
`speaker-embedding-extractor-model.cc` cargan sus modelos con un
`Ort::Session` plano (`std::make_unique<Ort::Session>(env_, path, opts)` /
`sess_->Run(...)`), sin operadores ONNX custom — son modelos ONNX
estándar, publicados como archivos `.onnx` sueltos en GitHub Releases
(`k2-fsa/sherpa-onnx` releases `speaker-segmentation-models` y
`speaker-recongition-models`), no en un formato propietario de
sherpa-onnx. Mismo patrón que `tts/supertonic.rs` ya usa en este repo
(`ort::session::Session` directo).

**Corrección encontrada (importante para T009)**: este documento describe
el paso de clustering como "clustering espectral", pero el código fuente
real de sherpa-onnx (`fast-clustering.cc`) **no usa clustering espectral**
— usa clustering jerárquico/aglomerativo (complete-linkage, distancia
coseno) vía una implementación al estilo `fastcluster` (Müllner), cortando
el dendrograma por umbral de distancia cuando no se conoce el número de
hablantes (`clustering.cluster-threshold`) o por `k` fijo si se conoce
(`clustering.num-clusters`). Sigue cumpliendo FR-003 (número de hablantes
desconocido) — el corte por umbral no necesita saber `k` de antemano —
pero el algoritmo descrito acá está mal nombrado. El crate Rust `kodama`
(crates.io, puro Rust) implementa la misma familia de algoritmo
(inspirado explícitamente en `fastcluster` de Müllner) y es un candidato
razonable para T009; no se agrega a `Cargo.toml` en T002 porque la
elección del algoritmo de clustering es tarea de T009, no de esta tarea
(agregar la dependencia de diarización), y esta corrección recién se
descubrió en la investigación de T002. Este párrafo debería revisarse
(¿renombrar "clustering espectral" → "clustering jerárquico/aglomerativo"
en el **Decision** de arriba?) antes de que T009 arranque. Detalle
completo, con enlaces a las fuentes, en
`.superpowers/sdd/task-T002-report.md`.

**Límite honesto a documentar (no ocultar)**: ningún pipeline de
diarización basado en un solo micrófono resuelve perfectamente la
superposición de voz total (dos personas hablando exactamente lo mismo,
mismo instante, sin separación espacial de canales). El overlap-aware
segmentation reduce el problema a "detectar que hubo superposición y no
inventar una atribución falsa" (que es lo que pide FR-004), no a "separar
ambas voces con precisión perfecta". SC-001 (>80% de segmentos bien
atribuidos) es una meta alcanzable con este enfoque; una separación
perfecta de audio superpuesto NO lo es con el estado del arte actual en
un solo canal, y no se promete como tal.

**Alternatives considered**:
- *NVIDIA NeMo diarization / Sortformer*: más preciso en benchmarks
  académicos, pero es un framework de entrenamiento/investigación en
  Python, pesado para empotrar en una app de escritorio distribuida como
  binario único. Rechazado por costo de empaquetado, no por precisión.
- *WhisperX / whisper-diarization*: combina Whisper + pyannote vía Python;
  mismo problema — requeriría un runtime Python embebido que Dilo no tiene
  hoy y que rompe la filosofía de binario nativo liviano.
- *Diarización basada solo en heurísticas de pausas/VAD (sin embeddings de
  hablante)*: más simple de implementar, pero no distingue hablantes
  reales — solo turnos de silencio. No cumple FR-003 (identificar
  hablantes distintos), fue descartado por no resolver el problema que
  esta feature existe para resolver.

## 2. Transcripción incremental para reuniones en español

**Decision**: transcripción por ventanas cortas superpuestas ("chunked
rolling-window"): se transcribe en lotes de pocos segundos a medida que el
VAD marca fin de una intervención, y se van agregando al transcript
acumulado — igual al patrón que ya usa el pipeline de dictado de Dilo hoy
(VAD → transcribir → emitir), aplicado de forma repetida durante toda la
sesión en vez de una sola vez al final.

**Rationale**: el motor de streaming real (`StreamingWorker` en
`managers/transcription.rs`) ya existe en el código, pero el flag
`supports_streaming` del modelo español actualmente en uso es `false` — no
hay un modelo con soporte de streaming real y buena calidad en español
disponible hoy en los motores que Dilo ya integra. Ventanas cortas
superpuestas logra el resultado que pide FR-002/SC-002 (texto nuevo a los
pocos segundos, no al final) usando únicamente capacidades de modelos que
ya funcionan bien en español, sin bloquear la feature a que aparezca un
modelo streaming-en-español production-ready.

**Alternatives considered**:
- *Esperar/exigir un modelo con streaming real en español*: bloquearía
  toda la Historia 1 y 2 a una dependencia externa fuera del control del
  equipo. Rechazado — el pipeline de streaming real queda como mejora
  futura cuando exista un modelo apto, sin cambiar el contrato de cara al
  usuario (FR-002 se sigue cumpliendo).
- *Transcribir todo al final (batch puro)*: es lo que hace el clon de Handy
  inspeccionado como referencia. Rechazado explícitamente por el Principio
  VI — no cumple SC-002 y es la clase de atajo que ya se descartó.

## 3. Captura de audio de sistema para reuniones virtuales (macOS)

**Decision**: usar **ScreenCaptureKit** (API nativa de Apple, disponible
desde macOS 13+ para captura de audio de sistema sin compartir pantalla)
para capturar el audio de salida del sistema en la Historia 2.

**Rationale**: es la única vía soportada por Apple para capturar audio de
sistema sin instalar un driver de audio virtual de terceros (ej. BlackHole)
ni una extensión de kernel. Requiere un permiso del sistema (Grabación de
pantalla y audio del sistema) que el usuario concede una vez — consistente
con cómo Dilo ya pide permisos de micrófono/accesibilidad hoy, sin pasos de
instalación adicionales para el usuario. Apps comparables (notetakers,
herramientas de captura) ya usan esta misma API en macOS reciente.

**Alternatives considered**:
- *Driver de audio virtual (BlackHole u otro)*: requiere instalación
  separada fuera de Dilo, rompe "no setup" y complica la distribución (no
  se puede empotrar un kernel extension dentro del `.app`). Rechazado.
- *Pedir a cada participante que instale algo / un bot que se una a la
  llamada*: contradice explícitamente FR-016 ("sin requerir que otros
  participantes instalen software ni que un bot se una"). Rechazado por
  spec.
- *Windows/Linux en v1*: no hay una API de captura de audio de sistema tan
  directa y sin dependencias como ScreenCaptureKit en esas plataformas
  todavía integrada al toolkit de Dilo. Documentado en Complexity Tracking
  del plan como limitación de alcance explícita, no oculta.

## 4. Detección de videollamada activa (Historia 3)

**Decision**: usar la misma sesión de `ScreenCaptureKit` del punto 3, en
modo de solo-consulta de metadata (sin capturar audio todavía) — se
consulta periódicamente si existe una app conocida de videollamada (Zoom,
Google Meet/Chrome, Teams) con una sesión de audio de salida activa y no
silenciosa. Al detectarla, se emite `meeting-call-detected` (ver
`contracts/tauri-commands.md`) sin empezar a grabar.

**Rationale**: reutiliza el mismo permiso y la misma API que ya hace falta
para la Historia 2 (no se pide un permiso nuevo ni se agrega una
dependencia distinta) — la detección es, en los hechos, un "modo de
prueba" de la misma captura antes de comprometerse a grabar.

**Alternatives considered**:
- *Detectar por proceso corriendo (`Zoom.app`, etc.)*: más simple, pero da
  falsos positivos (la app abierta sin llamada activa) y no cubre
  videollamadas dentro del navegador (Meet en Chrome) sin lógica adicional
  por navegador. Rechazado como señal principal; puede usarse como
  heurística complementaria más adelante, no en v1.
- *Integración directa con la API de cada app de videollamada (Zoom SDK,
  etc.)*: requeriría credenciales/SDKs por proveedor, contradice el
  Principio I (no atar el núcleo a integraciones específicas de terceros
  para una función que debe funcionar igual sin importar qué app se use).
  Rechazado.
