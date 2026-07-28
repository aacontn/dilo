# Implementation Plan: Notetaker de Reuniones

**Branch**: `001-meeting-notetaker` | **Date**: 2026-07-27 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-meeting-notetaker/spec.md`

## Summary

Agregar una segunda pata al producto: capturar reuniones (presenciales o
virtuales), transcribirlas de forma incremental, atribuir cada segmento a un
hablante distinguible (incluyendo el caso difícil de un solo micrófono de
campo lejano con voces superpuestas), detectar (para el caso virtual) cuando conviene ofrecer grabar con una
notificación de un click, generar resumen + pendientes vía el
proveedor LLM de post-proceso ya existente, y dejarlo todo revisable
(incluyendo notas propias del usuario, separadas del transcript), buscable
y sincronizable a un destino externo (ej. Apple Notes). Se
construye siguiendo el patrón de managers ya establecido en el backend, sin
reemplazar `transcription_history` sino agregando un ciclo de vida propio
para reuniones.

## Technical Context

**Language/Version**: Rust (edition 2021, stable toolchain) para el backend;
TypeScript estricto (sin `any`) para el frontend.

**Primary Dependencies**:
- Backend existente a reutilizar: `rusqlite` + `rusqlite_migration` (persistencia),
  `transcribe-cpp`/`transcribe-rs` (motores Whisper/Parakeet/Moonshine/SenseVoice),
  `vad-rs` (Silero VAD), `llm_client.rs` (proveedor LLM de post-proceso), Tauri 2.x
  (arquitectura comando-evento), `cpal`/`rubato` (audio toolkit).
- Nuevo, a resolver en Fase 0: motor de diarización local/offline embebible
  (NEEDS CLARIFICATION — no existe hoy en el codebase), mecanismo de captura de
  audio de sistema en macOS para reuniones virtuales (NEEDS CLARIFICATION),
  mecanismo de detección de videollamada activa para la Historia 3 (NEEDS
  CLARIFICATION).
- Frontend: React, Zustand, i18next, Tailwind — mismos que el resto de Dilo.

**Storage**: SQLite vía `rusqlite`, mismo motor que `transcription_history`
hoy, pero en tablas propias (`meetings`, `meeting_segments`) siguiendo el
patrón de migraciones de `managers/history.rs`.

**Testing**: `cargo test` (backend), `bun test tests/unit` (frontend unit),
`playwright test` (e2e, ya configurado en `.github/workflows/playwright.yml`).

**Target Platform**: macOS primero (Metal, permisos de accesibilidad y
micrófono ya resueltos por Dilo; captura de audio de sistema es
específicamente macOS-first para la Historia 2). Windows/Linux quedan para
después de validar el enfoque en macOS — ver Complexity Tracking.

**Project Type**: Desktop app (Tauri 2.x) — extensión de un proyecto
existente, no un proyecto nuevo.

**Performance Goals**: transcripción incremental visible pocos segundos
después de que alguien termina de hablar (spec SC-002); sin degradación
perceptible de latencia o memoria en sesiones de 2+ horas (spec SC-004).

**Constraints**: 100% offline para grabación/transcripción/diarización (spec
FR-013, FR-014, SC-005) — ningún audio sale del dispositivo; debe convivir
con el pipeline de dictado existente sin degradarlo.

**Scale/Scope**: grupos chicos (reunión de equipo o clase, no auditorio —
ver spec Assumptions). Sesiones de hasta varias horas.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principio | Evaluación | Estado |
|---|---|---|
| I. Núcleo Abierto y Agnóstico | El notetaker es una capacidad del núcleo (captura + presentación), no depende de ningún backend/negocio específico. El destino de sync (Apple Notes u otro) entra como configuración reemplazable, no hardcodeada. | ✅ PASS |
| II. Dilo Propone, Nunca Ejecuta | La sincronización a un destino externo (Historia 5) escribe únicamente en un destino que el propio usuario configuró de antemano (su propia app de notas) — no es una operación sensible de terceros (no envía, no borra, no compra). No requiere gate adicional de confirmación en tiempo real, pero el destino debe ser explícito y reversible (el usuario puede desconfigurarlo). | ✅ PASS |
| III. Español Primero, Sin Traducción Automática | Todo string nuevo de UI vía i18next; el copy `es` se escribe a mano como el resto del producto. Se verifica en Fase 2 (tasks) como criterio de aceptación, no solo como intención. | ✅ PASS (gate operativo en tasks) |
| IV. Cerca del Upstream (Handy) | El notetaker no existe en Handy upstream — es una feature nueva de Dilo, no una divergencia de algo que ya existía río arriba. No compite con este principio; el código nuevo vive en módulos propios (`managers/meeting.rs`, etc.) sin tocar la lógica de dictado existente. | ✅ PASS |
| V. Calidad No Negociable | `cargo fmt`/`clippy` y `eslint`/`prettier` aplican igual que al resto del repo; se listan como parte de Definition of Done en tasks, no como best-effort. | ✅ PASS (gate operativo en tasks) |
| VI. Sin Atajos de Alcance | Éste es el gate real de este plan. La Historia 1 (diarización presencial) es P1 y su enfoque técnico se investiga en Fase 0 (research.md) como un problema de primera clase, no se pospone. Si Fase 0 concluyera que no hay ningún enfoque viable local/offline, el plan debe decirlo explícitamente como bloqueo — no degradar en silencio a "solo post-proceso". | ⚠ VERIFICAR EN FASE 0 — ver research.md |

**Resultado del gate inicial**: PASA para avanzar a Fase 0, con la condición
de que Fase 0 resuelva de forma concreta (no evasiva) el enfoque de
diarización antes de pasar a Fase 1. Re-evaluar este gate después del
diseño.

### Re-evaluación post-diseño (después de Fase 0 y Fase 1)

| Principio | Re-evaluación | Estado |
|---|---|---|
| VI. Sin Atajos de Alcance | `research.md` §1 define un enfoque concreto y viable (pipeline ONNX estilo sherpa-onnx, embebible, offline, con clustering para número de hablantes desconocido) — no es un placeholder ni "a definir después". El límite honesto (overlap total de dos voces simultáneas no se separa con precisión perfecta) queda documentado explícitamente en vez de prometerse de más u ocultarse. `data-model.md` modela `overlapped` y `speaker_id NULL` como estados de primera clase, no como casos de error. | ✅ PASS — el gate se cumple con un enfoque real, sujeto al límite honesto documentado |

Todos los demás principios se mantienen ✅ PASS sin cambios tras el diseño —
ningún artefacto de Fase 1 introdujo dependencias de un backend específico,
lógica de ejecución sin confirmación, strings hardcodeados, ni divergencia
innecesaria del upstream.

## Project Structure

### Documentation (this feature)

```text
specs/001-meeting-notetaker/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md         # Phase 1 output
├── quickstart.md         # Phase 1 output
├── contracts/            # Phase 1 output
└── tasks.md              # Phase 2 output (/speckit-tasks, not this command)
```

### Source Code (repository root)

Dilo es una app Tauri existente (no un proyecto nuevo) — esta feature se
integra en la estructura ya presente:

```text
src-tauri/src/
├── managers/
│   ├── meeting.rs           # NUEVO — ciclo de vida de reuniones (start/stop/
│   │                        #   recover), sigue el patrón de audio.rs/history.rs
│   ├── diarization.rs        # NUEVO — motor de diarización local (enfoque
│   │                        #   concreto definido en research.md)
│   ├── history.rs            # existente, sin tocar transcription_history
│   ├── transcription.rs      # existente — se extiende para alimentar al
│   │                        #   pipeline de reunión, sin romper dictado
│   └── audio.rs              # existente — extendido con captura de audio
│                              #   de sistema (macOS) para reuniones virtuales
├── audio_toolkit/
│   ├── vad/                  # existente (Silero), se reutiliza tal cual
│   └── audio/                # existente, se extiende con captura de
│                              #   sistema (nuevo módulo, ej. system_audio.rs)
│                              #   y detección de llamada activa (Historia 3,
│                              #   research.md §4) sobre la misma sesión
├── commands/
│   └── meeting.rs            # NUEVO — comandos Tauri (start_meeting,
│                              #   stop_meeting, list_meetings, etc.)
└── llm_client.rs             # existente, reutilizado para resumen + pendientes

src/
├── components/
│   └── meeting/               # NUEVO — UI de grabación, tabs de revisión
│                              #   (Transcript/Resumen/Pendientes), hub de
│                              #   reuniones, asignación de hablantes
├── hooks/
│   └── useMeetings.ts         # NUEVO, sigue el patrón de useSettings.ts
├── stores/
│   └── meetingStore.ts        # NUEVO, Zustand, sigue settingsStore.ts
└── i18n/locales/*/translation.json  # nuevas claves, es escrito a mano
```

**Structure Decision**: extender la app Tauri existente con managers y
comandos nuevos siguiendo el patrón ya establecido (no un proyecto/servicio
separado). El único subsistema genuinamente nuevo a nivel de arquitectura es
la diarización local — todo lo demás compone sobre infraestructura que ya
existe en el repo.

## Complexity Tracking

> Fill ONLY if Constitution Check has violations that must be justified

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| Alcance inicial limitado a macOS para captura de audio de sistema (Historia 2) | La API de captura de audio de sistema (tipo ScreenCaptureKit) es específica de plataforma; no hay una librería cross-platform madura y offline disponible hoy en el ecosistema Rust/Tauri de Dilo. | Bloquear todo el feature hasta tener paridad Windows/Linux retrasaría la Historia 1 (P1, el diferencial real) sin necesidad — la diarización presencial no depende de captura de sistema. Windows/Linux quedan como expansión posterior de la Historia 2, no una reducción de alcance de la Historia 1. |
