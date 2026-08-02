# Tasks: Notetaker de Reuniones

**Input**: Design documents from `/specs/001-meeting-notetaker/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/tauri-commands.md, quickstart.md

**Tests**: no se pidieron explícitamente en la spec (TDD no fue solicitado); la
validación de cada historia se hace contra los escenarios de `quickstart.md` y
los criterios de éxito de `spec.md`, listados al final de cada fase.

**Organization**: tareas agrupadas por historia de usuario (spec.md), en el
mismo orden de prioridad P1→P6.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: puede ejecutarse en paralelo (archivos distintos, sin dependencias)
- **[Story]**: a qué historia de usuario pertenece (US1..US6)

## Path Conventions

Proyecto Tauri existente (no monorepo): `src-tauri/src/` (backend Rust),
`src/` (frontend React/TS) — según `plan.md`.

---

## Phase 1: Setup

**Purpose**: preparar el esqueleto del módulo sin implementar lógica todavía

- [ ] T001 Crear esqueleto de módulos backend: `src-tauri/src/managers/meeting.rs`, `src-tauri/src/managers/diarization.rs`, `src-tauri/src/commands/meeting.rs` (structs y `impl` vacíos, siguiendo el patrón de `managers/audio.rs`)
- [ ] T002 [P] Agregar dependencia de diarización (bindings Rust de sherpa-onnx, ver `research.md` §1) a `src-tauri/Cargo.toml`
- [ ] T003 [P] Crear esqueleto frontend: `src/components/meeting/` (directorio), `src/hooks/useMeetings.ts`, `src/stores/meetingStore.ts` (siguiendo el patrón de `useSettings.ts`/`settingsStore.ts`)
- [ ] T004 [P] Agregar namespace `meeting.*` vacío en `src/i18n/locales/en/translation.json` (idioma fuente para desarrollo; `es` se completa a mano en cada historia, Principio III)

**Checkpoint**: esqueleto compilable, sin funcionalidad — listo para Fase 2.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: infraestructura que TODAS las historias necesitan

**⚠️ CRITICAL**: ninguna historia de usuario arranca hasta completar esta fase

- [ ] T005 Definir migraciones SQLite para `meetings`, `meeting_segments`, `meeting_speakers`, `meeting_action_items`, `meeting_notes`, `sync_destinations` en `src-tauri/src/managers/meeting.rs` (array `MIGRATIONS`, patrón `rusqlite_migration` de `managers/history.rs`) — esquema completo en `data-model.md`
- [ ] T006 Implementar `MeetingManager` (conexión SQLite, apertura de DB) en `src-tauri/src/managers/meeting.rs`, siguiendo el patrón de `HistoryManager`
- [ ] T007 Registrar `MeetingManager` y `DiarizationManager` en el estado de Tauri en `src-tauri/src/lib.rs`
- [ ] T008 [P] Empaquetar/descargar los modelos ONNX de diarización (segmentación + embeddings de hablante) en `src-tauri/resources/models/`, siguiendo el patrón de descarga de `silero_vad_v4.onnx`
- [ ] T009 [P] Implementar `DiarizationEngine` (carga de modelos, corrida de segmentación + embeddings + clustering espectral) en `src-tauri/src/managers/diarization.rs` — enfoque de `research.md` §1
- [ ] T010 Definir y registrar los eventos Tauri (`meeting-segment`, `meeting-progress`, `meeting-finished`, `meeting-error`, `meeting-interrupted`, `meeting-call-detected`, `meeting-call-ended`) vía `tauri-specta` en `src-tauri/src/managers/meeting.rs`

**Checkpoint**: base lista — las historias de usuario pueden arrancar (en paralelo si hay más de una persona).

---

## Phase 3: User Story 1 - Diarización presencial (Priority: P1) 🎯 MVP

**Goal**: grabar una reunión presencial y obtener un transcript con hablantes distinguidos, 100% local.

**Independent Test**: grabar 3 personas en la misma sala con al menos una superposición de habla; verificar atribución por hablante y cero tráfico de red durante la sesión (quickstart.md Escenario 1).

- [ ] T011 [US1] Implementar comando `start_meeting` (`kind: "presencial"`) en `src-tauri/src/commands/meeting.rs` — crea fila en `meetings` con `status: recording`
- [ ] T012 [US1] Conectar captura de micrófono → VAD (Silero, reutilizado) → transcripción por ventanas cortas superpuestas (`research.md` §2) en `src-tauri/src/managers/meeting.rs`
- [ ] T013 [US1] Correr `DiarizationEngine` por segmento y persistir en `meeting_segments` con `speaker_id` o `NULL` si es incierto (FR-004) en `src-tauri/src/managers/meeting.rs`
- [ ] T014 [US1] Emitir evento `meeting-segment` de forma incremental a medida que se insertan segmentos (FR-002)
- [ ] T015 [US1] Implementar comando `stop_meeting` — transición `recording → processing`, dispara generación de resumen (ver T037) en `src-tauri/src/commands/meeting.rs`
- [ ] T016 [US1] Implementar comandos `assign_speaker_name` y `merge_speakers` (FR-005) en `src-tauri/src/commands/meeting.rs`
- [ ] T017 [P] [US1] Construir UI de controles de grabación (iniciar/detener, tipo presencial) en `src/components/meeting/RecordingControls.tsx`
- [ ] T018 [P] [US1] Construir vista de transcript en vivo con labels de hablante y marca de "incierto" en `src/components/meeting/LiveTranscript.tsx`
- [ ] T019 [P] [US1] Construir UI de asignación/fusión de hablantes en `src/components/meeting/SpeakerAssignment.tsx`
- [ ] T020 [US1] Completar strings `es`/`en` de controles de grabación y asignación de hablantes en `src/i18n/locales/{es,en}/translation.json`
- [ ] T021 [US1] Implementar recuperación ante crash: al arrancar la app, detectar reuniones `status: recording` sin `ended_at`, marcar `interrupted` y emitir `meeting-interrupted` (FR-008) en la inicialización de `MeetingManager`
- [ ] T022 [US1] Validar manualmente contra `quickstart.md` Escenario 1 (diarización) y Escenario 3 (recuperación); medir contra SC-001 (>80% segmentos bien atribuidos)

**Checkpoint**: Historia 1 funcional y testeable de forma independiente — éste es el MVP real del feature.

---

## Phase 4: User Story 2 - Grabar reunión virtual (Priority: P2)

**Goal**: capturar audio de sistema durante una videollamada, sin bot ni instalación de terceros.

**Independent Test**: grabar una videollamada de prueba de 2 participantes y verificar que el transcript incluye ambos lados (quickstart.md Escenario 2).

- [ ] T023 [US2] Implementar captura de audio de sistema en `src-tauri/src/audio_toolkit/audio/system_audio.rs` (macOS)
  - **Corrección 2026-08-02:** NO usar ScreenCaptureKit, como decía `research.md` §3.
    La inspección de Wispr Flow (que resuelve esto en producción) mostró que no lo
    usa: captura con la vía de **audio del sistema de macOS 14.4+**, que pide sólo
    permiso de **audio** (`NSAudioCaptureUsageDescription`) y no el de grabación de
    pantalla. Su Info.plist lo declara así y su helper enlaza CoreAudio sin
    ScreenCaptureKit. Es menos invasivo, no muestra el indicador morado, y permite
    tomar el audio de un proceso concreto en vez de toda la pantalla.
  - Requiere decidir cómo se llaman esas APIs desde Rust (FFI propio o crate), y esa
    decisión choca con la restricción de "sin dependencias nuevas": resolverla en el
    diseño antes de implementar.
- [ ] T024 [US2] Extender `start_meeting` para aceptar `kind: "virtual"`, mezclando audio de sistema + micrófono
- [ ] T025 [P] [US2] Agregar selector presencial/virtual a `src/components/meeting/RecordingControls.tsx` (extiende T017)
- [ ] T026 [US2] Manejar el flujo de permiso de macOS para captura de audio de sistema (solicitud + estado en Ajustes)
- [ ] T027 [US2] Validar manualmente contra `quickstart.md` Escenario 2

**Checkpoint**: Historias 1 y 2 funcionan de forma independiente.

---

## Phase 5: User Story 3 - Detección automática de reunión virtual (Priority: P3)

**Goal**: notificar cuando hay una videollamada activa, con un click para grabar; sugerir detener al colgar.

**Independent Test**: iniciar una videollamada sin tocar Dilo, verificar la notificación y el flujo de un click (quickstart.md Escenario 1b).

- [ ] T028 [US3] Implementar detección de llamada activa (consulta de metadata de ScreenCaptureKit, `research.md` §4) en `src-tauri/src/audio_toolkit/audio/system_audio.rs`
- [ ] T029 [US3] Emitir `meeting-call-detected` cuando se detecta llamada activa sin grabación en curso
- [ ] T030 [US3] Emitir `meeting-call-ended` cuando termina la llamada que originó una grabación por detección automática
- [ ] T031 [P] [US3] Construir notificación descartable con acción "Grabar" de un click en `src/components/meeting/CallDetectedToast.tsx`
- [ ] T032 [P] [US3] Construir prompt de confirmación "¿Detener grabación?" con opción de seguir grabando en `src/components/meeting/CallEndedPrompt.tsx`
- [ ] T033 [US3] Implementar de-duplicación: no repetir la notificación para la misma llamada ya descartada (Edge Case)
- [ ] T034 [US3] Validar manualmente contra `quickstart.md` Escenario 1b; medir contra SC-008

**Checkpoint**: Historias 1-3 funcionan de forma independiente.

---

## Phase 6: User Story 4 - Revisar una reunión pasada (Priority: P4)

**Goal**: navegar Mis Pensamientos / Transcript / Resumen / Pendientes de una reunión ya procesada.

**Independent Test**: abrir una reunión ya grabada y navegar las 4 pestañas sin reprocesar audio (quickstart.md Escenario 4).

- [ ] T035 [US4] Implementar comandos `get_meeting` y `list_meetings` en `src-tauri/src/commands/meeting.rs`
- [ ] T036 [US4] Implementar comando `save_meeting_notes` + tabla `meeting_notes` (FR-009b) en `src-tauri/src/commands/meeting.rs`
- [ ] T037 [US4] Reutilizar el proveedor de post-proceso de `llm_client.rs` para generar `summary` + `meeting_action_items` al pasar a `processing` (completa T015) en `src-tauri/src/managers/meeting.rs`
- [ ] T038 [P] [US4] Construir vista de detalle de reunión con las 4 pestañas en `src/components/meeting/MeetingDetail.tsx`
- [ ] T039 [P] [US4] Construir hub/listado de reuniones pasadas en `src/components/meeting/MeetingsHub.tsx`
- [ ] T040 [US4] Validar manualmente contra `quickstart.md` Escenario 4 (pestañas y pendientes)

**Checkpoint**: Historias 1-4 funcionan de forma independiente.

---

## Phase 7: User Story 5 - Buscar y preguntar sobre reuniones pasadas (Priority: P5)

**Goal**: encontrar contenido a través de reuniones pasadas y preguntar en lenguaje natural.

**Independent Test**: con 3+ reuniones grabadas, buscar un tema mencionado en todas y confirmar resultados con contexto (quickstart.md Escenario 4, parte 2).

- [ ] T041 [US5] Implementar búsqueda de texto completo sobre `meeting_segments`/`summary` (FTS5 o `LIKE`, según soporte de `rusqlite`) extendiendo `list_meetings`
- [ ] T042 [US5] Implementar comando `ask_meeting_question` usando `llm_client.rs` con el transcript de la reunión como contexto
- [ ] T043 [P] [US5] Agregar UI de búsqueda a `src/components/meeting/MeetingsHub.tsx` (extiende T039)
- [ ] T044 [P] [US5] Agregar UI de pregunta/respuesta a `src/components/meeting/MeetingDetail.tsx` (extiende T038)
- [ ] T045 [US5] Validar manualmente contra `quickstart.md` Escenario 4 (búsqueda y pregunta); medir contra SC-006

**Checkpoint**: Historias 1-5 funcionan de forma independiente.

---

## Phase 8: User Story 6 - Sincronizar con Apple Notes u otro destino (Priority: P6)

**Goal**: enviar resumen + pendientes a un destino configurado, automáticamente al terminar de procesar.

**Independent Test**: configurar Apple Notes, procesar una reunión, confirmar la nota nueva sin intervención manual (quickstart.md Escenario 5).

- [ ] T046 [US6] Implementar tabla `sync_destinations` + comandos `set_sync_destination`/`get_sync_destinations` en `src-tauri/src/commands/meeting.rs`
- [ ] T047 [US6] Implementar adaptador de sincronización a Apple Notes (`kind: "apple_notes"`) en `src-tauri/src/managers/meeting.rs` — mecanismo concreto (AppleScript/EventKit) a resolver en implementación, siguiendo el mismo enfoque de "no depender de un backend específico" del Principio I
- [ ] T048 [P] [US6] Construir UI de configuración de destino de sincronización en `src/components/settings/` (extiende el patrón de Ajustes existente)
- [ ] T049 [US6] Disparar sincronización automáticamente cuando `status → ready` si hay destino configurado
- [ ] T050 [US6] Validar manualmente contra `quickstart.md` Escenario 5; medir contra SC-007

**Checkpoint**: las 6 historias funcionan de forma independiente — feature completa.

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: mejoras que cruzan todas las historias — no se considera "listo" sin esto (Principios III, V y VI)

- [ ] T051 [P] Correr `cargo fmt`/`cargo clippy` y `eslint`/`prettier` sobre todos los archivos nuevos (Principio V)
- [ ] T052 [P] Completar traducción `es` a mano (no generada por máquina) de todas las claves `meeting.*` en `src/i18n/locales/es/translation.json` (Principio III)
- [ ] T053 Validar SC-004: sesión de 2+ horas sin degradación perceptible de memoria/latencia (quickstart.md Escenario 6)
- [ ] T054 Validar SC-005: 100% offline durante grabación/transcripción/diarización — auditoría de red completa (FR-013, FR-014)
- [ ] T055 Correr los 7 escenarios de `quickstart.md` de punta a punta como aceptación final
- [ ] T056 Actualizar el checkbox de "Notetaker de reuniones y notas" en el Roadmap de `README.md` una vez completo

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Fase 1)**: sin dependencias.
- **Foundational (Fase 2)**: depende de Setup — bloquea todas las historias.
- **Historias de Usuario (Fase 3-8)**: todas dependen de Foundational.
  - Pueden avanzar en paralelo si hay más de una persona, o en orden de
    prioridad P1→P6 si es una sola.
  - US2 y US3 comparten el módulo `system_audio.rs` (T023/T028) — si se
    paralelizan, coordinar ese archivo.
- **Polish (Fase 9)**: depende de las historias que se decida incluir en el release.

### User Story Dependencies

- **US1 (P1)**: sin dependencias de otras historias — es el MVP real.
- **US2 (P2)**: independiente de US1 a nivel de dato, pero comparte
  infraestructura de grabación (`meetings` table, eventos).
- **US3 (P3)**: depende de la captura de audio de sistema de US2
  (`system_audio.rs`) — no puede implementarse antes.
- **US4 (P4)**: necesita que exista al menos una reunión grabada (US1 o
  US2) para ser demostrable, pero su código no depende de la lógica interna
  de ninguna.
- **US5 (P5)**: necesita US4 (listado/detalle de reuniones) como base de UI.
- **US6 (P6)**: necesita US4 (reunión con resumen ya generado) para tener
  algo que sincronizar.

### Parallel Opportunities

- Todas las tareas `[P]` de Fase 1 y Fase 2 en paralelo.
- Una vez completa la Fase 2, US1 y US2 pueden avanzar en paralelo (no
  comparten archivos hasta T025).
- US3 debe esperar a que T023 (captura de sistema) esté lista.
- Dentro de cada historia, las tareas de frontend marcadas `[P]` (distintos
  componentes) pueden hacerse en paralelo a las de backend.

---

## Parallel Example: User Story 1

```bash
# Backend (secuencial, mismo archivo managers/meeting.rs):
Task: "T011 start_meeting command"
Task: "T012 captura + VAD + transcripción por ventanas"
Task: "T013 diarización por segmento"

# Frontend (en paralelo entre sí, archivos distintos):
Task: "T017 RecordingControls.tsx"
Task: "T018 LiveTranscript.tsx"
Task: "T019 SpeakerAssignment.tsx"
```

---

## Implementation Strategy

### MVP First (User Story 1 únicamente)

1. Fase 1: Setup
2. Fase 2: Foundational (crítico — bloquea todo)
3. Fase 3: Historia 1 (diarización presencial)
4. **PARAR Y VALIDAR**: correr quickstart.md Escenario 1 y 3, confirmar SC-001
5. Recién ahí el notetaker tiene el diferencial real — es el punto mínimo
   defendible según el Principio VI, no antes.

### Entrega incremental

1. Setup + Foundational → base lista
2. Historia 1 → validar independiente → **este es el MVP real** (no una
   versión recortada — ya incluye diarización)
3. Historia 2 → validar independiente
4. Historia 3 → validar independiente (depende de 2)
5. Historia 4 → validar independiente
6. Historia 5 → validar independiente (depende de 4)
7. Historia 6 → validar independiente (depende de 4)
8. Polish → gate final antes de considerar la feature completa

---

## Notes

- `[P]` = archivos distintos, sin dependencias entre sí.
- El label de historia (`[US1]`..`[US6]`) mapea cada tarea a su historia en `spec.md` para trazabilidad.
- A diferencia del patrón típico de "MVP = lo mínimo", acá el MVP (Historia 1) YA incluye la parte difícil (diarización) — es intencional, ver Principio VI de la constitución.
- Commitear después de cada tarea o grupo lógico, con prefijo convencional (`feat:`, etc.) — Principio V.
- Parar en cada checkpoint para validar la historia de forma independiente antes de seguir.
