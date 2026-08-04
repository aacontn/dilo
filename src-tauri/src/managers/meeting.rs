//! Manages the lifecycle of a meeting notetaker session: recording, live
//! transcription, and speaker diarization. T005 added the SQLite schema
//! (migrations), and T006 added `get_connection()` so later tasks can open
//! per-operation connections against the migrated database, mirroring
//! `HistoryManager`'s pattern. T011 added the first real business logic,
//! `start_meeting()` — it only creates the `meetings` row. T012 wired real
//! microphone capture + VAD + incremental transcription into a meeting
//! session — see [`MeetingManager::start_capture`] and the
//! coexistence-with-dictation decision documented just above it.
//!
//! **2026-08-04: el VAD neuronal salió del camino de reuniones.** Medido
//! contra `meetings.db` real, Silero (afinado para dictado: micrófono
//! cerca, una sola voz, silencio alrededor) descartaba entre 13% y 79% del
//! audio de reuniones reales — peor cuanto más se mezclaba la voz con
//! música o compresión de video. El reemplazo es una compuerta de energía
//! (RMS) mucho más permisiva: ver [`has_energy`] y el comentario de
//! [`ENERGY_GATE_RMS`] para la justificación del umbral. El VAD del dictado
//! (`managers/audio.rs`) no se tocó: ahí filtrar sigue siendo correcto.
//!
//! **2026-08-04: el troceo por turnos salió del camino de reuniones**
//! (Task 5 del plan "reuniones en streaming",
//! `.superpowers/sdd/2026-08-04-reuniones-en-streaming/`). Antes, el audio
//! se acumulaba en turnos cerrados por silencio o por un tope de duración
//! (`TurnAccumulator`), cada turno se diarizaba de a uno (`diarization.rs`)
//! y se re-identificaba contra un registro de hablantes por embeddings
//! (`SpeakerRegistry`) porque cada llamada a `diarize()` devolvía índices de
//! hablante locales a ESE turno. El problema motivador: una interrupción
//! corta (media palabra de otro hablante pisando al que tenía la palabra)
//! no cabía en un turno propio y se perdía, fundida en el de al lado.
//!
//! Ahora el audio capturado alimenta DOS flujos continuos en paralelo, sin
//! cortarlo en turnos: el reconocimiento de voz en streaming
//! (`TranscriptionManager::start_stream` con `StreamPurpose::Meeting`, que
//! entrega [`TimedToken`]s con marca de tiempo real) y la diarización en
//! streaming (`StreamingDiarizer::push`, que entrega `SpeakerSpan`s). Los
//! dos se cruzan con `align::attribute` para armar intervenciones
//! atribuidas (`AttributedRun`) que sobreviven una interrupción de un solo
//! token — ver [`segments_from_runs`] y el hilo diarizador en
//! [`MeetingManager::start_capture`]. Como el caché de hablantes de
//! Sortformer (`spkcache`/`fifo`) ya mantiene la identidad estable DENTRO de
//! una reunión completa (no por turno), el registro por embeddings dejó de
//! hacer falta: [`resolve_local_speaker`] sólo mapea el índice local de
//! Sortformer (0..4) a un `meeting_speakers.id`, sin comparar voces. La
//! diarización por lotes de `diarization.rs` no se tocó: sigue sirviendo
//! para audio ya grabado, sólo dejó de ser lo que atribuye hablantes en
//! vivo.

use crate::audio_toolkit::{
    audio::{system_audio_available, CaptureDiagnosis, SystemAudioRecorder},
    AudioRecorder, VadPolicy,
};
use crate::managers::audio::{AudioRecordingManager, MicOwner, MicrophoneArbiter};
use crate::managers::diarization::align::{attribute, AttributedRun};
use crate::managers::diarization::sortformer::{SpeakerSpan, StreamingDiarizer};
use crate::managers::diarization_models;
use crate::managers::model::ModelManager;
use crate::managers::transcription::{
    StreamPurpose, StreamTextEvent, TimedToken, TranscriptionManager,
};
use crate::settings::MeetingAudioSource;
use anyhow::{bail, Result};
use chrono::{Local, Utc};
use log::{debug, error, info, warn};
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use rusqlite_migration::{Migrations, M};
use serde::{Deserialize, Serialize};
use specta::Type;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Listener, Manager};
use tauri_specta::Event;

/// Database migrations for the meeting notetaker feature.
/// Each migration is applied in order. The library tracks which migrations
/// have been applied using SQLite's user_version pragma (same mechanism as
/// `managers/history.rs`).
///
/// All six tables are created in a single initial migration (rather than one
/// table per migration) so that the foreign-key dependency order between
/// them — `sync_destinations` -> `meetings` -> `meeting_speakers` ->
/// `meeting_segments`, and `meetings` -> `meeting_action_items` /
/// `meeting_notes` — is guaranteed within one `execute_batch` call. Schema
/// verbatim from `specs/001-meeting-notetaker/data-model.md`.
static MIGRATIONS: &[M] = &[M::up(
    "CREATE TABLE IF NOT EXISTS sync_destinations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        config TEXT NOT NULL,
        enabled BOOLEAN NOT NULL DEFAULT 1
    );

    CREATE TABLE IF NOT EXISTS meetings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        kind TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        ended_at INTEGER,
        status TEXT NOT NULL,
        summary TEXT,
        summary_prompt TEXT,
        sync_destination_id INTEGER,
        synced_at INTEGER,
        FOREIGN KEY (sync_destination_id) REFERENCES sync_destinations(id)
    );

    CREATE TABLE IF NOT EXISTS meeting_speakers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        meeting_id INTEGER NOT NULL,
        label TEXT NOT NULL,
        display_name TEXT,
        merged_into_id INTEGER,
        FOREIGN KEY (meeting_id) REFERENCES meetings(id),
        FOREIGN KEY (merged_into_id) REFERENCES meeting_speakers(id)
    );

    CREATE TABLE IF NOT EXISTS meeting_segments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        meeting_id INTEGER NOT NULL,
        speaker_id INTEGER,
        text TEXT NOT NULL,
        started_at_ms INTEGER NOT NULL,
        ended_at_ms INTEGER NOT NULL,
        overlapped BOOLEAN NOT NULL DEFAULT 0,
        FOREIGN KEY (meeting_id) REFERENCES meetings(id),
        FOREIGN KEY (speaker_id) REFERENCES meeting_speakers(id)
    );

    CREATE TABLE IF NOT EXISTS meeting_action_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        meeting_id INTEGER NOT NULL,
        text TEXT NOT NULL,
        done BOOLEAN NOT NULL DEFAULT 0,
        order_index INTEGER NOT NULL,
        FOREIGN KEY (meeting_id) REFERENCES meetings(id)
    );

    CREATE TABLE IF NOT EXISTS meeting_notes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        meeting_id INTEGER NOT NULL UNIQUE,
        content TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (meeting_id) REFERENCES meetings(id)
    );",
)];

/// Table names created by `MIGRATIONS`, in dependency order. Used by tests
/// to verify the schema was applied.
#[cfg(test)]
const MEETING_TABLES: &[&str] = &[
    "sync_destinations",
    "meetings",
    "meeting_speakers",
    "meeting_segments",
    "meeting_action_items",
    "meeting_notes",
];

// --- Tauri events (T010) -----------------------------------------------
//
// Type definitions only — nothing here emits an event yet. Emission starts
// in Phase 3 (T014+) once the commands that drive a meeting's lifecycle are
// implemented.
//
// A note on event names: `tauri_specta::Event`'s derive macro (pinned at
// tauri-specta-macros 2.0.0-rc.16 via tauri-specta =2.0.0-rc.21, see
// Cargo.lock) hardcodes the wire event name to `heck::ToKebabCase` of the
// Rust struct/enum identifier. It declares `attributes(tauri_specta)` but
// does not read any value from it in this version — there is no way to
// override the event name with an attribute, only by naming the type
// itself. That's also how the existing events in this codebase resolve
// their names: `HistoryUpdatePayload` -> `history-update-payload`,
// `StreamTextEvent` -> `stream-text-event` (see `src/bindings.ts`), not the
// shorter names their doc comments might suggest.
//
// Because of this, the 7 event structs below are named to match
// `specs/001-meeting-notetaker/contracts/tauri-commands.md`'s required
// wire names exactly (`MeetingSegment` -> `meeting-segment`, etc.) — they
// do NOT carry an `...Event` suffix the way a first read of the task brief
// might suggest, since e.g. `MeetingSegmentEvent` would kebab-case to
// `meeting-segment-event`, not `meeting-segment`.
//
// This also means `MeetingSegment` below is the flat, full segment shape
// from `data-model.md` / `contracts/tauri-commands.md`'s `MeetingSegment`
// TS interface (no `meeting_id` field — the doc's own wording is "Payload:
// `MeetingSegment` completo"), not a `{ meeting_id, segment }` wrapper.
// Keeping it flat also avoids defining a second, differently-shaped
// `MeetingSegment` type that Phase 3 would collide with when it needs this
// exact DTO for `Meeting.segments`. Reuse this type there instead of
// duplicating it.

/// Emitted whenever a new transcript segment is ready (incremental, during
/// recording).
#[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct MeetingSegment {
    pub id: i64,
    pub speaker_id: Option<i64>,
    pub text: String,
    pub started_at_ms: i64,
    pub ended_at_ms: i64,
    pub overlapped: bool,
}

/// Phase of post-recording processing (summary generation, diarization when
/// it runs as a separate step, etc.), reported via [`MeetingProgress`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "lowercase")]
pub enum MeetingProgressPhase {
    Transcribing,
    Diarizing,
    Summarizing,
}

/// Emitted while a finished recording is being processed (summary,
/// diarization if it runs as a separate step, etc.).
#[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct MeetingProgress {
    pub meeting_id: i64,
    pub phase: MeetingProgressPhase,
}

/// The meeting finished processing (`status` -> `ready`).
#[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct MeetingFinished {
    pub meeting_id: i64,
}

/// Error during recording or post-processing.
///
/// **Significa que la sesión terminó.** El frontend lo trata como fin de
/// sesión (limpia la sesión en curso y vuelve a "listo para grabar"), así que
/// sólo puede emitirse cuando la captura efectivamente ya no está corriendo o
/// se está cerrando — de lo contrario la pantalla pierde el botón de detener
/// mientras el micrófono sigue abierto. Para un fallo del que la sesión se
/// recupera, ver [`MeetingTurnFailed`].
#[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct MeetingError {
    pub meeting_id: i64,
    pub error: String,
}

/// Un turno se perdió (no se pudo transcribir o guardar) **pero la reunión
/// sigue grabando**.
///
/// Existe para no mentirle al frontend: mandar `MeetingError` acá terminaba
/// la sesión en pantalla mientras el backend seguía capturando, y sin botón
/// de detener el micrófono y el árbitro quedaban tomados hasta reiniciar la
/// app. Esto se muestra como aviso y no toca el estado de la sesión.
#[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct MeetingTurnFailed {
    pub meeting_id: i64,
    pub error: String,
}

/// Detected at app startup: a meeting without `ended_at` left over from a
/// previous session (crash recovery, FR-008).
#[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct MeetingInterrupted {
    pub meeting_id: i64,
}

/// An active video call was detected with no recording in progress
/// (User Story 3, FR-017). `call_source` is the detected app name when it
/// could be determined.
#[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct MeetingCallDetected {
    pub call_source: Option<String>,
}

/// The video call that triggered an auto-detected recording has ended
/// (User Story 3, FR-018).
#[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct MeetingCallEnded {
    pub meeting_id: i64,
}

/// Por qué se emitió un [`MeetingAudioWarning`] durante una grabación con
/// audio del sistema (cableado de audio de reuniones). El texto que ve el
/// usuario vive en el frontend (i18n, 21 idiomas) — acá sólo va el motivo,
/// no un mensaje.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "snake_case")]
pub enum MeetingAudioWarningKind {
    /// `CaptureDiagnosis::LikelyMissingPermission`: todo lo capturado es
    /// cero digital y había algo sonando — verificado contra hardware real,
    /// así es exactamente como se ve grabar sin el permiso de audio del
    /// sistema concedido (ver `system_audio.rs`).
    MissingPermission,
    /// `SystemAudioRecorder::output_device_changed()`: el usuario cambió el
    /// dispositivo de salida por defecto (por ejemplo, conectó audífonos) a
    /// mitad de reunión — la captura puede haber quedado muda.
    OutputDeviceChanged,
    /// I4 del reporte de seguimiento: la sesión lleva
    /// [`SILENCE_WARNING_THRESHOLD`] (o terminó) sin capturar ni una sola
    /// muestra distinta de cero, y no fue por falta de permiso
    /// (`MissingPermission` ya cubre ese caso). El acoplamiento kind/fuente
    /// mitiga el caso más común (una reunión presencial ya no usa audio del
    /// sistema por default), pero no lo cierra: una reunión online donde el
    /// usuario nunca compartió el audio, o donde la llamada va por el
    /// teléfono en vez del computador, sigue cayendo en silencio genuino sin
    /// ningún aviso si no fuera por esto.
    NoAudioCaptured,
    /// I2 del reporte de seguimiento: la fuente resuelta era audio del
    /// sistema pero `open()`/`start()` fallaron al abrir la sesión (por
    /// ejemplo, `AudioHardwareCreateProcessTap` falló) — la reunión sigue
    /// grabando, mediante el micrófono, en vez de abortar.
    FellBackToMicrophone,
}

/// Aviso durante una grabación con audio del sistema — no termina la
/// sesión (a diferencia de [`MeetingError`]), es información para que el
/// usuario pueda actuar (conceder el permiso, o saber que puede haber
/// perdido audio) sin esperar a colgar para enterarse.
#[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct MeetingAudioWarning {
    pub meeting_id: i64,
    pub kind: MeetingAudioWarningKind,
}

/// Cuántos avisos de audio de reunión se guardan mientras no haya ventana
/// que los muestre. Mismo límite y mismo motivo que
/// `MAX_PENDING_FALLBACK_NOTICES`/`MAX_PENDING_ASSISTANT_NOTICES`
/// (`actions.rs`/`assistant.rs`): una fuente en falla permanente durante una
/// reunión larga podría, en el peor caso, generar varios.
const MAX_PENDING_MEETING_AUDIO_NOTICES: usize = 10;

/// Cola de avisos de audio de reunión (`meeting-audio-warning`) pendientes de
/// mostrar — I5 del reporte de seguimiento.
///
/// El flujo esperado es grabar y volver a la videollamada: tanto
/// `return_to_main_window` como el botón de cerrar de la ventana de
/// Reuniones la **esconden** (`window.hide()`), no la destruyen —
/// `meeting_window.rs` lo hace así a propósito para no perder el estado de
/// una sesión en curso. El webview sigue vivo y su listener de
/// `meeting-audio-warning` sigue recibiendo el evento, pero el toast se
/// dibuja en una ventana que nadie está mirando. Como el aviso se emite como
/// máximo una vez por tipo y por sesión (`report_audio_warning`), sin esta
/// cola se perdía para siempre sin que nadie llegara a verlo.
///
/// Mismo patrón que `actions::PendingFallbackNotices`/
/// `assistant::PendingAssistantNotices` — reusado a propósito en vez de
/// inventar un mecanismo nuevo: el frontend la vacía tanto al montar como al
/// recuperar el foco la ventana de Reuniones
/// (`take_pending_meeting_audio_notices`, `useMeetings.ts`).
#[derive(Default)]
pub struct PendingMeetingAudioNotices(Mutex<Vec<MeetingAudioWarning>>);

impl PendingMeetingAudioNotices {
    fn push(&self, notice: MeetingAudioWarning) {
        let mut queue = match self.0.lock() {
            Ok(q) => q,
            Err(poisoned) => poisoned.into_inner(),
        };
        while queue.len() >= MAX_PENDING_MEETING_AUDIO_NOTICES {
            queue.remove(0);
        }
        queue.push(notice);
    }

    /// Devuelve los avisos pendientes y deja la cola vacía.
    pub fn take_all(&self) -> Vec<MeetingAudioWarning> {
        let mut queue = match self.0.lock() {
            Ok(q) => q,
            Err(poisoned) => poisoned.into_inner(),
        };
        std::mem::take(&mut *queue)
    }
}

// --- T012: microphone/system-audio capture -> energy gate -> incremental
// --- transcription --------------------------------------------------------
//
// # Coexistence with dictation (architecture decision, T012)
//
// **Decision: mutually exclusive.** A meeting recording and a normal
// dictation recording (the global-shortcut flow in `AudioRecordingManager`)
// never run at the same time. Attempting either while the other is actively
// recording fails fast with a clear error instead of silently mixing audio
// or crashing.
//
// **Why**: both `AudioRecordingManager` (dictation) and `MeetingManager`
// (this file) build their own independent `AudioRecorder` — see
// `managers/audio.rs`'s `create_audio_recorder` and this file's
// `build_meeting_recorder` — each of which opens its own `cpal::Stream` on
// the input device via `cpal::Device::build_input_stream`. `cpal` has no
// built-in concept of sharing one physical device between two independently
// negotiated streams: each stream negotiates its own sample format/rate and
// registers its own OS-level callback (CoreAudio HAL / WASAPI / ALSA-
// PipeWire-PulseAudio, depending on platform). Whether a second concurrent
// open of the *same* device succeeds is backend- and driver-dependent —
// some CoreAudio/PipeWire setups tolerate it, WASAPI exclusive-mode and many
// ALSA-only Linux setups do not — and even where it technically works,
// running two independent VAD-driven recordings off the same input in
// parallel serves no real product purpose here (a meeting session already
// captures everything dictation would, and mixing two separate transcript
// streams from the same room would be actively confusing). Given that, and
// given this task's environment has no real audio hardware to verify the
// "does it actually work" question empirically across all 3 platforms,
// mutual exclusion is the safe, honest default: it can never corrupt or mix
// audio, and it degrades to a clear error instead of undefined behavior.
//
// **How it's enforced**: `MicrophoneArbiter` (`managers/audio.rs`) is a
// small `Arc<Mutex<Option<MicOwner>>>` gate created once in
// `initialize_core_logic` and shared (cloned) into both
// `AudioRecordingManager` and `MeetingManager` — neither module imports the
// other's types, so there's no dependency cycle between `audio.rs` and
// `meeting.rs`. The arbiter tracks "is *any* dictation mic stream open,"
// not just "is a recording active": `AudioRecordingManager::
// start_microphone_stream` claims `MicOwner::Dictation` right before it
// actually opens the device (covering both on-demand recording and
// always-on's persistent idle stream — every caller of that function routes
// through the same check, startup/mode-switch included), and
// `AudioRecordingManager::stop_microphone_stream` releases it at the
// mirror-image point, when the device is actually closed.
// `MeetingManager::start_capture`/`stop_capture` do the same for
// `MicOwner::Meeting` around opening/closing their own `AudioRecorder`.
// Whichever side is active blocks the other with a message naming the
// current holder — including the always-on case: while always-on mode is
// enabled, `start_capture` deterministically fails with a clear error
// (the device stream never stops being open, so the arbiter never frees up)
// instead of silently opening a second concurrent stream. This closes what
// was originally flagged here as an open gap; see the T012 review report
// (`.superpowers/sdd/task-T012-report.md`, "Review fixes (round 2)") for
// the full before/after.
//
// **Residual, deliberate gap**: with the `lazy_stream_close` setting
// enabled, `AudioRecordingManager` keeps an on-demand mic stream open for
// `STREAM_IDLE_TIMEOUT` (30s) after a recording ends, in case another
// recording starts again soon (`schedule_lazy_close`). Since the arbiter
// now tracks the *stream*, not the *recording*, dictation keeps holding it
// for that full 30s grace window too — a meeting can't start during that
// window even though nothing is actively being dictated. This is the
// correct, honest consequence of the fix above (the device genuinely is
// still open), not a new bug — noted here so it isn't mistaken for one.
//
// # "Hours, not seconds" and the underlying `AudioRecorder`'s buffer
//
// `AudioRecorder` (`audio_toolkit/audio/recorder.rs`) was built for
// dictation's seconds-long sessions: everything that passes its VAD accumulates
// into one in-memory `Vec<f32>` for the whole `start()`..`stop()` window, only
// read back when `stop()` is finally called. This task reuses that recorder
// (via `build_meeting_recorder`, mirroring `audio.rs`'s
// `create_audio_recorder`) for a *single, continuous* `start()` spanning the
// whole meeting, rather than reimplementing microphone capture — but that
// means the recorder's own internal buffer also keeps every sample in
// memory for the meeting's full duration, on top of what the two streaming
// engines (ASR + `StreamingDiarizer`) already hold internally to do their
// own job. The recorder's copy is redundant (this module never reads
// `AudioRecorder::stop()`'s return value) and unbounded: roughly 64 KB/s of
// audio that passes the energy gate, so a hypothetical multi-hour meeting
// with e.g. 45 minutes of total speech would hold ~170 MB in that redundant
// buffer by the end. This is called out explicitly as a known
// simplification rather than fixed in this task: a correct fix
// (periodically recycling the recorder's `stop()`/`start()`, or adding a
// `drain()` method upstream) is not free — recycling would have to run from
// a thread other than the recorder's own consumer thread to avoid a
// deadlock (`stop()` blocks waiting for a reply the consumer thread would
// have to send while it's the one calling this code) — and isn't validated
// here against real audio. For the meeting lengths this feature targets
// (single meetings, not multi-day always-on capture) the memory cost is
// real but not disqualifying; flagged here for a follow-up task rather than
// risking an unverified fix.
//
// This bears on SC-004 ("sin degradación de memoria/latencia perceptible
// en reuniones de más de 2 horas") on **two** axes, not just memory. The
// `out_buf.extend_from_slice(buf)` call that grows this buffer
// (`audio_toolkit/audio/recorder.rs`'s `handle_frame`/`emit`) runs
// synchronously on `run_consumer`'s single thread — the same thread that
// also resamples every incoming chunk, drives the VAD, and calls this
// module's `audio_cb` (which is what feeds both streaming engines). A
// `Vec<f32>` that has grown to hundreds of MB reallocates (and memcpy's its
// *entire* existing contents) on an amortized-doubling schedule —
// infrequent, but each one copies more data than the last as the meeting
// goes on, so the worst-case stall on that single thread gets *larger*, not
// smaller, later into a long meeting. Any such stall delays `audio_cb` for
// whatever frames arrive during it, which delays when a token/span reaches
// the diarizer thread and therefore when a segment gets persisted — i.e. a
// plausible, compounding
// latency-degradation mechanism over a multi-hour meeting, not just a
// memory one. I have not measured this (no real multi-hour audio run in
// this environment) — flagging the mechanism, not a measurement, so
// whoever runs T053's SC-004 validation knows to watch both memory *and*
// segment-latency-over-time, not just memory.

/// Umbral de energía (RMS, en la misma escala [-1.0, 1.0] que las muestras
/// que entrega `cpal`) por debajo del cual un tramo de audio se trata como
/// silencio para el pipeline de reuniones: no se le manda ni al
/// reconocimiento de voz en streaming ni a la diarización en streaming (ver
/// `audio_cb` en [`MeetingManager::start_capture`]).
///
/// **Por qué RMS y no el VAD neuronal que reemplaza.** El VAD (Silero) es un
/// clasificador voz/no-voz: le pasa lo que reconoce como habla humana y
/// descarta el resto, así que música, aplausos, una risa, o voz muy
/// comprimida/mezclada con audio de sistema puede no "sonarle" a voz y
/// quedar afuera — exactamente lo medido contra `meetings.db` real que
/// motivó este cambio (39-79% del audio de reuniones con video/música
/// descartado). RMS no clasifica nada: sólo mide cuánta energía hay. Es
/// mucho más tonto y por eso mucho más permisivo — música, aplausos, voz
/// comprimida, todo lo que tenga amplitud real pasa igual — pero sigue
/// distinguiendo lo único que de verdad hay que distinguir acá: silencio
/// digital (o un piso de ruido tan bajo que no vale la pena transcribirlo)
/// contra cualquier otra cosa.
///
/// **Por qué no [`crate::audio_toolkit::audio::has_nonzero_sample`]**, la
/// señal que ya existe en el módulo de audio del sistema: esa función
/// contesta "¿hay AL MENOS UNA muestra distinta de cero?", pensada para
/// distinguir silencio digital exacto (el síntoma de grabar sin permiso de
/// audio del sistema, ver `system_audio.rs`) de cualquier captura con
/// contenido real. Sirve para ese diagnóstico puntual, pero es demasiado
/// laxa para gatillar transcripción: un piso de ruido eléctrico bajo, o un
/// solo sample de redondeo que no sea exactamente 0.0, ya la satisface sin
/// que haya nada que valga la pena transcribir. RMS sobre el tramo entero no
/// tiene ese problema: una sola muestra alta en un mar de ceros apenas mueve
/// el promedio cuadrático.
///
/// **El valor: 0.005 lineal, ≈ -46 dBFS** (`20 * log10(0.005) ≈ -46.02`).
/// Elegido para caer claramente entre dos franjas:
/// - **Por debajo, y por lo tanto rechazado:** silencio digital exacto
///   (RMS 0.0, el caso que motivó `has_nonzero_sample` en primer lugar) y el
///   piso de ruido típico de un micrófono o de audio de sistema sin nada
///   sonando — ruido térmico/eléctrico y de cuantización, que en la
///   práctica se queda bastante por debajo de -50 dBFS salvo hardware
///   defectuoso o ganancia de entrada anormalmente alta.
/// - **Por encima, y por lo tanto aceptado:** voz conversacional a nivel de
///   grabación normal (típicamente -25 a -15 dBFS de RMS) y música o audio
///   de sistema mezclado, incluso bajo o distante (-35 dBFS para abajo es ya
///   un caso extremo). Un margen de al menos ~20 dB separa el umbral de
///   cualquier contenido real que interese transcribir, así que un hablante
///   grabando bajo, o un video con volumen bajo, sigue pasando con margen de
///   sobra.
///
/// No hay una medición contra hardware real que calibre esto con precisión
/// (mismo límite que el resto de este módulo: sin audio real disponible en
/// este entorno) — el valor es una estimación de ingeniería a partir de
/// niveles típicos de dBFS, deliberadamente conservadora hacia el lado
/// permisivo (más cerca del piso de ruido que del contenido real), porque el
/// costo de dejar pasar un tramo casi silencioso (en el peor caso, un tramo
/// de audio real que no produce texto) es mucho menor que el de cortar voz
/// real.
const ENERGY_GATE_RMS: f32 = 0.005;

/// Energía RMS (root-mean-square) de `samples`, en la misma escala que las
/// muestras de entrada. `0.0` para un buffer vacío. Acumula en `f64` para no
/// perder precisión antes de volver a `f32`.
fn rms_energy(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum_sq: f64 = samples.iter().map(|&s| (s as f64) * (s as f64)).sum();
    ((sum_sq / samples.len() as f64).sqrt()) as f32
}

/// La compuerta de energía en sí: `true` si `samples` tiene suficiente
/// energía como para no ser silencio digital ni piso de ruido — ver
/// [`ENERGY_GATE_RMS`]. Función pura, aplicada por frame dentro de `audio_cb`
/// (ver [`MeetingManager::start_capture`]) antes de mandarle nada a los dos
/// motores en vivo.
fn has_energy(samples: &[f32]) -> bool {
    rms_energy(samples) >= ENERGY_GATE_RMS
}

/// How often the watchdog thread checks in (mantiene vivo el reloj de
/// inactividad del modelo y sondea el diagnóstico de audio del sistema).
const WATCHDOG_POLL_INTERVAL: Duration = Duration::from_millis(100);
/// Cada cuánto el watchdog sondea el diagnóstico del audio del sistema
/// (`SystemAudioRecorder::diagnose_now()`/`output_device_changed()`, I6/I5
/// del reporte de `system_audio.rs`) mientras graba con esa fuente. No es
/// `WATCHDOG_POLL_INTERVAL`: sondear cada 100ms sería ruido y, sondeado
/// demasiado pronto (antes del primer bloque de audio), `diagnose_now()`
/// puede dar legítimamente `NoSamplesCaptured` sin que signifique nada. Una
/// reunión de 40 minutos igual necesita enterarse mucho antes de colgar, no
/// sólo al final — de ahí el sondeo periódico en vez de uno solo en
/// `stop_capture`.
///
/// M6 (reporte de cableado): este símbolo tenía `#[allow(dead_code)]`
/// aunque ya se usa en `start_capture` — quitado.
const SYSTEM_AUDIO_DIAGNOSIS_POLL: Duration = Duration::from_secs(5);
/// I4 del reporte de cableado: a partir de cuánto tiempo sin capturar ni una
/// sola muestra distinta de cero se avisa, sin importar si algún proceso
/// está reproduciendo audio (a diferencia de `MissingPermission`, que exige
/// esa segunda señal). Dos minutos: bastante más que el arranque normal de
/// una reunión online (compartir audio, que el otro lado empiece a hablar),
/// pero corto en la escala de una reunión — grabar 2 minutos seguidos de
/// cero ya es señal suficiente de que algo no está sonando por el
/// computador (el usuario no compartió audio, o la llamada va por el
/// teléfono), no hace falta esperar a que termine para decirlo.
///
/// `stop_capture` NO usa este umbral: una reunión que terminó antes de
/// alcanzarlo (por ejemplo, se armó y se cortó a los 30s) igual avisa al
/// cerrar si todo lo capturado fue cero — ver el comentario ahí.
const SILENCE_WARNING_THRESHOLD: Duration = Duration::from_secs(120);
/// A partir de cuántos tramos de audio encolados sin diarizar se avisa en el
/// log. La cola (`mpsc`) hacia el hilo diarizador no tiene cota: si la
/// diarización va más lenta que tiempo real, crece sin freno y el audio
/// pendiente se acumula en memoria. La backpressure real es trabajo aparte;
/// esto al menos deja rastro en `handy.log` de que pasó, en vez de un
/// consumo de memoria inexplicable.
const QUEUE_DEPTH_WARN_THRESHOLD: usize = 50;

/// Avisa al frontend de un fallo que **mata la sesión** (`meeting-error`).
///
/// Sin esto una reunión podía "grabar" horas con cero segmentos y sin decir
/// nada: los errores del hilo diarizador terminaban únicamente en
/// `handy.log`. Quien lo llama tiene que dejar además la captura cerrada
/// (ver `spawn_capture_abort`): el frontend lee este evento como fin de
/// sesión, y anunciar el fin mientras el micrófono sigue abierto le deja la
/// app trancada al usuario.
fn report_fatal_capture_failure<R: tauri::Runtime>(
    app_handle: Option<&AppHandle<R>>,
    meeting_id: i64,
    error: String,
) {
    error!("Meeting {}: {}", meeting_id, error);
    if let Some(app) = app_handle {
        let payload = MeetingError { meeting_id, error };
        if let Err(e) = payload.emit(app) {
            warn!("Failed to emit meeting-error for {}: {}", meeting_id, e);
        }
    }
}

/// Avisa del primer turno perdido de esta sesión (`meeting-turn-failed`) y
/// sólo loggea los siguientes. **La reunión sigue grabando**: un turno que
/// falla no la termina, y el usuario tiene que conservar su botón de
/// detener.
///
/// Se emite sólo el primero porque el modo de falla típico es permanente (el
/// disco está lleno, el engine quedó roto) y se repetiría en cada turno — un
/// aviso sirve, doscientos son ruido.
fn report_turn_failure<R: tauri::Runtime>(
    app_handle: Option<&AppHandle<R>>,
    meeting_id: i64,
    already_reported: &mut bool,
    error: String,
) {
    error!("Meeting {}: {}", meeting_id, error);
    if *already_reported {
        return;
    }
    *already_reported = true;
    if let Some(app) = app_handle {
        let payload = MeetingTurnFailed { meeting_id, error };
        if let Err(e) = payload.emit(app) {
            warn!(
                "Failed to emit meeting-turn-failed for {}: {}",
                meeting_id, e
            );
        }
    }
}

/// Avisa `meeting-audio-warning` (audio del sistema: falta el permiso, el
/// dispositivo de salida cambió a mitad de reunión, varios minutos sin
/// capturar nada real, o se cayó a micrófono al abrir) — **no termina la
/// sesión**, es sólo información. Se reporta como máximo una vez por `kind`
/// y por sesión de captura (`already_reported`, compartido entre el
/// watchdog y `stop_capture` — ver `AudioWarningState`): la reunión sigue
/// grabando aunque falte el permiso, así que repetir el aviso en cada
/// sondeo del watchdog sería ruido — el usuario ya lo vio la primera vez.
///
/// M1 (reporte de seguimiento): el guard va PRIMERO, antes del `warn!` y de
/// cualquier trabajo. Antes el log corría en cada sondeo del watchdog
/// (`SYSTEM_AUDIO_DIAGNOSIS_POLL`, cada 5s) mientras la condición se
/// mantuviera cierta — con el permiso realmente faltando eso son ~720
/// líneas/hora en `handy.log` sin decir nada que la primera línea no dijera
/// ya.
fn report_audio_warning<R: tauri::Runtime>(
    app_handle: Option<&AppHandle<R>>,
    meeting_id: i64,
    already_reported: &AtomicBool,
    kind: MeetingAudioWarningKind,
) {
    if already_reported.swap(true, Ordering::SeqCst) {
        return;
    }
    warn!(
        "Meeting {}: aviso de audio del sistema {:?}",
        meeting_id, kind
    );
    let Some(app) = app_handle else { return };
    let payload = MeetingAudioWarning { meeting_id, kind };
    // I5: se encola SIEMPRE, no sólo cuando la ventana de Reuniones está
    // escondida — igual que `PendingFallbackNotices`/`PendingAssistantNotices`,
    // más simple que decidir acá si hay o no una ventana visible escuchando,
    // y el costo es sólo clonar un struct de dos campos.
    if let Some(pending) = app.try_state::<PendingMeetingAudioNotices>() {
        pending.push(payload.clone());
    }
    if let Err(e) = payload.emit(app) {
        warn!(
            "Failed to emit meeting-audio-warning for {}: {}",
            meeting_id, e
        );
    }
}

/// Cierra la captura de una sesión que no puede continuar, desde afuera del
/// hilo diarizador.
///
/// Va por el estado de Tauri porque ese hilo no tiene el `MeetingManager`, y
/// **en otro hilo** porque `stop_capture` une justamente al hilo que la
/// llamaría: hacerlo en línea sería un join sobre sí mismo. Sin esto, un
/// fallo fatal dejaba el micrófono y el árbitro tomados (dictado incluido)
/// hasta reiniciar la app.
fn spawn_capture_abort(app_handle: &AppHandle, meeting_id: i64) {
    let Some(manager) = app_handle.try_state::<Arc<MeetingManager>>() else {
        warn!(
            "Meeting {}: no hay MeetingManager en el estado para cerrar la captura",
            meeting_id
        );
        return;
    };
    let manager = Arc::clone(&manager);
    tauri::async_runtime::spawn_blocking(move || {
        if let Err(e) = manager.stop_capture(meeting_id) {
            warn!(
                "Meeting {}: no se pudo cerrar la captura tras el fallo fatal ({})",
                meeting_id, e
            );
        }
    });
}

/// Build the `AudioRecorder` a meeting capture session uses. Wired to a
/// different callback than dictation's `create_audio_recorder`
/// (`managers/audio.rs`) — this one feeds `audio_cb`, which forwards
/// energy-gated frames to both live engines (see `MeetingManager::
/// start_capture`), not just to a single `StreamRouter`.
///
/// **2026-08-04: no VAD attached anymore.** This used to build a Silero VAD
/// wrapped in `SmoothedVad` (mirroring dictation's own setup) and register
/// it via `with_vad`, gating every frame through `VadPolicy::Offline`. Now
/// it starts the recorder with `VadPolicy::Disabled` (see `MeetingRecorder::
/// start`) — a policy `recorder.rs` already had for exactly this ("Bypass
/// VAD and forward every frame") but that the meeting path never used
/// before this change — so there's nothing left for a VAD to gate here, and
/// no `vad_path`/model to load for it either. See the module doc comment
/// for why: the neural VAD dropped a large fraction of real meeting audio
/// (tuned for dictation's near-mic single-voice silence, not system audio
/// mixed with music/compression), and every frame this recorder now
/// forwards passes through the energy gate instead (`ENERGY_GATE_RMS`,
/// applied inside `audio_cb` — see `start_capture`), which is far more
/// permissive.
///
/// M10 (fix round 1): este símbolo tenía `#[allow(dead_code)]` aunque ya
/// tiene dos llamadores reales en `start_capture` — quitado.
fn build_meeting_recorder(
    audio_cb: impl Fn(&[f32]) + Send + Sync + 'static,
) -> Result<AudioRecorder> {
    let recorder = AudioRecorder::new()
        .map_err(|e| anyhow::anyhow!("Failed to create AudioRecorder for meeting capture: {}", e))?
        .with_audio_callback(audio_cb);

    Ok(recorder)
}

/// El tipo de una reunión — sólo dos, no hay un tercero
/// (`data-model.md`). Se persiste como texto crudo en `meetings.kind` desde
/// antes de esta tarea (`start_meeting(kind: &str)`); este enum es sólo la
/// versión validada que usa el código nuevo de cableado de audio para no
/// pasar un `&str` suelto por `resolve_meeting_audio_source`/`start_capture`.
///
/// **Decisión de diseño (cableado de audio de reuniones):** antes de esta
/// tarea había DOS perillas independientes — el `kind` de la reunión (fijo
/// en `"presencial"` desde el frontend) y un ajuste global de "fuente de
/// audio" aparte — que podían quedar incoherentes entre sí (la interfaz
/// decía "reunión online" mientras la base guardaba `kind = "presencial"`,
/// M2 del reporte). Ahora hay una sola perilla: el usuario elige el TIPO de
/// reunión, y la fuente se deduce de ahí (`resolve_meeting_audio_source`) —
/// mandato del dueño: "por el audio del computador, no del micrófono; el
/// micrófono sólo como opción para presencial".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MeetingKind {
    Presencial,
    Virtual,
}

impl MeetingKind {
    /// `None` si `s` no es ni `"presencial"` ni `"virtual"` — los dos únicos
    /// valores que acepta `meetings.kind` (ver `data-model.md`).
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "presencial" => Some(Self::Presencial),
            "virtual" => Some(Self::Virtual),
            _ => None,
        }
    }
}

/// Resuelve qué fuente de audio usa REALMENTE una reunión, cruzando el TIPO
/// de reunión que eligió el usuario con si el audio del sistema está
/// disponible en esta máquina (`system_audio_available()`: macOS 14.2+).
/// Función pura y testeable a propósito — es la pieza que la tarea de
/// cableado pidió explícitamente poder probar sin hardware.
///
/// Ya no lee ningún ajuste global de "fuente de audio" (M2 del reporte de
/// seguimiento: ese ajuste podía quedar incoherente con el `kind` real de la
/// reunión). La tabla completa:
///
/// | `kind`       | audio del sistema disponible | fuente resuelta |
/// |--------------|-------------------------------|------------------|
/// | `Virtual`    | sí                            | `SystemAudio`    |
/// | `Virtual`    | no                             | `Microphone`     |
/// | `Presencial` | (no aplica)                    | `Microphone`     |
///
/// `Presencial` nunca resuelve a audio del sistema — el micrófono es sólo
/// para reuniones presenciales, no una alternativa que el audio del sistema
/// pueda usar. El micrófono nunca necesita "resolverse hacia" nada más: está
/// disponible en cualquier plataforma, así que una vez decidido, se usa tal
/// cual — no hay una tercera fuente a la que caer.
///
/// Lo que el ajuste persistido `AppSettings::meeting_audio_source` sigue
/// haciendo: recordar el último `kind` elegido para preseleccionarlo la
/// próxima vez que se abre el selector (ver `RecordingControls.tsx` y el
/// doc comment del campo en `settings.rs`) — ya no determina la fuente real
/// de ninguna reunión, eso es exclusivamente trabajo de esta función.
pub fn resolve_meeting_audio_source(
    kind: MeetingKind,
    system_audio_available: bool,
) -> MeetingAudioSource {
    match kind {
        MeetingKind::Virtual if system_audio_available => MeetingAudioSource::SystemAudio,
        _ => MeetingAudioSource::Microphone,
    }
}

/// Resuelve qué modelo de transcripción usa ESTA reunión: el propio
/// (`meeting_model_id`) si el usuario eligió uno, si no el del dictado
/// (`selected_model`) — ver el doc comment de `AppSettings::meeting_model_id`.
/// Mismo patrón que `resolve_mode_provider` en `settings.rs` para el
/// proveedor de post-proceso de un modo: heredar es el default silencioso, y
/// esta función es pura y testeable a propósito, igual que
/// `resolve_meeting_audio_source` arriba — `start_capture` sólo la llama con
/// los ajustes ya leídos.
///
/// Vacío o sólo espacios cuenta como "sin elegir" y también hereda: un
/// `settings.json` tocado a mano con `"meeting_model_id": ""` no debe dejar
/// la reunión sin ningún modelo.
pub fn resolve_meeting_model_id(meeting_model_id: Option<&str>, selected_model: &str) -> String {
    meeting_model_id
        .map(str::trim)
        .filter(|id| !id.is_empty())
        .unwrap_or(selected_model)
        .to_string()
}

/// Build the `SystemAudioRecorder` a meeting capture session uses cuando la
/// fuente resuelta es `MeetingAudioSource::SystemAudio`. Espejo de
/// `build_meeting_recorder`.
///
/// **2026-08-04: ya no aplica ningún VAD.** `SystemAudioRecorder` nunca tuvo
/// VAD propio — `with_frame_callback` siempre entregó las muestras del tap
/// sin filtrar (ver su doc comment en `system_audio/macos.rs`). Hasta este
/// cambio, este helper compensaba eso aplicando acá mismo el mismo VAD
/// (`SileroVad` + `SmoothedVad`) que usaba el camino del micrófono, para que
/// el resto del pipeline recibiera exactamente lo mismo de las dos fuentes.
/// Ahora el camino del micrófono tampoco filtra por VAD (`build_meeting_recorder`,
/// `VadPolicy::Disabled`), así que "lo mismo de las dos fuentes" pasó a ser
/// "sin filtrar en ninguna" — este helper vuelve a ser lo que su nombre
/// sugiere: sólo construye el recorder y conecta `audio_cb` directo, sin
/// nada en el medio. La compuerta de energía (`ENERGY_GATE_RMS`) que
/// reemplaza al VAD vive dentro de `audio_cb` (`start_capture`), no acá, para
/// que las dos fuentes la apliquen de la misma forma.
fn build_meeting_system_audio_recorder(
    audio_cb: impl Fn(&[f32]) + Send + Sync + 'static,
) -> Result<SystemAudioRecorder> {
    let recorder = SystemAudioRecorder::new()
        .map_err(|e| {
            anyhow::anyhow!(
                "Failed to create SystemAudioRecorder for meeting capture: {}",
                e
            )
        })?
        .with_frame_callback(move |frame: &[f32]| audio_cb(frame));

    Ok(recorder)
}

/// Uno de los dos backends de audio que puede alimentar una sesión de
/// reunión — ver `resolve_meeting_audio_source`. `AudioRecorder` tiene su
/// propio ciclo start/stop con `VadPolicy` (arranca con `VadPolicy::Disabled`
/// desde el 2026-08-04 — ver `build_meeting_recorder`); `SystemAudioRecorder`
/// nunca tuvo VAD y su `start()`/`stop()` no toman política. Esta enum
/// absorbe esa diferencia de forma para que `CaptureSession` y
/// `start_capture`/`stop_capture` no tengan que ramificar en cada punto de
/// uso.
///
/// El variante `SystemAudio` guarda un `Arc<Mutex<_>>`, no el recorder
/// directo: el propio módulo de `SystemAudioRecorder` documenta que es
/// `!Sync` (su `ctx` guarda un `mpsc::Receiver`, que no es `Sync`) y avisa
/// explícitamente que "quien lo cablee a un flujo con más de un hilo... va a
/// necesitar envolverlo en un `Mutex`". Acá hace falta más de un hilo: el
/// watchdog necesita su propia referencia para sondear `diagnose_now()`/
/// `output_device_changed()` en caliente (I6/I5 de `system_audio.rs`)
/// mientras `CaptureSession` sigue siendo dueña de la sesión — ver
/// `start_capture`. El `Mutex` nunca compite de verdad (el watchdog sondea
/// cada `SYSTEM_AUDIO_DIAGNOSIS_POLL`, no en el camino caliente de audio) —
/// existe sólo para satisfacer `Sync`, igual que en
/// `build_meeting_system_audio_recorder`.
enum MeetingRecorder {
    Microphone(AudioRecorder),
    SystemAudio(Arc<Mutex<SystemAudioRecorder>>),
}

impl MeetingRecorder {
    fn open(&mut self, device: Option<cpal::Device>) -> Result<()> {
        match self {
            MeetingRecorder::Microphone(r) => r.open(device).map_err(|e| anyhow::anyhow!("{e}")),
            MeetingRecorder::SystemAudio(r) => {
                r.lock().unwrap().open().map_err(|e| anyhow::anyhow!("{e}"))
            }
        }
    }

    fn start(&self) -> Result<()> {
        match self {
            // `VadPolicy::Disabled` ("Bypass VAD and forward every frame",
            // `audio_toolkit/audio/recorder.rs`) since 2026-08-04 — see the
            // module doc comment and `build_meeting_recorder` for why the
            // meeting path stopped gating on the neural VAD. The energy
            // gate that replaces it (`ENERGY_GATE_RMS`) runs downstream, on
            // whatever this delivers unfiltered.
            MeetingRecorder::Microphone(r) => r
                .start(VadPolicy::Disabled)
                .map_err(|e| anyhow::anyhow!("{e}")),
            MeetingRecorder::SystemAudio(r) => r
                .lock()
                .unwrap()
                .start()
                .map_err(|e| anyhow::anyhow!("{e}")),
        }
    }

    /// Detiene la captura. El `Vec<f32>` que devuelve el backend se
    /// descarta a propósito en los dos casos — ver el comentario del módulo
    /// sobre por qué el buffer redundante de `AudioRecorder::stop()` no se
    /// usa. El diagnóstico de `SystemAudioRecorder::stop()` sí se propaga
    /// (I4 del reporte de seguimiento): además del sondeo periódico en
    /// caliente vía `diagnose_now()` durante la grabación, `stop_capture`
    /// necesita el diagnóstico FINAL para poder avisar al cerrar una
    /// reunión más corta que `SILENCE_WARNING_THRESHOLD` que de todas
    /// formas no capturó nada real — antes ese último dato se tiraba.
    /// `None` para micrófono: no hay ningún diagnóstico de silencio para esa
    /// fuente (fuera de alcance de esta tarea, ver `report.md`).
    fn stop(&self) -> Option<CaptureDiagnosis> {
        match self {
            MeetingRecorder::Microphone(r) => {
                let _ = r.stop();
                None
            }
            MeetingRecorder::SystemAudio(r) => match r.lock().unwrap().stop() {
                Ok(result) => Some(result.diagnosis),
                Err(e) => {
                    warn!("SystemAudioRecorder::stop() falló al cerrar la reunión: {e}");
                    None
                }
            },
        }
    }

    fn close(&mut self) {
        match self {
            MeetingRecorder::Microphone(r) => {
                let _ = r.close();
            }
            MeetingRecorder::SystemAudio(r) => {
                let _ = r.lock().unwrap().close();
            }
        }
    }
}

/// Qué avisos de audio del sistema ya se reportaron en esta sesión de
/// captura — I4/I5 del reporte de seguimiento. Compartido (vía `Arc`) entre
/// el watchdog, que sondea durante la grabación, y `stop_capture`, que hace
/// una última revisión al cerrar (para que una reunión más corta que
/// `SILENCE_WARNING_THRESHOLD` también avise si no capturó nada real). Los
/// dos lados usan `AtomicBool` — no `bool` liso — justamente porque pueden
/// tocarse desde esos dos hilos distintos.
///
/// `None` cuando la sesión graba por micrófono: no hay diagnóstico de
/// silencio para esa fuente.
#[derive(Default)]
struct AudioWarningState {
    permission_reported: AtomicBool,
    silence_reported: AtomicBool,
}

// --- Task 5 ("reuniones en streaming"): dos flujos continuos, sin turnos --
//
// # De un registro por embeddings a un mapa de índices locales
//
// Antes de esta tarea, cada turno se diarizaba por separado
// (`DiarizationEngine::diarize`, T009) y devolvía índices de hablante
// locales a ESA llamada — el "hablante 0" de un turno no tenía relación
// con el "hablante 0" del siguiente, así que hacía falta un registro que
// comparara embeddings de voz (CAM++, coseno contra `CLUSTER_THRESHOLD`)
// para re-identificar a la misma persona entre turnos.
//
// [`StreamingDiarizer`] (Task 2) no tiene ese problema: su caché de
// hablantes por orden de llegada (`spkcache`/`fifo`) mantiene la identidad
// estable DENTRO de una reunión completa — el índice local que devuelve
// `SpeakerSpan::speaker` (0..`SORTFORMER_MAX_SPEAKERS`) es el mismo para la
// misma voz del principio al fin de la sesión. [`resolve_local_speaker`]
// sólo necesita entonces un mapa `índice local -> meeting_speakers.id`,
// creado la primera vez que aparece cada índice — sin comparar voces, sin
// umbrales de similitud, sin incertidumbre que declarar.
//
// # De turnos a intervenciones atribuidas
//
// El audio ya no se corta en turnos: [`MeetingManager::start_capture`]
// alimenta el reconocimiento de voz en streaming (`TimedToken`s con marca
// real, Task 3) y [`StreamingDiarizer::push`] (`SpeakerSpan`s, Task 2) en
// paralelo. `align::attribute` (Task 4) cruza ambos flujos por solape
// temporal y arma [`AttributedRun`]s — la unidad que sobrevive incluso una
// interrupción de un solo token, el problema que motivó todo este plan.
// [`segments_from_runs`] convierte cada `AttributedRun` en el
// `MeetingSegment` que ya se persistía y emitía; el hilo diarizador de
// `start_capture` es quien decide CUÁNDO una run ya está cerrada (ver
// [`maybe_persist_new_runs`]) y quien resuelve su hablante local antes de
// guardarla ([`persist_and_emit_run`]).
//
// # Important 4/3 del fix round 1: la compuerta sólo protege al ASR, y las
// marcas vuelven a ser reloj de reunión
//
// La primera versión de esta tarea aplicaba [`has_energy`] por igual a los
// dos motores, para que sus relojes en milisegundos contaran exactamente el
// mismo audio y quedaran directamente comparables. Eso rompía dos cosas a
// la vez: `StreamingDiarizer` documenta que corta turnos por silencio real
// (`sortformer.rs`, "la emisión sigue cierres de turno"), así que borrarle
// las pausas antes de que las viera dejaba turnos que no cerraban nunca; y
// `started_at_ms`/`ended_at_ms` — que el usuario ve en el transcript — pasó
// a medir la posición dentro del audio CON VOZ, no la posición real dentro
// de la reunión, corriéndose hacia atrás con cada pausa descartada.
//
// Ahora la compuerta sólo protege al reconocimiento de voz (que sí
// alucina texto sobre silencio digital) — la diarización recibe TODO el
// audio, silencio incluido, así que su reloj en milisegundos ya ES reloj
// de reunión sin ninguna conversión. El reconocimiento, en cambio, sigue
// viendo sólo lo filtrado, así que su reloj queda comprimido respecto al
// de pared; [`AudioToWallClock`] reconstruye la correspondencia y el
// listener de `stream-text-event` convierte cada `TimedToken` a reloj de
// reunión ANTES de guardarlo en [`TranscriptState::tokens`] — para cuando
// `align::attribute` los cruza contra los `SpeakerSpan`s, los dos ya
// hablan el mismo reloj, y `segments_from_runs` no necesita saber que la
// conversión existió.
//
// # FR-004 (marcar incierto en vez de adivinar) sigue vigente
//
// Un token sin ningún `SpeakerSpan` que lo cubra queda con `speaker: None`
// en `align::attribute` — nunca se adivina (ver el doc comment de ese
// módulo). Eso pasa, entre otros casos, mientras el modelo Sortformer
// todavía está cargando (~492 MB, se descarga en runtime la primera vez):
// el audio capturado antes de que esté listo se sigue transcribiendo igual
// (el reconocimiento de voz no depende de la diarización), sólo que sin
// hablante — exactamente la misma degradación honesta que antes, ahora sin
// necesitar un caso especial para "el motor no está listo".

/// Comandos que `audio_cb` y el listener de `stream-text-event` mandan al
/// hilo diarizador de una sesión de captura — un solo canal FIFO para que
/// el orden de llegada (audio, más audio, actualización de tokens, cierre)
/// se preserve tal cual, mismo patrón que `StreamCmd` en
/// `transcription.rs`.
enum DiarizerCmd {
    /// Un tramo de audio, SIN filtrar por la compuerta de energía —
    /// `StreamingDiarizer` necesita ver el silencio real para cortar
    /// turnos (Important 4 del fix round 1, ver el comentario de esta
    /// sección). La compuerta sigue existiendo, pero sólo protege al
    /// reconocimiento de voz (`stream_router.feed`, en `audio_cb`).
    Audio(Vec<f32>),
    /// Llegaron tokens nuevos por `stream-text-event`: puede haber una
    /// intervención más para cerrar aunque no haya ningún tramo nuevo.
    TokensUpdated,
    /// Fin de la captura: vaciar lo que quede pendiente (`StreamingDiarizer
    /// ::flush`) y persistir TODO lo que falte, última intervención
    /// incluida, antes de salir del hilo.
    Flush,
}

/// Estado de los dos relojes que lleva `audio_cb` frame a frame: `asr_ms`
/// (sólo lo que pasó la compuerta de energía, lo que ve el ASR) y
/// `total_ms` (TODO lo que llegó, pase o no la compuerta — lo que ve
/// `StreamingDiarizer`, ver Important 4 del fix round 1). `was_gap` es
/// interno: si el frame anterior no tenía energía (o todavía no llegó
/// ninguno), para saber cuándo `step_audio_clock` tiene que marcar un
/// punto de referencia nuevo.
///
/// `Default` es manual, NO `#[derive(Default)]` — a propósito. `was_gap`
/// arranca en `true`, no en el `false` que un derive le daría a un `bool`:
/// el estado inicial, antes de que llegue el primer frame, tiene que
/// contar como "veníamos de un hueco" para que el PRIMER frame con
/// energía dispare el primer punto de referencia en `AudioToWallClock`
/// (en `(0, 0)`, el arranque de la captura). El test
/// `step_audio_clock_todos_los_frames_con_energia_avanzan_igual` lo
/// ejercita — con un derive, ese primer quiebre nunca se marcaría y
/// `to_wall_ms` quedaría sin ningún punto de referencia hasta el primer
/// silencio real, exactamente la misma clase de desalineación que N1.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct AudioClockState {
    asr_ms: u64,
    total_ms: u64,
    was_gap: bool,
}

impl Default for AudioClockState {
    fn default() -> Self {
        Self {
            asr_ms: 0,
            total_ms: 0,
            was_gap: true,
        }
    }
}

/// Punto de referencia a marcar en `AudioToWallClock`, si corresponde —
/// devuelto por [`step_audio_clock`] cuando ESTE frame es el que reanuda
/// al ASR después de un hueco.
type AudioClockMark = Option<(u64, u64)>;

/// Aplica UN frame (con o sin energía, de `frame_ms` milisegundos) al
/// estado de los dos relojes — la lógica que `audio_cb` corre en vivo,
/// acá aislada de sus efectos de lado (`stream_router.feed`,
/// `AudioToWallClock::mark`) para poder probarla sin hardware ni threads.
///
/// **N2 del fix round 3 — qué prueba esto y qué no.** La re-revisión
/// demostró que el test de monotonía de `AudioToWallClock::to_wall_ms`
/// (fix round 2) no hubiera detectado la regresión de N1: construye sus
/// quiebres a mano, ya monótonos por construcción, así que verifica una
/// propiedad de la interpolación (que nunca estuvo rota) y no ejercita el
/// caso patológico real — cuánto avanza cada reloj frame a frame. Lo que
/// puede volver a romperse es esto: que `total_ms` deje de sumar cuando
/// el frame no tiene energía (por ejemplo, si alguien "simplifica" el
/// código y mueve la suma de vuelta adentro del `if has_energy`). Esta
/// función es el punto exacto donde ese invariante vive, aislado para que
/// un test lo pueda ejercitar directamente en vez de a través de
/// `audio_cb` completo (que necesitaría un recorder real).
fn step_audio_clock(
    mut state: AudioClockState,
    has_energy: bool,
    frame_ms: u64,
) -> (AudioClockState, AudioClockMark) {
    let mut mark = None;
    if has_energy {
        if state.was_gap {
            mark = Some((state.asr_ms, state.total_ms));
            state.was_gap = false;
        }
        state.asr_ms += frame_ms;
    } else {
        state.was_gap = true;
    }
    // Fuera del `if has_energy` a propósito: `total_ms` tiene que sumar
    // CADA frame, tenga o no energía — es lo único que lo mantiene igual
    // al reloj de `StreamingDiarizer`, que recibe todo sin filtrar.
    state.total_ms += frame_ms;
    (state, mark)
}

/// Traduce milisegundos "de reconocimiento" (los que cuenta el ASR en
/// streaming — sólo avanzan cuando `audio_cb` deja pasar un frame por la
/// compuerta de energía, ver [`has_energy`]) a milisegundos "de reunión":
/// el reloj por MUESTRAS que ve `StreamingDiarizer`, no reloj de pared
/// (`Instant`).
///
/// **N1 del fix round 2 — el ancla original estaba mal.** La primera
/// versión de esto marcaba cada punto de referencia con
/// `capture_started.elapsed()` (reloj de pared de verdad), asumiendo que
/// `SpeakerSpan` también medía en reloj de pared. Es falso:
/// `StreamingDiarizer::push` calcula sus tiempos puramente por muestras
/// procesadas (`processed_s = total_model_frames * SUBSAMPLING *
/// AUDIO_FRAME_DURATION_S`, `sortformer.rs`), nunca toca un reloj real. Los
/// dos relojes no estaban en el mismo marco: `capture_started` se toma
/// ANTES de abrir el recorder (sesgo constante = la latencia de apertura
/// del dispositivo, segundos en el camino de fallback), `FrameResampler`
/// entrega frames en ráfaga por buffer de cpal (jitter que podía romper la
/// monotonía de `to_wall_ms` y hacer que `maybe_persist_new_runs` se
/// saltara una intervención real leyéndola como "ya persistida"), y el
/// hilo consumidor puede atrasarse respecto al reloj real bajo presión de
/// CPU sin autocorregirse jamás.
///
/// El ancla correcta: como la diarización recibe TODO el audio sin
/// filtrar (Important 4 del fix round 1), su reloj es exactamente la suma
/// de milisegundos de CADA frame que le llega a `audio_cb`, pase o no la
/// compuerta — eso es lo que `audio_cb` lleva en `total_ms` y lo que
/// `mark` recibe como segundo elemento ahora, en vez de
/// `capture_started.elapsed()`. Por construcción, sin sesgo (mismo origen:
/// la primera muestra), sin jitter (mismo conteo de muestras, no reloj de
/// pared) y sin deriva (no depende de cuándo el hilo consumidor llegó a
/// procesar el frame). El diseño ya sabía esto — el `backlog` del hilo
/// diarizador existe justamente "para que el reloj de la diarización
/// arranque en la MISMA muestra cero"; este ancla es la otra mitad de la
/// misma idea.
///
/// Cada silencio que la compuerta descarta comprime el reloj del ASR
/// respecto al de la diarización; esta estructura registra, cada vez que
/// `audio_cb` retoma después de un hueco, el punto exacto donde ambos
/// coincidían (`(asr_ms, total_ms)`), para reconstruir el reloj de reunión
/// de cualquier marca del ASR por interpolación lineal — entre dos frames
/// consecutivos SIN hueco de por medio, los dos relojes avanzan 1:1, así
/// que sólo hace falta un punto de referencia por hueco, no uno por frame.
///
/// `mark` lo llama sólo `audio_cb` (un único hilo, en orden estrictamente
/// creciente de `asr_ms`); `to_wall_ms` lo llama el listener de
/// `stream-text-event` para convertir tokens antes de guardarlos en
/// [`TranscriptState::tokens`]. Agregar un punto de referencia nuevo nunca
/// cambia la interpolación de una marca anterior a él (`to_wall_ms` sólo
/// mira hacia atrás), así que convertir el mismo `asr_ms` en momentos
/// distintos siempre da el mismo resultado.
#[derive(Default)]
struct AudioToWallClock {
    breakpoints: Vec<(u64, u64)>,
}

impl AudioToWallClock {
    fn mark(&mut self, asr_ms: u64, meeting_ms: u64) {
        self.breakpoints.push((asr_ms, meeting_ms));
    }

    /// Milisegundo de reunión correspondiente a `asr_ms`. Sin ningún punto
    /// de referencia todavía (nada se alimentó nunca al ASR), devuelve
    /// `asr_ms` tal cual — mejor aproximación disponible, y el valor que
    /// ya tenía antes de que esta conversión existiera.
    fn to_wall_ms(&self, asr_ms: u64) -> u64 {
        match self.breakpoints.iter().rposition(|&(a, _)| a <= asr_ms) {
            Some(i) => {
                let (bp_asr, bp_meeting) = self.breakpoints[i];
                bp_meeting + (asr_ms - bp_asr)
            }
            None => asr_ms,
        }
    }
}

/// Convierte un `TimedToken` del reloj del ASR al reloj de reunión,
/// acotando su duración a la original — N3 del fix round 2. `start_ms` y
/// `end_ms` se interpolan por separado (`AudioToWallClock::to_wall_ms`),
/// así que pueden caer contra quiebres distintos si el hueco de silencio
/// que la compuerta le sacó al ASR partió justo ese token: sin acotar, el
/// token pasaría a "durar" en reloj de reunión todo el silencio
/// intermedio, y como `align::attribute` atribuye por mayor solape, ese
/// token inflado podría terminar atribuido a quien habló del otro lado del
/// silencio. Acotar a `end - start` original es conservador: no inventa
/// dónde cae el token dentro del hueco, sólo evita que se coma silencio
/// ajeno.
fn convert_token_to_meeting_clock(token: TimedToken, clock: &AudioToWallClock) -> TimedToken {
    let start_ms = clock.to_wall_ms(token.start_ms);
    let original_duration = token.end_ms.saturating_sub(token.start_ms);
    let end_ms = clock
        .to_wall_ms(token.end_ms)
        .min(start_ms + original_duration);
    TimedToken {
        text: token.text,
        start_ms,
        end_ms,
    }
}

/// Estado compartido entre el hilo diarizador (que recibe `SpeakerSpan`s de
/// `StreamingDiarizer::push`/`flush`) y el listener de `stream-text-event`
/// (que recibe `TimedToken`s del reconocimiento en streaming) — los dos
/// pueden destrabar intervenciones nuevas, así que persistirlas bajo el
/// mismo lock es lo único que evita procesar la misma dos veces o perderla
/// por una carrera entre ambos.
#[derive(Default)]
struct TranscriptState {
    /// Snapshot más reciente de `stream-text-event`, YA convertido a reloj
    /// de reunión (`AudioToWallClock::to_wall_ms`, ver el listener en
    /// `start_capture`) — reemplaza al anterior entero (no se acumula
    /// token a token): `StreamTextEvent::tokens` ya trae la transcripción
    /// completa de la sesión hasta esa revisión.
    tokens: Vec<TimedToken>,
    /// Todos los `SpeakerSpan`s recibidos hasta ahora, en el orden en que
    /// `StreamingDiarizer` los fue emitiendo (monótono, ver
    /// `spans_are_monotonic`).
    spans: Vec<SpeakerSpan>,
    /// Marca de agua por CONTENIDO, no por índice — `end_ms` de la última
    /// `AttributedRun` persistida con éxito. Important 5 del fix round 1:
    /// `align::attribute(&tokens, &spans)` recalcula la lista de runs
    /// ENTERA en cada llamada; un índice fijo (`persisted_runs: usize` en
    /// la versión anterior) se corrompía si esa lista alguna vez se
    /// achicaba — por ejemplo si una revisión del ASR retira un token
    /// todavía tentativo — porque `runs.len()` caía bajo el índice
    /// guardado y nada se volvía a persistir nunca más. Comparar por
    /// `end_ms` no tiene ese problema: una run ya cubierta se saltea sin
    /// importar en qué índice termine cayendo en la próxima recomputación.
    /// Sólo avanza cuando [`persist_and_emit_run`] devuelve `Ok` — ver
    /// [`maybe_persist_new_runs`].
    persisted_until_ms: u64,
    /// Índice local de hablante (`SpeakerSpan::speaker`, 0..
    /// `SORTFORMER_MAX_SPEAKERS`) -> `meeting_speakers.id`. Sortformer ya
    /// mantiene esa identidad estable dentro de la sesión (ver el
    /// comentario de esta sección), así que este mapa sólo necesita crear
    /// la fila la primera vez que ve cada índice.
    local_speakers: HashMap<u8, i64>,
}

/// Convierte intervenciones atribuidas (`align::attribute`, Task 4) en los
/// segmentos que `meeting_segments`/`meeting-segment` ya conocían — el
/// contrato hacia afuera no cambia. Función pura, sin base de datos: `id`
/// queda en `0` (lo asigna el INSERT real) y `speaker_id` lleva el índice
/// LOCAL de Sortformer tal cual, todavía sin resolver contra
/// `meeting_speakers` — eso es trabajo de [`persist_and_emit_run`], que lo
/// resuelve la primera vez que persiste cada índice.
///
/// `overlapped` siempre `false`: a diferencia del motor de diarización por
/// lotes, `StreamingDiarizer` ya resuelve los solapes de hablantes ANTES de
/// devolver un `SpeakerSpan` (`flatten_overlaps`, ver `sortformer.rs`) —
/// para cuando un token llega hasta acá, la ambigüedad de "quién hablaba"
/// ya se resolvió (o el token quedó sin hablante, `speaker: None`).
fn segments_from_runs(runs: &[AttributedRun]) -> Vec<MeetingSegment> {
    runs.iter()
        .map(|run| MeetingSegment {
            id: 0,
            speaker_id: run.speaker.map(i64::from),
            text: run.text.clone(),
            started_at_ms: run.start_ms as i64,
            ended_at_ms: run.end_ms as i64,
            overlapped: false,
        })
        .collect()
}

/// Resuelve el `speaker_id` real de un índice local de Sortformer,
/// creándolo la primera vez que aparece en esta reunión. A diferencia del
/// `SpeakerRegistry` por embeddings que esto reemplaza, no hay comparación
/// de voces ni incertidumbre que declarar: el índice local YA es una
/// identidad estable dentro de la sesión (ver el comentario de esta
/// sección), así que la única pregunta es "¿ya lo vimos?".
fn resolve_local_speaker(
    conn: &Connection,
    meeting_id: i64,
    local_speakers: &mut HashMap<u8, i64>,
    local_index: u8,
) -> Result<i64> {
    if let Some(&id) = local_speakers.get(&local_index) {
        return Ok(id);
    }
    let id = insert_speaker(conn, meeting_id)?;
    local_speakers.insert(local_index, id);
    Ok(id)
}

/// Sigue la cadena de `merged_into_id` hasta el hablante que realmente
/// representa a `speaker_id` hoy (`data-model.md`: "segmentos apuntando a un
/// hablante fusionado se resuelven al destino"). Un hablante sin fusionar se
/// resuelve a sí mismo.
///
/// La cota de saltos no es paranoia decorativa: [`MeetingManager::merge_speakers`]
/// ya rechaza los ciclos al escribir y comprime las cadenas a profundidad 1,
/// pero esta función también corre sobre datos que pudieron quedar de una
/// versión anterior o de una escritura a mano, y un ciclo ahí colgaría la
/// lectura del transcript para siempre. Ante una cadena absurda corta y avisa
/// en vez de girar.
fn resolve_speaker(conn: &Connection, speaker_id: i64) -> Result<i64> {
    const MAX_HOPS: usize = 32;

    let mut current = speaker_id;
    for _ in 0..MAX_HOPS {
        let next: Option<i64> = conn
            .query_row(
                "SELECT merged_into_id FROM meeting_speakers WHERE id = ?1",
                params![current],
                |row| row.get(0),
            )
            .optional()?
            .ok_or_else(|| anyhow::anyhow!("speaker_not_found"))?;

        match next {
            None => return Ok(current),
            Some(target) => current = target,
        }
    }

    bail!("speaker_merge_chain_too_long")
}

/// Crea la fila de un hablante nuevo para `meeting_id` con la etiqueta por
/// defecto `Hablante N` (`data-model.md`), donde N es el siguiente número
/// libre en ESA reunión. El número sale de la base y no del largo del
/// registro en memoria para que una segunda sesión de captura sobre la misma
/// reunión no reutilice etiquetas ya usadas.
fn insert_speaker(conn: &Connection, meeting_id: i64) -> Result<i64> {
    let existing: i64 = conn.query_row(
        "SELECT COUNT(*) FROM meeting_speakers WHERE meeting_id = ?1",
        params![meeting_id],
        |row| row.get(0),
    )?;
    let label = format!("Hablante {}", existing + 1);
    conn.execute(
        "INSERT INTO meeting_speakers (meeting_id, label) VALUES (?1, ?2)",
        params![meeting_id, label],
    )?;
    Ok(conn.last_insert_rowid())
}

/// Persiste UNA intervención ya convertida a `MeetingSegment`
/// ([`segments_from_runs`]) y, cuando hay `app_handle`, emite
/// `meeting-segment`. `local_speaker` es el índice local de Sortformer del
/// que salió esta run (`AttributedRun::speaker`) — `None` significa
/// "incierto" (FR-004), no "sin implementar". El texto en blanco (tokens de
/// puntuación/espacios sin nada más) no se persiste ni se emite: nada que
/// mostrarle al usuario, igual que una transcripción vacía en el diseño
/// anterior.
///
/// Generic sobre el runtime de Tauri (`R`) para que la emisión se pueda
/// testear con `tauri::test::mock_app`'s `MockRuntime` sin un event loop ni
/// ventana real — mismo patrón que el resto de los `report_*` de este
/// módulo.
fn persist_and_emit_run<R: tauri::Runtime>(
    conn: &Connection,
    app_handle: Option<&AppHandle<R>>,
    meeting_id: i64,
    mut segment: MeetingSegment,
    local_speaker: Option<u8>,
    local_speakers: &mut HashMap<u8, i64>,
) -> Result<Option<MeetingSegment>> {
    if segment.text.trim().is_empty() {
        return Ok(None);
    }

    segment.speaker_id = match local_speaker {
        Some(local_index) => Some(resolve_local_speaker(
            conn,
            meeting_id,
            local_speakers,
            local_index,
        )?),
        None => None,
    };

    conn.execute(
        "INSERT INTO meeting_segments (meeting_id, speaker_id, text, started_at_ms, ended_at_ms, overlapped) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            meeting_id,
            segment.speaker_id,
            segment.text,
            segment.started_at_ms,
            segment.ended_at_ms,
            segment.overlapped
        ],
    )?;
    segment.id = conn.last_insert_rowid();

    if let Some(app) = app_handle {
        if let Err(e) = segment.clone().emit(app) {
            warn!(
                "Failed to emit meeting-segment for meeting {}: {}",
                meeting_id, e
            );
        }
    }

    Ok(Some(segment))
}

/// Empuja un tramo de audio ya filtrado por la compuerta de energía a
/// `StreamingDiarizer::push` y agrega los tramos nuevos (si hay) a
/// `state.spans`. Un error de diarización no mata la sesión: se reporta
/// como `meeting-turn-failed` (la reunión sigue grabando) y el tramo queda
/// sin diarizar, no sin transcribir — el reconocimiento de voz corre en su
/// propio stream y no depende de esto.
fn push_diarizer_chunk<R: tauri::Runtime>(
    diarizer: &mut StreamingDiarizer,
    chunk: &[f32],
    app_handle: Option<&AppHandle<R>>,
    meeting_id: i64,
    state: &Mutex<TranscriptState>,
    turn_failure_reported: &mut bool,
) {
    match diarizer.push(chunk) {
        Ok(spans) if !spans.is_empty() => {
            state.lock().unwrap().spans.extend(spans);
        }
        Ok(_) => {}
        Err(e) => report_turn_failure(
            app_handle,
            meeting_id,
            turn_failure_reported,
            format!("la diarización en vivo falló: {e}"),
        ),
    }
}

/// Recalcula `align::attribute` sobre la cola de tokens/tramos que todavía
/// no se persistió y persiste+emite las intervenciones que ya se pueden dar
/// por cerradas.
///
/// **Por qué no persistir la última run todavía.** `attribute` re-agrupa
/// tokens en runs cada vez que se le llama; mientras la MISMA persona siga
/// hablando, la última run de la lista puede seguir creciendo con el
/// próximo token que llegue. Recién cuando aparece una run MÁS detrás de
/// ella (cambio de hablante, según los tramos ya emitidos) se sabe que la
/// anterior no va a cambiar más — por eso `include_last` es `false` en
/// cada llamada normal (nueva tanda de audio o de tokens) y sólo pasa a
/// `true` una vez, al cerrar la reunión (`DiarizerCmd::Flush`), cuando ya
/// no va a llegar nada más que pudiera extenderla.
///
/// **Por qué recorta la entrada en vez de recalcular sobre toda la
/// reunión** (Important 6 del fix round 1): `attribute` es O(tokens ×
/// tramos), y las dos listas crecen con la duración de la reunión —
/// llamarla sobre la historia completa en cada evento (varias veces por
/// segundo, durante horas) degrada de forma cuadrática. El corte en
/// `persisted_until_ms` siempre cae justo en un límite de run real (el
/// `end_ms` de la última que se persistió), así que ningún token o tramo
/// anterior a ese punto puede seguir perteneciendo a una run que arranca
/// después — recortar ahí no cambia el resultado, sólo el costo.
///
/// **Por qué no retiene el lock durante la escritura a la base**
/// (Important 6 también): el listener de `stream-text-event` corre en el
/// hilo de decodificación del ASR y necesita este mismo `Mutex` para
/// reemplazar `tokens` en cada actualización — retenerlo acá durante un
/// `INSERT` de SQLite (o el `emit` a la ventana) lo hacía esperar sin
/// necesidad, en el camino caliente del reconocimiento. Esta función sólo
/// toma el lock dos veces, brevemente: una para sacar una copia de lo que
/// necesita calcular (`tokens`/`spans` ya recortados, `local_speakers` con
/// `mem::take`), y otra al final para devolver `local_speakers` y publicar
/// la nueva marca de agua. El cálculo y la escritura a la base, en el
/// medio, corren sin el lock — seguro porque sólo este hilo (el
/// diarizador; el listener sólo llega hasta acá mandando
/// `DiarizerCmd::TokensUpdated`, nunca llamando a esta función
/// directamente) toca `local_speakers`/`persisted_until_ms`.
///
/// **Si `persist_and_emit_run` falla, se corta ahí mismo** (Important 5 del
/// fix round 1): ni se avanza `persisted_until_ms` para esa run ni se
/// intentan las que siguen. Seguir de largo hubiera podido persistir una
/// run POSTERIOR y de todos modos avanzar la marca hasta ella, perdiendo la
/// que falló para siempre (la marca ya nunca volvería a apuntar tan atrás).
/// Cortar acá dice "hasta acá llegó lo guardado" de verdad, y deja a la
/// PRÓXIMA llamada — nueva tanda de audio o de tokens — reintentar desde la
/// misma run que falló.
fn maybe_persist_new_runs<R: tauri::Runtime>(
    conn: &Connection,
    app_handle: Option<&AppHandle<R>>,
    meeting_id: i64,
    state: &Mutex<TranscriptState>,
    include_last: bool,
    turn_failure_reported: &mut bool,
) {
    let (tokens, spans, persisted_until_ms, mut local_speakers) = {
        let mut state = state.lock().unwrap();
        let watermark = state.persisted_until_ms;
        let tokens: Vec<TimedToken> = state
            .tokens
            .iter()
            .filter(|t| t.end_ms > watermark)
            .cloned()
            .collect();
        let spans: Vec<SpeakerSpan> = state
            .spans
            .iter()
            .filter(|s| s.end_ms > watermark)
            .cloned()
            .collect();
        (
            tokens,
            spans,
            watermark,
            std::mem::take(&mut state.local_speakers),
        )
    };

    let runs = attribute(&tokens, &spans);
    let boundary = if include_last {
        runs.len()
    } else {
        runs.len().saturating_sub(1)
    };

    let mut new_persisted_until_ms = persisted_until_ms;
    for run in &runs[..boundary] {
        // Ya cubierta por una llamada anterior — se saltea, no se
        // reprocesa. Comparar por contenido (`end_ms`) en vez de por
        // índice es justo lo que evita que una lista de runs más corta
        // que antes (una revisión del ASR) trabe la persistencia entera.
        if run.end_ms <= new_persisted_until_ms {
            continue;
        }

        let segment = segments_from_runs(std::slice::from_ref(run))
            .into_iter()
            .next()
            .expect("segments_from_runs conserva el largo de su entrada");

        match persist_and_emit_run(
            conn,
            app_handle,
            meeting_id,
            segment,
            run.speaker,
            &mut local_speakers,
        ) {
            Ok(_) => new_persisted_until_ms = run.end_ms,
            Err(e) => {
                report_turn_failure(
                    app_handle,
                    meeting_id,
                    turn_failure_reported,
                    format!("no se pudo guardar una intervención transcrita: {e}"),
                );
                break;
            }
        }
    }

    let mut state = state.lock().unwrap();
    state.local_speakers = local_speakers;
    state.persisted_until_ms = new_persisted_until_ms;
}

// --- T035: listado y detalle de reuniones pasadas ----------------------
//
// Hasta acá el backend graba y persiste, pero ninguna pantalla puede leer lo
// grabado: `start_meeting`/`stop_meeting` devuelven sólo un id, y los únicos
// tipos de lectura que existen (`MeetingSegment`) son para el evento en vivo.
// `list_meetings` y `get_meeting` son los dos comandos que le faltan a
// Historia 4 (`contracts/tauri-commands.md`).
//
// **Alcance deliberadamente acotado**: `list_meetings` no implementa la
// búsqueda de texto (`query` en el contrato) — eso es Historia 5 (T041). Y
// `Meeting` no trae `notes` ni `actionItems`: ninguna de las dos tiene
// todavía una fuente de datos real en este alcance (`save_meeting_notes` y la
// generación de resumen/pendientes son tareas aparte), así que agregar esos
// campos hoy sólo devolvería `null`/`[]` disfrazado de contrato cumplido.

/// Resumen liviano de una reunión para el listado — a propósito NO trae
/// `segments` ni `speakers`: el listado se pinta con una sola fila por
/// reunión, cargar el transcript completo de todas para mostrar una lista
/// sería desperdiciar memoria y tiempo por algo que la UI ni muestra ahí.
#[derive(Clone, Debug, Serialize, Deserialize, Type)]
pub struct MeetingSummary {
    pub id: i64,
    pub title: String,
    pub kind: String,
    pub started_at: i64,
    pub ended_at: Option<i64>,
    pub status: String,
}

/// Página de resultados de `list_meetings`, mismo patrón que
/// `history::PaginatedHistory`.
#[derive(Clone, Debug, Serialize, Deserialize, Type)]
pub struct PaginatedMeetings {
    pub meetings: Vec<MeetingSummary>,
    pub has_more: bool,
}

/// Un hablante tal como lo debe ver el usuario: nunca incluye a los que
/// fueron fusionados dentro de otro (`get_meeting` los filtra al armar esta
/// lista) — para el usuario esas voces ya son la misma persona.
#[derive(Clone, Debug, Serialize, Deserialize, Type)]
pub struct MeetingSpeaker {
    pub id: i64,
    pub label: String,
    pub display_name: Option<String>,
}

/// Reunión completa para leerla (`get_meeting`): sus datos, su transcript en
/// orden cronológico y sus hablantes vigentes. Ver la nota de alcance arriba
/// sobre por qué no incluye `notes` ni `actionItems` todavía.
#[derive(Clone, Debug, Serialize, Deserialize, Type)]
pub struct Meeting {
    pub id: i64,
    pub title: String,
    pub kind: String,
    pub started_at: i64,
    pub ended_at: Option<i64>,
    pub status: String,
    pub summary: Option<String>,
    pub segments: Vec<MeetingSegment>,
    pub speakers: Vec<MeetingSpeaker>,
}

/// State for one in-progress meeting capture session — the microphone-open,
/// VAD-active window between `start_capture` and `stop_capture`. Deliberately
/// separate from dictation's `RecordingState` (see the coexistence note
/// above): a meeting isn't triggered by a shortcut binding, runs far longer,
/// and drives its own recorder/threads rather than the shared dictation one.
struct CaptureSession {
    meeting_id: i64,
    recorder: MeetingRecorder,
    capture_started: Instant,
    shutdown: Arc<AtomicBool>,
    watchdog_handle: Option<thread::JoinHandle<()>>,
    /// El hilo que corre `StreamingDiarizer::push`/`flush`, escucha
    /// `DiarizerCmd::TokensUpdated` y persiste las intervenciones que ya se
    /// pueden dar por cerradas (ver `maybe_persist_new_runs`). Reemplaza al
    /// `transcriber_handle` de antes de esta tarea: ya no hay turnos que
    /// transcribir de a uno, así que este hilo diariza y persiste, no
    /// transcribe (eso corre en el propio worker de streaming de
    /// `TranscriptionManager`).
    diarizer_handle: Option<thread::JoinHandle<()>>,
    /// Extremo emisor del canal hacia `diarizer_handle` — `stop_capture` lo
    /// usa para mandar `DiarizerCmd::Flush` como último mensaje antes de
    /// unirse al hilo.
    diar_tx: mpsc::Sender<DiarizerCmd>,
    /// Id del listener de `stream-text-event` registrado en `start_capture`
    /// — `stop_capture` lo saca con `unlisten` para no acumular un listener
    /// por reunión durante la vida de la app.
    stream_listener_id: Option<tauri::EventId>,
    /// `Some` sólo cuando la sesión graba por audio del sistema — ver
    /// `AudioWarningState`. `stop_capture` lo usa para la revisión final de
    /// I4 y para no reportar dos veces algo que el watchdog ya avisó.
    audio_warning_state: Option<Arc<AudioWarningState>>,
}

pub struct MeetingManager {
    db_path: PathBuf,
    /// Capture dependencies, wired once via `with_capture_deps` after
    /// construction (see its docs for why `new()` itself doesn't take
    /// them). `None` in the db-only construction the existing T005-T011
    /// tests below use, where `start_capture`/`stop_capture` are never
    /// called.
    app_handle: Option<AppHandle>,
    transcription_manager: Option<Arc<TranscriptionManager>>,
    mic_arbiter: Option<MicrophoneArbiter>,
    /// Para consultar `supports_streaming` del modelo resuelto de una
    /// reunión ANTES de abrir el micrófono — fix round 1 de la revisión de
    /// esta tarea (Critical 1): desde que el streaming es el único camino
    /// de texto, grabar con un modelo que no lo soporta no perdía turnos
    /// como en el diseño anterior, grababa horas sin guardar nada. Consulta
    /// del catálogo (`ModelManager::get_model_info`), no carga ningún
    /// modelo.
    model_manager: Option<Arc<ModelManager>>,
    /// Motor de diarización en streaming (Sortformer, Task 2), compartido
    /// entre reuniones. Se carga perezosamente en el primer `start_capture`
    /// (~492 MB, se descarga en runtime la primera vez) y se conserva
    /// cargado entre reuniones — recargarlo es caro y nada lo descarga
    /// (a diferencia del modelo de reconocimiento de voz, que sí tiene un
    /// descargador por inactividad, ver `TranscriptionManager`). Cada
    /// reunión sólo le pide `reset()` (limpia el caché de hablantes) al
    /// cerrar, para que la siguiente arranque sin arrastrar identidades de
    /// la anterior — ver `DiarizerCmd::Flush` en el hilo diarizador.
    streaming_diarizer: Arc<Mutex<Option<StreamingDiarizer>>>,
    /// M7 del fix round 1: `spawn_sortformer_warmup` se llama una vez por
    /// `start_capture`, pero la descarga+carga del modelo (~492 MB) puede
    /// seguir en vuelo cuando una reunión corta termina y otra arranca —
    /// sin este guard, un segundo `spawn_sortformer_warmup` concurrente
    /// pasaba el chequeo `is_none()` de `streaming_diarizer` (todavía nadie
    /// había escrito el resultado del primero) y largaba una SEGUNDA carga
    /// en paralelo; la que terminara después pisaba `streaming_diarizer`
    /// con un `StreamingDiarizer` recién nacido, reiniciando `spkcache`/
    /// `emitted_until_ms` a mitad de la reunión que ya estaba usando el
    /// anterior. `compare_exchange` en vez de un simple chequeo hace que
    /// sólo una carga pueda estar en vuelo a la vez.
    streaming_diarizer_loading: Arc<AtomicBool>,
    /// Mismo directorio de modelos que usa `ModelManager`: es donde vive (o
    /// se descarga) el modelo Sortformer.
    models_dir: Option<PathBuf>,
    capture: Mutex<Option<CaptureSession>>,
}

impl MeetingManager {
    /// Open (or create) the meeting database at `db_path` and apply any
    /// pending migrations. Mirrors `HistoryManager::new` /
    /// `HistoryManager::init_database`, minus the tauri-plugin-sql legacy
    /// migration path (there is no pre-existing meeting data to carry over).
    ///
    /// Does not wire up capture (microphone/VAD/transcription) — call
    /// [`Self::with_capture_deps`] for that. Kept separate so every existing
    /// db-only test (and any future one that only needs the schema) doesn't
    /// need a real `AppHandle`/`TranscriptionManager` just to construct a
    /// manager.
    pub fn new(db_path: PathBuf) -> Result<Self> {
        let manager = Self {
            db_path,
            app_handle: None,
            transcription_manager: None,
            mic_arbiter: None,
            model_manager: None,
            streaming_diarizer: Arc::new(Mutex::new(None)),
            streaming_diarizer_loading: Arc::new(AtomicBool::new(false)),
            models_dir: None,
            capture: Mutex::new(None),
        };
        manager.init_database()?;
        Ok(manager)
    }

    /// Wire up the dependencies `start_capture`/`stop_capture` need. Called
    /// once in `initialize_core_logic`, after `MeetingManager::new`, before
    /// the manager is wrapped in `Arc` and handed to Tauri as managed state.
    pub fn with_capture_deps(
        mut self,
        app_handle: AppHandle,
        transcription_manager: Arc<TranscriptionManager>,
        mic_arbiter: MicrophoneArbiter,
        model_manager: Arc<ModelManager>,
        models_dir: PathBuf,
    ) -> Self {
        self.app_handle = Some(app_handle);
        self.transcription_manager = Some(transcription_manager);
        self.mic_arbiter = Some(mic_arbiter);
        self.model_manager = Some(model_manager);
        self.models_dir = Some(models_dir);
        self
    }

    /// Deja el modelo Sortformer listo en un hilo aparte: lo descarga si
    /// falta y lo carga en el `Arc` compartido. No bloquea el arranque de la
    /// grabación — el audio que llega mientras carga no se pierde, el hilo
    /// diarizador lo bufferiza hasta que el modelo esté listo (ver
    /// `DiarizerCmd::Audio` en `start_capture`) para que el reloj en
    /// milisegundos de la diarización arranque en la MISMA muestra cero que
    /// el del reconocimiento de voz, no en la muestra donde el modelo
    /// terminó de cargar.
    fn spawn_sortformer_warmup(&self) {
        let Some(models_dir) = self.models_dir.clone() else {
            return;
        };
        let slot = Arc::clone(&self.streaming_diarizer);
        if slot.lock().unwrap().is_some() {
            return;
        }
        // M7 del fix round 1: reclama el permiso de cargar ANTES de
        // lanzar la tarea async, no sólo mirar si ya hay algo cargado —
        // ver el doc comment de `streaming_diarizer_loading`. Si ya hay
        // una carga en vuelo, esta llamada no hace nada más: la reunión en
        // curso sigue bufferizando su audio (`backlog`, en el hilo
        // diarizador de `start_capture`) hasta que esa carga termine.
        let loading = Arc::clone(&self.streaming_diarizer_loading);
        if loading
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return;
        }

        tauri::async_runtime::spawn(async move {
            // RAII no es práctico acá (el guard tendría que sobrevivir el
            // `.await` de `spawn_blocking` de abajo dentro del mismo
            // scope) — se libera a mano en cada salida, éxito o error.
            let model_path =
                match diarization_models::ensure_sortformer_model_downloaded(&models_dir).await {
                    Ok(p) => p,
                    Err(e) => {
                        warn!(
                            "No se pudo obtener el modelo Sortformer; la reunión quedará sin \
                             hablantes: {}",
                            e
                        );
                        loading.store(false, Ordering::Release);
                        return;
                    }
                };

            // Cargar ~492 MB de sesión ONNX es trabajo bloqueante: fuera del
            // executor async, como hace el resto del código con las
            // operaciones pesadas de modelo.
            let _ = tauri::async_runtime::spawn_blocking(move || {
                match StreamingDiarizer::load(&model_path) {
                    Ok(diarizer) => {
                        *slot.lock().unwrap() = Some(diarizer);
                        info!("Motor de diarización en streaming listo para la reunión en curso");
                    }
                    Err(e) => warn!(
                    "No se pudo cargar el modelo Sortformer; la reunión quedará sin hablantes: {}",
                    e
                ),
                }
            })
            .await;
            loading.store(false, Ordering::Release);
        });
    }

    /// Start capturing audio for `meeting_id` (a row already created by
    /// [`Self::start_meeting`]): opens the microphone and feeds two live
    /// engines in parallel — speech recognition (`TranscriptionManager::
    /// start_stream`) and speaker diarization (`StreamingDiarizer::push`) —
    /// persisting+emitting each attributed intervention as it closes (see
    /// [`maybe_persist_new_runs`]). Runs until [`Self::stop_capture`] is
    /// called — meetings run for hours, not the seconds a dictation
    /// recording does, so this spawns its own long-lived watchdog +
    /// diarizer threads rather than reusing dictation's keypress-driven
    /// start/stop.
    ///
    /// Fails if a capture is already active, if this manager wasn't
    /// configured via [`Self::with_capture_deps`], or if the microphone is
    /// currently held by a dictation recording (see the coexistence note
    /// above).
    ///
    /// `kind` es el tipo de reunión que eligió el usuario para ESTA sesión
    /// (`commands::meeting::start_meeting` lo valida y lo pasa acá) — junto
    /// con si el audio del sistema está disponible en esta máquina, es lo
    /// único que decide la fuente real de audio (`resolve_meeting_audio_source`,
    /// M2 del reporte de seguimiento).
    pub fn start_capture(&self, meeting_id: i64, kind: MeetingKind) -> Result<()> {
        let app_handle = self
            .app_handle
            .clone()
            .ok_or_else(|| anyhow::anyhow!("MeetingManager capture not configured"))?;
        let transcription_manager = self
            .transcription_manager
            .clone()
            .ok_or_else(|| anyhow::anyhow!("MeetingManager capture not configured"))?;
        let mic_arbiter = self
            .mic_arbiter
            .clone()
            .ok_or_else(|| anyhow::anyhow!("MeetingManager capture not configured"))?;

        // El modelo de ESTA reunión, resuelto una sola vez acá: el propio de
        // reuniones si el usuario eligió uno (`settings.meeting_model_id`),
        // si no el mismo que el dictado — ver el doc comment del campo en
        // `settings.rs`. Todo lo que sigue (la carga de acá abajo y el
        // reintento del watchdog más adelante en esta función) usa siempre
        // esta variable, nunca `settings.selected_model` directamente: ese
        // es el del dictado y puede cambiar bajo los pies mientras la
        // reunión graba (el selector de dictado del popover sigue activo).
        let meeting_model_id = {
            let settings = crate::settings::get_settings(&app_handle);
            resolve_meeting_model_id(
                settings.meeting_model_id.as_deref(),
                &settings.selected_model,
            )
        };

        // Critical 1 del fix round 1 (revisión de esta tarea): el
        // reconocimiento en streaming es el ÚNICO camino de texto de una
        // reunión desde que se borró el reintento por turno
        // (`transcribe_with_reload`) — `TranscriptionManager::start_stream`
        // exige `supports_streaming` y, si el modelo no lo tiene, se cae en
        // silencio a "sin streaming" (`run_stream_worker` en
        // `transcription.rs`) sin avisar a nadie. Antes de esta tarea el
        // camino por turnos transcribía con cualquier motor, streaming o
        // no, así que este chequeo no hacía falta. Rechazar acá, ANTES de
        // abrir el micrófono, es lo único que evita grabar una reunión
        // entera sin guardar ni un segmento. Consulta del catálogo
        // (`ModelManager::get_model_info`, sin cargar nada) — el popover ya
        // filtra su selector de modelo de reuniones a los que soportan
        // streaming, pero "heredar del dictado" puede seguir apuntando a
        // uno que no sirve, así que el backend no puede confiar sólo en
        // eso.
        let model_manager = self
            .model_manager
            .clone()
            .ok_or_else(|| anyhow::anyhow!("MeetingManager capture not configured"))?;
        let meeting_model_supports_streaming = model_manager
            .get_model_info(&meeting_model_id)
            .map(|info| info.supports_streaming)
            .unwrap_or(false);
        if !meeting_model_supports_streaming {
            bail!("meeting_model_not_streaming:{meeting_model_id}");
        }

        // Kick off the ASR model load now (non-blocking, idempotent if
        // already loaded/loading) rather than waiting for the first
        // completed turn to discover it isn't ready. Mirrors how dictation
        // kicks this off in parallel with opening the mic (`actions.rs`) —
        // by the time a turn actually finishes (seconds into the meeting),
        // the model has almost always finished loading.
        transcription_manager.initiate_model_load_id(meeting_model_id.clone());

        let mut capture_guard = self.capture.lock().unwrap();
        if capture_guard.is_some() {
            bail!("meeting_capture_already_active");
        }

        // M5 (reporte de seguimiento): esto se toma SIEMPRE, incluso cuando
        // `kind`/la disponibilidad de esta máquina van a resolver en audio
        // del sistema y la sesión nunca va a tocar el micrófono físico. Es
        // correcto para la exclusividad con el dictado — sigue siendo cierto
        // que "una reunión está grabando" no debe convivir con un dictado en
        // curso, sea cual sea su fuente — pero desde acá el bloqueo pasa a
        // ser una política conservadora de "una sola grabación a la vez",
        // no una consecuencia física de dos streams peleándose por el mismo
        // dispositivo de entrada (que es la razón original documentada más
        // arriba, en la sección "Coexistence with dictation"). La ventana de
        // gracia de 30s de `lazy_stream_close` (ver esa misma sección) sigue
        // bloqueando una reunión por audio del sistema exactamente igual que
        // a una por micrófono, aunque esa reunión no necesite el micrófono
        // para nada.
        mic_arbiter
            .try_acquire(MicOwner::Meeting)
            .map_err(|owner| {
                anyhow::anyhow!(
                    "El micrófono está en uso por {} ahora mismo.",
                    owner.label()
                )
            })?;

        let start_result = (|| -> Result<CaptureSession> {
            let capture_started = Instant::now();
            let stream_router = transcription_manager.stream_router();
            let (diar_tx, diar_rx) = mpsc::channel::<DiarizerCmd>();
            // Profundidad de la cola de audio pendiente de diarizar, sólo
            // para poder avisarlo (ver `QUEUE_DEPTH_WARN_THRESHOLD`).
            let diar_queue_depth = Arc::new(AtomicUsize::new(0));
            // Reconstruye el reloj de reunión a partir del reloj comprimido
            // del ASR — ver el doc comment de `AudioToWallClock` (fix
            // round 2: el ancla es el reloj por MUESTRAS de la diarización,
            // no reloj de pared) y el comentario del módulo (Important 3/4
            // del fix round 1).
            let clock = Arc::new(Mutex::new(AudioToWallClock::default()));
            // Estado de los dos relojes (`AudioClockState` — `asr_ms` sólo
            // lo que pasó la compuerta, `total_ms` TODO lo que llegó, ver
            // `step_audio_clock`). Único hilo escritor (`audio_cb`), por
            // eso alcanza un `Mutex` en vez de átomos separados que
            // podrían quedar inconsistentes entre sí.
            let asr_clock = Arc::new(Mutex::new(AudioClockState::default()));

            // Cada intento de abrir un recorder necesita su propio callback
            // (`audio_cb` consume el que le pasan) — I2 del reporte de
            // seguimiento puede necesitar construir el micrófono DESPUÉS de
            // que audio del sistema ya se haya intentado y fallado, así que
            // esto es una fábrica en vez de un valor único.
            //
            // Important 4 del fix round 1: la compuerta de energía sólo
            // protege al ASR (`stream_router.feed`) — el reconocimiento sí
            // alucina texto sobre silencio digital. La diarización recibe
            // TODO el audio sin filtrar: `StreamingDiarizer` necesita ver
            // las pausas reales para cortar turnos (ver el comentario del
            // módulo). Como el ASR ve un subconjunto, su reloj en
            // milisegundos queda comprimido respecto al de la diarización —
            // `AudioToWallClock` (arriba) es quien lo destraduce, marcando
            // un punto de referencia (contra `total_ms`, NO contra
            // `capture_started.elapsed()` — ver N1 del fix round 2) cada
            // vez que el ASR retoma después de un hueco de silencio.
            let build_audio_cb = || {
                let stream_router = Arc::clone(&stream_router);
                let diar_tx = diar_tx.clone();
                let diar_queue_depth = Arc::clone(&diar_queue_depth);
                let clock = Arc::clone(&clock);
                let asr_clock = Arc::clone(&asr_clock);
                move |frame: &[f32]| {
                    // 16 kHz mono, igual que el resto del pipeline de
                    // reuniones (ver `AudioRecorder`/`StreamingDiarizer`).
                    let frame_ms = (frame.len() as u64 * 1000) / 16_000;
                    let has_energy = has_energy(frame);
                    let mark = {
                        let mut guard = asr_clock.lock().unwrap();
                        let (new_state, mark) = step_audio_clock(*guard, has_energy, frame_ms);
                        *guard = new_state;
                        mark
                    };
                    if let Some((asr_ms, total_ms)) = mark {
                        clock.lock().unwrap().mark(asr_ms, total_ms);
                    }
                    if has_energy {
                        stream_router.feed(frame);
                    }

                    // Sin filtrar: ver Important 4 arriba.
                    let depth = diar_queue_depth.fetch_add(1, Ordering::Relaxed) + 1;
                    if depth == QUEUE_DEPTH_WARN_THRESHOLD {
                        warn!(
                            "Meeting {}: {} tramos de audio esperando diarización en vivo — la \
                             diarización va más lenta que tiempo real y el audio pendiente se \
                             acumula en memoria",
                            meeting_id, depth
                        );
                    }
                    let _ = diar_tx.send(DiarizerCmd::Audio(frame.to_vec()));
                }
            };
            let mic_device = || {
                app_handle
                    .try_state::<Arc<AudioRecordingManager>>()
                    .and_then(|manager| manager.selected_input_device())
            };

            // Fuente de audio resuelta contra el TIPO de reunión elegido y
            // si el audio del sistema está disponible en esta máquina — ver
            // `resolve_meeting_audio_source`. Sólo se usa para decidir el
            // recorder/dispositivo iniciales: I2 de más abajo, si falla,
            // reconstruye `recorder` directamente como `Microphone` sin
            // necesitar releer esta variable.
            let audio_source = resolve_meeting_audio_source(kind, system_audio_available());

            // Critical 2 del fix round 1 (revisión de esta tarea): antes,
            // `start_stream` se llamaba ACÁ, antes de construir el
            // recorder — y `build_meeting_recorder`/
            // `build_meeting_system_audio_recorder` de más abajo podían
            // fallar con `?` sin haber cancelado el stream, dejando el
            // motor de reconocimiento sacado del mutex para siempre (el
            // worker de `run_stream_worker` queda vivo en `rx.recv()`
            // esperando comandos que nunca llegan). El dictado siguiente se
            // encontraba el motor prestado y fallaba con "Model is not
            // loaded" hasta reiniciar la app, sin ningún aviso, porque el
            // árbitro del micrófono ya se había soltado. Construir el
            // recorder PRIMERO y recién después arrancar el stream (todavía
            // antes de `recorder.start()`, que es lo único que puede
            // entregar el primer frame) cierra ese hueco: ningún `?` de
            // construcción puede fallar ya con el stream abierto.
            let mut recorder = match audio_source {
                MeetingAudioSource::Microphone => {
                    MeetingRecorder::Microphone(build_meeting_recorder(build_audio_cb())?)
                }
                MeetingAudioSource::SystemAudio => MeetingRecorder::SystemAudio(Arc::new(
                    Mutex::new(build_meeting_system_audio_recorder(build_audio_cb())?),
                )),
            };
            // El micrófono elegido en Ajustes sólo aplica a esa rama: la
            // reunión tiene su propio `AudioRecorder`, así que sin esto
            // abría el default del sistema e ignoraba el ajuste en
            // silencio. El audio del sistema no toma dispositivo de
            // entrada — un tap global captura todo lo que suena en el
            // equipo, no lo que entra por un micrófono en particular.
            let selected_device = match audio_source {
                MeetingAudioSource::Microphone => mic_device(),
                MeetingAudioSource::SystemAudio => None,
            };

            // Arranca el stream de ASR ANTES de que exista un solo frame de
            // audio real (`recorder.start()`, más abajo, es lo primero que
            // puede entregar uno). No es sólo prolijidad: `StreamRouter::
            // feed` es un no-op silencioso mientras el router no está
            // abierto (ver `transcription.rs`) — si un frame con energía
            // llegara antes de este punto, `audio_cb` lo contaría igual en
            // su reloj del ASR (`asr_clock`, ver más arriba) aunque el
            // motor nunca lo hubiera recibido de verdad, desalineando
            // `AudioToWallClock` desde el primer punto de referencia. No
            // bloquea: sólo abre el canal interno y dispara un hilo aparte
            // que espera a que el modelo (ya en camino, ver
            // `initiate_model_load_id` arriba) termine de cargar antes de
            // empezar a decodificar de verdad. De acá en adelante,
            // CUALQUIER camino de salida (`?` o `bail!`) tiene que pasar
            // por `cancel_stream()` primero — ver Critical 2 arriba.
            //
            // Límite conocido, sin resolver en esta tarea: si el modelo de
            // reconocimiento nunca llega a cargar (falla la descarga,
            // archivo corrupto), `start_stream` se cae en silencio a "sin
            // streaming" y esta reunión no va a producir ningún segmento —
            // a diferencia del diseño anterior, ya no hay un reintento
            // por-turno que pudiera recuperarla a mitad de camino, porque
            // el motor se toma una sola vez para toda la sesión, no una vez
            // por turno. No medido contra ese caso de falla real.
            transcription_manager.start_stream(StreamPurpose::Meeting);

            let mut fell_back_to_microphone = false;
            if let Err(e) = recorder
                .open(selected_device)
                .and_then(|_| recorder.start())
            {
                recorder.close();
                if audio_source != MeetingAudioSource::SystemAudio {
                    transcription_manager.cancel_stream();
                    bail!("Failed to start meeting capture: {}", e);
                }
                // I2 del reporte de seguimiento: `resolve_meeting_audio_source`
                // sólo degrada por versión de macOS, no porque la sesión
                // REALMENTE abra — si `AudioHardwareCreateProcessTap` (o
                // `AudioDeviceStart`) falla acá (permiso denegado a último
                // momento, dispositivo agregado rechazado, lo que sea),
                // antes la reunión moría entera con un string crudo, en un
                // caso donde el micrófono habría grabado sin problema. Cae a
                // micrófono en vez de abortar la reunión.
                warn!(
                    "Meeting {}: no se pudo abrir el audio del sistema, se cae a micrófono: {}",
                    meeting_id, e
                );
                // No hace falta reasignar `audio_source` acá: nada la vuelve
                // a leer después de este punto — lo que importa de acá en
                // más es la variante real de `recorder` (ya reconstruido
                // como `Microphone` abajo) y `fell_back_to_microphone`.
                fell_back_to_microphone = true;
                // Sin `?`: el stream ya está abierto acá (Critical 2), así
                // que un fallo de construcción tiene que cancelarlo antes
                // de salir, igual que las otras dos salidas de este bloque.
                recorder = match build_meeting_recorder(build_audio_cb()) {
                    Ok(r) => MeetingRecorder::Microphone(r),
                    Err(e) => {
                        transcription_manager.cancel_stream();
                        return Err(e);
                    }
                };
                if let Err(e) = recorder.open(mic_device()).and_then(|_| recorder.start()) {
                    recorder.close();
                    transcription_manager.cancel_stream();
                    bail!("Failed to start meeting capture: {}", e);
                }
            }

            if fell_back_to_microphone {
                // Aviso de una sola vez, disparado acá mismo — no necesita
                // dedup real, pero `report_audio_warning` pide un
                // `AtomicBool` para compartir firma con el resto de los
                // avisos de audio de reunión (I5, ver `AudioWarningState`).
                report_audio_warning(
                    Some(&app_handle),
                    meeting_id,
                    &AtomicBool::new(false),
                    MeetingAudioWarningKind::FellBackToMicrophone,
                );
            }

            // Referencia propia para que el watchdog pueda sondear el
            // diagnóstico de permiso/dispositivo de salida (I6/I5 de
            // `system_audio.rs`) sin disputarle la dueñidad de la sesión a
            // `CaptureSession` — ver el comentario de `MeetingRecorder`.
            // `None` para micrófono (incluida una sesión que cayó a
            // micrófono por I2): no hay nada que sondear ahí, y una sesión
            // así ya avisó `FellBackToMicrophone` arriba.
            let audio_diagnostics_handle = match &recorder {
                MeetingRecorder::SystemAudio(r) => Some(Arc::clone(r)),
                MeetingRecorder::Microphone(_) => None,
            };
            // I4/I5: estado de avisos de "sin audio real" compartido entre
            // el watchdog y `stop_capture` — ver `AudioWarningState`. Mismo
            // criterio que `audio_diagnostics_handle`: sólo existe cuando la
            // sesión terminó grabando por audio del sistema.
            let audio_warning_state = match &recorder {
                MeetingRecorder::SystemAudio(_) => Some(Arc::new(AudioWarningState::default())),
                MeetingRecorder::Microphone(_) => None,
            };

            let shutdown = Arc::new(AtomicBool::new(false));

            // Estado compartido entre el hilo diarizador y el listener de
            // `stream-text-event` de más abajo — ver `TranscriptState`.
            let transcript_state = Arc::new(Mutex::new(TranscriptState::default()));

            // Tokens con tiempo del reconocimiento en streaming: llegan por
            // evento (mismo bus que ya usa el overlay del dictado), no por
            // llamada directa, porque `TranscriptionManager` no conoce a
            // `MeetingManager` — ver `StreamPurpose`/`StreamTextEvent` en
            // `transcription.rs`. Sólo puede haber un stream activo a la vez
            // (exclusión mutua con el dictado, ver la nota de coexistencia),
            // así que mientras esta reunión graba, cualquier evento que
            // llegue es suyo. Cada token se convierte a reloj de reunión acá
            // mismo, antes de guardarlo — ver `AudioToWallClock` y el
            // comentario del módulo (Important 3/4 del fix round 1): así
            // `TranscriptState::tokens` y `TranscriptState::spans` quedan en
            // el mismo reloj para cuando `align::attribute` los cruce.
            let stream_listener_id = {
                let transcript_state = Arc::clone(&transcript_state);
                let diar_tx = diar_tx.clone();
                let clock = Arc::clone(&clock);
                StreamTextEvent::listen(&app_handle, move |event| {
                    if let Some(tokens) = event.payload.tokens {
                        let clock = clock.lock().unwrap();
                        let tokens = tokens
                            .into_iter()
                            .map(|token| convert_token_to_meeting_clock(token, &clock))
                            .collect();
                        drop(clock);
                        transcript_state.lock().unwrap().tokens = tokens;
                        let _ = diar_tx.send(DiarizerCmd::TokensUpdated);
                    }
                })
            };

            let watchdog_handle = {
                let shutdown = Arc::clone(&shutdown);
                let transcription_manager = Arc::clone(&transcription_manager);
                let app_handle = app_handle.clone();
                let audio_warning_state = audio_warning_state.clone();
                thread::spawn(move || {
                    // Sondeo del audio del sistema (I6/I5): una vez por
                    // `SYSTEM_AUDIO_DIAGNOSIS_POLL`, no en cada vuelta de
                    // 100ms del watchdog — sondear "demasiado temprano"
                    // (antes del primer bloque de audio) puede dar
                    // legítimamente `NoSamplesCaptured`, y una reunión de 40
                    // minutos igual necesita enterarse mucho antes de
                    // colgar, no sólo al final. Cada aviso se manda como
                    // máximo una vez por sesión (`report_audio_warning`).
                    let mut last_diagnosis_poll = Instant::now();
                    // No comparte estado con `audio_warning_state`
                    // (permiso/silencio): el cambio de dispositivo de salida
                    // se puede reconocer (`acknowledge_output_device_change`)
                    // y volver a avisar más adelante en la misma reunión, así
                    // que `stop_capture` no necesita revisarlo al cerrar.
                    let output_device_warning_reported = AtomicBool::new(false);

                    while !shutdown.load(Ordering::Relaxed) {
                        thread::sleep(WATCHDOG_POLL_INTERVAL);
                        // Mantener vivo el reloj de inactividad del modelo:
                        // el watcher de `TranscriptionManager` sólo mira el
                        // dictado, y un tramo callado de la reunión (una
                        // pausa, un break) le parece inactividad. Si descarga
                        // el modelo, el stream de esta reunión se queda sin
                        // motor a mitad de camino — ver `set_meeting_capture_
                        // active` más abajo, que además evita que el
                        // descargador por inactividad lo intente del todo.
                        transcription_manager.touch_activity();

                        if let (Some(sa), Some(warning_state)) =
                            (&audio_diagnostics_handle, &audio_warning_state)
                        {
                            if last_diagnosis_poll.elapsed() >= SYSTEM_AUDIO_DIAGNOSIS_POLL {
                                last_diagnosis_poll = Instant::now();
                                let sa = sa.lock().unwrap();

                                // M1 (reporte de seguimiento): una vez que ya
                                // se avisó de que no hay audio real (falta el
                                // permiso, o silencio prolongado — I4),
                                // volver a llamar `diagnose_now()` no aporta
                                // nada más y es la rama cara de
                                // `SystemAudioRecorder`: enumera TODOS los
                                // procesos de audio del sistema vía CoreAudio
                                // (`any_process_playing_audio` en
                                // `macos.rs`). Dejar de sondearla evita ese
                                // costo cada `SYSTEM_AUDIO_DIAGNOSIS_POLL` por
                                // el resto de una reunión que ya sabemos que
                                // está en problemas.
                                let already_warned_no_audio =
                                    warning_state.permission_reported.load(Ordering::Relaxed)
                                        || warning_state.silence_reported.load(Ordering::Relaxed);
                                if !already_warned_no_audio {
                                    match sa.diagnose_now() {
                                        CaptureDiagnosis::LikelyMissingPermission => {
                                            report_audio_warning(
                                                Some(&app_handle),
                                                meeting_id,
                                                &warning_state.permission_reported,
                                                MeetingAudioWarningKind::MissingPermission,
                                            );
                                        }
                                        CaptureDiagnosis::AudioPresent => {}
                                        // I4: `NoSamplesCaptured`/
                                        // `GenuineSilence`/`Undetermined` —
                                        // ninguno es "falta el permiso", pero
                                        // los tres significan "cero audio
                                        // real hasta ahora". `saw_nonzero`
                                        // sólo se resetea en `stop()`, así
                                        // que seguir en cualquiera de estos
                                        // estados ya implica cero audio real
                                        // desde el arranque de la sesión —
                                        // no hace falta un timer aparte,
                                        // `capture_started.elapsed()` alcanza.
                                        _ => {
                                            if capture_started.elapsed()
                                                >= SILENCE_WARNING_THRESHOLD
                                            {
                                                report_audio_warning(
                                                    Some(&app_handle),
                                                    meeting_id,
                                                    &warning_state.silence_reported,
                                                    MeetingAudioWarningKind::NoAudioCaptured,
                                                );
                                            }
                                        }
                                    }
                                }

                                if sa.output_device_changed() {
                                    report_audio_warning(
                                        Some(&app_handle),
                                        meeting_id,
                                        &output_device_warning_reported,
                                        MeetingAudioWarningKind::OutputDeviceChanged,
                                    );
                                    // Reconoce el cambio para que uno nuevo
                                    // (por ejemplo, otro cambio de salida más
                                    // adelante en la misma reunión) pueda
                                    // volver a avisar — a diferencia del
                                    // permiso, acá sí hay un "acknowledge"
                                    // propio en `system_audio.rs`.
                                    sa.acknowledge_output_device_change();
                                }
                            }
                        }
                    }
                })
            };

            let diarizer_handle = {
                let db_path = self.db_path.clone();
                let app_handle = app_handle.clone();
                let streaming_diarizer = Arc::clone(&self.streaming_diarizer);
                let transcript_state = Arc::clone(&transcript_state);
                let diar_queue_depth = Arc::clone(&diar_queue_depth);
                thread::spawn(move || {
                    // Un solo aviso de intervención perdida por sesión de
                    // captura, ver `report_turn_failure`.
                    let mut turn_failure_reported = false;
                    let conn = match Connection::open(&db_path) {
                        Ok(c) => c,
                        Err(e) => {
                            // Fatal: sin conexión no hay nada que guardar en
                            // toda la sesión. Se avisa como fin de sesión Y
                            // se cierra la captura, para que lo que ve el
                            // usuario y lo que hace el micrófono coincidan.
                            report_fatal_capture_failure(
                                Some(&app_handle),
                                meeting_id,
                                format!(
                                    "no se pudo abrir la base de datos para guardar la \
                                     reunión, no se va a guardar nada de lo que se hable: {e}"
                                ),
                            );
                            spawn_capture_abort(&app_handle, meeting_id);
                            return;
                        }
                    };

                    // Audio que llegó ANTES de que el modelo Sortformer
                    // terminara de cargar: se bufferiza acá y se drena en
                    // cuanto el motor esté listo, para que su reloj en
                    // milisegundos arranque en la misma muestra cero que el
                    // del reconocimiento de voz — ver `spawn_sortformer_
                    // warmup` y el comentario del módulo. Si el modelo nunca
                    // llega a cargar, este buffer crece sin freno por el
                    // resto de la reunión (mismo tipo de límite conocido que
                    // el resto de este módulo documenta para otros casos sin
                    // hardware real para medirlos).
                    let mut backlog: Vec<f32> = Vec::new();

                    while let Ok(cmd) = diar_rx.recv() {
                        match cmd {
                            DiarizerCmd::Audio(chunk) => {
                                let _ = diar_queue_depth.fetch_update(
                                    Ordering::Relaxed,
                                    Ordering::Relaxed,
                                    |depth| depth.checked_sub(1),
                                );
                                let mut guard = streaming_diarizer.lock().unwrap();
                                match guard.as_mut() {
                                    Some(diarizer) => {
                                        if !backlog.is_empty() {
                                            let pending = std::mem::take(&mut backlog);
                                            push_diarizer_chunk(
                                                diarizer,
                                                &pending,
                                                Some(&app_handle),
                                                meeting_id,
                                                &transcript_state,
                                                &mut turn_failure_reported,
                                            );
                                        }
                                        push_diarizer_chunk(
                                            diarizer,
                                            &chunk,
                                            Some(&app_handle),
                                            meeting_id,
                                            &transcript_state,
                                            &mut turn_failure_reported,
                                        );
                                        drop(guard);
                                        maybe_persist_new_runs(
                                            &conn,
                                            Some(&app_handle),
                                            meeting_id,
                                            &transcript_state,
                                            false,
                                            &mut turn_failure_reported,
                                        );
                                    }
                                    None => {
                                        drop(guard);
                                        backlog.extend_from_slice(&chunk);
                                    }
                                }
                            }
                            DiarizerCmd::TokensUpdated => {
                                maybe_persist_new_runs(
                                    &conn,
                                    Some(&app_handle),
                                    meeting_id,
                                    &transcript_state,
                                    false,
                                    &mut turn_failure_reported,
                                );
                            }
                            DiarizerCmd::Flush => {
                                let mut guard = streaming_diarizer.lock().unwrap();
                                if let Some(diarizer) = guard.as_mut() {
                                    if !backlog.is_empty() {
                                        let pending = std::mem::take(&mut backlog);
                                        push_diarizer_chunk(
                                            diarizer,
                                            &pending,
                                            Some(&app_handle),
                                            meeting_id,
                                            &transcript_state,
                                            &mut turn_failure_reported,
                                        );
                                    }
                                    match diarizer.flush() {
                                        Ok(spans) => {
                                            transcript_state.lock().unwrap().spans.extend(spans);
                                        }
                                        Err(e) => warn!(
                                            "Meeting {}: flush() de la diarización en vivo \
                                             falló: {}",
                                            meeting_id, e
                                        ),
                                    }
                                    // Nueva reunión, caché de hablantes
                                    // limpio — ver el doc comment de
                                    // `streaming_diarizer`.
                                    diarizer.reset();
                                }
                                drop(guard);
                                maybe_persist_new_runs(
                                    &conn,
                                    Some(&app_handle),
                                    meeting_id,
                                    &transcript_state,
                                    true,
                                    &mut turn_failure_reported,
                                );
                                break;
                            }
                        }
                    }
                })
            };

            Ok(CaptureSession {
                meeting_id,
                recorder,
                capture_started,
                shutdown,
                watchdog_handle: Some(watchdog_handle),
                diarizer_handle: Some(diarizer_handle),
                diar_tx,
                stream_listener_id: Some(stream_listener_id),
                audio_warning_state,
            })
        })();

        match start_result {
            Ok(session) => {
                // Recién con el micrófono ya abierto: preparar el modelo de
                // diarización nunca debe demorar el inicio de la grabación.
                self.spawn_sortformer_warmup();
                // Que nadie descargue el modelo de reconocimiento mientras
                // dure la reunión: con "Descargar de inmediato" se
                // descargaba después de cada turno y el siguiente fallaba.
                transcription_manager.set_meeting_capture_active(true);
                // Única señal visible de que el micrófono está abierto cuando
                // la ventana de reuniones está cerrada.
                crate::tray::set_meeting_recording(&app_handle, true);
                info!("Meeting {} capture started", meeting_id);
                *capture_guard = Some(session);
                Ok(())
            }
            Err(e) => {
                mic_arbiter.release(MicOwner::Meeting);
                Err(e)
            }
        }
    }

    /// Stop the active capture session cleanly: stop and close the
    /// microphone, close both live engines (ASR + diarization), flush and
    /// persist whatever intervention was still open, join the
    /// watchdog/diarizer threads, and release the microphone arbiter.
    /// Idempotent-ish: fails with an error (not a panic) if no capture is
    /// active, which is fine for callers to log and ignore.
    ///
    /// This is the internal method the future `stop_meeting` Tauri command
    /// (T015) calls before it transitions `meetings.status` to
    /// `processing`/kicks off summary generation — this task does not
    /// implement that command itself.
    pub fn stop_capture(&self, meeting_id: i64) -> Result<()> {
        // Held for the ENTIRE critical section below — including
        // recorder.stop(), the thread joins, and the arbiter release at the
        // end — not dropped early. Dropping it right after `take()` (as an
        // earlier version of this function did) let a concurrent
        // `start_capture` see no active session, acquire the arbiter (the
        // same-owner re-acquire check made that look legitimate), and open a
        // second `AudioRecorder` on the same device while this teardown was
        // still in flight; this function's later `release()` would then
        // wipe out that new session's legitimate claim. That's exactly the
        // failure mode the arbiter exists to prevent (T012 review finding
        // #1), so `start_capture`'s own `self.capture.lock()` now blocks
        // until this whole function — arbiter release included — is done,
        // mirroring how `AudioRecordingManager::try_start_recording`/
        // `stop_recording` hold `self.state` across their whole critical
        // section for the same reason.
        let mut capture_guard = self.capture.lock().unwrap();
        let mut session = capture_guard
            .take()
            .ok_or_else(|| anyhow::anyhow!("no_active_meeting_capture"))?;

        if session.meeting_id != meeting_id {
            warn!(
                "stop_capture({}) called while meeting {} was the one actually capturing; \
                 stopping it anyway since only one capture can be active",
                meeting_id, session.meeting_id
            );
        }

        // Stop the recorder first — its drain still feeds `audio_cb` for
        // any trailing buffered audio, so both live engines see it before we
        // close them below. The samples themselves are redundant with what
        // we already collected via the callback (see the module doc
        // comment); only the final diagnosis (audio del sistema únicamente)
        // se conserva, para el chequeo de I4 más abajo.
        let final_diagnosis = session.recorder.stop();

        // El ASR ya recibió (vía `audio_cb`, arriba) todo el audio que iba a
        // recibir para esta reunión — `finalize_stream` BLOQUEA hasta que el
        // hilo de streaming termine de procesar ese último tramo y emita su
        // último `stream-text-event`, así que cuando vuelve acá
        // `transcript_state.tokens` ya tiene lo último dicho. El texto que
        // devuelve se descarta a propósito: ya está en los tokens que el
        // listener capturó: lo único que se pierde es el texto que
        // `finalize()` pudiera comprometer MÁS ALLÁ del último evento (el
        // motor no expone tokens ahí, ver `TranscriptionManager::
        // finalize_stream`) — hueco chico y conocido (como mucho una o dos
        // palabras que seguían tentativas), no una carrera de datos: sin
        // este bloqueo sí lo sería.
        if let Some(tm) = &self.transcription_manager {
            if let Err(e) = tm.finalize_stream() {
                // M8 del fix round 1: un timeout acá (`finalize_stream`
                // esperó `STREAM_FINALIZE_REPLY_TIMEOUT` sin respuesta del
                // hilo de streaming) puede dejar el motor de reconocimiento
                // sin devolver — el próximo dictado se encontraría con
                // "Model is not loaded" hasta reiniciar la app, el mismo
                // síntoma del Critical 2 de esta revisión, pero por un
                // camino que esta tarea no puede cerrar del todo (el hilo
                // de streaming vive en `transcription.rs`, fuera de
                // alcance). Detectarlo y subir el nivel del log a `error!`
                // (con la consecuencia explícita) es lo mínimo razonable
                // acá: no hay ningún canal existente hacia el usuario para
                // "el dictado puede haber quedado roto", y esta reunión ya
                // está cerrando de todos modos.
                let timed_out = e.to_string().contains("Timed out waiting");
                if timed_out {
                    error!(
                        "Meeting {}: finalize_stream() se agotó por tiempo al cerrar la \
                         reunión — el dictado puede quedar sin streaming hasta reiniciar Dilo: {}",
                        meeting_id, e
                    );
                } else {
                    warn!(
                        "Meeting {}: finalize_stream falló al cerrar la reunión: {}",
                        meeting_id, e
                    );
                }
            }
        }
        if let Some(app) = &self.app_handle {
            if let Some(id) = session.stream_listener_id.take() {
                app.unlisten(id);
            }
        }
        // Último mensaje del canal: vacía lo que el diarizador tenga
        // pendiente (`StreamingDiarizer::flush`) y persiste TODO lo que
        // falte, última intervención incluida — ver `DiarizerCmd::Flush`.
        let _ = session.diar_tx.send(DiarizerCmd::Flush);

        session.shutdown.store(true, Ordering::Relaxed);
        if let Some(h) = session.watchdog_handle.take() {
            let _ = h.join();
        }
        if let Some(h) = session.diarizer_handle.take() {
            let _ = h.join();
        }

        // I4 del reporte de seguimiento: el watchdog sólo avisa cada
        // `SYSTEM_AUDIO_DIAGNOSIS_POLL`, y sólo después de
        // `SILENCE_WARNING_THRESHOLD` de silencio para el aviso genérico —
        // una reunión por audio del sistema que se armó y se cortó antes de
        // llegar a ese umbral (o incluso antes del primer sondeo) terminaba
        // sin ningún aviso pese a no haber capturado nada real. Esta es la
        // revisión final: usa el diagnóstico de `recorder.stop()` de arriba,
        // ya con los hilos unidos (nadie más puede estar reportando en
        // paralelo), y respeta lo que el watchdog ya haya avisado durante la
        // grabación (`AudioWarningState` es compartido, no se avisa dos
        // veces por lo mismo).
        if let (Some(diagnosis), Some(warning_state)) =
            (final_diagnosis, &session.audio_warning_state)
        {
            match diagnosis {
                CaptureDiagnosis::LikelyMissingPermission => {
                    report_audio_warning(
                        self.app_handle.as_ref(),
                        session.meeting_id,
                        &warning_state.permission_reported,
                        MeetingAudioWarningKind::MissingPermission,
                    );
                }
                CaptureDiagnosis::AudioPresent => {}
                _ => {
                    report_audio_warning(
                        self.app_handle.as_ref(),
                        session.meeting_id,
                        &warning_state.silence_reported,
                        MeetingAudioWarningKind::NoAudioCaptured,
                    );
                }
            }
        }

        session.recorder.close();

        // Recién acá, con los hilos ya unidos: mientras se drenaba la cola
        // los turnos pendientes todavía necesitaban el modelo cargado.
        if let Some(tm) = &self.transcription_manager {
            tm.set_meeting_capture_active(false);
            // Vuelve al modelo del dictado ahora que la reunión soltó el
            // suyo — barato cuando los dos son el mismo (herencia, el caso
            // más común: `initiate_model_load` no hace nada si ya es el
            // cargado) y necesario cuando la reunión usó uno propio: sin
            // esto, el próximo dictado corría sobre el modelo de la
            // reunión hasta la siguiente carga explícita. No bloqueante,
            // igual que el resto de esta función.
            tm.initiate_model_load();
        }
        if let Some(app) = &self.app_handle {
            crate::tray::set_meeting_recording(app, false);
        }

        if let Some(arbiter) = &self.mic_arbiter {
            arbiter.release(MicOwner::Meeting);
        }

        info!(
            "Meeting {} capture stopped after {:?}",
            session.meeting_id,
            session.capture_started.elapsed()
        );
        Ok(())
    }

    fn init_database(&self) -> Result<()> {
        info!("Initializing meeting database at {:?}", self.db_path);

        let mut conn = Connection::open(&self.db_path)?;

        let migrations = Migrations::new(MIGRATIONS.to_vec());

        #[cfg(debug_assertions)]
        migrations.validate().expect("Invalid meeting migrations");

        let version_before: i32 =
            conn.pragma_query_value(None, "user_version", |row| row.get(0))?;
        debug!(
            "Meeting database version before migration: {}",
            version_before
        );

        migrations.to_latest(&mut conn)?;

        let version_after: i32 = conn.pragma_query_value(None, "user_version", |row| row.get(0))?;

        if version_after > version_before {
            info!(
                "Meeting database migrated from version {} to {}",
                version_before, version_after
            );
        } else {
            debug!(
                "Meeting database already at latest version {}",
                version_after
            );
        }

        Ok(())
    }

    /// Open a new connection to the meeting database. Mirrors
    /// `HistoryManager::get_connection`: the manager does not keep a
    /// persistent connection in the struct, so each operation opens its own
    /// short-lived connection against `db_path`.
    fn get_connection(&self) -> Result<Connection> {
        Ok(Connection::open(&self.db_path)?)
    }

    /// Start a new meeting: inserts a `meetings` row with `status =
    /// "recording"` and returns its `id`. This is the only business logic
    /// behind the `start_meeting` Tauri command (T011) — it does not touch
    /// the microphone or any recording pipeline, that's T012's job.
    ///
    /// Fails with `"recording_busy"` if another meeting already has
    /// `status = 'recording'` (contract: `specs/001-meeting-notetaker/
    /// contracts/tauri-commands.md#start_meeting`). The check-then-insert
    /// runs inside a single `IMMEDIATE` transaction so two overlapping
    /// calls can't both observe "no meeting recording" and both insert.
    ///
    /// `title` defaults to a timestamp derived from the current local time
    /// (e.g. "Reunión 28/07 10:30"); the user can rename it later via the
    /// future `rename_meeting` command.
    pub fn start_meeting(&self, kind: &str) -> Result<i64> {
        let mut conn = self.get_connection()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;

        let already_recording: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM meetings WHERE status = 'recording')",
            [],
            |row| row.get(0),
        )?;
        if already_recording {
            bail!("recording_busy");
        }

        let started_at = Utc::now().timestamp();
        let title = format!("Reunión {}", Local::now().format("%d/%m %H:%M"));

        tx.execute(
            "INSERT INTO meetings (title, kind, started_at, status) VALUES (?1, ?2, ?3, 'recording')",
            params![title, kind, started_at],
        )?;
        let id = tx.last_insert_rowid();
        tx.commit()?;

        info!("Started meeting {} (kind={})", id, kind);
        Ok(id)
    }

    /// Cierra la grabación de una reunión: `recording → processing`, con
    /// `ended_at` puesto (a partir de acá la validación de `data-model.md`
    /// exige que no sea NULL). Sólo mueve el estado — detener el micrófono y
    /// terminar el post-proceso son pasos separados, ver
    /// [`Self::finalize_meeting`] y el comando `stop_meeting`.
    ///
    /// Falla con `"meeting_not_recording"` si la reunión no existe o no está
    /// grabando, para que un doble click en "detener" no arrastre una reunión
    /// ya terminada de vuelta a `processing`. El chequeo y el update van en
    /// una sola transacción `IMMEDIATE`, misma razón que en
    /// [`Self::start_meeting`].
    pub fn stop_meeting(&self, meeting_id: i64) -> Result<()> {
        let mut conn = self.get_connection()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;

        let updated = tx.execute(
            "UPDATE meetings SET status = 'processing', ended_at = ?2 \
             WHERE id = ?1 AND status = 'recording'",
            params![meeting_id, Utc::now().timestamp()],
        )?;
        if updated == 0 {
            bail!("meeting_not_recording");
        }
        tx.commit()?;

        // Los turnos que quedaron en la cola se siguen transcribiendo
        // mientras el estado ya es `processing` — el evento lo dice tal cual
        // en vez de anunciar una fase que todavía no corre.
        if let Some(app) = &self.app_handle {
            let progress = MeetingProgress {
                meeting_id,
                phase: MeetingProgressPhase::Transcribing,
            };
            if let Err(e) = progress.emit(app) {
                warn!("Failed to emit meeting-progress for {}: {}", meeting_id, e);
            }
        }

        info!("Meeting {} stopped: recording -> processing", meeting_id);
        Ok(())
    }

    /// Termina el post-proceso de una reunión: `processing → ready` y evento
    /// `meeting-finished`.
    ///
    /// **Alcance deliberado (Principio VI, no es un atajo silencioso)**: hoy
    /// el post-proceso de la Historia 1 no tiene ningún paso propio — cuando
    /// `stop_capture` terminó de drenar la cola, el transcript diarizado ya
    /// está completo y persistido. La generación de resumen y pendientes es
    /// T037 (Historia 4) y se engancha exactamente acá, antes de marcar
    /// `ready`: emitir `MeetingProgressPhase::Summarizing`, generar con
    /// `llm_client.rs`, guardar `summary` + `meeting_action_items`.
    ///
    /// Hasta entonces una reunión llega a `ready` con `summary = NULL`, que
    /// significa "transcript listo, sin resumen todavía" — no "resumen
    /// vacío". Dejarla clavada en `processing` para siempre habría sido peor:
    /// rompe el checkpoint de la Historia 1 (que es testeable de forma
    /// independiente sin resumen, ver `quickstart.md` Escenario 1) y le
    /// miente al usuario sobre que algo está corriendo.
    pub fn finalize_meeting(&self, meeting_id: i64) -> Result<()> {
        let conn = self.get_connection()?;
        let updated = conn.execute(
            "UPDATE meetings SET status = 'ready' WHERE id = ?1 AND status = 'processing'",
            params![meeting_id],
        )?;
        if updated == 0 {
            bail!("meeting_not_processing");
        }

        if let Some(app) = &self.app_handle {
            if let Err(e) = (MeetingFinished { meeting_id }).emit(app) {
                warn!("Failed to emit meeting-finished for {}: {}", meeting_id, e);
            }
        }

        info!("Meeting {} finished: processing -> ready", meeting_id);
        Ok(())
    }

    /// Reporta un error de post-proceso al frontend (`meeting-error`). La
    /// reunión queda en `processing`: el transcript ya persistido no se
    /// pierde (FR-007) y un reintento futuro puede retomarla desde ahí.
    fn report_meeting_error(&self, meeting_id: i64, error: String) {
        error!("Meeting {}: {}", meeting_id, error);
        if let Some(app) = &self.app_handle {
            let payload = MeetingError { meeting_id, error };
            if let Err(e) = payload.emit(app) {
                warn!("Failed to emit meeting-error for {}: {}", meeting_id, e);
            }
        }
    }

    /// Recuperación ante interrupción (FR-008): al arrancar la app, marca
    /// como `interrupted` toda reunión que quedó a medio camino y emite
    /// `meeting-interrupted` por cada una. Devuelve los ids recuperados.
    ///
    /// **Barre dos estados, no uno.** El obvio es `recording`: la app murió
    /// grabando. El otro es `processing`, que existe desde que
    /// [`Self::stop_meeting`] devuelve antes de terminar de drenar la cola —
    /// si el proceso muere en esa ventana, la reunión queda para siempre
    /// "procesando" y ningún otro camino la toca. Sin este barrido, apretar
    /// detener y que se caiga la app dejaba una reunión zombi.
    ///
    /// **Por qué `interrupted` y no `ready` para las de `processing`.** El
    /// transcript de una reunión que se cayó drenando puede estar completo o
    /// puede faltarle los últimos turnos que quedaron en la cola (ese audio
    /// vivía en memoria y se fue con el proceso) — y desde acá **no hay forma
    /// de distinguir un caso del otro**. Marcarla `ready` afirmaría una
    /// completitud que no podemos verificar; `interrupted` dice lo que
    /// realmente sabemos: esto quedó a medias. Cuando exista T037 (resumen),
    /// vale reconsiderarlo: ahí una reunión en `processing` podría retomar el
    /// post-proceso en vez de darse por interrumpida.
    ///
    /// **`ended_at` sale del transcript, no del reloj.** La reunión terminó
    /// cuando murió el proceso, no cuando el usuario reabrió la app días
    /// después. El último `ended_at_ms` de sus segmentos, sumado a
    /// `started_at`, es la mejor aproximación disponible; sin segmentos, la
    /// reunión duró efectivamente cero. Las de `processing` ya lo tienen
    /// sellado por `stop_meeting` y no se pisa.
    pub fn recover_interrupted_meetings(&self) -> Result<Vec<i64>> {
        let conn = self.get_connection()?;

        let pending: Vec<(i64, i64)> = {
            let mut stmt = conn.prepare(
                "SELECT id, started_at FROM meetings \
                 WHERE status IN ('recording', 'processing')",
            )?;
            let rows = stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?;
            rows.collect::<rusqlite::Result<Vec<_>>>()?
        };

        let mut recovered = Vec::new();
        for (meeting_id, started_at) in pending {
            let last_segment_ms: Option<i64> = conn.query_row(
                "SELECT MAX(ended_at_ms) FROM meeting_segments WHERE meeting_id = ?1",
                params![meeting_id],
                |row| row.get(0),
            )?;
            let derived_ended_at = started_at + last_segment_ms.unwrap_or(0) / 1000;

            conn.execute(
                "UPDATE meetings SET status = 'interrupted', \
                 ended_at = COALESCE(ended_at, ?2) WHERE id = ?1",
                params![meeting_id, derived_ended_at],
            )?;

            warn!(
                "Reunión {} quedó a medias en una sesión anterior: marcada como interrumpida",
                meeting_id
            );
            recovered.push(meeting_id);

            if let Some(app) = &self.app_handle {
                if let Err(e) = (MeetingInterrupted { meeting_id }).emit(app) {
                    warn!(
                        "Failed to emit meeting-interrupted for {}: {}",
                        meeting_id, e
                    );
                }
            }
        }

        Ok(recovered)
    }

    /// Borra una reunión que nunca llegó a grabar nada. Sólo para el camino
    /// de error de `start_meeting`: si abrir el micrófono falla, la fila
    /// recién creada no representa ninguna grabación, y dejarla ahí
    /// bloquearía la siguiente reunión con `recording_busy` además de
    /// ensuciar el listado con una reunión vacía.
    ///
    /// Deliberadamente **no** borra segmentos ni hablantes: si llegó a
    /// existir aunque sea uno, esto no es el caso de uso correcto y hay que
    /// cerrar la reunión por el camino normal (`stop_meeting`). Por eso el
    /// DELETE exige que no haya segmentos.
    pub fn discard_meeting(&self, meeting_id: i64) {
        let conn = match self.get_connection() {
            Ok(c) => c,
            Err(e) => {
                warn!("No se pudo descartar la reunión {}: {}", meeting_id, e);
                return;
            }
        };

        let result = conn.execute(
            "DELETE FROM meetings WHERE id = ?1 AND status = 'recording' \
             AND NOT EXISTS (SELECT 1 FROM meeting_segments WHERE meeting_id = ?1)",
            params![meeting_id],
        );
        match result {
            Ok(1) => info!("Reunión {} descartada: nunca llegó a grabar", meeting_id),
            Ok(_) => warn!(
                "Reunión {} no se descartó: ya tenía contenido o no estaba grabando",
                meeting_id
            ),
            Err(e) => warn!("No se pudo descartar la reunión {}: {}", meeting_id, e),
        }
    }

    /// Nombre que el usuario le pone a un hablante detectado (FR-005). Un
    /// nombre vacío (o sólo espacios) **borra** el nombre y deja la etiqueta
    /// automática `Hablante N` — es la forma natural de deshacer, sin
    /// necesitar un comando aparte.
    ///
    /// Falla con `"speaker_merged"` si el hablante fue fusionado dentro de
    /// otro: renombrarlo no tendría efecto visible (todo lo suyo se muestra
    /// bajo el destino), así que es mejor un error claro que un cambio que el
    /// usuario no ve. La UI debe ofrecer renombrar el destino.
    pub fn assign_speaker_name(&self, speaker_id: i64, display_name: &str) -> Result<()> {
        let conn = self.get_connection()?;

        let merged_into: Option<i64> = conn
            .query_row(
                "SELECT merged_into_id FROM meeting_speakers WHERE id = ?1",
                params![speaker_id],
                |row| row.get(0),
            )
            .optional()?
            .ok_or_else(|| anyhow::anyhow!("speaker_not_found"))?;
        if merged_into.is_some() {
            bail!("speaker_merged");
        }

        let trimmed = display_name.trim();
        let value = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed)
        };
        conn.execute(
            "UPDATE meeting_speakers SET display_name = ?2 WHERE id = ?1",
            params![speaker_id, value],
        )?;

        Ok(())
    }

    /// Fusiona dos identificadores de hablante que el sistema separó de más
    /// (FR-005): `source` pasa a apuntar a `target` vía `merged_into_id`.
    ///
    /// **Los segmentos NO se repuntan.** `data-model.md` define que los
    /// segmentos que apuntan a un hablante fusionado "se resuelven al
    /// destino" al leerlos, y eso tiene dos ventajas concretas sobre reescribir
    /// `meeting_segments.speaker_id`: (1) la fusión es un dato reversible en
    /// vez de una migración destructiva sobre el transcript, y (2) si la
    /// reunión sigue grabando, el mapa de hablantes locales en memoria
    /// (`TranscriptState::local_speakers`, ver el hilo diarizador de
    /// `start_capture`) sigue apuntando el mismo índice local de Sortformer
    /// al mismo `speaker_id` de antes de la fusión, y va a seguir
    /// atribuyéndole intervenciones nuevas — que se resuelven solas al
    /// destino, sin que la fusión tenga que comunicarse con el hilo
    /// diarizador.
    ///
    /// Detalles de integridad:
    ///
    /// - Ambos hablantes deben pertenecer a `meeting_id` (`speaker_not_in_meeting`):
    ///   un hablante es local a una reunión, fusionar entre reuniones no
    ///   significa nada.
    /// - Fusionar algo consigo mismo falla (`cannot_merge_into_itself`).
    /// - Si `target` ya está fusionado, se usa su destino final: las cadenas
    ///   se comprimen a profundidad 1 (acá y en los que ya apuntaban a
    ///   `source`), así ninguna lectura futura tiene que caminar una cadena
    ///   larga.
    /// - Un ciclo se rechaza (`merge_would_create_a_cycle`) en vez de dejar la
    ///   base en un estado donde resolver un hablante nunca termina.
    /// - Si el destino no tiene nombre y el origen sí, el nombre se lleva al
    ///   destino: el usuario ya se tomó el trabajo de nombrar a esa persona y
    ///   perder el nombre por fusionar "en la dirección equivocada" sería
    ///   hostil.
    pub fn merge_speakers(
        &self,
        meeting_id: i64,
        source_speaker_id: i64,
        target_speaker_id: i64,
    ) -> Result<()> {
        if source_speaker_id == target_speaker_id {
            bail!("cannot_merge_into_itself");
        }

        let mut conn = self.get_connection()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;

        for id in [source_speaker_id, target_speaker_id] {
            let belongs: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM meeting_speakers WHERE id = ?1 AND meeting_id = ?2)",
                params![id, meeting_id],
                |row| row.get(0),
            )?;
            if !belongs {
                bail!("speaker_not_in_meeting");
            }
        }

        let final_target = resolve_speaker(&tx, target_speaker_id)?;
        if final_target == source_speaker_id {
            bail!("merge_would_create_a_cycle");
        }

        tx.execute(
            "UPDATE meeting_speakers SET merged_into_id = ?2 WHERE id = ?1",
            params![source_speaker_id, final_target],
        )?;
        // Compresión de cadenas: quienes ya apuntaban al origen pasan a
        // apuntar directo al destino final.
        tx.execute(
            "UPDATE meeting_speakers SET merged_into_id = ?2 WHERE merged_into_id = ?1",
            params![source_speaker_id, final_target],
        )?;

        let source_name: Option<String> = tx.query_row(
            "SELECT display_name FROM meeting_speakers WHERE id = ?1",
            params![source_speaker_id],
            |row| row.get(0),
        )?;
        let target_name: Option<String> = tx.query_row(
            "SELECT display_name FROM meeting_speakers WHERE id = ?1",
            params![final_target],
            |row| row.get(0),
        )?;
        if target_name.is_none() {
            if let Some(name) = source_name {
                tx.execute(
                    "UPDATE meeting_speakers SET display_name = ?2 WHERE id = ?1",
                    params![final_target, name],
                )?;
            }
        }

        tx.commit()?;
        info!(
            "Meeting {}: hablante {} fusionado en {}",
            meeting_id, source_speaker_id, final_target
        );
        Ok(())
    }

    /// Listado paginado de reuniones para el hub (T035, Historia 4), de más
    /// reciente a más antigua. Sólo trae `MeetingSummary` — ver la nota de
    /// alcance de la sección T035 sobre por qué no carga segmentos/hablantes
    /// acá.
    ///
    /// `limit` se acota a `[1, 200]` (mismo espíritu que el `.min(100)` de
    /// `HistoryManager::get_history_entries`: un límite sin techo es una
    /// forma fácil de que un bug de la UI pida "todas las reuniones" de
    /// golpe) y `offset` a `>= 0`. `has_more` sale de pedir una fila de más:
    /// si vuelven `limit + 1` filas, sobra al menos una más allá de esta
    /// página.
    ///
    /// Empatar por `started_at DESC` solo no alcanza: dos reuniones creadas
    /// dentro del mismo segundo (`started_at` es un timestamp Unix en
    /// segundos) quedarían en un orden indefinido de una llamada a la
    /// siguiente. `id DESC` como desempate hace el orden determinista y
    /// coincide con "más reciente primero" porque el id es autoincremental.
    pub fn list_meetings(&self, limit: i64, offset: i64) -> Result<PaginatedMeetings> {
        let limit = limit.clamp(1, 200);
        let offset = offset.max(0);
        let conn = self.get_connection()?;

        let mut stmt = conn.prepare(
            "SELECT id, title, kind, started_at, ended_at, status FROM meetings \
             ORDER BY started_at DESC, id DESC LIMIT ?1 OFFSET ?2",
        )?;
        let mut meetings: Vec<MeetingSummary> = stmt
            .query_map(params![limit + 1, offset], |row| {
                Ok(MeetingSummary {
                    id: row.get(0)?,
                    title: row.get(1)?,
                    kind: row.get(2)?,
                    started_at: row.get(3)?,
                    ended_at: row.get(4)?,
                    status: row.get(5)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;

        let has_more = meetings.len() as i64 > limit;
        if has_more {
            meetings.pop();
        }

        Ok(PaginatedMeetings { meetings, has_more })
    }

    /// Reunión completa para leerla (T035, Historia 4): sus datos, su
    /// transcript en orden cronológico y sus hablantes vigentes.
    ///
    /// **Lo crítico acá es la resolución de hablantes fusionados**
    /// (`data-model.md`: "segmentos apuntando a un hablante fusionado se
    /// resuelven al destino" — ver también el doc comment de
    /// [`merge_speakers`] sobre por qué los segmentos no se repuntan al
    /// fusionar). Esta función es la lectura que cumple esa promesa:
    ///
    /// - Cada segmento con `speaker_id` se pasa por [`resolve_speaker`], que
    ///   sigue la cadena `merged_into_id` hasta el destino final. Un segmento
    ///   `speaker_id = NULL` (incierto, FR-004) se deja tal cual — resolver
    ///   `None` no tiene sentido y romperlo sería peor que dejarlo incierto.
    /// - La lista de hablantes filtra `merged_into_id IS NOT NULL`: el
    ///   usuario fusionó esas voces a propósito para dejar de verlas como
    ///   personas separadas, así que no deben reaparecer en la lista aunque
    ///   sigan existiendo como filas (la fusión es reversible, no destructiva).
    ///
    /// Falla con `"meeting_not_found"` en vez de entrar en pánico cuando el
    /// id no existe — un id vencido (reunión borrada, o un link viejo) es un
    /// caso esperable, no un bug.
    pub fn get_meeting(&self, meeting_id: i64) -> Result<Meeting> {
        let conn = self.get_connection()?;

        let (title, kind, started_at, ended_at, status, summary): (
            String,
            String,
            i64,
            Option<i64>,
            String,
            Option<String>,
        ) = conn
            .query_row(
                "SELECT title, kind, started_at, ended_at, status, summary \
                 FROM meetings WHERE id = ?1",
                params![meeting_id],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get(5)?,
                    ))
                },
            )
            .optional()?
            .ok_or_else(|| anyhow::anyhow!("meeting_not_found"))?;

        let raw_segments: Vec<(i64, Option<i64>, String, i64, i64, bool)> = {
            let mut stmt = conn.prepare(
                "SELECT id, speaker_id, text, started_at_ms, ended_at_ms, overlapped \
                 FROM meeting_segments WHERE meeting_id = ?1 \
                 ORDER BY started_at_ms ASC, id ASC",
            )?;
            let rows = stmt
                .query_map(params![meeting_id], |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get(5)?,
                    ))
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            rows
        };

        let mut segments = Vec::with_capacity(raw_segments.len());
        for (id, speaker_id, text, started_at_ms, ended_at_ms, overlapped) in raw_segments {
            let resolved_speaker_id = match speaker_id {
                Some(raw_id) => Some(resolve_speaker(&conn, raw_id)?),
                None => None,
            };
            segments.push(MeetingSegment {
                id,
                speaker_id: resolved_speaker_id,
                text,
                started_at_ms,
                ended_at_ms,
                overlapped,
            });
        }

        let speakers: Vec<MeetingSpeaker> = {
            let mut stmt = conn.prepare(
                "SELECT id, label, display_name FROM meeting_speakers \
                 WHERE meeting_id = ?1 AND merged_into_id IS NULL \
                 ORDER BY id ASC",
            )?;
            let rows = stmt
                .query_map(params![meeting_id], |row| {
                    Ok(MeetingSpeaker {
                        id: row.get(0)?,
                        label: row.get(1)?,
                        display_name: row.get(2)?,
                    })
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            rows
        };

        Ok(Meeting {
            id: meeting_id,
            title,
            kind,
            started_at,
            ended_at,
            status,
            summary,
            segments,
            speakers,
        })
    }

    /// Secuencia completa de detención, pensada para correr fuera del hilo
    /// del comando: detiene la captura (bloquea hasta que el hilo
    /// transcriptor drena y persiste los turnos en cola — puede tardar
    /// segundos) y recién ahí marca la reunión como lista.
    ///
    /// Que no haya captura activa NO es un error acá: la reunión pudo
    /// haberse creado sin abrir el micrófono (o el proceso pudo perderla), y
    /// el estado igual tiene que poder cerrarse.
    /// Segunda mitad de detener una reunión, para correr fuera del hilo del
    /// comando. `transition_ok` dice si la fila llegó a `processing`.
    ///
    /// **El micrófono se suelta en los dos casos.** Cuando la transición
    /// falla (la reunión no estaba `recording`: recuperada como
    /// `interrupted`, ya detenida) la captura puede seguir abierta igual, y
    /// dejarla tomada significa el micrófono ocupado y el dictado bloqueado
    /// hasta reiniciar la app. Lo que sí se saltea es `finalize_meeting`:
    /// marcar `ready` una reunión que nunca pasó por `processing` sería
    /// mentir sobre su estado, y sólo generaría un `meeting-error` de más.
    pub fn finish_stop(&self, meeting_id: i64, transition_ok: bool) {
        if transition_ok {
            self.drain_and_finalize(meeting_id);
            return;
        }

        if let Err(e) = self.stop_capture(meeting_id) {
            debug!(
                "Meeting {}: no había captura activa que soltar tras una detención fallida ({})",
                meeting_id, e
            );
        }
    }

    pub fn drain_and_finalize(&self, meeting_id: i64) {
        if let Err(e) = self.stop_capture(meeting_id) {
            debug!(
                "Meeting {}: no había captura activa que detener ({})",
                meeting_id, e
            );
        }

        if let Err(e) = self.finalize_meeting(meeting_id) {
            self.report_meeting_error(meeting_id, format!("no se pudo cerrar la reunión: {e}"));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `None` con runtime explícito: `persist_and_emit_run`/`report_*` son
    /// genéricas sobre el runtime de Tauri (ver sus doc comments), así que
    /// los tests que no verifican la emisión tienen que decir de qué
    /// runtime hablan.
    const NO_APP: Option<&AppHandle> = None;

    // ---------- resolve_meeting_audio_source (cableado de audio) ----------

    #[test]
    fn reunion_virtual_resuelve_audio_de_sistema_cuando_esta_disponible() {
        assert_eq!(
            resolve_meeting_audio_source(MeetingKind::Virtual, true),
            MeetingAudioSource::SystemAudio
        );
    }

    #[test]
    fn reunion_virtual_degrada_a_microfono_sin_audio_de_sistema_disponible() {
        assert_eq!(
            resolve_meeting_audio_source(MeetingKind::Virtual, false),
            MeetingAudioSource::Microphone
        );
    }

    #[test]
    fn reunion_presencial_usa_microfono_aunque_el_audio_de_sistema_este_disponible() {
        // El mandato del dueño es explícito: el micrófono es sólo para
        // presencial, nunca al revés — una reunión presencial no debe poder
        // terminar grabando con audio del sistema sólo porque la máquina lo
        // soporta.
        assert_eq!(
            resolve_meeting_audio_source(MeetingKind::Presencial, true),
            MeetingAudioSource::Microphone
        );
    }

    #[test]
    fn reunion_presencial_usa_microfono_sin_audio_de_sistema_disponible() {
        assert_eq!(
            resolve_meeting_audio_source(MeetingKind::Presencial, false),
            MeetingAudioSource::Microphone
        );
    }

    // ---------- resolve_meeting_model_id (modelo propio de reuniones) -----

    #[test]
    fn sin_modelo_propio_hereda_el_del_dictado() {
        assert_eq!(
            resolve_meeting_model_id(None, "whisper-large-v3-turbo"),
            "whisper-large-v3-turbo"
        );
    }

    #[test]
    fn un_modelo_propio_gana_sobre_el_del_dictado() {
        assert_eq!(
            resolve_meeting_model_id(Some("parakeet-tdt-0.6b-v3"), "whisper-small"),
            "parakeet-tdt-0.6b-v3"
        );
    }

    #[test]
    fn vacio_o_solo_espacios_cuenta_como_sin_elegir_y_hereda() {
        // Un `settings.json` tocado a mano con `"meeting_model_id": ""` (o
        // `"   "`) no debe dejar la reunión sin modelo — hereda igual que
        // `None`.
        assert_eq!(
            resolve_meeting_model_id(Some(""), "whisper-small"),
            "whisper-small"
        );
        assert_eq!(
            resolve_meeting_model_id(Some("   "), "whisper-small"),
            "whisper-small"
        );
    }

    #[test]
    fn el_mismo_modelo_elegido_a_mano_que_el_del_dictado_no_es_un_caso_especial() {
        // Documenta el "barato cuando coinciden" del comentario de
        // `TranscriptionManager::initiate_model_load_id`: si el usuario elige
        // a mano el mismo modelo que ya usa el dictado, esta función no
        // necesita saberlo — simplemente devuelve ese id, e
        // `initiate_model_load_id` es quien no hace ningún trabajo de más
        // porque el id resuelto ya coincide con el cargado.
        assert_eq!(
            resolve_meeting_model_id(Some("whisper-small"), "whisper-small"),
            "whisper-small"
        );
    }

    #[test]
    fn meeting_kind_parsea_los_dos_valores_validos() {
        assert_eq!(
            MeetingKind::parse("presencial"),
            Some(MeetingKind::Presencial)
        );
        assert_eq!(MeetingKind::parse("virtual"), Some(MeetingKind::Virtual));
    }

    #[test]
    fn meeting_kind_rechaza_cualquier_otro_texto() {
        assert_eq!(MeetingKind::parse(""), None);
        assert_eq!(MeetingKind::parse("Presencial"), None);
        assert_eq!(MeetingKind::parse("online"), None);
    }

    /// Unique temp db path for a test (mirrors the inline pattern the
    /// existing T007 tests below already use, factored out so the new
    /// `start_meeting` tests don't duplicate it a third/fourth time).
    fn temp_db_path(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "dilo-meeting-test-{}-{}-{}.db",
            label,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    /// Inserta directamente una fila en `meeting_segments`, sin pasar por
    /// ningún motor de reconocimiento ni diarización — reemplaza los usos
    /// de `CompletedTurn`/`persist_and_emit_segment` que sólo necesitaban
    /// dejar un segmento ya guardado como fixture para un test de otra
    /// cosa (recuperación, fusión de hablantes, listado...). La cobertura
    /// de la persistencia en sí vive en los tests de `persist_and_emit_run`
    /// de más arriba.
    fn insert_test_segment(
        conn: &Connection,
        meeting_id: i64,
        speaker_id: Option<i64>,
        text: &str,
        started_at_ms: i64,
        ended_at_ms: i64,
    ) -> i64 {
        conn.execute(
            "INSERT INTO meeting_segments (meeting_id, speaker_id, text, started_at_ms, ended_at_ms, overlapped) \
             VALUES (?1, ?2, ?3, ?4, ?5, 0)",
            params![meeting_id, speaker_id, text, started_at_ms, ended_at_ms],
        )
        .expect("insert_test_segment");
        conn.last_insert_rowid()
    }

    fn apply_migrations(conn: &mut Connection) {
        let migrations = Migrations::new(MIGRATIONS.to_vec());
        migrations.validate().expect("migrations should be valid");
        migrations
            .to_latest(conn)
            .expect("migrations should apply cleanly");
    }

    fn table_exists(conn: &Connection, table: &str) -> bool {
        conn.query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
            [table],
            |row| row.get::<_, i64>(0),
        )
        .expect("query sqlite_master")
            == 1
    }

    #[test]
    fn migrations_apply_cleanly_on_in_memory_db() {
        let mut conn = Connection::open_in_memory().expect("open in-memory db");
        apply_migrations(&mut conn);
    }

    #[test]
    fn migrations_create_all_meeting_tables() {
        let mut conn = Connection::open_in_memory().expect("open in-memory db");
        apply_migrations(&mut conn);

        for table in MEETING_TABLES {
            assert!(
                table_exists(&conn, table),
                "expected table {} to exist",
                table
            );
        }
    }

    #[test]
    fn migrations_are_idempotent_when_applied_twice() {
        let mut conn = Connection::open_in_memory().expect("open in-memory db");
        apply_migrations(&mut conn);
        // Applying to_latest again on an already-migrated connection should
        // be a no-op, not an error (mirrors real app restarts).
        let migrations = Migrations::new(MIGRATIONS.to_vec());
        migrations
            .to_latest(&mut conn)
            .expect("re-applying migrations should be a no-op");
    }

    #[test]
    fn empty_select_against_each_table_succeeds() {
        let mut conn = Connection::open_in_memory().expect("open in-memory db");
        apply_migrations(&mut conn);

        for table in MEETING_TABLES {
            let mut stmt = conn
                .prepare(&format!("SELECT * FROM {}", table))
                .unwrap_or_else(|e| panic!("failed to prepare SELECT against {}: {}", table, e));
            let _rows = stmt
                .query([])
                .unwrap_or_else(|e| panic!("SELECT against {} failed: {}", table, e));
        }
    }

    #[test]
    fn meeting_manager_new_applies_migrations_to_file_db() {
        let dir = std::env::temp_dir().join(format!(
            "dilo-meeting-test-{}-{}.db",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));

        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new should succeed");

        let conn = Connection::open(&dir).expect("open the db file MeetingManager created");
        for table in MEETING_TABLES {
            assert!(
                table_exists(&conn, table),
                "expected table {} to exist",
                table
            );
        }

        drop(manager);
        drop(conn);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn get_connection_returns_a_valid_connection_against_migrated_db() {
        let dir = std::env::temp_dir().join(format!(
            "dilo-meeting-test-get-connection-{}-{}.db",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));

        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new should succeed");

        let conn = manager
            .get_connection()
            .expect("get_connection should open a connection");
        for table in MEETING_TABLES {
            assert!(
                table_exists(&conn, table),
                "expected table {} to be visible via get_connection",
                table
            );
        }

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn start_meeting_inserts_a_recording_row_with_expected_fields() {
        let dir = temp_db_path("start-meeting-basic");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new should succeed");

        let before = Utc::now().timestamp();
        let id = manager
            .start_meeting("presencial")
            .expect("start_meeting should succeed");
        let after = Utc::now().timestamp();

        let conn = manager.get_connection().expect("get_connection");
        let (title, kind, started_at, ended_at, status): (
            String,
            String,
            i64,
            Option<i64>,
            String,
        ) = conn
            .query_row(
                "SELECT title, kind, started_at, ended_at, status FROM meetings WHERE id = ?1",
                [id],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                    ))
                },
            )
            .expect("the inserted row should be readable back");

        assert_eq!(kind, "presencial");
        assert_eq!(status, "recording");
        assert!(
            ended_at.is_none(),
            "ended_at must be NULL while status = recording"
        );
        assert!(
            (before..=after).contains(&started_at),
            "started_at ({started_at}) should fall within [{before}, {after}]"
        );
        assert!(
            title.starts_with("Reunión "),
            "unexpected default title: {title:?}"
        );

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn start_meeting_fails_when_a_meeting_is_already_recording() {
        let dir = temp_db_path("start-meeting-conflict");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new should succeed");

        manager
            .start_meeting("presencial")
            .expect("the first start_meeting should succeed");

        let second = manager.start_meeting("presencial");
        assert!(
            second.is_err(),
            "a second start_meeting should fail while the first meeting is still recording"
        );
        assert_eq!(second.unwrap_err().to_string(), "recording_busy");

        let conn = manager.get_connection().expect("get_connection");
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM meetings", [], |row| row.get(0))
            .expect("count meetings");
        assert_eq!(count, 1, "the rejected second call must not insert a row");

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    // ------------------------------------------------------------------
    // 2026-08-04: has_energy/rms_energy — the energy gate that replaced the
    // neural VAD in the meeting path. Pure, deterministic, no model needed
    // (this is exactly the kind of thing the neural VAD couldn't offer:
    // testable without loading 16MB of ONNX). Synthetic sine waves at
    // chosen amplitudes stand in for "digital silence", "low background
    // noise floor", and "speech/music" — see `ENERGY_GATE_RMS`'s doc
    // comment for the dBFS reasoning behind the thresholds picked below.
    // ------------------------------------------------------------------

    /// A synthetic tone at `amplitude`, used to stand in for either speech,
    /// music, or (at a tiny amplitude) a quiet noise floor — real recorded
    /// audio isn't available in this environment, but RMS only cares about
    /// amplitude, not waveform shape, so a sine at the right level is a
    /// faithful stand-in for what `has_energy` actually measures.
    fn tone(amplitude: f32, n: usize) -> Vec<f32> {
        (0..n)
            .map(|i| amplitude * ((i as f32) * 0.3).sin())
            .collect()
    }

    #[test]
    fn has_energy_rejects_exact_digital_silence() {
        // The exact symptom `has_nonzero_sample` was built to catch
        // (recording without the system-audio permission granted): every
        // sample is precisely 0.0.
        assert!(!has_energy(&vec![0.0; 480]));
    }

    #[test]
    fn has_energy_rejects_empty_buffer() {
        assert!(!has_energy(&[]));
    }

    #[test]
    fn has_energy_rejects_low_background_noise_floor() {
        // ~0.0007 RMS (amplitude 0.001) — well under a typical mic/system
        // noise floor's -50dBFS, several orders of magnitude under
        // ENERGY_GATE_RMS (~-46dBFS). This is the case the task explicitly
        // calls out: a low noise floor must not gate a transcription.
        let quiet = tone(0.001, 480);
        assert!(
            !has_energy(&quiet),
            "a quiet noise floor must stay below the gate"
        );
    }

    #[test]
    fn has_energy_accepts_conversational_speech_level_signal() {
        // amplitude 0.1 -> RMS ~0.0707, comfortably inside typical
        // conversational-recording levels (-25 to -15dBFS-ish) and well
        // above ENERGY_GATE_RMS.
        let speech = tone(0.1, 480);
        assert!(has_energy(&speech));
    }

    #[test]
    fn has_energy_accepts_music_like_mixed_signal() {
        // Two mixed frequencies at moderate amplitude, standing in for
        // music or system audio mixed with voice — the case the neural VAD
        // was measured dropping the most of (up to 79% of a real meeting's
        // audio, see the module doc comment).
        let music: Vec<f32> = (0..480)
            .map(|i| 0.08 * ((i as f32) * 0.3).sin() + 0.05 * ((i as f32) * 0.9).sin())
            .collect();
        assert!(has_energy(&music));
    }

    #[test]
    fn has_energy_threshold_boundary_is_inclusive() {
        // A flat signal at exactly ENERGY_GATE_RMS has RMS == ENERGY_GATE_RMS
        // (RMS of a constant signal is its own absolute value) — pins `>=`
        // over `>` at the boundary.
        let boundary = vec![ENERGY_GATE_RMS; 10];
        assert!(has_energy(&boundary));
    }

    #[test]
    fn rms_energy_of_full_scale_square_wave_is_one() {
        // A signal pinned at +/-1.0 the whole way has RMS exactly 1.0 —
        // the simplest possible non-degenerate check on the formula itself,
        // independent of the gate threshold.
        assert!((rms_energy(&[1.0, -1.0, 1.0, -1.0]) - 1.0).abs() < 1e-6);
    }

    // ------------------------------------------------------------------
    // Fix round 1 (revisión de esta tarea): esta cobertura se había
    // borrado enterita junto con `TurnAccumulator`/la vieja
    // `persist_and_emit_segment`, pero medía algo que sigue vivo y que
    // Important 4 volvió a depender de nuevo: que el umbral RMS de
    // `has_energy` distingue voz real de una pausa real en una grabación
    // real, no sintética — desde el fix round 1, esa distinción decide qué
    // le llega al ASR (la diarización ya recibe todo). Recortada a lo que
    // sigue existiendo: ya no arma turnos ni persiste nada, corre la
    // compuerta sobre audio real y reconstruye el reloj de pared con
    // `AudioToWallClock`, la misma máquina que usa `audio_cb`.
    //
    // Requiere red (descarga el mismo wav de prueba de siempre, ~1.8MB) —
    // `#[ignore]`, mismo criterio que el resto de los tests end-to-end de
    // este archivo. Correr a mano con:
    //   cargo test --lib managers::meeting::tests::has_energy_distingue_voz_de_pausas_reales_en_grabacion_real -- --ignored
    // ------------------------------------------------------------------
    #[tokio::test]
    #[ignore = "requiere red: descarga un wav de prueba real"]
    async fn has_energy_distingue_voz_de_pausas_reales_en_grabacion_real() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let wav_path = tmp.path().join("0-four-speakers-zh.wav");
        let wav_bytes = reqwest::get(
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/0-four-speakers-zh.wav",
        )
        .await
        .expect("downloading the test wav")
        .bytes()
        .await
        .expect("reading the test wav");
        std::fs::write(&wav_path, &wav_bytes).expect("writing the test wav");

        let samples =
            crate::audio_toolkit::read_wav_samples(&wav_path).expect("reading wav samples");

        // Recorre en frames de 30ms @ 16kHz, igual que `audio_cb` —
        // alimenta la compuerta y `AudioToWallClock` exactamente como el
        // camino en vivo (fix round 2: `total_ms` cuenta TODOS los
        // frames, pasen o no la compuerta — el mismo reloj que ve
        // `StreamingDiarizer`, ya no una aproximación de reloj de pared),
        // para probar los dos juntos sobre audio real.
        let frame_len = 480usize;
        let mut clock = AudioToWallClock::default();
        let mut asr_ms = 0u64;
        let mut total_ms = 0u64;
        let mut was_gap = true;
        let mut loud_frames = 0usize;
        let mut quiet_frames = 0usize;

        for frame in samples.chunks(frame_len) {
            if frame.len() < frame_len {
                break; // recorta el último frame parcial, igual que haría el resampler
            }
            if has_energy(frame) {
                loud_frames += 1;
                if was_gap {
                    clock.mark(asr_ms, total_ms);
                    was_gap = false;
                }
                asr_ms += 30;
            } else {
                quiet_frames += 1;
                was_gap = true;
            }
            total_ms += 30;
        }

        // La asunción de la que depende Important 4: una grabación real de
        // varios hablantes tiene TANTO tramos con energía como pausas
        // reales — si `has_energy` no distinguiera nada (todo pasa, o nada
        // pasa), la compuerta no serviría para proteger al ASR sin también
        // volverlo sordo a la voz real.
        assert!(
            loud_frames > 0,
            "una grabación real con voz debería tener algún frame con energía"
        );
        assert!(
            quiet_frames > 0,
            "una grabación real de varios hablantes debería tener pausas reales — la \
             misma asunción de la que depende Important 4 (la compuerta protege al ASR, \
             ya no a la diarización)"
        );

        // Chequeo de cordura sobre `AudioToWallClock::to_wall_ms` con
        // quiebres reales (no sintéticos): el reloj de reunión
        // reconstruido nunca puede ir más atrás que el propio reloj
        // comprimido del ASR (cada pausa sólo puede haber hecho crecer
        // `total_ms` más que `asr_ms`, nunca al revés), y tiene que ser
        // monótono sobre toda la grabación real — el chequeo que N1
        // rompía con el ancla de reloj de pared y que los tests sintéticos
        // de arriba ya cubren, repetido acá contra quiebres reales.
        let wall_ms_at_end = clock.to_wall_ms(asr_ms);
        assert!(
            wall_ms_at_end >= asr_ms,
            "el reloj de reunión reconstruido no puede ir más atrás que el reloj \
             comprimido del ASR: {wall_ms_at_end} < {asr_ms}"
        );
        let mut last = clock.to_wall_ms(0);
        for probe_asr_ms in (0..=asr_ms).step_by(30) {
            let wall_ms = clock.to_wall_ms(probe_asr_ms);
            assert!(
                wall_ms >= last,
                "to_wall_ms no es monótona en asr_ms={probe_asr_ms} sobre audio real: \
                 {wall_ms} < {last}"
            );
            last = wall_ms;
        }
    }

    // ------------------------------------------------------------------
    // N2 del fix round 2: `AudioToWallClock` son 8 líneas de lógica pura
    // justo donde un error corre la atribución en silencio (ver N1) — el
    // único test que tenía antes era el `#[ignore]` de audio real, que
    // nunca corre en los gates y cuya única aserción sobre el reloj
    // (`wall_ms_at_end >= asr_ms`) es trivialmente cierta para cualquier
    // conjunto de quiebres no negativos. Estos son de mesa, baratos, y
    // corren siempre.
    // ------------------------------------------------------------------

    #[test]
    fn to_wall_ms_sin_quiebres_devuelve_el_mismo_valor() {
        let clock = AudioToWallClock::default();
        assert_eq!(clock.to_wall_ms(0), 0);
        assert_eq!(clock.to_wall_ms(1_234), 1_234);
    }

    #[test]
    fn to_wall_ms_justo_en_un_quiebre() {
        let mut clock = AudioToWallClock::default();
        clock.mark(500, 800); // el ASR llevaba 500ms cuando la reunión iba en 800ms
        assert_eq!(clock.to_wall_ms(500), 800);
    }

    #[test]
    fn to_wall_ms_interpola_entre_dos_quiebres() {
        let mut clock = AudioToWallClock::default();
        clock.mark(0, 0);
        clock.mark(1_000, 3_000); // un hueco de 2s en el medio
                                  // Después del segundo quiebre, los dos relojes vuelven a avanzar
                                  // 1:1 -- 200ms más de ASR son 200ms más de reunión.
        assert_eq!(clock.to_wall_ms(1_200), 3_200);
    }

    #[test]
    fn to_wall_ms_despues_de_un_hueco_largo() {
        let mut clock = AudioToWallClock::default();
        clock.mark(0, 0);
        clock.mark(100, 100);
        clock.mark(150, 60_100); // un minuto de silencio entre los dos
        assert_eq!(clock.to_wall_ms(200), 60_150);
    }

    #[test]
    fn to_wall_ms_es_monotona_sobre_una_secuencia_de_quiebres() {
        // OJO — qué prueba esto y qué no (corregido en el fix round 3,
        // N2): esto verifica la INTERPOLACIÓN de `AudioToWallClock` sobre
        // quiebres que ya son monótonos por construcción (se arman a
        // mano, ordenados). Nunca estuvo rota y este test no hubiera
        // detectado la regresión de N1 — se comprobó insertándolo tal
        // cual en el commit de antes del arreglo (`29c8edfe`) y pasó
        // igual, porque el problema de N1 no estaba en la interpolación
        // sino en QUÉ la alimentaba (`capture_started.elapsed()` en vez
        // de `total_ms`). El test que sí hubiera detectado esa clase de
        // regresión es sobre `step_audio_clock`, más abajo (N2 del fix
        // round 3) — ahí es donde vive el invariante real: que `total_ms`
        // sume TODOS los frames, no sólo los que pasan la compuerta.
        let mut clock = AudioToWallClock::default();
        let breaks = [(0, 0), (50, 200), (120, 500), (121, 501), (500, 2_000)];
        for &(asr_ms, meeting_ms) in &breaks {
            clock.mark(asr_ms, meeting_ms);
        }

        let mut last = clock.to_wall_ms(0);
        for asr_ms in 0..600u64 {
            let wall_ms = clock.to_wall_ms(asr_ms);
            assert!(
                wall_ms >= last,
                "to_wall_ms no es monótona en asr_ms={asr_ms}: {wall_ms} < {last}"
            );
            last = wall_ms;
        }
    }

    // ------------------------------------------------------------------
    // N2 del fix round 3: `step_audio_clock` es donde vive el invariante
    // que puede volver a romperse — que `total_ms` sume TODOS los frames,
    // tenga o no energía cada uno. Simula lo que `audio_cb` le haría al
    // reloj a lo largo de una secuencia, sin recorder ni hilos.
    // ------------------------------------------------------------------

    /// Aplica `frames` (cada uno `(tiene_energía, frame_ms)`) en orden y
    /// devuelve el estado final más los quiebres que se habrían marcado —
    /// la misma secuencia de llamadas que hace `audio_cb`, una por frame.
    fn simulate_audio_clock(frames: &[(bool, u64)]) -> (AudioClockState, Vec<(u64, u64)>) {
        let mut state = AudioClockState::default();
        let mut marks = Vec::new();
        for &(has_energy, frame_ms) in frames {
            let (new_state, mark) = step_audio_clock(state, has_energy, frame_ms);
            state = new_state;
            if let Some(m) = mark {
                marks.push(m);
            }
        }
        (state, marks)
    }

    #[test]
    fn step_audio_clock_todos_los_frames_con_energia_avanzan_igual() {
        // Sin ningún hueco, los dos relojes tienen que terminar exactamente
        // iguales -- un solo quiebre, al principio, en (0, 0).
        let frames: Vec<(bool, u64)> = (0..10).map(|_| (true, 30)).collect();
        let (state, marks) = simulate_audio_clock(&frames);
        assert_eq!(state.asr_ms, 300);
        assert_eq!(state.total_ms, 300);
        assert_eq!(
            state.asr_ms, state.total_ms,
            "sin huecos, los dos relojes coinciden"
        );
        assert_eq!(marks, vec![(0, 0)]);
    }

    #[test]
    fn step_audio_clock_el_silencio_intercalado_avanza_total_ms_sin_avanzar_asr_ms() {
        // El corazón del asunto (N2): mientras un frame no tiene energía,
        // `asr_ms` tiene que quedarse quieto y `total_ms` tiene que seguir
        // sumando igual. Es justo lo que se rompe si alguien vuelve a
        // meter la suma de `total_ms` adentro del `if has_energy`.
        let mut state = AudioClockState::default();

        let (s1, _) = step_audio_clock(state, true, 30); // voz
        state = s1;
        assert_eq!((state.asr_ms, state.total_ms), (30, 30));

        let (s2, mark2) = step_audio_clock(state, false, 30); // silencio
        state = s2;
        assert_eq!(
            (state.asr_ms, state.total_ms),
            (30, 60),
            "total_ms debe avanzar en el frame de silencio aunque asr_ms no se mueva"
        );
        assert_eq!(mark2, None, "un frame de silencio no marca ningún quiebre");

        let (s3, _) = step_audio_clock(state, false, 30); // más silencio
        state = s3;
        assert_eq!(
            (state.asr_ms, state.total_ms),
            (30, 90),
            "total_ms sigue avanzando frame a frame aunque el silencio se extienda"
        );

        let (s4, mark4) = step_audio_clock(state, true, 30); // vuelve la voz
        state = s4;
        assert_eq!((state.asr_ms, state.total_ms), (60, 120));
        assert_eq!(
            mark4,
            Some((30, 90)),
            "al retomar tras el hueco, marca el punto donde asr_ms y total_ms volvieron a \
             coincidir"
        );
    }

    #[test]
    fn step_audio_clock_secuencia_larga_alternada_la_diferencia_crece_exacto_lo_descartado() {
        // energía, energía, silencio x3, energía, energía, silencio x2,
        // energía -- 30ms por frame. La diferencia entre total_ms y
        // asr_ms en todo momento tiene que ser EXACTAMENTE la suma de los
        // frames de silencio vistos hasta ahí, sin deriva de ningún tipo.
        let pattern = [
            true, true, false, false, false, true, true, false, false, true,
        ];
        let frames: Vec<(bool, u64)> = pattern.iter().map(|&e| (e, 30)).collect();

        let mut state = AudioClockState::default();
        let mut discarded_ms = 0u64;
        for &(has_energy, frame_ms) in &frames {
            let (new_state, _) = step_audio_clock(state, has_energy, frame_ms);
            state = new_state;
            if !has_energy {
                discarded_ms += frame_ms;
            }
            assert_eq!(
                state.total_ms - state.asr_ms,
                discarded_ms,
                "la diferencia entre los dos relojes tiene que ser exactamente el silencio \
                 descartado hasta ahora, sin deriva"
            );
        }

        let loud_frames = pattern.iter().filter(|&&e| e).count() as u64;
        let quiet_frames = pattern.iter().filter(|&&e| !e).count() as u64;
        assert_eq!(state.asr_ms, loud_frames * 30);
        assert_eq!(state.total_ms, (loud_frames + quiet_frames) * 30);
    }

    // ------------------------------------------------------------------
    // N3 del fix round 2: convert_token_to_meeting_clock no debe dejar que
    // un token se "coma" un hueco de silencio que la compuerta le sacó al
    // ASR justo en medio de él.
    // ------------------------------------------------------------------

    #[test]
    fn convert_token_to_meeting_clock_sin_hueco_no_cambia_la_duracion() {
        let mut clock = AudioToWallClock::default();
        clock.mark(0, 0);
        let token = TimedToken {
            text: "hola".into(),
            start_ms: 100,
            end_ms: 400,
        };
        let converted = convert_token_to_meeting_clock(token, &clock);
        assert_eq!(converted.start_ms, 100);
        assert_eq!(converted.end_ms, 400);
    }

    #[test]
    fn convert_token_to_meeting_clock_acota_un_token_partido_por_un_hueco() {
        let mut clock = AudioToWallClock::default();
        clock.mark(0, 0);
        // Un hueco de 5s de silencio empieza en asr_ms=100.
        clock.mark(100, 5_100);
        // Un token cuyo comienzo cayó ANTES del hueco y cuyo fin el ASR
        // reporta apenas 50ms después (100ms de duración original), pero
        // que interpola contra el quiebre de después del hueco.
        let token = TimedToken {
            text: "eh".into(),
            start_ms: 50,
            end_ms: 150,
        };
        let converted = convert_token_to_meeting_clock(token, &clock);
        assert_eq!(converted.start_ms, 50, "el comienzo no cruza el hueco");
        assert_eq!(
            converted.end_ms - converted.start_ms,
            100,
            "la duración queda acotada a la original (100ms), no se come el hueco de 5s"
        );
    }

    // ------------------------------------------------------------------
    // Task 5 ("reuniones en streaming"): segments_from_runs — el test del
    // brief, el síntoma que motivó todo el plan expresado como test sobre
    // la pieza que arma segmentos a partir de intervenciones atribuidas.
    // ------------------------------------------------------------------

    #[test]
    fn una_interrupcion_corta_se_persiste_como_segmento_propio() {
        let runs = vec![
            AttributedRun {
                text: "estaba".into(),
                speaker: Some(0),
                start_ms: 0,
                end_ms: 430,
            },
            AttributedRun {
                text: " no".into(),
                speaker: Some(1),
                start_ms: 430,
                end_ms: 620,
            },
            AttributedRun {
                text: " diciendo".into(),
                speaker: Some(0),
                start_ms: 620,
                end_ms: 1000,
            },
        ];
        let segments = segments_from_runs(&runs);
        assert_eq!(segments.len(), 3);
        assert_eq!(segments[1].speaker_id, Some(1));
    }

    #[test]
    fn segments_from_runs_conserva_texto_y_tiempos() {
        let runs = vec![AttributedRun {
            text: "hola que tal".into(),
            speaker: None,
            start_ms: 100,
            end_ms: 900,
        }];
        let segments = segments_from_runs(&runs);
        assert_eq!(segments.len(), 1);
        assert_eq!(segments[0].text, "hola que tal");
        assert_eq!(segments[0].speaker_id, None);
        assert_eq!(segments[0].started_at_ms, 100);
        assert_eq!(segments[0].ended_at_ms, 900);
        assert!(!segments[0].overlapped);
    }

    #[test]
    fn segments_from_runs_de_una_lista_vacia_es_vacio() {
        assert!(segments_from_runs(&[]).is_empty());
    }

    // ------------------------------------------------------------------
    // resolve_local_speaker — el reemplazo trivial del registro por
    // embeddings: el índice local de Sortformer ya es una identidad
    // estable dentro de la sesión, así que sólo hay que recordar qué id
    // real le tocó la primera vez.
    // ------------------------------------------------------------------

    #[test]
    fn resolve_local_speaker_crea_una_vez_y_reutiliza_despues() {
        let dir = temp_db_path("resolve-local-speaker");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let meeting_id = manager.start_meeting("presencial").expect("start_meeting");
        let conn = manager.get_connection().expect("get_connection");

        let mut local_speakers = HashMap::new();
        let first = resolve_local_speaker(&conn, meeting_id, &mut local_speakers, 0)
            .expect("resolver hablante local 0");
        let again = resolve_local_speaker(&conn, meeting_id, &mut local_speakers, 0)
            .expect("resolver hablante local 0 de nuevo");
        let other = resolve_local_speaker(&conn, meeting_id, &mut local_speakers, 1)
            .expect("resolver hablante local 1");

        assert_eq!(
            first, again,
            "el mismo índice local siempre es el mismo hablante"
        );
        assert_ne!(
            first, other,
            "índices locales distintos son hablantes distintos"
        );

        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM meeting_speakers", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(count, 2, "sólo se crea una fila por índice local nuevo");

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    // ------------------------------------------------------------------
    // persist_and_emit_run — inserta+emite UNA intervención ya convertida
    // por `segments_from_runs`, resolviendo su hablante local si tiene uno.
    // Reemplaza a `persist_and_emit_segment`: ya no transcribe (el texto
    // llega hecho, del reconocimiento en streaming), pero conserva el mismo
    // contrato de persistencia hacia `meeting_segments`/`meeting-segment`.
    // ------------------------------------------------------------------

    #[test]
    fn persist_and_emit_run_inserts_a_row_with_expected_defaults() {
        let dir = temp_db_path("persist-run-basic");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new should succeed");
        let meeting_id = manager
            .start_meeting("presencial")
            .expect("start_meeting should succeed");
        let conn = manager.get_connection().expect("get_connection");

        let run = AttributedRun {
            text: "hola, esto es una prueba".into(),
            speaker: None,
            start_ms: 1_000,
            end_ms: 3_500,
        };
        let segment = segments_from_runs(std::slice::from_ref(&run))
            .into_iter()
            .next()
            .unwrap();
        let mut local_speakers = HashMap::new();

        let segment = persist_and_emit_run(
            &conn,
            NO_APP,
            meeting_id,
            segment,
            run.speaker,
            &mut local_speakers,
        )
        .expect("persisting should succeed")
        .expect("non-empty text should produce a segment");

        assert_eq!(segment.text, "hola, esto es una prueba");
        assert_eq!(segment.speaker_id, None);
        assert_eq!(segment.started_at_ms, 1_000);
        assert_eq!(segment.ended_at_ms, 3_500);
        assert!(!segment.overlapped);

        let (text, speaker_id): (String, Option<i64>) = conn
            .query_row(
                "SELECT text, speaker_id FROM meeting_segments WHERE id = ?1",
                [segment.id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("the inserted segment should be readable back");
        assert_eq!(text, "hola, esto es una prueba");
        assert_eq!(
            speaker_id, None,
            "una intervención sin hablante se persiste con speaker_id NULL (FR-004)"
        );

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn persist_and_emit_run_resolves_local_speaker_to_a_real_id() {
        let dir = temp_db_path("persist-run-speaker");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let meeting_id = manager.start_meeting("presencial").expect("start_meeting");
        let conn = manager.get_connection().expect("get_connection");

        let run = AttributedRun {
            text: "dale".into(),
            speaker: Some(2),
            start_ms: 0,
            end_ms: 1_200,
        };
        let segment = segments_from_runs(std::slice::from_ref(&run))
            .into_iter()
            .next()
            .unwrap();
        assert_eq!(
            segment.speaker_id,
            Some(2),
            "segments_from_runs deja el índice local tal cual, sin resolver"
        );
        let mut local_speakers = HashMap::new();

        let segment = persist_and_emit_run(
            &conn,
            NO_APP,
            meeting_id,
            segment,
            run.speaker,
            &mut local_speakers,
        )
        .expect("persisting should succeed")
        .expect("non-empty text");

        assert_ne!(
            segment.speaker_id,
            Some(2),
            "el id persistido es el real de meeting_speakers, no el índice local"
        );
        let (stored_speaker, stored_overlap): (Option<i64>, bool) = conn
            .query_row(
                "SELECT speaker_id, overlapped FROM meeting_segments WHERE id = ?1",
                [segment.id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("readable back");
        assert_eq!(stored_speaker, segment.speaker_id);
        assert!(!stored_overlap);
        assert_eq!(local_speakers.get(&2), Some(&segment.speaker_id.unwrap()));

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn persist_and_emit_run_skips_empty_text() {
        let dir = temp_db_path("persist-run-empty");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let meeting_id = manager.start_meeting("presencial").expect("start_meeting");
        let conn = manager.get_connection().expect("get_connection");

        let run = AttributedRun {
            text: "   ".into(),
            speaker: None,
            start_ms: 0,
            end_ms: 500,
        };
        let segment = segments_from_runs(std::slice::from_ref(&run))
            .into_iter()
            .next()
            .unwrap();
        let mut local_speakers = HashMap::new();

        let result = persist_and_emit_run(
            &conn,
            NO_APP,
            meeting_id,
            segment,
            run.speaker,
            &mut local_speakers,
        )
        .expect("an empty text is not an error");
        assert!(
            result.is_none(),
            "a blank text should not produce a segment"
        );

        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM meeting_segments", [], |row| {
                row.get(0)
            })
            .expect("count meeting_segments");
        assert_eq!(count, 0, "nothing should be inserted for empty text");

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    // ------------------------------------------------------------------
    // maybe_persist_new_runs — el núcleo del hilo diarizador: recalcula
    // `align::attribute` sobre lo acumulado y sólo persiste las
    // intervenciones que ya no pueden cambiar. La última run se retiene
    // hasta que aparece una más detrás, o hasta el cierre (`include_last`).
    // ------------------------------------------------------------------

    #[test]
    fn maybe_persist_new_runs_retiene_la_ultima_run_hasta_que_aparece_otra() {
        let dir = temp_db_path("maybe-persist-retains-last");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let meeting_id = manager.start_meeting("presencial").expect("start_meeting");
        let conn = manager.get_connection().expect("get_connection");

        let state = Mutex::new(TranscriptState {
            tokens: vec![TimedToken {
                text: "hola".into(),
                start_ms: 0,
                end_ms: 300,
            }],
            spans: vec![SpeakerSpan {
                start_ms: 0,
                end_ms: 300,
                speaker: 0,
            }],
            persisted_until_ms: 0,
            local_speakers: HashMap::new(),
        });
        let mut turn_failure_reported = false;

        maybe_persist_new_runs(
            &conn,
            NO_APP,
            meeting_id,
            &state,
            false,
            &mut turn_failure_reported,
        );
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM meeting_segments", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(
            count, 0,
            "con una sola run en curso, nada se persiste todavía"
        );

        // Llega un segundo hablante: la primera run ya no puede cambiar.
        {
            let mut guard = state.lock().unwrap();
            guard.tokens.push(TimedToken {
                text: " chao".into(),
                start_ms: 400,
                end_ms: 700,
            });
            guard.spans.push(SpeakerSpan {
                start_ms: 400,
                end_ms: 700,
                speaker: 1,
            });
        }
        maybe_persist_new_runs(
            &conn,
            NO_APP,
            meeting_id,
            &state,
            false,
            &mut turn_failure_reported,
        );

        let texts: Vec<String> = {
            let mut stmt = conn
                .prepare("SELECT text FROM meeting_segments ORDER BY id")
                .unwrap();
            stmt.query_map([], |row| row.get(0))
                .unwrap()
                .map(|r| r.unwrap())
                .collect()
        };
        assert_eq!(
            texts,
            vec!["hola".to_string()],
            "sólo la run cerrada (la primera) se persiste; la segunda sigue en curso"
        );

        // Cierre de la reunión: ahora sí se persiste la última.
        maybe_persist_new_runs(
            &conn,
            NO_APP,
            meeting_id,
            &state,
            true,
            &mut turn_failure_reported,
        );
        let final_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM meeting_segments", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(
            final_count, 2,
            "al cerrar, la última run también se persiste"
        );

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    // ------------------------------------------------------------------
    // T016: nombres y fusión de hablantes (FR-005) — la contraparte humana
    // de la atribución automática de T013.
    // ------------------------------------------------------------------

    /// Reunión con dos hablantes, que es el escenario mínimo donde fusionar
    /// significa algo.
    fn meeting_with_two_speakers(manager: &MeetingManager) -> (i64, i64, i64, Connection) {
        let meeting_id = manager.start_meeting("presencial").expect("start_meeting");
        let conn = manager.get_connection().expect("get_connection");
        let a = insert_speaker(&conn, meeting_id).expect("hablante 1");
        let b = insert_speaker(&conn, meeting_id).expect("hablante 2");
        (meeting_id, a, b, conn)
    }

    fn display_name_of(conn: &Connection, speaker_id: i64) -> Option<String> {
        conn.query_row(
            "SELECT display_name FROM meeting_speakers WHERE id = ?1",
            [speaker_id],
            |row| row.get(0),
        )
        .expect("el hablante debe existir")
    }

    // ------------------------------------------------------------------
    // T021: recuperación ante interrupción (FR-008).
    // ------------------------------------------------------------------

    /// Simula el crash: la app muere sin pasar por `stop_meeting`, así que la
    /// fila queda tal cual la dejó `start_meeting`. Se reabre el manager
    /// sobre la misma base, que es exactamente lo que pasa al reabrir Dilo.
    #[test]
    fn recovery_marks_a_meeting_that_died_recording() {
        let dir = temp_db_path("recovery-recording");
        let meeting_id;
        {
            let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
            meeting_id = manager.start_meeting("presencial").expect("start_meeting");
            let conn = manager.get_connection().expect("get_connection");
            // 30 s hablados antes del crash.
            insert_test_segment(&conn, meeting_id, None, "alcanzó a decir esto", 0, 30_000);
        } // <- acá "muere" el proceso

        let manager = MeetingManager::new(dir.clone()).expect("reabrir");
        let recovered = manager
            .recover_interrupted_meetings()
            .expect("recuperación");
        assert_eq!(recovered, vec![meeting_id]);

        let conn = manager.get_connection().expect("get_connection");
        let (status, ended_at, started_at) = meeting_row(&conn, meeting_id);
        assert_eq!(status, "interrupted");
        assert_eq!(
            ended_at,
            Some(started_at + 30),
            "el fin sale del último segmento, no del reloj de cuando se reabrió la app"
        );

        let segmentos: i64 = conn
            .query_row("SELECT COUNT(*) FROM meeting_segments", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(
            segmentos, 1,
            "FR-007/SC-003: el transcript parcial sobrevive a la interrupción"
        );

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn recovery_also_sweeps_a_meeting_that_died_while_processing() {
        let dir = temp_db_path("recovery-processing");
        let meeting_id;
        let ended_at_before;
        {
            let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
            meeting_id = manager.start_meeting("presencial").expect("start_meeting");
            // El usuario apretó detener y la app murió drenando la cola.
            manager.stop_meeting(meeting_id).expect("stop_meeting");
            let conn = manager.get_connection().expect("get_connection");
            ended_at_before = meeting_row(&conn, meeting_id).1;
        }

        let manager = MeetingManager::new(dir.clone()).expect("reabrir");
        let recovered = manager
            .recover_interrupted_meetings()
            .expect("recuperación");
        assert_eq!(
            recovered,
            vec![meeting_id],
            "sin este barrido, una reunión detenida justo antes del crash queda zombi en \
             'processing' para siempre"
        );

        let conn = manager.get_connection().expect("get_connection");
        let (status, ended_at, _) = meeting_row(&conn, meeting_id);
        assert_eq!(status, "interrupted");
        assert_eq!(
            ended_at, ended_at_before,
            "el fin ya lo había sellado stop_meeting: no se pisa"
        );

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn recovery_leaves_finished_meetings_alone_and_frees_the_slot() {
        let dir = temp_db_path("recovery-idempotent");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");

        let ready = manager.start_meeting("presencial").expect("start_meeting");
        manager.stop_meeting(ready).expect("stop");
        manager.finalize_meeting(ready).expect("finalize");

        let crashed = manager.start_meeting("presencial").expect("start_meeting");

        let recovered = manager
            .recover_interrupted_meetings()
            .expect("recuperación");
        assert_eq!(
            recovered,
            vec![crashed],
            "una reunión ya cerrada no se toca"
        );

        let conn = manager.get_connection().expect("get_connection");
        assert_eq!(meeting_row(&conn, ready).0, "ready");

        // Correr la recuperación de nuevo (otro arranque) no cambia nada.
        assert!(manager
            .recover_interrupted_meetings()
            .expect("segunda recuperación")
            .is_empty());

        // Y lo más importante para el usuario: puede volver a grabar.
        assert!(
            manager.start_meeting("presencial").is_ok(),
            "recuperar debe liberar el slot: si no, la reunión zombi bloquea todas las próximas"
        );

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn recovery_of_a_meeting_without_segments_uses_its_start_time() {
        let dir = temp_db_path("recovery-empty");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let meeting_id = manager.start_meeting("presencial").expect("start_meeting");

        manager
            .recover_interrupted_meetings()
            .expect("recuperación");

        let conn = manager.get_connection().expect("get_connection");
        let (status, ended_at, started_at) = meeting_row(&conn, meeting_id);
        assert_eq!(status, "interrupted");
        assert_eq!(
            ended_at,
            Some(started_at),
            "sin nada transcrito, la reunión duró efectivamente cero"
        );

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn discard_meeting_removes_an_empty_one_but_keeps_one_with_content() {
        let dir = temp_db_path("discard-meeting");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");

        // Caso real: abrir el micrófono falló, la reunión no grabó nada.
        let empty = manager.start_meeting("presencial").expect("start_meeting");
        manager.discard_meeting(empty);
        let conn = manager.get_connection().expect("get_connection");
        let left: i64 = conn
            .query_row("SELECT COUNT(*) FROM meetings", [], |row| row.get(0))
            .unwrap();
        assert_eq!(
            left, 0,
            "una reunión que nunca grabó no debe quedar dando vueltas"
        );
        assert!(
            manager.start_meeting("presencial").is_ok(),
            "y no debe dejar bloqueada la siguiente con recording_busy"
        );

        // Con un solo segmento ya hay transcript: descartar no puede tocarla.
        let with_content: i64 = conn
            .query_row(
                "SELECT id FROM meetings ORDER BY id DESC LIMIT 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        insert_test_segment(&conn, with_content, None, "algo", 0, 500);

        manager.discard_meeting(with_content);
        let still_there: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM meetings WHERE id = ?1",
                [with_content],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            still_there, 1,
            "si ya hay transcript, descartar sería perder lo grabado (FR-007)"
        );

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn assign_speaker_name_sets_trims_and_clears() {
        let dir = temp_db_path("assign-speaker-name");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let (_meeting_id, speaker, _b, conn) = meeting_with_two_speakers(&manager);

        manager
            .assign_speaker_name(speaker, "  Alfonso  ")
            .expect("asignar nombre");
        assert_eq!(
            display_name_of(&conn, speaker),
            Some("Alfonso".to_string()),
            "el nombre se guarda sin espacios de sobra"
        );

        manager
            .assign_speaker_name(speaker, "Ana")
            .expect("renombrar");
        assert_eq!(display_name_of(&conn, speaker), Some("Ana".to_string()));

        manager
            .assign_speaker_name(speaker, "   ")
            .expect("borrar nombre");
        assert_eq!(
            display_name_of(&conn, speaker),
            None,
            "un nombre vacío devuelve al hablante a su etiqueta automática"
        );

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn assign_speaker_name_fails_for_unknown_or_merged_speakers() {
        let dir = temp_db_path("assign-speaker-name-errors");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let (meeting_id, a, b, conn) = meeting_with_two_speakers(&manager);

        let err = manager
            .assign_speaker_name(9_999, "Nadie")
            .expect_err("un hablante inexistente no se puede nombrar");
        assert!(err.to_string().contains("speaker_not_found"));

        manager.merge_speakers(meeting_id, a, b).expect("fusionar");
        let err = manager
            .assign_speaker_name(a, "Ana")
            .expect_err("renombrar un hablante fusionado no tendría efecto visible");
        assert!(err.to_string().contains("speaker_merged"));

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn merging_resolves_segments_without_rewriting_them() {
        let dir = temp_db_path("merge-resolves");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let (meeting_id, a, b, conn) = meeting_with_two_speakers(&manager);

        // Un segmento atribuido al hablante que se va a fusionar.
        let segment_id = insert_test_segment(&conn, meeting_id, Some(a), "hola", 0, 900);

        manager.merge_speakers(meeting_id, a, b).expect("fusionar");

        let stored: Option<i64> = conn
            .query_row(
                "SELECT speaker_id FROM meeting_segments WHERE id = ?1",
                [segment_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            stored,
            Some(a),
            "el transcript no se reescribe: la fusión es un dato reversible, no una migración"
        );
        assert_eq!(
            resolve_speaker(&conn, a).unwrap(),
            b,
            "al leerlo, ese segmento se resuelve al destino"
        );
        assert_eq!(
            resolve_speaker(&conn, b).unwrap(),
            b,
            "un hablante sin fusionar se resuelve a sí mismo"
        );

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn merge_rejects_itself_cross_meeting_and_cycles() {
        let dir = temp_db_path("merge-guards");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let (meeting_id, a, b, conn) = meeting_with_two_speakers(&manager);

        let err = manager
            .merge_speakers(meeting_id, a, a)
            .expect_err("fusionar algo consigo mismo");
        assert!(err.to_string().contains("cannot_merge_into_itself"));

        // Otra reunión, otro hablante: un hablante es local a su reunión.
        manager.stop_meeting(meeting_id).expect("stop");
        let other_meeting = manager.start_meeting("presencial").expect("start_meeting");
        let foreign = insert_speaker(&conn, other_meeting).expect("hablante ajeno");
        let err = manager
            .merge_speakers(meeting_id, a, foreign)
            .expect_err("fusionar entre reuniones no significa nada");
        assert!(err.to_string().contains("speaker_not_in_meeting"));

        manager.merge_speakers(meeting_id, a, b).expect("fusionar");
        let err = manager
            .merge_speakers(meeting_id, b, a)
            .expect_err("la vuelta cerraría un ciclo");
        assert!(err.to_string().contains("merge_would_create_a_cycle"));

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn merging_compresses_chains_to_a_single_hop() {
        let dir = temp_db_path("merge-chain");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let (meeting_id, a, b, conn) = meeting_with_two_speakers(&manager);
        let c = insert_speaker(&conn, meeting_id).expect("hablante 3");

        manager.merge_speakers(meeting_id, a, b).expect("a -> b");
        manager.merge_speakers(meeting_id, b, c).expect("b -> c");

        let direct: Option<i64> = conn
            .query_row(
                "SELECT merged_into_id FROM meeting_speakers WHERE id = ?1",
                [a],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            direct,
            Some(c),
            "al fusionar b en c, quien ya apuntaba a b pasa a apuntar directo a c"
        );
        assert_eq!(resolve_speaker(&conn, a).unwrap(), c);

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn merging_carries_the_name_over_when_the_target_has_none() {
        let dir = temp_db_path("merge-names");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let (meeting_id, a, b, conn) = meeting_with_two_speakers(&manager);

        manager.assign_speaker_name(a, "Ana").expect("nombrar a");
        manager.merge_speakers(meeting_id, a, b).expect("fusionar");
        assert_eq!(
            display_name_of(&conn, b),
            Some("Ana".to_string()),
            "el usuario ya nombró a esa persona: fusionar 'al revés' no debe perder el nombre"
        );

        // Si el destino YA tenía nombre, gana el del destino.
        let c = insert_speaker(&conn, meeting_id).expect("hablante 3");
        let d = insert_speaker(&conn, meeting_id).expect("hablante 4");
        manager.assign_speaker_name(c, "Caro").expect("nombrar c");
        manager.assign_speaker_name(d, "Dani").expect("nombrar d");
        manager.merge_speakers(meeting_id, c, d).expect("fusionar");
        assert_eq!(display_name_of(&conn, d), Some("Dani".to_string()));

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    // ------------------------------------------------------------------
    // T015: máquina de estados del cierre (recording -> processing -> ready).
    //
    // Los eventos que emiten estos métodos (`meeting-progress`,
    // `meeting-finished`) NO están cubiertos acá: `MeetingManager` guarda un
    // `AppHandle<Wry>` concreto, y hacerlo genérico sobre el runtime sólo
    // para estos tests sería un refactor grande de producción. El mecanismo
    // de emisión en sí ya está probado en los tests de T014; lo que se prueba
    // acá es la parte que puede corromper datos: las transiciones.
    // ------------------------------------------------------------------

    fn meeting_row(conn: &Connection, meeting_id: i64) -> (String, Option<i64>, i64) {
        conn.query_row(
            "SELECT status, ended_at, started_at FROM meetings WHERE id = ?1",
            [meeting_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("la reunión debe existir")
    }

    #[test]
    fn stop_meeting_moves_to_processing_and_stamps_ended_at() {
        let dir = temp_db_path("stop-meeting-basic");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let meeting_id = manager.start_meeting("presencial").expect("start_meeting");

        manager.stop_meeting(meeting_id).expect("stop_meeting");

        let conn = manager.get_connection().expect("get_connection");
        let (status, ended_at, started_at) = meeting_row(&conn, meeting_id);
        assert_eq!(status, "processing");
        let ended_at = ended_at.expect("data-model.md: ended_at deja de ser NULL al detener");
        assert!(ended_at >= started_at);

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn stopping_twice_fails_without_touching_the_row() {
        let dir = temp_db_path("stop-meeting-twice");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let meeting_id = manager.start_meeting("presencial").expect("start_meeting");
        manager.stop_meeting(meeting_id).expect("primer stop");

        let conn = manager.get_connection().expect("get_connection");
        let before = meeting_row(&conn, meeting_id);

        let err = manager
            .stop_meeting(meeting_id)
            .expect_err("un segundo stop no debe pasar");
        assert!(err.to_string().contains("meeting_not_recording"));

        assert_eq!(
            meeting_row(&conn, meeting_id),
            before,
            "un doble click en detener no debe re-timestampear ni revivir la reunión"
        );

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn stop_meeting_fails_for_an_unknown_meeting() {
        let dir = temp_db_path("stop-meeting-unknown");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");

        let err = manager
            .stop_meeting(9_999)
            .expect_err("una reunión inexistente no se puede detener");
        assert!(err.to_string().contains("meeting_not_recording"));

        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn stopping_a_meeting_frees_the_slot_for_the_next_one() {
        let dir = temp_db_path("stop-meeting-frees-slot");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let first = manager.start_meeting("presencial").expect("start_meeting");

        assert!(
            manager.start_meeting("presencial").is_err(),
            "con una reunión grabando, otra no debe poder empezar (recording_busy)"
        );

        manager.stop_meeting(first).expect("stop_meeting");
        let second = manager
            .start_meeting("presencial")
            .expect("detenida la primera, la siguiente sí debe poder empezar");
        assert_ne!(first, second);

        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn finalize_meeting_moves_processing_to_ready() {
        let dir = temp_db_path("finalize-meeting");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let meeting_id = manager.start_meeting("presencial").expect("start_meeting");

        // Sin pasar por processing no se puede terminar.
        let err = manager
            .finalize_meeting(meeting_id)
            .expect_err("una reunión grabando no está lista para cerrarse");
        assert!(err.to_string().contains("meeting_not_processing"));

        manager.stop_meeting(meeting_id).expect("stop_meeting");
        manager.finalize_meeting(meeting_id).expect("finalize");

        let conn = manager.get_connection().expect("get_connection");
        let (status, ended_at, _) = meeting_row(&conn, meeting_id);
        assert_eq!(status, "ready");
        assert!(ended_at.is_some());

        let summary: Option<String> = conn
            .query_row(
                "SELECT summary FROM meetings WHERE id = ?1",
                [meeting_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            summary, None,
            "la Historia 1 llega a ready sin resumen: eso lo agrega T037, y NULL significa \
             'sin resumen todavía', no 'resumen vacío'"
        );

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn drain_and_finalize_reaches_ready_without_an_active_capture() {
        let dir = temp_db_path("drain-no-capture");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let meeting_id = manager.start_meeting("presencial").expect("start_meeting");
        manager.stop_meeting(meeting_id).expect("stop_meeting");

        // No hay micrófono abierto (este manager ni siquiera tiene deps de
        // captura): que no haya nada que drenar no debe impedir cerrar.
        manager.drain_and_finalize(meeting_id);

        let conn = manager.get_connection().expect("get_connection");
        let (status, _, _) = meeting_row(&conn, meeting_id);
        assert_eq!(status, "ready");

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    // ------------------------------------------------------------------
    // T014: emisión incremental de `meeting-segment` (FR-002).
    //
    // El camino de emisión ya existía (T012 lo cableó, T013 le agregó
    // hablante y superposición), pero hasta acá NINGÚN test lo ejercitaba:
    // todos pasaban `app_handle: None`. Estos dos tests cierran esa brecha
    // con el runtime mock de Tauri, que es la única forma de tener un
    // `AppHandle` sin event loop ni ventana.
    // ------------------------------------------------------------------

    /// App mock con el registro de eventos de tauri-specta montado, igual
    /// que hace `lib.rs` con `specta_builder.mount_events(app)`. Sin ese
    /// montaje `Event::emit` entra en pánico ("EventRegistry not found in
    /// Tauri state") — o sea que este helper también documenta que la
    /// emisión depende de que el evento esté en el `collect_events!` de
    /// `lib.rs`, no sólo de que el struct derive `tauri_specta::Event`.
    fn mock_app_with_events() -> tauri::App<tauri::test::MockRuntime> {
        let app = tauri::test::mock_app();
        let builder = tauri_specta::Builder::<tauri::test::MockRuntime>::new().events(
            tauri_specta::collect_events![
                MeetingSegment,
                MeetingError,
                MeetingTurnFailed,
                MeetingAudioWarning
            ],
        );
        builder.mount_events(app.handle());
        app.handle().manage(PendingMeetingAudioNotices::default());
        app
    }

    #[test]
    fn each_persisted_run_emits_meeting_segment_incrementally() {
        let app = mock_app_with_events();
        let handle = app.handle().clone();

        let received = Arc::new(Mutex::new(Vec::<serde_json::Value>::new()));
        let received_cb = Arc::clone(&received);
        handle.listen("meeting-segment", move |event| {
            let payload: serde_json::Value =
                serde_json::from_str(event.payload()).expect("payload JSON");
            received_cb.lock().unwrap().push(payload);
        });

        let dir = temp_db_path("emit-incremental");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let meeting_id = manager.start_meeting("presencial").expect("start_meeting");
        let conn = manager.get_connection().expect("get_connection");
        let mut local_speakers = HashMap::new();

        // Tres intervenciones consecutivas, como las que produce la
        // captura en vivo.
        for i in 0..3u64 {
            let run = AttributedRun {
                text: format!("turno {i}"),
                speaker: Some(0),
                start_ms: i * 1_000,
                end_ms: i * 1_000 + 800,
            };
            let segment = segments_from_runs(std::slice::from_ref(&run))
                .into_iter()
                .next()
                .unwrap();
            persist_and_emit_run(
                &conn,
                Some(&handle),
                meeting_id,
                segment,
                run.speaker,
                &mut local_speakers,
            )
            .expect("persisting should succeed")
            .expect("non-empty text");
        }

        let received = received.lock().unwrap();
        assert_eq!(
            received.len(),
            3,
            "FR-002: un evento por segmento, a medida que se insertan — no uno solo al final"
        );

        // El contrato (`contracts/tauri-commands.md`) dice payload =
        // `MeetingSegment` completo; verificarlo campo por campo evita que
        // un rename silencioso rompa al frontend sin romper ningún test.
        let first = &received[0];
        assert_eq!(first["text"], "turno 0");
        assert!(first["speaker_id"].is_number());
        assert_eq!(first["started_at_ms"], 0);
        assert_eq!(first["ended_at_ms"], 800);
        assert_eq!(first["overlapped"], false);
        assert!(first["id"].is_number());
        assert_eq!(received[2]["text"], "turno 2");
        // Las tres intervenciones vinieron del mismo índice local (0):
        // deben resolver al mismo speaker_id real.
        assert_eq!(first["speaker_id"], received[2]["speaker_id"]);

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn a_blank_run_emits_nothing() {
        let app = mock_app_with_events();
        let handle = app.handle().clone();

        let received = Arc::new(Mutex::new(0usize));
        let received_cb = Arc::clone(&received);
        handle.listen("meeting-segment", move |_| {
            *received_cb.lock().unwrap() += 1;
        });

        let dir = temp_db_path("emit-empty");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let meeting_id = manager.start_meeting("presencial").expect("start_meeting");
        let conn = manager.get_connection().expect("get_connection");

        let run = AttributedRun {
            text: "   ".into(),
            speaker: None,
            start_ms: 0,
            end_ms: 500,
        };
        let segment = segments_from_runs(std::slice::from_ref(&run))
            .into_iter()
            .next()
            .unwrap();
        let mut local_speakers = HashMap::new();
        let result = persist_and_emit_run(
            &conn,
            Some(&handle),
            meeting_id,
            segment,
            run.speaker,
            &mut local_speakers,
        )
        .expect("persisting should succeed");

        assert!(result.is_none());
        assert_eq!(
            *received.lock().unwrap(),
            0,
            "un texto en blanco no debe ensuciar el transcript en vivo"
        );

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    // ------------------------------------------------------------------
    // T035: `list_meetings` / `get_meeting` — el registro de reuniones
    // pasadas, hasta ahora ilegible desde ninguna pantalla.
    // ------------------------------------------------------------------

    #[test]
    fn list_meetings_orders_newest_first_and_reports_has_more() {
        let dir = temp_db_path("list-meetings-order");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let conn = manager.get_connection().expect("get_connection");

        let mut ids = Vec::new();
        for i in 0..3 {
            let id = manager.start_meeting("presencial").expect("start_meeting");
            manager.stop_meeting(id).expect("stop_meeting");
            // `started_at` a segundos distintos y crecientes a propósito: sin
            // esto, tres reuniones creadas en el mismo test podrían caer en
            // el mismo segundo de reloj y el orden "más reciente primero"
            // quedaría indefinido en vez de probado.
            conn.execute(
                "UPDATE meetings SET started_at = ?2 WHERE id = ?1",
                params![id, 1_000_000_i64 + i],
            )
            .expect("set started_at");
            ids.push(id);
        }
        // started_at creciente -> ids[2] es la más nueva, ids[0] la más vieja.

        let page1 = manager.list_meetings(2, 0).expect("list_meetings page 1");
        assert_eq!(page1.meetings.len(), 2);
        assert_eq!(
            page1.meetings[0].id, ids[2],
            "la más reciente debe ir primero"
        );
        assert_eq!(page1.meetings[1].id, ids[1]);
        assert!(
            page1.has_more,
            "queda una reunión más allá de esta página de 2"
        );

        let page2 = manager.list_meetings(2, 2).expect("list_meetings page 2");
        assert_eq!(page2.meetings.len(), 1);
        assert_eq!(page2.meetings[0].id, ids[0], "la más vieja va al final");
        assert!(!page2.has_more, "no queda nada después de esta página");

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn list_meetings_on_empty_database_returns_empty_list() {
        let dir = temp_db_path("list-meetings-empty");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");

        let page = manager
            .list_meetings(20, 0)
            .expect("list_meetings sobre una base vacía no debe fallar");
        assert!(page.meetings.is_empty());
        assert!(!page.has_more);

        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn get_meeting_returns_segments_in_chronological_order() {
        let dir = temp_db_path("get-meeting-chrono");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let meeting_id = manager.start_meeting("presencial").expect("start_meeting");
        let conn = manager.get_connection().expect("get_connection");

        // Persistidos fuera de orden a propósito: lo que tiene que ordenar
        // `get_meeting` es `started_at_ms`, no el orden de inserción (que acá
        // es justo el contrario).
        insert_test_segment(&conn, meeting_id, None, "segmento b", 5_000, 6_000);
        insert_test_segment(&conn, meeting_id, None, "segmento a", 0, 1_000);
        insert_test_segment(&conn, meeting_id, None, "segmento c", 10_000, 11_000);

        let meeting = manager.get_meeting(meeting_id).expect("get_meeting");
        let starts: Vec<i64> = meeting.segments.iter().map(|s| s.started_at_ms).collect();
        assert_eq!(
            starts,
            vec![0, 5_000, 10_000],
            "los segmentos deben salir en orden cronológico, no de inserción"
        );

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    /// El test más importante de esta tarea: un hablante fusionado dentro de
    /// otro tiene que desaparecer como persona separada, pero sus segmentos
    /// no deben perderse — se resuelven al destino de la fusión. De paso
    /// verifica que un segmento incierto (`speaker_id = NULL`) no se rompe al
    /// resolver: sigue incierto, no se le inventa un hablante.
    #[test]
    fn get_meeting_resolves_merged_speakers_and_hides_them_from_the_list() {
        let dir = temp_db_path("get-meeting-merge");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let (meeting_id, a, b, conn) = meeting_with_two_speakers(&manager);

        let segment_a_id = insert_test_segment(&conn, meeting_id, Some(a), "hola", 0, 1_000);
        let segment_uncertain_id =
            insert_test_segment(&conn, meeting_id, None, "hola", 2_000, 3_000);

        manager
            .merge_speakers(meeting_id, a, b)
            .expect("fusionar A en B");

        let meeting = manager.get_meeting(meeting_id).expect("get_meeting");

        let resolved_a = meeting
            .segments
            .iter()
            .find(|s| s.id == segment_a_id)
            .expect("el segmento de A sigue presente");
        assert_eq!(
            resolved_a.speaker_id,
            Some(b),
            "el segmento que apuntaba a A debe salir resuelto a B, el destino de la fusión"
        );

        let still_uncertain = meeting
            .segments
            .iter()
            .find(|s| s.id == segment_uncertain_id)
            .expect("el segmento incierto sigue presente");
        assert_eq!(
            still_uncertain.speaker_id, None,
            "un segmento sin hablante (incierto) no debe salir con uno inventado al resolver"
        );

        let speaker_ids: Vec<i64> = meeting.speakers.iter().map(|s| s.id).collect();
        assert!(
            speaker_ids.contains(&b),
            "B sigue siendo un hablante vigente de la reunión"
        );
        assert!(
            !speaker_ids.contains(&a),
            "A fue fusionado dentro de B: el usuario ya no debe verlo como persona separada"
        );

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn get_meeting_fails_clearly_for_unknown_id() {
        let dir = temp_db_path("get-meeting-missing");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");

        let err = manager
            .get_meeting(9_999)
            .expect_err("un id que no existe no debe devolver una reunión");
        assert!(err.to_string().contains("meeting_not_found"));

        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    // ------------------------------------------------------------------
    // Los fallos del pipeline de captura dejan de ser mudos, pero cada uno
    // por su canal: el que mata la sesión por `meeting-error` (que el
    // frontend lee como fin de sesión), el que pierde un turno por
    // `meeting-turn-failed` (la reunión sigue grabando y detenible).
    // ------------------------------------------------------------------

    /// Junta lo emitido en un evento, para poder afirmar también sobre el
    /// que NO se emitió.
    fn collect_event(
        handle: &AppHandle<tauri::test::MockRuntime>,
        name: &str,
    ) -> Arc<Mutex<Vec<serde_json::Value>>> {
        let received = Arc::new(Mutex::new(Vec::<serde_json::Value>::new()));
        let received_cb = Arc::clone(&received);
        handle.listen(name.to_string(), move |event| {
            let payload: serde_json::Value =
                serde_json::from_str(event.payload()).expect("payload JSON");
            received_cb.lock().unwrap().push(payload);
        });
        received
    }

    #[test]
    fn a_fatal_capture_failure_is_reported_as_the_end_of_the_session() {
        let app = mock_app_with_events();
        let handle = app.handle().clone();
        let errors = collect_event(&handle, "meeting-error");

        report_fatal_capture_failure(
            Some(&handle),
            42,
            "no se pudo abrir la base de datos: disco lleno".to_string(),
        );

        let errors = errors.lock().unwrap();
        assert_eq!(errors.len(), 1);
        assert_eq!(errors[0]["meeting_id"], 42);
        assert_eq!(
            errors[0]["error"],
            "no se pudo abrir la base de datos: disco lleno"
        );
    }

    #[test]
    fn a_failed_turn_never_reports_the_end_of_the_session() {
        let app = mock_app_with_events();
        let handle = app.handle().clone();
        let errors = collect_event(&handle, "meeting-error");
        let turn_failures = collect_event(&handle, "meeting-turn-failed");

        let mut reported = false;
        report_turn_failure(
            Some(&handle),
            42,
            &mut reported,
            "no se pudo guardar un segmento transcrito: disco lleno".to_string(),
        );
        report_turn_failure(
            Some(&handle),
            42,
            &mut reported,
            "no se pudo guardar un segmento transcrito: disco lleno".to_string(),
        );
        report_turn_failure(Some(&handle), 42, &mut reported, "y otro más".to_string());

        assert!(
            errors.lock().unwrap().is_empty(),
            "perder un turno NO termina la reunión: con `meeting-error` el frontend limpia la \
             sesión, se lleva el botón de detener y deja el micrófono abierto sin forma de cerrarlo"
        );

        let turn_failures = turn_failures.lock().unwrap();
        assert_eq!(
            turn_failures.len(),
            1,
            "un aviso por sesión: el modo de falla típico es permanente y se repite en cada turno"
        );
        assert_eq!(turn_failures[0]["meeting_id"], 42);
        assert_eq!(
            turn_failures[0]["error"],
            "no se pudo guardar un segmento transcrito: disco lleno"
        );
    }

    // ------------------------------------------------------------------
    // I5/M1 del reporte de seguimiento: un aviso de audio no se repite por
    // tipo, y sobrevive a que nadie esté escuchando (ventana de Reuniones
    // escondida) vía `PendingMeetingAudioNotices`.
    // ------------------------------------------------------------------

    #[test]
    fn audio_warning_se_reporta_una_vez_por_tipo_y_se_encola_para_una_ventana_escondida() {
        let app = mock_app_with_events();
        let handle = app.handle().clone();
        let warnings = collect_event(&handle, "meeting-audio-warning");

        let reported = AtomicBool::new(false);
        report_audio_warning(
            Some(&handle),
            42,
            &reported,
            MeetingAudioWarningKind::MissingPermission,
        );
        report_audio_warning(
            Some(&handle),
            42,
            &reported,
            MeetingAudioWarningKind::MissingPermission,
        );

        assert_eq!(
            warnings.lock().unwrap().len(),
            1,
            "el mismo tipo de aviso, sondeado varias veces, no debe emitirse dos veces"
        );

        // El listener de arriba ya lo consumió, pero la cola de pendientes
        // (para cuando la ventana de Reuniones está escondida) es
        // independiente: se llena en paralelo, sin que nadie la haya vaciado
        // todavía.
        let pending = handle.state::<PendingMeetingAudioNotices>().take_all();
        assert_eq!(
            pending.len(),
            1,
            "el aviso se encola igual, para poder mostrarlo cuando la ventana de \
             Reuniones se vuelva a abrir o recupere el foco"
        );
        assert_eq!(pending[0].meeting_id, 42);
        assert_eq!(pending[0].kind, MeetingAudioWarningKind::MissingPermission);

        // Ya vaciada: una segunda lectura no repite lo mismo.
        assert!(handle
            .state::<PendingMeetingAudioNotices>()
            .take_all()
            .is_empty());
    }

    #[test]
    fn tipos_distintos_de_aviso_se_reportan_por_separado() {
        let app = mock_app_with_events();
        let handle = app.handle().clone();
        let warnings = collect_event(&handle, "meeting-audio-warning");

        let permission_reported = AtomicBool::new(false);
        let silence_reported = AtomicBool::new(false);
        report_audio_warning(
            Some(&handle),
            7,
            &permission_reported,
            MeetingAudioWarningKind::MissingPermission,
        );
        report_audio_warning(
            Some(&handle),
            7,
            &silence_reported,
            MeetingAudioWarningKind::NoAudioCaptured,
        );

        assert_eq!(
            warnings.lock().unwrap().len(),
            2,
            "dos tipos de aviso distintos, cada uno con su propio guard, deben avisarse los dos"
        );
    }

    // ------------------------------------------------------------------
    // Detener una reunión que ya no estaba `recording` igual tiene que
    // soltar el micrófono; lo que no corresponde es marcarla lista.
    // ------------------------------------------------------------------

    #[test]
    fn a_failed_stop_still_releases_the_capture_without_finalizing() {
        let dir = temp_db_path("finish-stop-failed-transition");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let meeting_id = manager.start_meeting("presencial").expect("start_meeting");

        // La reunión quedó `interrupted` (recuperada de una sesión que
        // murió), así que la transición de `stop_meeting` falla.
        let conn = manager.get_connection().expect("get_connection");
        conn.execute(
            "UPDATE meetings SET status = 'interrupted' WHERE id = ?1",
            params![meeting_id],
        )
        .expect("marcar interrupted");
        assert!(
            manager.stop_meeting(meeting_id).is_err(),
            "una reunión que no está grabando no puede transicionar"
        );

        // El camino que el comando despacha igual: suelta la captura (acá no
        // hay ninguna abierta, así que sólo loggea) y NO finaliza.
        manager.finish_stop(meeting_id, false);

        let (status, _, _) = meeting_row(&conn, meeting_id);
        assert_eq!(
            status, "interrupted",
            "sin transición no hay `ready`: marcarla lista mentiría sobre su estado"
        );

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn a_successful_stop_still_finalizes_the_meeting() {
        let dir = temp_db_path("finish-stop-ok");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let meeting_id = manager.start_meeting("presencial").expect("start_meeting");
        manager.stop_meeting(meeting_id).expect("stop_meeting");

        manager.finish_stop(meeting_id, true);

        let conn = manager.get_connection().expect("get_connection");
        let (status, ended_at, _) = meeting_row(&conn, meeting_id);
        assert_eq!(status, "ready");
        assert!(ended_at.is_some());

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }
}
