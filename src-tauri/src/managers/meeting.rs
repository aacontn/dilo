//! Manages the lifecycle of a meeting notetaker session: recording, live
//! transcription, and speaker diarization. T005 added the SQLite schema
//! (migrations), and T006 added `get_connection()` so later tasks can open
//! per-operation connections against the migrated database, mirroring
//! `HistoryManager`'s pattern. T011 added the first real business logic,
//! `start_meeting()` — it only creates the `meetings` row. T012 (this task)
//! wires real microphone capture + VAD + incremental transcription into a
//! meeting session — see [`MeetingManager::start_capture`] and the
//! coexistence-with-dictation decision documented just above it. T013 adds
//! per-turn speaker attribution on top of that pipeline — see the
//! "T013: diarización incremental" section below.

use crate::audio_toolkit::{
    audio::{system_audio_available, CaptureDiagnosis, SystemAudioRecorder},
    vad::{
        SmoothedVad, VadFrame, VAD_OFFLINE_HANGOVER_FRAMES, VAD_ONSET_FRAMES, VAD_PREFILL_FRAMES,
        VAD_STREAMING_HANGOVER_FRAMES,
    },
    AudioRecorder, SileroVad, VadPolicy, VoiceActivityDetector,
};
use crate::managers::audio::{AudioRecordingManager, MicOwner, MicrophoneArbiter, VAD_THRESHOLD};
use crate::managers::diarization::{
    cosine_similarity, DiarizationEngine, DiarizedSegment, CLUSTER_THRESHOLD,
};
use crate::managers::diarization_models;
use crate::managers::transcription::TranscriptionManager;
use crate::settings::{self, MeetingAudioSource};
use anyhow::{bail, Result};
use chrono::{Local, Utc};
use log::{debug, error, info, warn};
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use rusqlite_migration::{Migrations, M};
use serde::{Deserialize, Serialize};
use specta::Type;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager};
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

// --- T012: microphone capture -> VAD -> incremental transcription -----
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
// means the recorder's own internal buffer also keeps every VAD-passed
// (speech) sample in memory for the meeting's full duration, in addition to
// this module's own per-turn accumulator (`TurnAccumulator`), which is what
// actually drives transcription and is reset after every turn. The
// recorder's copy is redundant (this module never reads `AudioRecorder::
// stop()`'s return value) and unbounded: roughly 64 KB/s of *speech* audio,
// so a hypothetical multi-hour meeting with e.g. 45 minutes of total speech
// would hold ~170 MB in that redundant buffer by the end. This is called out
// explicitly as a known simplification rather than fixed in this task: a
// correct fix (periodically recycling the recorder's `stop()`/`start()`
// around confirmed turn boundaries to reset its internal buffer, or adding a
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
// module's `audio_cb` (which is what actually feeds `TurnAccumulator` and,
// downstream, when a turn gets transcribed). A `Vec<f32>` that has grown to
// hundreds of MB reallocates (and memcpy's its *entire* existing contents)
// on an amortized-doubling schedule — infrequent, but each one copies more
// data than the last as the meeting goes on, so the worst-case stall on
// that single thread gets *larger*, not smaller, later into a long
// meeting. Any such stall delays `audio_cb` for whatever frames arrive
// during it, which delays turn-boundary detection and therefore when a
// segment reaches the transcriber thread — i.e. a plausible, compounding
// latency-degradation mechanism over a multi-hour meeting, not just a
// memory one. I have not measured this (no real multi-hour audio run in
// this environment) — flagging the mechanism, not a measurement, so
// whoever runs T053's SC-004 validation knows to watch both memory *and*
// segment-latency-over-time, not just memory.

/// One completed VAD-detected speech turn, ready to transcribe. `research.md`
/// §2's "ventanas cortas superpuestas" decision maps one VAD turn to one
/// transcription window — no more sophisticated windowing than that.
///
/// `#[allow(dead_code)]` throughout this section: everything below is wired
/// only through `start_capture`/`stop_capture`, which the brief for this
/// task explicitly scopes out of exposing via a Tauri command yet (a future
/// task wires them up — see the doc comment above). `cargo test` exercises
/// all of it directly (see `mod tests` below), so it isn't actually dead,
/// just not yet reachable from `cargo check`'s/`cargo clippy`'s non-test
/// reachability roots.
#[allow(dead_code)]
struct CompletedTurn {
    samples: Vec<f32>,
    started_at_ms: i64,
    ended_at_ms: i64,
}

/// Groups a live stream of VAD-passed speech frames into discrete
/// [`CompletedTurn`]s. Deliberately decoupled from real time and from
/// `AudioRecorder`/cpal: the live capture path drives it from
/// `push_speech`/`take_if_silent` off a wall-clock watchdog, while tests
/// drive the exact same buffering/timestamp logic deterministically by
/// feeding pre-recorded frames through the real Silero+`SmoothedVad` engine
/// directly and calling `push_speech`/`take_remaining` at the VAD's own
/// Speech->Noise transitions — no live timing, no hardware, no flakiness.
#[derive(Default)]
#[allow(dead_code)]
struct TurnAccumulator {
    buffer: Vec<f32>,
    turn_started_ms: Option<i64>,
    last_frame_at: Option<Instant>,
}

impl TurnAccumulator {
    /// Feed one chunk of VAD-passed speech audio. `now_ms` is the caller's
    /// clock (ms since capture started) and only used to timestamp the
    /// start of a fresh turn.
    #[allow(dead_code)]
    fn push_speech(&mut self, samples: &[f32], now_ms: i64) {
        if self.buffer.is_empty() {
            self.turn_started_ms = Some(now_ms);
        }
        self.buffer.extend_from_slice(samples);
        self.last_frame_at = Some(Instant::now());
    }

    /// If a turn is in progress and has been silent for at least `gap`
    /// (no `push_speech` call in that long), take and return it. Used by
    /// the live watchdog thread.
    #[allow(dead_code)]
    fn take_if_silent(&mut self, gap: Duration, now_ms: i64) -> Option<CompletedTurn> {
        let idle_for = self.last_frame_at?.elapsed();
        if self.buffer.is_empty() || idle_for < gap {
            return None;
        }
        self.take_remaining(now_ms)
    }

    /// Si hay un turno en curso y acumuló al menos `max_ms` de audio, lo
    /// cierra aunque siga entrando voz — a diferencia de `take_if_silent`,
    /// que nunca dispara en conversación continua porque nunca hay
    /// `TURN_SILENCE_GAP` de silencio real. Es el tope duro que evita que un
    /// turno crezca sin límite (ver `MAX_TURN_MS`).
    ///
    /// La duración se mide por samples acumulados a 16 kHz, no por reloj de
    /// pared: es la misma unidad que usa `split_turn_into_pieces` (y, debajo,
    /// el motor de diarización) para sus propios offsets, así que un turno
    /// cerrado por tope mide exactamente lo mismo aquí y allá.
    #[allow(dead_code)]
    fn take_if_over(&mut self, max_ms: u64, now_ms: i64) -> Option<CompletedTurn> {
        if self.buffer.is_empty() {
            return None;
        }
        let duration_ms = (self.buffer.len() as u64 * 1000) / DIARIZATION_SAMPLE_RATE as u64;
        if duration_ms < max_ms {
            return None;
        }
        self.take_remaining(now_ms)
    }

    /// Unconditionally take whatever is buffered, regardless of silence
    /// gap. Used by tests (driven off real VAD Speech->Noise transitions
    /// instead of wall-clock silence) and by `stop_capture` to flush a
    /// trailing partial turn when capture ends mid-speech.
    #[allow(dead_code)]
    fn take_remaining(&mut self, now_ms: i64) -> Option<CompletedTurn> {
        if self.buffer.is_empty() {
            return None;
        }
        let started_at_ms = self.turn_started_ms.take()?;
        self.last_frame_at = None;
        Some(CompletedTurn {
            samples: std::mem::take(&mut self.buffer),
            started_at_ms,
            ended_at_ms: now_ms,
        })
    }
}

/// How long a turn must go without a new speech frame before the live
/// watchdog finalizes it. Frames arrive ~every 30ms while the VAD considers
/// a turn ongoing (including its hangover tail), so this only needs to
/// comfortably exceed normal frame-to-frame jitter, not the VAD's own
/// hangover (which has already elapsed by the time frames stop arriving).
#[allow(dead_code)]
const TURN_SILENCE_GAP: Duration = Duration::from_millis(200);
/// Tope duro de duración de un turno. En conversación continua nunca hay
/// `TURN_SILENCE_GAP` de silencio real, así que sin este tope un turno crece
/// sin límite y colapsa una reunión de varias personas en un solo bloque sin
/// hablante — el problema real que este cambio arregla (18.7s de una
/// reunión de 3 personas en un turno, cero hablantes).
///
/// 8s y no más: el modelo de segmentación usa una ventana de 10s
/// (`SegmentationModel`, `diarization.rs`) y, con una sola ventana de
/// audio, `run_pipeline` corre su caso especial de un solo chunk
/// (`HandleOneChunkSpecialCase`) — el camino más preciso, sin clustering
/// entre ventanas. Un turno de hasta 8s cabe siempre en esa única ventana.
#[allow(dead_code)]
const MAX_TURN_MS: u64 = 8_000;
/// How often the watchdog thread checks for a silence gap.
#[allow(dead_code)]
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
#[allow(dead_code)]
const SYSTEM_AUDIO_DIAGNOSIS_POLL: Duration = Duration::from_secs(5);
/// Turns shorter than this are zero-padded before transcription, mirroring
/// `AudioRecordingManager::stop_recording`'s short-buffer padding (some
/// engines need a minimum input duration to run at all).
#[allow(dead_code)]
const MIN_TURN_SAMPLES: usize = 16_000; // 1s @ 16kHz
/// A partir de cuántos turnos encolados sin transcribir se avisa en el log.
/// La cola (`mpsc`) no tiene cota: si transcribir va más lento que hablar,
/// crece sin freno y el audio pendiente se acumula en memoria. La
/// backpressure real es trabajo aparte; esto al menos deja rastro en
/// `handy.log` de que pasó, en vez de un consumo de memoria inexplicable.
const QUEUE_DEPTH_WARN_THRESHOLD: usize = 50;

/// ¿Este error dice "el modelo no está cargado"? Los dos mensajes salen de
/// `TranscriptionManager::transcribe` y son los únicos que un reintento con
/// recarga puede arreglar; cualquier otro (audio inválido, motor que explotó)
/// volvería a fallar igual.
fn is_model_not_loaded_error(error: &anyhow::Error) -> bool {
    let message = error.to_string();
    message.contains("Model is not loaded") || message.contains("Model failed to load")
}

/// Transcribe un turno y, si falló **porque el modelo no estaba cargado**,
/// lo recarga y reintenta ese mismo turno UNA vez.
///
/// El modelo se puede descargar en medio de una reunión (watcher de
/// inactividad, cambio de modelo, descarga manual desde la bandeja). Sin este
/// reintento el turno se perdía en silencio y —peor— todos los siguientes,
/// porque nadie volvía a cargar el modelo: la reunión seguía "grabando" horas
/// sin producir un solo segmento.
///
/// Un solo reintento a propósito: si tras recargar sigue fallando, el
/// problema no es la descarga y reintentar en bucle sólo trabaría la cola de
/// turnos detrás de éste.
fn transcribe_with_reload(
    samples: Vec<f32>,
    transcribe: &dyn Fn(Vec<f32>) -> Result<String>,
    reload: &dyn Fn(),
) -> Result<String> {
    // La copia es para poder reintentar: `transcribe` consume las muestras.
    // Un turno son segundos de audio a 16 kHz, un par de MB en el peor caso.
    let retry_samples = samples.clone();
    match transcribe(samples) {
        Err(e) if is_model_not_loaded_error(&e) => {
            warn!("El modelo se había descargado; recargando y reintentando el turno: {e}");
            reload();
            transcribe(retry_samples)
        }
        other => other,
    }
}

/// Avisa al frontend de un fallo que **mata la sesión** (`meeting-error`).
///
/// Sin esto una reunión podía "grabar" horas con cero segmentos y sin decir
/// nada: los errores del hilo transcriptor terminaban únicamente en
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

/// Avisa `meeting-audio-warning` (audio del sistema: falta el permiso, o el
/// dispositivo de salida cambió a mitad de reunión) — **no termina la
/// sesión**, es sólo información. Se reporta como máximo una vez por
/// `kind` y por sesión de captura (`already_reported` lo trackea aparte por
/// tipo, ver `start_capture`): la reunión sigue grabando aunque falte el
/// permiso, así que repetir el aviso en cada sondeo del watchdog sería
/// ruido — el usuario ya lo vio la primera vez.
fn report_audio_warning<R: tauri::Runtime>(
    app_handle: Option<&AppHandle<R>>,
    meeting_id: i64,
    already_reported: &mut bool,
    kind: MeetingAudioWarningKind,
) {
    warn!(
        "Meeting {}: aviso de audio del sistema {:?}",
        meeting_id, kind
    );
    if *already_reported {
        return;
    }
    *already_reported = true;
    if let Some(app) = app_handle {
        let payload = MeetingAudioWarning { meeting_id, kind };
        if let Err(e) = payload.emit(app) {
            warn!(
                "Failed to emit meeting-audio-warning for {}: {}",
                meeting_id, e
            );
        }
    }
}

/// Cierra la captura de una sesión que no puede continuar, desde afuera del
/// hilo transcriptor.
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

/// Build the `AudioRecorder` a meeting capture session uses: same reusable
/// building blocks as dictation's `create_audio_recorder` in
/// `managers/audio.rs` (Silero VAD wrapped in `SmoothedVad`, the shared
/// `VAD_THRESHOLD`), wired to a different callback — this one feeds
/// `audio_cb`'s caller-supplied turn accumulator instead of dictation's
/// `StreamRouter` (which is a single global dictation-only route, not
/// suited to a meeting's own long-running, independently-timed session).
/// Not reusing `create_audio_recorder` itself since it's hardwired to that
/// router; reusing the primitives it's built from instead.
#[allow(dead_code)]
fn build_meeting_recorder(
    vad_path: &Path,
    audio_cb: impl Fn(&[f32]) + Send + Sync + 'static,
) -> Result<AudioRecorder> {
    let silero = SileroVad::new(vad_path, VAD_THRESHOLD)
        .map_err(|e| anyhow::anyhow!("Failed to create SileroVad for meeting capture: {}", e))?;
    let smoothed_vad = SmoothedVad::new(
        Box::new(silero),
        VAD_PREFILL_FRAMES,
        VAD_OFFLINE_HANGOVER_FRAMES,
        VAD_ONSET_FRAMES,
    );

    let recorder = AudioRecorder::new()
        .map_err(|e| anyhow::anyhow!("Failed to create AudioRecorder for meeting capture: {}", e))?
        .with_vad(
            Box::new(smoothed_vad),
            VAD_OFFLINE_HANGOVER_FRAMES,
            VAD_STREAMING_HANGOVER_FRAMES,
        )
        .with_audio_callback(audio_cb);

    Ok(recorder)
}

/// Resuelve qué fuente de audio usa REALMENTE una reunión, cruzando el
/// ajuste del usuario (`AppSettings::meeting_audio_source`) con si el audio
/// del sistema está disponible en esta máquina (`system_audio_available()`:
/// macOS 14.2+). Función pura y testeable a propósito — es la pieza que la
/// tarea de cableado pidió explícitamente poder probar sin hardware.
///
/// El micrófono nunca necesita "resolverse hacia" nada: está disponible en
/// cualquier plataforma, así que si el usuario ya lo eligió, se usa tal
/// cual. Sólo `SystemAudio` puede degradar, y sólo hacia `Microphone` — no
/// hay una tercera fuente a la que caer.
pub fn resolve_meeting_audio_source(
    setting: MeetingAudioSource,
    system_audio_available: bool,
) -> MeetingAudioSource {
    match setting {
        MeetingAudioSource::SystemAudio if !system_audio_available => {
            MeetingAudioSource::Microphone
        }
        other => other,
    }
}

/// Build the `SystemAudioRecorder` a meeting capture session uses cuando la
/// fuente resuelta es `MeetingAudioSource::SystemAudio`. Espejo de
/// `build_meeting_recorder`, con una diferencia que importa:
/// `SystemAudioRecorder` no tiene ningún VAD propio (el del micrófono vive
/// ADENTRO de `AudioRecorder` — ver `with_audio_callback` en
/// `audio_toolkit/audio/recorder.rs`), así que `with_frame_callback` entrega
/// las muestras del tap **sin filtrar**. Para que el resto del pipeline
/// (acumulador de turnos, corte por voz, diarización) reciba exactamente lo
/// mismo que hoy recibe del micrófono, este helper aplica acá el mismo VAD
/// (`SileroVad` + `SmoothedVad`, mismas constantes que `build_meeting_recorder`
/// para `VadPolicy::Offline` — la única política que usa una reunión) antes
/// de llamar a `audio_cb`.
///
/// `Mutex` en vez de un VAD por hilo: el callback es `Fn`, no `FnMut` (misma
/// restricción que `AudioRecorder::with_audio_callback`), y el VAD necesita
/// mutar su estado interno (buffer de prefill, contador de hangover) entre
/// frames — mismo patrón que `VadConfig` usa en `recorder.rs` para el
/// micrófono. Un solo hilo llama a este callback (el consumidor de
/// `SystemAudioRecorder`, ver `system_audio/macos.rs`), así que el `Mutex`
/// nunca compite de verdad; existe sólo para satisfacer el tipo.
#[allow(dead_code)]
fn build_meeting_system_audio_recorder(
    vad_path: &Path,
    audio_cb: impl Fn(&[f32]) + Send + Sync + 'static,
) -> Result<SystemAudioRecorder> {
    let silero = SileroVad::new(vad_path, VAD_THRESHOLD).map_err(|e| {
        anyhow::anyhow!(
            "Failed to create SileroVad for system-audio meeting capture: {}",
            e
        )
    })?;
    let smoothed_vad = SmoothedVad::new(
        Box::new(silero),
        VAD_PREFILL_FRAMES,
        VAD_OFFLINE_HANGOVER_FRAMES,
        VAD_ONSET_FRAMES,
    );
    let vad: Mutex<Box<dyn VoiceActivityDetector>> = Mutex::new(Box::new(smoothed_vad));

    let recorder = SystemAudioRecorder::new()
        .map_err(|e| {
            anyhow::anyhow!(
                "Failed to create SystemAudioRecorder for meeting capture: {}",
                e
            )
        })?
        .with_frame_callback(move |frame: &[f32]| {
            let mut vad = vad.lock().unwrap();
            match vad.push_frame(frame) {
                Ok(VadFrame::Speech(buf)) => audio_cb(buf),
                Ok(VadFrame::Noise) => {}
                Err(e) => {
                    // Fail open, igual que `handle_frame` en
                    // `audio_toolkit/audio/recorder.rs`
                    // (`unwrap_or(VadFrame::Speech(samples))`): preferir de
                    // más a perder audio de la reunión por un fallo puntual
                    // del VAD.
                    warn!("VAD del audio del sistema falló, se deja pasar el frame: {e}");
                    audio_cb(frame);
                }
            }
        });

    Ok(recorder)
}

/// Uno de los dos backends de audio que puede alimentar una sesión de
/// reunión — ver `resolve_meeting_audio_source`. `AudioRecorder` trae su
/// propio VAD y su propio ciclo start/stop con `VadPolicy`; `SystemAudioRecorder`
/// no tiene VAD propio (aplicado por `build_meeting_system_audio_recorder`
/// antes de llegar acá) y su `start()`/`stop()` no toman política. Esta
/// enum absorbe esa diferencia de forma para que `CaptureSession` y
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
            MeetingRecorder::Microphone(r) => r
                .start(VadPolicy::Offline)
                .map_err(|e| anyhow::anyhow!("{e}")),
            MeetingRecorder::SystemAudio(r) => r
                .lock()
                .unwrap()
                .start()
                .map_err(|e| anyhow::anyhow!("{e}")),
        }
    }

    /// Detiene la captura. El valor de retorno del backend se descarta a
    /// propósito en los dos casos — ver el comentario del módulo sobre por
    /// qué el buffer redundante de `AudioRecorder::stop()` no se usa, y el
    /// comentario de `system_audio.rs` sobre por qué `SystemAudioRecorder::
    /// stop()` sí importa (el diagnóstico de permiso vive ahí): ese
    /// diagnóstico se consulta por separado, en caliente, vía
    /// `diagnose_now()` durante la grabación — no hace falta leerlo de vuelta
    /// acá para no perderlo.
    fn stop(&self) {
        match self {
            MeetingRecorder::Microphone(r) => {
                let _ = r.stop();
            }
            MeetingRecorder::SystemAudio(r) => {
                let _ = r.lock().unwrap().stop();
            }
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

// --- T013/T014: diarización incremental + corte por voz dentro del turno --
//
// # Por qué un registro incremental y no una diarización al final
//
// `DiarizationEngine::diarize` (T009) es un pipeline offline: recibe UN
// audio completo y devuelve segmentos cuyos índices de hablante son locales
// a esa llamada — el clustering que decide "estas voces son la misma
// persona" corre sobre todos los embeddings de ese audio junto. Una reunión
// en vivo no tiene ese audio completo hasta que termina, y FR-002/FR-007
// exigen persistir cada segmento apenas se transcribe, con su hablante, no
// al final. Correr `diarize` por turno resuelve la parte local (¿cuántas
// voces hay en este turno? ¿se pisaron?) pero NO la identidad entre turnos:
// el "hablante 0" de un turno no tiene ninguna relación con el "hablante 0"
// del siguiente.
//
// La pieza que cierra esa brecha es [`SpeakerRegistry`]: por cada pieza (ver
// más abajo) se calcula un embedding de voz (`DiarizationEngine::embed`, el
// mismo vector CAM++ de 192 dims que el pipeline usa para clusterizar) y se
// compara por similitud coseno contra los centroides de los hablantes ya
// vistos EN ESTA reunión. Es la versión incremental del mismo juicio que
// hace el clustering aglomerativo de T009, por eso sus umbrales se derivan
// de `CLUSTER_THRESHOLD` en vez de ser números nuevos: el mismo par de
// voces debe agruparse igual por los dos caminos.
//
// # Corte por voz dentro de un turno (T014)
//
// Un turno (`CompletedTurn`) es sólo un tramo de audio con voz continua —
// puede tener varios hablantes adentro, sobre todo ahora que `MAX_TURN_MS`
// puede cortarlo a mitad de conversación en vez de esperar un silencio real.
// [`split_turn_into_pieces`] es la función pura que toma los
// `DiarizedSegment` que devolvió UNA llamada a `diarize` sobre el turno
// entero y los convierte en [`TurnPiece`]s: tramos disjuntos, cada uno con
// UN hablante local (o `None` cuando dos voces se pisaron demasiado para
// separarlas). [`process_turn_pieces`] hace lo mismo que antes hacía
// `attribute_turn` por turno, pero por pieza: extrae su audio
// (`extract_ranges`), calcula su embedding y lo resuelve contra
// `SpeakerRegistry`, y persiste una fila por pieza con offsets absolutos
// (`turn.started_at_ms + pieza.start_ms`).
//
// # Cómo se cumple FR-004 (marcar incierto en vez de adivinar)
//
// Hay tres caminos distintos a `speaker_id = NULL`, todos deliberados:
//
// 1. **La pieza es de voz mezclada** (`TurnPiece.speaker == None`,
//    `overlapped == true`): `split_turn_into_pieces` fusionó dos segmentos
//    de hablantes distintos que se solapaban más del 60% del más corto — no
//    hay forma de separar esa voz con un solo micrófono, así que ni se
//    calcula su embedding ni se compara contra el registro.
// 2. **Poco audio limpio** (< [`MIN_EMBED_SAMPLES`]): un embedding sobre
//    medio segundo de voz no es confiable; preferimos no atribuir.
// 3. **Similitud ambigua**: la mejor coincidencia cae en la banda de
//    incertidumbre alrededor del umbral, o hay dos hablantes conocidos casi
//    igual de parecidos (margen chico). Asignar el "menos malo" es
//    justamente lo que FR-004 prohíbe.
//
// Una pieza sin atribuir NO actualiza ningún centroide ni crea un hablante
// nuevo: un caso dudoso no debe mover la referencia contra la que se
// comparan las piezas siguientes.
//
// # Degradación honesta cuando el motor no está listo
//
// El modelo de embeddings (~27 MB) se descarga en runtime (T008) y ambos
// modelos tardan en cargar. `start_capture` dispara esa preparación en un
// hilo aparte y NO bloquea el micrófono esperándola: los turnos que
// completen antes de que el motor esté listo (o cuya diarización falle) se
// persisten enteros, en una sola fila, con `speaker_id = NULL` (incierto) —
// exactamente el comportamiento de antes de T014, ver el `if
// segments.is_empty()` en el hilo transcriptor de `start_capture`. La
// alternativa —demorar el inicio de la grabación hasta tener los modelos—
// perdería audio real de la reunión, que es peor que perder la atribución
// de los primeros segundos.

/// Sample rate que exigen tanto el modelo de segmentación como el de
/// embeddings (`DiarizationEngine::diarize` rechaza cualquier otro), y que
/// es también el que entrega `AudioRecorder` — no hace falta resamplear.
const DIARIZATION_SAMPLE_RATE: u32 = crate::audio_toolkit::constants::WHISPER_SAMPLE_RATE;

/// Similitud coseno equivalente al corte del dendrograma de T009
/// (`CLUSTER_THRESHOLD` es una DISimilitud: `1 - cos`). Los dos umbrales de
/// abajo abren una banda de incertidumbre alrededor de este punto.
const SAME_SPEAKER_SIMILARITY: f32 = 1.0 - CLUSTER_THRESHOLD;

/// Media banda de incertidumbre alrededor de [`SAME_SPEAKER_SIMILARITY`].
/// Dentro de `±UNCERTAIN_BAND` el motor no se compromete: ni asigna ni crea
/// hablante nuevo (FR-004). Fuera de esa banda se comporta exactamente como
/// el clustering de T009 con el mismo audio.
const UNCERTAIN_BAND: f32 = 0.05;

/// Por encima de esto, el turno es del hablante conocido más parecido.
const ASSIGN_MIN_SIMILARITY: f32 = SAME_SPEAKER_SIMILARITY + UNCERTAIN_BAND;

/// Por debajo de esto, el turno es de alguien que no habíamos oído: se crea
/// un hablante nuevo (FR-003 — nunca se fija un número de hablantes de
/// antemano).
const NEW_SPEAKER_MAX_SIMILARITY: f32 = SAME_SPEAKER_SIMILARITY - UNCERTAIN_BAND;

/// Ventaja mínima que el mejor candidato le tiene que sacar al segundo para
/// que la asignación cuente como confiable. Sin esto, dos personas de voz
/// parecida se roban turnos entre sí de forma alternada y el transcript
/// queda peor que sin atribuir.
const MIN_SIMILARITY_MARGIN: f32 = 0.05;

/// Mínimo de audio limpio (un solo hablante, sin superposición) que un turno
/// necesita para calcular un embedding en el que valga la pena confiar:
/// 0.5 s a 16 kHz.
const MIN_EMBED_SAMPLES: usize = 8_000;

/// Fracción del segmento más corto que dos segmentos consecutivos tienen
/// que solaparse para considerarse "la misma voz mezclada" en vez de un
/// simple empalme entre hablantes que se turnan rápido. Por encima de esto
/// no hay forma de separar limpiamente esa voz con un solo micrófono.
const OVERLAP_MERGE_RATIO: f32 = 0.6;

/// Piezas más cortas que esto se fusionan con la vecina (ver
/// `split_turn_into_pieces`): un fragmento de menos de 700ms casi nunca es
/// una frase completa, y suele ser ruido del corte entre hablantes en vez
/// de una voz real e independiente.
const MIN_PIECE_MS: u64 = 700;

/// Un tramo disjunto dentro de un turno, ya resuelto de solapes: el
/// resultado de `split_turn_into_pieces`. `speaker` es un índice local a la
/// llamada de `diarize` de ESTE turno (igual que `DiarizedSegment::speaker`)
/// — `process_turn_pieces` es quien lo traduce a un `speaker_id` de verdad
/// vía `SpeakerRegistry`.
#[derive(Debug, Clone, PartialEq)]
struct TurnPiece {
    /// Offset de inicio en milisegundos, relativo al turno (mismo sistema
    /// de coordenadas que `DiarizedSegment`).
    start_ms: u64,
    end_ms: u64,
    /// `None` = voz mezclada o sin diarización (FR-004): no se embebe ni se
    /// compara contra el registro de hablantes.
    speaker: Option<usize>,
    /// Dos hablantes se solaparon más del `OVERLAP_MERGE_RATIO` del más
    /// corto en esta pieza.
    overlapped: bool,
}

/// Corta los `DiarizedSegment`s de UN turno ya diarizado en `TurnPiece`s
/// disjuntas, una por cambio de hablante. Función pura: es la parte del
/// corte por voz que se puede testear sin cargar 34 MB de modelos ONNX.
///
/// Reglas (en este orden):
/// 1. Ordenar por `start_ms`.
/// 2. Dos segmentos consecutivos que se solapan más del
///    `OVERLAP_MERGE_RATIO` del más corto se fusionan en UNA pieza
///    `speaker: None, overlapped: true` — voz mezclada, no separable.
/// 3. Un solape menor recorta el inicio del segmento posterior al fin del
///    anterior.
/// 4. Una pieza resultante más corta que `MIN_PIECE_MS` se fusiona con la
///    anterior (o la siguiente si es la primera), conservando el hablante
///    de la pieza más larga de las dos.
/// 5. Lista vacía -> una sola pieza `[0, turn_len_ms)` sin hablante, igual
///    que el comportamiento sin diarización.
fn split_turn_into_pieces(segments: &[DiarizedSegment], turn_len_ms: u64) -> Vec<TurnPiece> {
    if segments.is_empty() {
        return vec![TurnPiece {
            start_ms: 0,
            end_ms: turn_len_ms,
            speaker: None,
            overlapped: false,
        }];
    }

    let mut sorted: Vec<&DiarizedSegment> = segments.iter().collect();
    sorted.sort_by_key(|s| s.start_ms);

    let mut pieces: Vec<TurnPiece> = Vec::with_capacity(sorted.len());
    for seg in sorted {
        if seg.end_ms <= seg.start_ms {
            continue; // segmento degenerado (duración cero o negativa): se ignora
        }
        let mut piece = TurnPiece {
            start_ms: seg.start_ms,
            end_ms: seg.end_ms,
            speaker: Some(seg.speaker),
            overlapped: seg.overlapped,
        };

        if let Some(prev) = pieces.last_mut() {
            if piece.start_ms < prev.end_ms {
                let overlap_len = prev.end_ms.min(piece.end_ms).saturating_sub(piece.start_ms);
                let shorter_len = (prev.end_ms - prev.start_ms).min(piece.end_ms - piece.start_ms);
                if shorter_len > 0 && overlap_len as f32 > OVERLAP_MERGE_RATIO * shorter_len as f32
                {
                    // Solape mayor: una sola voz mezclada, no separable.
                    prev.end_ms = prev.end_ms.max(piece.end_ms);
                    prev.speaker = None;
                    prev.overlapped = true;
                    continue;
                }
                // Solape menor: el posterior cede el tramo pisado.
                piece.start_ms = prev.end_ms;
                if piece.start_ms >= piece.end_ms {
                    continue; // el recorte lo dejó vacío
                }
            }
        }
        pieces.push(piece);
    }

    if pieces.is_empty() {
        return vec![TurnPiece {
            start_ms: 0,
            end_ms: turn_len_ms,
            speaker: None,
            overlapped: false,
        }];
    }

    merge_tiny_pieces(pieces)
}

/// Combina `b` dentro de `a`: extiende el rango, conserva el hablante de la
/// pieza más larga de las dos y propaga `overlapped`. Usado tanto para
/// fusionar solapes grandes como piezas diminutas.
fn merge_piece_into(a: &mut TurnPiece, b: &TurnPiece) {
    let a_len = a.end_ms.saturating_sub(a.start_ms);
    let b_len = b.end_ms.saturating_sub(b.start_ms);
    a.start_ms = a.start_ms.min(b.start_ms);
    a.end_ms = a.end_ms.max(b.end_ms);
    if b_len > a_len {
        a.speaker = b.speaker;
    }
    a.overlapped = a.overlapped || b.overlapped;
}

/// Fusiona piezas más cortas que `MIN_PIECE_MS` con su vecina — la anterior
/// normalmente, o la siguiente si la diminuta es la primera de la lista (no
/// hay anterior con la que fusionarla).
fn merge_tiny_pieces(pieces: Vec<TurnPiece>) -> Vec<TurnPiece> {
    if pieces.len() <= 1 {
        return pieces;
    }

    let mut result: Vec<TurnPiece> = Vec::with_capacity(pieces.len());
    for piece in pieces {
        let len = piece.end_ms.saturating_sub(piece.start_ms);
        if len < MIN_PIECE_MS && !result.is_empty() {
            let prev = result.last_mut().expect("checked not empty above");
            merge_piece_into(prev, &piece);
        } else {
            result.push(piece);
        }
    }

    // La primera pieza no tuvo anterior con la que fusionarse arriba: si
    // sigue siendo diminuta, se funde hacia adelante con la que le sigue.
    if result.len() > 1 {
        let first_len = result[0].end_ms.saturating_sub(result[0].start_ms);
        if first_len < MIN_PIECE_MS {
            let first = result.remove(0);
            merge_piece_into(&mut result[0], &first);
        }
    }

    result
}

/// Recorta y concatena los `ranges` (en ms) del audio de un turno. Los
/// rangos que caen fuera del audio se ignoran en vez de entrar en pánico:
/// `diarize` trabaja con frames redondeados, así que el último rango puede
/// terminar unos milisegundos después del final real del buffer.
fn extract_ranges(samples: &[f32], ranges: &[(u64, u64)], sample_rate: u32) -> Vec<f32> {
    let mut out = Vec::new();
    for &(start_ms, end_ms) in ranges {
        let start = (start_ms as usize * sample_rate as usize) / 1000;
        let end = (end_ms as usize * sample_rate as usize) / 1000;
        let start = start.min(samples.len());
        let end = end.min(samples.len());
        if end > start {
            out.extend_from_slice(&samples[start..end]);
        }
    }
    out
}

/// Calcula el embedding de voz de UNA pieza ya extraída (un solo hablante,
/// sin superposición) si hay audio suficiente para confiar en él. `None` es
/// "incierto" (FR-004), ya sea por poco audio o porque el motor falló.
///
/// Nunca devuelve error: una falla acá degrada a "pieza sin hablante", que
/// es un transcript peor pero correcto, mientras que propagar el error
/// perdería la pieza entera (el texto ya transcrito) por un problema de
/// atribución.
fn embed_piece(engine: &DiarizationEngine, samples: &[f32]) -> Option<Vec<f32>> {
    if samples.len() < MIN_EMBED_SAMPLES {
        debug!(
            "Pieza con sólo {} samples: muy poco audio para un embedding confiable",
            samples.len()
        );
        return None;
    }
    match engine.embed(samples, DIARIZATION_SAMPLE_RATE) {
        Ok(embedding) => Some(embedding),
        Err(e) => {
            warn!("Embedding de una pieza falló, queda sin atribuir: {}", e);
            None
        }
    }
}

/// Qué decidió el registro sobre un embedding de turno.
#[derive(Debug, PartialEq)]
enum SpeakerMatch {
    /// Índice dentro de `SpeakerRegistry::entries` (no el id de la base).
    Existing(usize),
    New,
    Uncertain,
}

struct SpeakerEntry {
    /// `meeting_speakers.id`.
    id: i64,
    /// Media de los embeddings normalizados atribuidos a este hablante.
    centroid: Vec<f32>,
    turns: u32,
}

/// Los hablantes vistos hasta ahora EN ESTA reunión, con su centroide de voz.
/// Vive en el hilo transcriptor de una sesión de captura: un hablante es
/// local a una reunión (`data-model.md`), no una identidad de voz persistente
/// entre reuniones.
#[derive(Default)]
struct SpeakerRegistry {
    entries: Vec<SpeakerEntry>,
}

impl SpeakerRegistry {
    /// Decisión pura (sin base de datos) sobre un embedding: hablante
    /// conocido, hablante nuevo, o incierto.
    fn classify(&self, embedding: &[f32]) -> SpeakerMatch {
        if self.entries.is_empty() {
            return SpeakerMatch::New;
        }

        let mut sims: Vec<(usize, f32)> = self
            .entries
            .iter()
            .enumerate()
            .map(|(i, e)| (i, cosine_similarity(embedding, &e.centroid)))
            .collect();
        sims.sort_by(|a, b| b.1.total_cmp(&a.1));

        let (best_index, best) = sims[0];
        let runner_up = sims.get(1).map(|(_, s)| *s).unwrap_or(f32::NEG_INFINITY);

        if best >= ASSIGN_MIN_SIMILARITY {
            if best - runner_up < MIN_SIMILARITY_MARGIN {
                // Dos hablantes conocidos casi igual de parecidos: asignar
                // al mejor por una diferencia despreciable es adivinar.
                return SpeakerMatch::Uncertain;
            }
            return SpeakerMatch::Existing(best_index);
        }

        if best <= NEW_SPEAKER_MAX_SIMILARITY {
            return SpeakerMatch::New;
        }

        SpeakerMatch::Uncertain
    }

    /// Actualiza el centroide de un hablante con un turno nuevo (media
    /// corrida sobre embeddings normalizados, para que un turno largo no
    /// pese más que uno corto sólo por magnitud).
    fn reinforce(&mut self, index: usize, embedding: &[f32]) {
        let entry = &mut self.entries[index];
        let normalized = l2_normalize(embedding);
        if normalized.len() != entry.centroid.len() {
            return;
        }
        let n = entry.turns as f32;
        for (c, v) in entry.centroid.iter_mut().zip(&normalized) {
            *c = (*c * n + v) / (n + 1.0);
        }
        entry.turns += 1;
    }

    /// Resuelve el `speaker_id` que le corresponde a un turno y persiste el
    /// hablante nuevo cuando hace falta. `None` = incierto (FR-004).
    fn resolve(
        &mut self,
        conn: &Connection,
        meeting_id: i64,
        embedding: Option<&[f32]>,
    ) -> Result<Option<i64>> {
        let Some(embedding) = embedding else {
            return Ok(None);
        };

        match self.classify(embedding) {
            SpeakerMatch::Existing(index) => {
                self.reinforce(index, embedding);
                Ok(Some(self.entries[index].id))
            }
            SpeakerMatch::New => {
                let id = insert_speaker(conn, meeting_id)?;
                self.entries.push(SpeakerEntry {
                    id,
                    centroid: l2_normalize(embedding),
                    turns: 1,
                });
                Ok(Some(id))
            }
            SpeakerMatch::Uncertain => Ok(None),
        }
    }
}

fn l2_normalize(v: &[f32]) -> Vec<f32> {
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm == 0.0 {
        return v.to_vec();
    }
    v.iter().map(|x| x / norm).collect()
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

/// Procesa UN turno ya diarizado: lo corta en [`TurnPiece`]s
/// (`split_turn_into_pieces`) y persiste una fila por pieza, con offsets
/// absolutos (`turn.started_at_ms + pieza.start_ms`). Es el reemplazo de
/// T014 a "un turno, un segmento" — la contraparte de
/// `persist_and_emit_segment` a nivel de turno completo.
///
/// `embed` y `transcribe` están inyectados por la misma razón: poder
/// testear el flujo completo de piezas sin cargar los ~34 MB de modelos
/// ONNX de diarización ni un motor de transcripción real. Sólo se llama a
/// `embed` para piezas con hablante local conocido (`piece.speaker.is_some()`)
/// — las piezas `None` (mezcla/superposición) NO se embeben ni tocan el
/// registro (FR-004, vigente).
///
/// Llamar sólo cuando `segments` no está vacío: con `segments` vacío
/// (motor no cargado o `diarize` falló) el llamador debe seguir usando
/// `persist_and_emit_segment` directo sobre el turno entero, que es el
/// comportamiento anterior a T014 exacto (ver `start_capture`).
///
/// Devuelve un resultado por pieza, en orden, para que el llamador decida
/// cómo reportar cada fallo (mismo criterio por turno que ya usa
/// `start_capture`: una pieza perdida no debe tumbar las siguientes).
#[allow(dead_code, clippy::too_many_arguments)]
fn process_turn_pieces<R: tauri::Runtime>(
    conn: &Connection,
    app_handle: Option<&AppHandle<R>>,
    meeting_id: i64,
    turn: &CompletedTurn,
    segments: &[DiarizedSegment],
    registry: &mut SpeakerRegistry,
    embed: &dyn Fn(&[f32]) -> Option<Vec<f32>>,
    transcribe: &dyn Fn(Vec<f32>) -> Result<String>,
) -> Vec<Result<Option<MeetingSegment>>> {
    // Mismo sistema de coordenadas que los `DiarizedSegment`: ambos se
    // miden sobre `turn.samples` a `DIARIZATION_SAMPLE_RATE`, no sobre el
    // reloj de pared que cerró el turno.
    let turn_len_ms = (turn.samples.len() as u64 * 1000) / DIARIZATION_SAMPLE_RATE as u64;
    let pieces = split_turn_into_pieces(segments, turn_len_ms);

    let mut results = Vec::with_capacity(pieces.len());
    for piece in pieces {
        let piece_samples = extract_ranges(
            &turn.samples,
            &[(piece.start_ms, piece.end_ms)],
            DIARIZATION_SAMPLE_RATE,
        );

        let embedding = if piece.speaker.is_some() {
            embed(&piece_samples)
        } else {
            None
        };
        let speaker_id = match registry.resolve(conn, meeting_id, embedding.as_deref()) {
            Ok(id) => id,
            Err(e) => {
                warn!(
                    "Meeting {}: no se pudo resolver el hablante de una pieza, queda sin \
                     atribuir: {}",
                    meeting_id, e
                );
                None
            }
        };

        let piece_turn = CompletedTurn {
            samples: piece_samples,
            started_at_ms: turn.started_at_ms + piece.start_ms as i64,
            ended_at_ms: turn.started_at_ms + piece.end_ms as i64,
        };
        let piece_audio_ms = piece_turn.ended_at_ms - piece_turn.started_at_ms;
        let started = Instant::now();
        let result = persist_and_emit_segment(
            conn,
            app_handle,
            meeting_id,
            piece_turn,
            speaker_id,
            piece.overlapped,
            transcribe,
        );
        if let Ok(Some(_)) = &result {
            debug!(
                "Meeting {}: pieza de {} ms transcrita en {:?}",
                meeting_id,
                piece_audio_ms,
                started.elapsed()
            );
        }
        results.push(result);
    }

    results
}

/// Transcribe one completed turn, insert it into `meeting_segments`, and
/// (when `app_handle` is given) emit `meeting-segment`. `speaker_id` comes
/// from T013's [`SpeakerRegistry::resolve`] — `None` means "uncertain"
/// (FR-004), not "not implemented".
///
/// `transcribe` is injected so this whole persist+emit path is testable
/// without a loaded ML model: production passes a closure around
/// `TranscriptionManager::transcribe`, tests pass a stub. Most tests pass
/// `None` for `app_handle`, which skips the Tauri emit and asserts against
/// the returned segment (or the DB row) instead.
///
/// Generic over the Tauri runtime (`R`) purely so the emission itself can be
/// tested: production always instantiates it with `Wry`, while T014's test
/// drives it with `tauri::test::mock_app`'s `MockRuntime` — a real
/// `AppHandle<Wry>` needs an event loop and a window, so without this the
/// "does the event actually reach the frontend bus" question could only be
/// answered by hand. This is the generalization Tauri's own testing docs
/// recommend for exactly this reason.
///
/// Returns `Ok(None)` when the transcription came back empty (silence/noise
/// the VAD let through) — nothing is persisted or emitted for it.
#[allow(dead_code)]
fn persist_and_emit_segment<R: tauri::Runtime>(
    conn: &Connection,
    app_handle: Option<&AppHandle<R>>,
    meeting_id: i64,
    turn: CompletedTurn,
    speaker_id: Option<i64>,
    overlapped: bool,
    transcribe: &dyn Fn(Vec<f32>) -> Result<String>,
) -> Result<Option<MeetingSegment>> {
    let mut samples = turn.samples;
    if !samples.is_empty() && samples.len() < MIN_TURN_SAMPLES {
        samples.resize(MIN_TURN_SAMPLES * 5 / 4, 0.0);
    }

    let text = transcribe(samples)?;
    if text.trim().is_empty() {
        debug!(
            "Meeting {}: turn [{}, {}]ms produced empty transcription, skipping",
            meeting_id, turn.started_at_ms, turn.ended_at_ms
        );
        return Ok(None);
    }

    conn.execute(
        "INSERT INTO meeting_segments (meeting_id, speaker_id, text, started_at_ms, ended_at_ms, overlapped) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            meeting_id,
            speaker_id,
            text,
            turn.started_at_ms,
            turn.ended_at_ms,
            overlapped
        ],
    )?;
    let id = conn.last_insert_rowid();

    let segment = MeetingSegment {
        id,
        speaker_id,
        text,
        started_at_ms: turn.started_at_ms,
        ended_at_ms: turn.ended_at_ms,
        overlapped,
    };

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
#[allow(dead_code)]
struct CaptureSession {
    meeting_id: i64,
    recorder: MeetingRecorder,
    accumulator: Arc<Mutex<TurnAccumulator>>,
    capture_started: Instant,
    shutdown: Arc<AtomicBool>,
    watchdog_handle: Option<thread::JoinHandle<()>>,
    transcriber_handle: Option<thread::JoinHandle<()>>,
    /// Held so `stop_capture` can push one final flushed turn before
    /// dropping every sender (this one plus the watchdog thread's own
    /// clone), which closes the channel and lets the transcriber thread's
    /// `recv()` loop exit after draining it.
    final_turn_tx: Option<mpsc::Sender<CompletedTurn>>,
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
    /// Motor de diarización compartido con el estado de Tauri (T007/T009).
    /// Se carga perezosamente en el primer `start_capture` (T013) — el `Arc`
    /// existe desde el arranque de la app, pero sin modelos adentro.
    diarization_engine: Option<Arc<DiarizationEngine>>,
    /// Mismo directorio de modelos que usa `ModelManager`: es donde vive (o
    /// se descarga) el modelo de embeddings de hablante.
    models_dir: Option<PathBuf>,
    #[allow(dead_code)]
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
            diarization_engine: None,
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
        diarization_engine: Arc<DiarizationEngine>,
        models_dir: PathBuf,
    ) -> Self {
        self.app_handle = Some(app_handle);
        self.transcription_manager = Some(transcription_manager);
        self.mic_arbiter = Some(mic_arbiter);
        self.diarization_engine = Some(diarization_engine);
        self.models_dir = Some(models_dir);
        self
    }

    /// Deja los modelos de diarización listos en un hilo aparte: descarga el
    /// de embeddings si falta (~27 MB, una sola vez en la vida del equipo) y
    /// carga ambos en el motor compartido. No bloquea el arranque de la
    /// grabación — ver la nota de "degradación honesta" en la sección T013.
    fn spawn_diarization_warmup(&self, app_handle: &AppHandle) {
        let (Some(engine), Some(models_dir)) =
            (self.diarization_engine.clone(), self.models_dir.clone())
        else {
            return;
        };
        if engine.is_loaded() {
            return;
        }

        let segmentation_path = match app_handle.path().resolve(
            format!(
                "resources/models/{}",
                diarization_models::SEGMENTATION_MODEL_FILENAME
            ),
            tauri::path::BaseDirectory::Resource,
        ) {
            Ok(p) => p,
            Err(e) => {
                warn!(
                    "No se pudo resolver el modelo de segmentación; la reunión quedará sin \
                     hablantes: {}",
                    e
                );
                return;
            }
        };

        tauri::async_runtime::spawn(async move {
            let embedding_path =
                match diarization_models::ensure_embedding_model_downloaded(&models_dir).await {
                    Ok(p) => p,
                    Err(e) => {
                        warn!(
                            "No se pudo obtener el modelo de embeddings de hablante; la reunión \
                             quedará sin hablantes: {}",
                            e
                        );
                        return;
                    }
                };

            // Cargar ~34 MB de sesiones ONNX es trabajo bloqueante: fuera
            // del executor async, como hace el resto del código con las
            // operaciones pesadas de modelo.
            let _ = tauri::async_runtime::spawn_blocking(move || {
                match engine.ensure_loaded(&segmentation_path, &embedding_path) {
                    Ok(()) => info!("Motor de diarización listo para la reunión en curso"),
                    Err(e) => warn!(
                        "No se pudieron cargar los modelos de diarización; la reunión quedará \
                         sin hablantes: {}",
                        e
                    ),
                }
            })
            .await;
        });
    }

    /// Start capturing audio for `meeting_id` (a row already created by
    /// [`Self::start_meeting`]): opens the microphone, applies the Silero
    /// VAD to detect speech turns, and transcribes+persists+emits each turn
    /// as it completes (see [`persist_and_emit_segment`]). Runs until
    /// [`Self::stop_capture`] is called — meetings run for hours, not the
    /// seconds a dictation recording does, so this spawns its own long-lived
    /// watchdog + transcriber threads rather than reusing dictation's
    /// keypress-driven start/stop.
    ///
    /// Fails if a capture is already active, if this manager wasn't
    /// configured via [`Self::with_capture_deps`], or if the microphone is
    /// currently held by a dictation recording (see the coexistence note
    /// above `CompletedTurn`).
    ///
    /// Not called from a Tauri command yet — that's a future task's job
    /// (see the brief's explicit scope note); exercised directly by this
    /// module's tests today.
    #[allow(dead_code)]
    pub fn start_capture(&self, meeting_id: i64) -> Result<()> {
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

        // Kick off the ASR model load now (non-blocking, idempotent if
        // already loaded/loading) rather than waiting for the first
        // completed turn to discover it isn't ready. Mirrors how dictation
        // kicks this off in parallel with opening the mic (`actions.rs`) —
        // by the time a turn actually finishes (seconds into the meeting),
        // the model has almost always finished loading.
        transcription_manager.initiate_model_load();

        let mut capture_guard = self.capture.lock().unwrap();
        if capture_guard.is_some() {
            bail!("meeting_capture_already_active");
        }

        mic_arbiter
            .try_acquire(MicOwner::Meeting)
            .map_err(|owner| {
                anyhow::anyhow!(
                    "El micrófono está en uso por {} ahora mismo.",
                    owner.label()
                )
            })?;

        let start_result = (|| -> Result<CaptureSession> {
            let vad_path = app_handle
                .path()
                .resolve(
                    "resources/models/silero_vad_v4.onnx",
                    tauri::path::BaseDirectory::Resource,
                )
                .map_err(|e| anyhow::anyhow!("Failed to resolve VAD path: {}", e))?;

            let accumulator = Arc::new(Mutex::new(TurnAccumulator::default()));
            let capture_started = Instant::now();
            let (turn_tx, turn_rx) = mpsc::channel::<CompletedTurn>();
            // Profundidad de la cola de turnos pendientes de transcribir,
            // sólo para poder avisarlo (ver `QUEUE_DEPTH_WARN_THRESHOLD`).
            let queue_depth = Arc::new(AtomicUsize::new(0));

            let audio_cb = {
                let accumulator = Arc::clone(&accumulator);
                move |frame: &[f32]| {
                    let now_ms = capture_started.elapsed().as_millis() as i64;
                    accumulator.lock().unwrap().push_speech(frame, now_ms);
                }
            };

            // Fuente de audio resuelta contra el ajuste del usuario y si el
            // audio del sistema está disponible en esta máquina — ver
            // `resolve_meeting_audio_source`.
            let audio_source = resolve_meeting_audio_source(
                settings::get_settings(&app_handle).meeting_audio_source,
                system_audio_available(),
            );

            let mut recorder = match audio_source {
                MeetingAudioSource::Microphone => {
                    MeetingRecorder::Microphone(build_meeting_recorder(&vad_path, audio_cb)?)
                }
                MeetingAudioSource::SystemAudio => MeetingRecorder::SystemAudio(Arc::new(
                    Mutex::new(build_meeting_system_audio_recorder(&vad_path, audio_cb)?),
                )),
            };
            // El micrófono elegido en Ajustes sólo aplica a esa rama: la
            // reunión tiene su propio `AudioRecorder`, así que sin esto
            // abría el default del sistema e ignoraba el ajuste en
            // silencio. El audio del sistema no toma dispositivo de
            // entrada — un tap global captura todo lo que suena en el
            // equipo, no lo que entra por un micrófono en particular.
            let selected_device = match audio_source {
                MeetingAudioSource::Microphone => app_handle
                    .try_state::<Arc<AudioRecordingManager>>()
                    .and_then(|manager| manager.selected_input_device()),
                MeetingAudioSource::SystemAudio => None,
            };
            recorder
                .open(selected_device)
                .map_err(|e| anyhow::anyhow!("Failed to open audio capture for meeting: {}", e))?;
            if let Err(e) = recorder.start() {
                recorder.close();
                bail!("Failed to start meeting capture: {}", e);
            }

            // Referencia propia para que el watchdog pueda sondear el
            // diagnóstico de permiso/dispositivo de salida (I6/I5 de
            // `system_audio.rs`) sin disputarle la dueñidad de la sesión a
            // `CaptureSession` — ver el comentario de `MeetingRecorder`.
            // `None` para micrófono: no hay nada que sondear ahí, el
            // micrófono falla con un error explícito de permiso al abrir en
            // vez de en silencio.
            let audio_diagnostics_handle = match &recorder {
                MeetingRecorder::SystemAudio(r) => Some(Arc::clone(r)),
                MeetingRecorder::Microphone(_) => None,
            };

            let shutdown = Arc::new(AtomicBool::new(false));

            let watchdog_handle = {
                let accumulator = Arc::clone(&accumulator);
                let shutdown = Arc::clone(&shutdown);
                let turn_tx = turn_tx.clone();
                let transcription_manager = Arc::clone(&transcription_manager);
                let queue_depth = Arc::clone(&queue_depth);
                let app_handle = app_handle.clone();
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
                    let mut permission_warning_reported = false;
                    let mut output_device_warning_reported = false;

                    while !shutdown.load(Ordering::Relaxed) {
                        thread::sleep(WATCHDOG_POLL_INTERVAL);
                        // Mantener vivo el reloj de inactividad del modelo:
                        // el watcher de `TranscriptionManager` sólo mira el
                        // dictado, y un tramo callado de la reunión (una
                        // pausa, un break) le parece inactividad. Si descarga
                        // el modelo, todos los turnos siguientes fallan.
                        transcription_manager.touch_activity();
                        let now_ms = capture_started.elapsed().as_millis() as i64;
                        // Tope duro primero: en conversación continua nunca
                        // hay silencio, así que `take_if_silent` solo no
                        // basta para cerrar el turno (ver MAX_TURN_MS).
                        let completed = {
                            let mut acc = accumulator.lock().unwrap();
                            acc.take_if_over(MAX_TURN_MS, now_ms)
                                .or_else(|| acc.take_if_silent(TURN_SILENCE_GAP, now_ms))
                        };
                        if let Some(turn) = completed {
                            let depth = queue_depth.fetch_add(1, Ordering::Relaxed) + 1;
                            if depth == QUEUE_DEPTH_WARN_THRESHOLD {
                                warn!(
                                    "Meeting {}: {} turnos esperando transcripción — transcribir \
                                     va más lento que hablar y el audio pendiente se acumula en \
                                     memoria",
                                    meeting_id, depth
                                );
                            }
                            let _ = turn_tx.send(turn);
                        }

                        if let Some(sa) = &audio_diagnostics_handle {
                            if last_diagnosis_poll.elapsed() >= SYSTEM_AUDIO_DIAGNOSIS_POLL {
                                last_diagnosis_poll = Instant::now();
                                let sa = sa.lock().unwrap();
                                if sa.diagnose_now() == CaptureDiagnosis::LikelyMissingPermission {
                                    report_audio_warning(
                                        Some(&app_handle),
                                        meeting_id,
                                        &mut permission_warning_reported,
                                        MeetingAudioWarningKind::MissingPermission,
                                    );
                                }
                                if sa.output_device_changed() {
                                    report_audio_warning(
                                        Some(&app_handle),
                                        meeting_id,
                                        &mut output_device_warning_reported,
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

            let transcriber_handle = {
                let db_path = self.db_path.clone();
                let app_handle = app_handle.clone();
                let transcription_manager = Arc::clone(&transcription_manager);
                let diarization_engine = self.diarization_engine.clone();
                let queue_depth = Arc::clone(&queue_depth);
                thread::spawn(move || {
                    // Un solo aviso de turno perdido por sesión de captura,
                    // ver `report_turn_failure`.
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
                                    "no se pudo abrir la base de datos para transcribir la \
                                     reunión, no se va a guardar nada de lo que se hable: {e}"
                                ),
                            );
                            spawn_capture_abort(&app_handle, meeting_id);
                            return;
                        }
                    };
                    // El registro de hablantes vive acá, en el único hilo que
                    // atribuye segmentos de esta sesión: sin locks, y sin
                    // sobrevivir a la sesión (un hablante es local a una
                    // reunión, `data-model.md`).
                    let mut registry = SpeakerRegistry::default();
                    while let Ok(turn) = turn_rx.recv() {
                        // `fetch_update` y no `fetch_sub`: el turno final que
                        // empuja `stop_capture` no pasó por el watchdog y no
                        // sumó, así que restar a ciegas daría la vuelta el
                        // contador sin signo.
                        let _ = queue_depth.fetch_update(
                            Ordering::Relaxed,
                            Ordering::Relaxed,
                            |depth| depth.checked_sub(1),
                        );

                        // Si el modelo se descargó mientras la reunión seguía
                        // (watcher de inactividad, cambio de modelo), este
                        // turno/pieza lo recarga y se reintenta una vez en vez
                        // de perderse — y con él todos los que vinieran atrás.
                        let transcribe = |samples: Vec<f32>| {
                            transcribe_with_reload(
                                samples,
                                &|s| transcription_manager.transcribe(s),
                                &|| {
                                    transcription_manager.initiate_model_load();
                                    transcription_manager.wait_for_model_load();
                                },
                            )
                        };

                        // Diarizar ANTES de transcribir: `persist_and_emit_segment`
                        // consume el audio (y le agrega padding a los turnos
                        // cortos, que falsearía la duración del audio que ve
                        // el motor de diarización).
                        let segments: Vec<DiarizedSegment> = match diarization_engine.as_deref() {
                            Some(engine) if engine.is_loaded() => {
                                match engine.diarize(&turn.samples, DIARIZATION_SAMPLE_RATE) {
                                    Ok(segs) => segs,
                                    Err(e) => {
                                        warn!(
                                            "Meeting {}: diarización del turno falló, se \
                                             transcribe entero sin hablante: {}",
                                            meeting_id, e
                                        );
                                        Vec::new()
                                    }
                                }
                            }
                            // Motor todavía cargando (o no disponible).
                            _ => Vec::new(),
                        };

                        if segments.is_empty() {
                            // Sin diarización disponible: comportamiento
                            // anterior a T014 exacto, un solo segmento para
                            // todo el turno, sin hablante.
                            if let Err(e) = persist_and_emit_segment(
                                &conn,
                                Some(&app_handle),
                                meeting_id,
                                turn,
                                None,
                                false,
                                &transcribe,
                            ) {
                                // Se perdió ESTE turno, no la reunión: la
                                // captura sigue abierta y detenible. Por eso
                                // el aviso es `meeting-turn-failed` y no
                                // `meeting-error`, que el frontend lee como
                                // fin de sesión.
                                report_turn_failure(
                                    Some(&app_handle),
                                    meeting_id,
                                    &mut turn_failure_reported,
                                    format!("no se pudo guardar un segmento transcrito: {e}"),
                                );
                            }
                            continue;
                        }

                        // Corte por voz: una fila por pieza, con offsets
                        // absolutos. `segments` no vacío implica que el
                        // motor de diarización está cargado (única rama de
                        // arriba que lo llena).
                        let engine = diarization_engine
                            .as_deref()
                            .expect("segments no vacíos implica motor de diarización cargado");
                        let embed = |samples: &[f32]| embed_piece(engine, samples);
                        let piece_results = process_turn_pieces(
                            &conn,
                            Some(&app_handle),
                            meeting_id,
                            &turn,
                            &segments,
                            &mut registry,
                            &embed,
                            &transcribe,
                        );
                        for result in piece_results {
                            if let Err(e) = result {
                                report_turn_failure(
                                    Some(&app_handle),
                                    meeting_id,
                                    &mut turn_failure_reported,
                                    format!("no se pudo guardar una pieza transcrita: {e}"),
                                );
                            }
                        }
                    }
                })
            };

            Ok(CaptureSession {
                meeting_id,
                recorder,
                accumulator,
                capture_started,
                shutdown,
                watchdog_handle: Some(watchdog_handle),
                transcriber_handle: Some(transcriber_handle),
                final_turn_tx: Some(turn_tx),
            })
        })();

        match start_result {
            Ok(session) => {
                // Recién con el micrófono ya abierto: preparar los modelos de
                // diarización nunca debe demorar el inicio de la grabación.
                self.spawn_diarization_warmup(&app_handle);
                // Que nadie descargue el modelo mientras dure la reunión:
                // con "Descargar de inmediato" se descargaba después de cada
                // turno y el siguiente fallaba.
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
    /// microphone, flush any trailing partial turn (capture can stop
    /// mid-speech), join the watchdog/transcriber threads, and release the
    /// microphone arbiter. Idempotent-ish: fails with an error (not a
    /// panic) if no capture is active, which is fine for callers to log and
    /// ignore.
    ///
    /// This is the internal method the future `stop_meeting` Tauri command
    /// (T015) calls before it transitions `meetings.status` to
    /// `processing`/kicks off summary generation — this task does not
    /// implement that command itself.
    #[allow(dead_code)]
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
        // any trailing buffered audio, so the accumulator sees it before we
        // flush below. Its own return value is redundant with what we
        // already collected via the callback (see the module doc comment)
        // and is discarded.
        session.recorder.stop();

        let now_ms = session.capture_started.elapsed().as_millis() as i64;
        if let Some(turn) = session.accumulator.lock().unwrap().take_remaining(now_ms) {
            if let Some(tx) = &session.final_turn_tx {
                let _ = tx.send(turn);
            }
        }
        // Drop every sender: this one plus the watchdog thread's clone
        // (dropped when it's joined below) — once both are gone, the
        // transcriber thread's `recv()` returns `Err` after draining
        // whatever's still queued, and its loop exits.
        session.final_turn_tx = None;

        session.shutdown.store(true, Ordering::Relaxed);
        if let Some(h) = session.watchdog_handle.take() {
            let _ = h.join();
        }
        if let Some(h) = session.transcriber_handle.take() {
            let _ = h.join();
        }

        session.recorder.close();

        // Recién acá, con los hilos ya unidos: mientras se drenaba la cola
        // los turnos pendientes todavía necesitaban el modelo cargado.
        if let Some(tm) = &self.transcription_manager {
            tm.set_meeting_capture_active(false);
        }
        if let Some(app) = &self.app_handle {
            crate::tray::set_meeting_recording(app, false);
        }

        if let Some(arbiter) = &self.mic_arbiter {
            arbiter.release(MicOwner::Meeting);
        }

        info!("Meeting {} capture stopped", session.meeting_id);
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
    /// reunión sigue grabando, el registro de hablantes en memoria (T013)
    /// conserva el centroide del hablante fusionado y va a seguir atribuyéndole
    /// turnos nuevos — que se resuelven solos al destino, sin que la fusión
    /// tenga que comunicarse con el hilo transcriptor.
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
    use std::collections::HashMap;
    use tauri::Listener;

    /// `None` con runtime explícito: `persist_and_emit_segment` es genérica
    /// sobre el runtime de Tauri (ver su doc comment), así que los tests que
    /// no verifican la emisión tienen que decir de qué runtime hablan.
    const NO_APP: Option<&AppHandle> = None;

    // ---------- resolve_meeting_audio_source (cableado de audio) ----------

    #[test]
    fn resuelve_audio_de_sistema_cuando_esta_disponible() {
        assert_eq!(
            resolve_meeting_audio_source(MeetingAudioSource::SystemAudio, true),
            MeetingAudioSource::SystemAudio
        );
    }

    #[test]
    fn degrada_a_microfono_cuando_el_audio_de_sistema_no_esta_disponible() {
        assert_eq!(
            resolve_meeting_audio_source(MeetingAudioSource::SystemAudio, false),
            MeetingAudioSource::Microphone
        );
    }

    #[test]
    fn microfono_elegido_a_mano_nunca_cambia_aunque_el_audio_de_sistema_este_disponible() {
        assert_eq!(
            resolve_meeting_audio_source(MeetingAudioSource::Microphone, true),
            MeetingAudioSource::Microphone
        );
    }

    #[test]
    fn microfono_elegido_a_mano_se_mantiene_sin_audio_de_sistema_disponible() {
        assert_eq!(
            resolve_meeting_audio_source(MeetingAudioSource::Microphone, false),
            MeetingAudioSource::Microphone
        );
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
    // T012: TurnAccumulator — pure, deterministic, no VAD/model needed.
    // ------------------------------------------------------------------

    #[test]
    fn turn_accumulator_groups_contiguous_pushes_into_one_turn() {
        let mut acc = TurnAccumulator::default();
        assert!(
            acc.take_remaining(1000).is_none(),
            "nothing buffered yet -> no turn"
        );

        acc.push_speech(&[0.1, 0.2], 100);
        acc.push_speech(&[0.3], 150);

        let turn = acc
            .take_remaining(200)
            .expect("a turn should be in progress");
        assert_eq!(turn.samples, vec![0.1, 0.2, 0.3]);
        assert_eq!(turn.started_at_ms, 100);
        assert_eq!(turn.ended_at_ms, 200);

        assert!(
            acc.take_remaining(300).is_none(),
            "the turn was already taken; nothing should remain"
        );
    }

    #[test]
    fn turn_accumulator_starts_a_fresh_turn_after_take() {
        let mut acc = TurnAccumulator::default();
        acc.push_speech(&[1.0], 0);
        let first = acc.take_remaining(50).expect("first turn");
        assert_eq!(first.started_at_ms, 0);
        assert_eq!(first.samples, vec![1.0]);

        acc.push_speech(&[2.0], 500);
        let second = acc.take_remaining(550).expect("second turn");
        assert_eq!(second.started_at_ms, 500);
        assert_eq!(second.samples, vec![2.0]);
    }

    #[test]
    fn turn_accumulator_take_if_silent_waits_for_the_gap() {
        let mut acc = TurnAccumulator::default();
        acc.push_speech(&[1.0], 0);

        assert!(
            acc.take_if_silent(Duration::from_secs(5), 10).is_none(),
            "gap has not elapsed yet"
        );

        std::thread::sleep(Duration::from_millis(30));

        let turn = acc
            .take_if_silent(Duration::from_millis(5), 40)
            .expect("gap has elapsed; the turn should finalize");
        assert_eq!(turn.samples, vec![1.0]);
        assert_eq!(turn.ended_at_ms, 40);
    }

    #[test]
    fn turn_accumulator_take_if_silent_is_none_with_nothing_buffered() {
        let mut acc = TurnAccumulator::default();
        assert!(acc.take_if_silent(Duration::from_millis(0), 0).is_none());
    }

    // ------------------------------------------------------------------
    // T014: take_if_over — el tope duro de MAX_TURN_MS, independiente de
    // take_if_silent (arriba). La duración se mide en samples (16kHz), no
    // en reloj de pared, así que estos tests no necesitan `sleep`.
    // ------------------------------------------------------------------

    #[test]
    fn turn_accumulator_take_if_over_does_not_fire_before_the_cap() {
        let mut acc = TurnAccumulator::default();
        // 7999ms de audio a 16kHz: justo bajo el tope de 8000ms.
        acc.push_speech(&vec![0.0; 127_999], 0);

        assert!(
            acc.take_if_over(8_000, 8_000).is_none(),
            "el tope no se superó todavía"
        );
        // take_if_silent tampoco debe verse afectado por este chequeo: el
        // turno sigue intacto y disponible.
        assert!(acc
            .take_if_silent(Duration::from_millis(0), 8_000)
            .is_some());
    }

    #[test]
    fn turn_accumulator_take_if_over_closes_the_turn_once_the_cap_is_reached() {
        let mut acc = TurnAccumulator::default();
        // 8000ms exactos de audio a 16kHz (128_000 samples): en el punto
        // justo del tope, ya debe cerrar.
        acc.push_speech(&vec![0.5; 128_000], 100);

        let turn = acc
            .take_if_over(8_000, 8_100)
            .expect("el tope se alcanzó, el turno debe cerrarse aunque siga habiendo voz");
        assert_eq!(turn.samples.len(), 128_000);
        assert_eq!(turn.started_at_ms, 100);
        assert_eq!(turn.ended_at_ms, 8_100);

        assert!(
            acc.take_remaining(9_000).is_none(),
            "el turno ya se tomó; no debe quedar nada en el buffer"
        );
    }

    #[test]
    fn turn_accumulator_take_if_over_is_none_with_nothing_buffered() {
        let mut acc = TurnAccumulator::default();
        assert!(acc.take_if_over(0, 0).is_none());
    }

    // ------------------------------------------------------------------
    // T012: persist_and_emit_segment — DB row shape + speaker_id/overlapped
    // defaults, driven with a stub transcriber (no ML model needed).
    // ------------------------------------------------------------------

    #[test]
    fn persist_and_emit_segment_inserts_a_row_with_expected_defaults() {
        let dir = temp_db_path("persist-segment-basic");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new should succeed");
        let meeting_id = manager
            .start_meeting("presencial")
            .expect("start_meeting should succeed");

        let conn = manager.get_connection().expect("get_connection");
        let turn = CompletedTurn {
            samples: vec![0.0; 4000],
            started_at_ms: 1_000,
            ended_at_ms: 3_500,
        };
        let transcribe: &dyn Fn(Vec<f32>) -> Result<String> =
            &|_samples| Ok("hola, esto es una prueba".to_string());

        let segment =
            persist_and_emit_segment(&conn, NO_APP, meeting_id, turn, None, false, transcribe)
                .expect("persisting should succeed")
                .expect("non-empty transcription should produce a segment");

        assert_eq!(segment.text, "hola, esto es una prueba");
        assert_eq!(segment.speaker_id, None);
        assert_eq!(segment.started_at_ms, 1_000);
        assert_eq!(segment.ended_at_ms, 3_500);
        assert!(!segment.overlapped);

        let (text, speaker_id, started_at_ms, ended_at_ms, overlapped): (
            String,
            Option<i64>,
            i64,
            i64,
            bool,
        ) = conn
            .query_row(
                "SELECT text, speaker_id, started_at_ms, ended_at_ms, overlapped \
                 FROM meeting_segments WHERE id = ?1",
                [segment.id],
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
            .expect("the inserted segment should be readable back");

        assert_eq!(text, "hola, esto es una prueba");
        assert_eq!(
            speaker_id, None,
            "un turno sin atribución confiable se persiste con speaker_id NULL (FR-004)"
        );
        assert_eq!(started_at_ms, 1_000);
        assert_eq!(ended_at_ms, 3_500);
        assert!(!overlapped);

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn persist_and_emit_segment_pads_short_turns_before_transcribing() {
        let dir = temp_db_path("persist-segment-padding");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new should succeed");
        let meeting_id = manager
            .start_meeting("presencial")
            .expect("start_meeting should succeed");
        let conn = manager.get_connection().expect("get_connection");

        let observed_len = Arc::new(Mutex::new(0usize));
        let observed_len_cb = Arc::clone(&observed_len);
        let turn = CompletedTurn {
            samples: vec![0.5; 100], // far under MIN_TURN_SAMPLES
            started_at_ms: 0,
            ended_at_ms: 10,
        };
        let transcribe: &dyn Fn(Vec<f32>) -> Result<String> = &move |samples| {
            *observed_len_cb.lock().unwrap() = samples.len();
            Ok("ok".to_string())
        };

        persist_and_emit_segment(&conn, NO_APP, meeting_id, turn, None, false, transcribe)
            .expect("persisting should succeed");

        assert_eq!(
            *observed_len.lock().unwrap(),
            MIN_TURN_SAMPLES * 5 / 4,
            "a short turn should be zero-padded the same way \
             AudioRecordingManager::stop_recording pads short dictation buffers"
        );

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn persist_and_emit_segment_skips_empty_transcription() {
        let dir = temp_db_path("persist-segment-empty");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new should succeed");
        let meeting_id = manager
            .start_meeting("presencial")
            .expect("start_meeting should succeed");
        let conn = manager.get_connection().expect("get_connection");

        let turn = CompletedTurn {
            samples: vec![0.0; 4000],
            started_at_ms: 0,
            ended_at_ms: 100,
        };
        let transcribe: &dyn Fn(Vec<f32>) -> Result<String> = &|_| Ok("   ".to_string());

        let result =
            persist_and_emit_segment(&conn, NO_APP, meeting_id, turn, None, false, transcribe)
                .expect("an empty transcription is not an error");
        assert!(
            result.is_none(),
            "a blank transcription should not produce a segment"
        );

        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM meeting_segments", [], |row| {
                row.get(0)
            })
            .expect("count meeting_segments");
        assert_eq!(
            count, 0,
            "nothing should be inserted for an empty transcription"
        );

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn persist_and_emit_segment_propagates_transcribe_errors() {
        let dir = temp_db_path("persist-segment-error");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new should succeed");
        let meeting_id = manager
            .start_meeting("presencial")
            .expect("start_meeting should succeed");
        let conn = manager.get_connection().expect("get_connection");

        let turn = CompletedTurn {
            samples: vec![0.0; 4000],
            started_at_ms: 0,
            ended_at_ms: 100,
        };
        let transcribe: &dyn Fn(Vec<f32>) -> Result<String> =
            &|_| Err(anyhow::anyhow!("engine exploded"));

        let result =
            persist_and_emit_segment(&conn, NO_APP, meeting_id, turn, None, false, transcribe);
        assert!(result.is_err());

        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM meeting_segments", [], |row| {
                row.get(0)
            })
            .expect("count meeting_segments");
        assert_eq!(count, 0, "a failed transcription must not insert a row");

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    // ------------------------------------------------------------------
    // End-to-end test against real speech audio: drives the real Silero +
    // SmoothedVad engine (the committed `silero_vad_v4.onnx`, no download
    // needed for the model itself) over a real multi-speaker recording,
    // through the exact same `TurnAccumulator` and `persist_and_emit_segment`
    // the live capture path uses (with a stub transcriber standing in for a
    // loaded ML model), and asserts multiple segments land in
    // `meeting_segments` in order with sane timestamps.
    //
    // Reuses the same fixture wav `diarization.rs`'s T009 end-to-end test
    // downloads (real speech with natural pauses between speakers — good
    // for exercising turn segmentation). Note for the record: the task
    // brief pointed at "tests de transcription.rs" for a reusable audio
    // fixture, but transcription.rs's own tests don't use one; this
    // fixture/pattern actually lives in diarization.rs (T009), the closest
    // sibling task, which is what this test follows.
    //
    // Requires network (downloads the ~1.8MB test wav only; the VAD model
    // is already committed under resources/models/) -- #[ignore], same
    // convention as diarization.rs. Run manually with:
    //   cargo test --lib managers::meeting::tests::capture_pipeline_segments_real_speech_audio -- --ignored
    // ------------------------------------------------------------------
    #[tokio::test]
    #[ignore = "requiere red: descarga un wav de prueba real (el modelo VAD ya está committeado)"]
    async fn capture_pipeline_segments_real_speech_audio() {
        use crate::audio_toolkit::vad::VadFrame;
        use crate::audio_toolkit::VoiceActivityDetector;

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

        let vad_model_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("resources/models/silero_vad_v4.onnx");
        let silero = SileroVad::new(&vad_model_path, VAD_THRESHOLD)
            .expect("the committed VAD model should load");
        let mut vad = SmoothedVad::new(
            Box::new(silero),
            VAD_PREFILL_FRAMES,
            VAD_OFFLINE_HANGOVER_FRAMES,
            VAD_ONSET_FRAMES,
        );

        // Drive the same TurnAccumulator the live capture path uses, but
        // deterministically off the VAD's own Speech->Noise transitions
        // instead of a wall-clock silence timer (see the module doc comment
        // on `TurnAccumulator` for why that's the intended test seam).
        let frame_len = 480usize; // 30ms @ 16kHz
        let mut acc = TurnAccumulator::default();
        let mut turns = Vec::new();
        for (i, frame) in samples.chunks(frame_len).enumerate() {
            if frame.len() < frame_len {
                break; // drop a trailing partial frame, same as the resampler would
            }
            let now_ms = (i * 30) as i64;
            match vad.push_frame(frame).expect("push_frame should not fail") {
                VadFrame::Speech(buf) => acc.push_speech(buf, now_ms),
                VadFrame::Noise => {
                    if let Some(turn) = acc.take_remaining(now_ms) {
                        turns.push(turn);
                    }
                }
            }
        }
        if let Some(turn) = acc.take_remaining((samples.len() / 16) as i64) {
            turns.push(turn);
        }

        assert!(
            turns.len() > 1,
            "a real multi-speaker recording with pauses between speakers should segment into \
             more than one turn, got {}",
            turns.len()
        );
        for turn in &turns {
            assert!(turn.ended_at_ms > turn.started_at_ms);
            assert!(!turn.samples.is_empty());
        }

        // Now run each detected turn through the exact same persist path
        // start_capture's transcriber thread uses, with a stub transcriber.
        let dir = temp_db_path("capture-pipeline-e2e");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new should succeed");
        let meeting_id = manager
            .start_meeting("presencial")
            .expect("start_meeting should succeed");
        let conn = manager.get_connection().expect("get_connection");

        for turn in turns {
            let transcribe: &dyn Fn(Vec<f32>) -> Result<String> =
                &move |samples| Ok(format!("[turno con {} muestras]", samples.len()));
            persist_and_emit_segment(&conn, NO_APP, meeting_id, turn, None, false, transcribe)
                .expect("persisting a real-audio turn should succeed");
        }

        let stored: i64 = conn
            .query_row("SELECT COUNT(*) FROM meeting_segments", [], |row| {
                row.get(0)
            })
            .expect("count meeting_segments");
        assert!(
            stored > 1,
            "expected multiple incremental segments to be inserted during capture, got {}",
            stored
        );

        // FR-002/research.md §2: segments carry increasing timestamps, one
        // VAD turn per row. This test drives the persist path directly with
        // `speaker_id = None`, so the rows come back unattributed — the real
        // attribution path (T013) is covered by the `SpeakerRegistry` tests
        // below and by the `#[ignore]`d end-to-end test.
        let mut stmt = conn
            .prepare(
                "SELECT speaker_id, started_at_ms, ended_at_ms, overlapped \
                 FROM meeting_segments ORDER BY id",
            )
            .unwrap();
        let rows: Vec<(Option<i64>, i64, i64, bool)> = stmt
            .query_map([], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
            })
            .unwrap()
            .map(|r| r.unwrap())
            .collect();
        let mut last_end = -1i64;
        for (speaker_id, started_at_ms, ended_at_ms, overlapped) in rows {
            assert_eq!(speaker_id, None);
            assert!(!overlapped);
            assert!(started_at_ms >= last_end);
            assert!(ended_at_ms > started_at_ms);
            last_end = ended_at_ms;
        }

        drop(stmt);
        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    // ------------------------------------------------------------------
    // T014: corte por voz dentro de un turno (`split_turn_into_pieces`) y
    // resolución de hablante por pieza (`process_turn_pieces`).
    //
    // `split_turn_into_pieces` es una función pura sobre los
    // `DiarizedSegment` que devuelve el motor -- se testea sin modelos ONNX.
    // Los embeddings sintéticos de acá abajo son vectores unitarios en 2D
    // con ángulos elegidos para caer a propósito en cada lado de los
    // umbrales de `SpeakerRegistry`; el camino con voces reales lo cubre el
    // test `#[ignore]` del final, que sí carga los dos modelos.
    // ------------------------------------------------------------------

    fn seg(speaker: usize, start_ms: u64, end_ms: u64, overlapped: bool) -> DiarizedSegment {
        DiarizedSegment {
            start_ms,
            end_ms,
            speaker,
            overlapped,
        }
    }

    /// Vector unitario a `degrees` grados del eje x: `cos(ángulo entre dos)`
    /// es exactamente su similitud coseno, así que los umbrales se pueden
    /// apuntar con precisión.
    fn unit_at(degrees: f32) -> Vec<f32> {
        let rad = degrees.to_radians();
        vec![rad.cos(), rad.sin()]
    }

    #[test]
    fn split_turn_into_pieces_returns_one_open_piece_when_there_is_no_diarization() {
        assert_eq!(
            split_turn_into_pieces(&[], 5_000),
            vec![TurnPiece {
                start_ms: 0,
                end_ms: 5_000,
                speaker: None,
                overlapped: false,
            }],
            "sin diarización, el corte por voz debe equivaler al comportamiento sin diarizar: \
             una sola pieza para todo el turno"
        );
    }

    #[test]
    fn split_turn_into_pieces_splits_a_clean_speaker_change_and_sorts_by_start() {
        // A propósito fuera de orden: la regla 1 (ordenar por start_ms) se
        // testea acá en vez de con un test aparte.
        let segments = vec![seg(1, 3_000, 6_000, false), seg(0, 0, 3_000, false)];

        let pieces = split_turn_into_pieces(&segments, 6_000);

        assert_eq!(
            pieces,
            vec![
                TurnPiece {
                    start_ms: 0,
                    end_ms: 3_000,
                    speaker: Some(0),
                    overlapped: false,
                },
                TurnPiece {
                    start_ms: 3_000,
                    end_ms: 6_000,
                    speaker: Some(1),
                    overlapped: false,
                },
            ]
        );
    }

    #[test]
    fn split_turn_into_pieces_merges_a_major_overlap_into_one_mixed_piece() {
        // A = [0, 2000), B = [500, 2500): se pisan 1500ms de los 2000ms de
        // cada una -- 75% > OVERLAP_MERGE_RATIO (60%).
        let segments = vec![seg(0, 0, 2_000, false), seg(1, 500, 2_500, false)];

        let pieces = split_turn_into_pieces(&segments, 2_500);

        assert_eq!(
            pieces,
            vec![TurnPiece {
                start_ms: 0,
                end_ms: 2_500,
                speaker: None,
                overlapped: true,
            }],
            "un solape mayor al 60% del más corto es voz mezclada: no separable con un mic"
        );
    }

    #[test]
    fn split_turn_into_pieces_trims_a_minor_overlap_between_speakers() {
        // A = [0, 3000), B = [2800, 5000): se pisan 200ms de los 2200ms de
        // B -- 9%, muy por debajo del 60%.
        let segments = vec![seg(0, 0, 3_000, false), seg(1, 2_800, 5_000, false)];

        let pieces = split_turn_into_pieces(&segments, 5_000);

        assert_eq!(
            pieces,
            vec![
                TurnPiece {
                    start_ms: 0,
                    end_ms: 3_000,
                    speaker: Some(0),
                    overlapped: false,
                },
                TurnPiece {
                    start_ms: 3_000,
                    end_ms: 5_000,
                    speaker: Some(1),
                    overlapped: false,
                },
            ],
            "un solape chico recorta el inicio del posterior al fin del anterior"
        );
    }

    #[test]
    fn split_turn_into_pieces_merges_a_tiny_piece_into_the_larger_previous_one() {
        let segments = vec![
            seg(0, 0, 3_000, false),     // 3000ms, la más larga
            seg(1, 3_000, 3_400, false), // 400ms, < MIN_PIECE_MS (700ms)
            seg(0, 3_400, 6_000, false), // 2600ms
        ];

        let pieces = split_turn_into_pieces(&segments, 6_000);

        assert_eq!(
            pieces,
            vec![
                TurnPiece {
                    start_ms: 0,
                    end_ms: 3_400,
                    speaker: Some(0),
                    overlapped: false,
                },
                TurnPiece {
                    start_ms: 3_400,
                    end_ms: 6_000,
                    speaker: Some(0),
                    overlapped: false,
                },
            ],
            "la pieza diminuta se funde con la anterior, conservando el hablante de la mayor"
        );
    }

    #[test]
    fn split_turn_into_pieces_merges_a_leading_tiny_piece_with_the_next_one() {
        let segments = vec![
            seg(0, 0, 300, false),     // 300ms, primera pieza, diminuta
            seg(1, 300, 4_000, false), // 3700ms
        ];

        let pieces = split_turn_into_pieces(&segments, 4_000);

        assert_eq!(
            pieces,
            vec![TurnPiece {
                start_ms: 0,
                end_ms: 4_000,
                speaker: Some(1),
                overlapped: false,
            }],
            "sin pieza anterior, la diminuta se funde con la siguiente"
        );
    }

    #[test]
    fn extract_ranges_concatenates_and_clamps_out_of_bounds() {
        let samples: Vec<f32> = (0..16_000).map(|i| i as f32).collect(); // 1s a 16kHz
        let extracted = extract_ranges(&samples, &[(0, 250), (500, 750)], 16_000);
        assert_eq!(extracted.len(), 8_000);
        assert_eq!(extracted[0], 0.0);
        assert_eq!(extracted[4_000], 8_000.0);

        // Un rango que se pasa del final del buffer se recorta en vez de
        // entrar en pánico (diarize trabaja con frames redondeados).
        let clamped = extract_ranges(&samples, &[(900, 5_000)], 16_000);
        assert_eq!(clamped.len(), 1_600);
    }

    // ------------------------------------------------------------------
    // T014: process_turn_pieces con stubs -- integra split_turn_into_pieces
    // + extract_ranges + SpeakerRegistry + persist_and_emit_segment sin
    // cargar ningún modelo real, con un turno sintético de 2 hablantes.
    // ------------------------------------------------------------------

    #[test]
    fn process_turn_pieces_persists_one_row_per_piece_with_absolute_offsets() {
        let dir = temp_db_path("process-turn-pieces");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let meeting_id = manager.start_meeting("presencial").expect("start_meeting");
        let conn = manager.get_connection().expect("get_connection");

        // 6000ms de audio a 16kHz: los primeros 3000ms "son" el hablante 0
        // (valor 0.1), los últimos 3000ms el hablante 1 (valor 0.9) -- el
        // stub de embed de abajo lee ese valor para decidir qué vector
        // devolver, así el test no depende de ningún modelo real.
        let mut samples = vec![0.1_f32; 48_000];
        samples.extend(vec![0.9_f32; 48_000]);
        let turn = CompletedTurn {
            samples,
            started_at_ms: 10_000,
            ended_at_ms: 16_000,
        };
        let segments = vec![seg(0, 0, 3_000, false), seg(1, 3_000, 6_000, false)];

        let embed: &dyn Fn(&[f32]) -> Option<Vec<f32>> = &|samples: &[f32]| {
            if samples.first().copied().unwrap_or(0.0) < 0.5 {
                Some(unit_at(0.0))
            } else {
                Some(unit_at(90.0)) // bien lejos del primero: otra voz
            }
        };
        let transcribe: &dyn Fn(Vec<f32>) -> Result<String> =
            &|samples: Vec<f32>| Ok(format!("pieza de {} samples", samples.len()));

        let mut registry = SpeakerRegistry::default();
        let results = process_turn_pieces(
            &conn,
            NO_APP,
            meeting_id,
            &turn,
            &segments,
            &mut registry,
            embed,
            transcribe,
        );

        assert_eq!(results.len(), 2, "un turno de 2 hablantes -> 2 piezas");
        for result in &results {
            assert!(
                matches!(result, Ok(Some(_))),
                "cada pieza debería persistirse: {:?}",
                result.as_ref().err()
            );
        }

        let mut stmt = conn
            .prepare(
                "SELECT speaker_id, started_at_ms, ended_at_ms FROM meeting_segments \
                 ORDER BY id",
            )
            .unwrap();
        let rows: Vec<(Option<i64>, i64, i64)> = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
            .unwrap()
            .map(|r| r.unwrap())
            .collect();

        assert_eq!(
            rows.len(),
            2,
            "dos filas en meeting_segments, una por pieza"
        );
        assert_eq!(
            (rows[0].1, rows[0].2),
            (10_000, 13_000),
            "offsets absolutos = turn.started_at_ms + límites de la pieza"
        );
        assert_eq!((rows[1].1, rows[1].2), (13_000, 16_000));
        assert!(
            rows[0].0.is_some() && rows[1].0.is_some(),
            "ambas piezas tienen suficiente audio limpio para atribuirse"
        );
        assert_ne!(
            rows[0].0, rows[1].0,
            "dos voces bien distintas deben terminar en dos hablantes distintos"
        );
        assert_eq!(registry.entries.len(), 2);

        drop(stmt);
        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn speaker_registry_creates_a_speaker_for_the_first_voice_it_hears() {
        let dir = temp_db_path("registry-first-voice");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let meeting_id = manager.start_meeting("presencial").expect("start_meeting");
        let conn = manager.get_connection().expect("get_connection");

        let mut registry = SpeakerRegistry::default();
        let id = registry
            .resolve(&conn, meeting_id, Some(&unit_at(0.0)))
            .expect("resolve")
            .expect("la primera voz siempre estrena hablante");

        let (label, display_name): (String, Option<String>) = conn
            .query_row(
                "SELECT label, display_name FROM meeting_speakers WHERE id = ?1",
                [id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("la fila del hablante debe existir");
        assert_eq!(label, "Hablante 1");
        assert_eq!(display_name, None, "el nombre lo pone el usuario (FR-005)");

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn speaker_registry_reuses_a_known_voice_and_creates_one_for_a_new_voice() {
        let dir = temp_db_path("registry-two-voices");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let meeting_id = manager.start_meeting("presencial").expect("start_meeting");
        let conn = manager.get_connection().expect("get_connection");

        let mut registry = SpeakerRegistry::default();
        let first = registry
            .resolve(&conn, meeting_id, Some(&unit_at(0.0)))
            .unwrap()
            .unwrap();
        // 10° -> cos = 0.985: claramente la misma voz.
        let again = registry
            .resolve(&conn, meeting_id, Some(&unit_at(10.0)))
            .unwrap()
            .unwrap();
        // 90° -> cos = 0: claramente otra persona.
        let other = registry
            .resolve(&conn, meeting_id, Some(&unit_at(90.0)))
            .unwrap()
            .unwrap();

        assert_eq!(first, again, "la misma voz no debe estrenar hablante");
        assert_ne!(other, first, "una voz distinta debe estrenar hablante");

        let labels: Vec<String> = {
            let mut stmt = conn
                .prepare("SELECT label FROM meeting_speakers WHERE meeting_id = ?1 ORDER BY id")
                .unwrap();
            let rows = stmt
                .query_map([meeting_id], |row| row.get(0))
                .unwrap()
                .map(|r| r.unwrap())
                .collect();
            rows
        };
        assert_eq!(labels, vec!["Hablante 1", "Hablante 2"]);

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn speaker_registry_leaves_an_ambiguous_voice_unattributed() {
        let mut registry = SpeakerRegistry::default();
        registry.entries.push(SpeakerEntry {
            id: 1,
            centroid: unit_at(0.0),
            turns: 1,
        });

        // 60° -> cos = 0.5, justo en el medio de la banda de
        // incertidumbre: ni se asigna al conocido ni se inventa uno nuevo.
        assert_eq!(
            registry.classify(&unit_at(60.0)),
            SpeakerMatch::Uncertain,
            "FR-004: en la duda, ningún hablante"
        );
    }

    #[test]
    fn speaker_registry_refuses_to_pick_between_two_equally_close_speakers() {
        let mut registry = SpeakerRegistry::default();
        registry.entries.push(SpeakerEntry {
            id: 1,
            centroid: unit_at(20.0), // cos(20°) = 0.940 contra el turno
            turns: 1,
        });
        registry.entries.push(SpeakerEntry {
            id: 2,
            centroid: unit_at(25.0), // cos(25°) = 0.906 -> margen 0.034
            turns: 1,
        });

        assert_eq!(
            registry.classify(&unit_at(0.0)),
            SpeakerMatch::Uncertain,
            "dos hablantes conocidos casi igual de parecidos: asignar al mejor es adivinar"
        );
    }

    #[test]
    fn speaker_registry_reinforce_moves_the_centroid_toward_the_new_turn() {
        let mut registry = SpeakerRegistry::default();
        registry.entries.push(SpeakerEntry {
            id: 1,
            centroid: unit_at(0.0),
            turns: 1,
        });

        registry.reinforce(0, &unit_at(20.0));

        let centroid = &registry.entries[0].centroid;
        let sim_new = cosine_similarity(centroid, &unit_at(20.0));
        let sim_old = cosine_similarity(centroid, &unit_at(0.0));
        assert!(
            (sim_new - sim_old).abs() < 1e-5,
            "la media de dos turnos debe quedar equidistante de ambos, quedó {sim_old} vs {sim_new}"
        );
        assert_eq!(registry.entries[0].turns, 2);
    }

    #[test]
    fn speaker_registry_resolve_is_none_without_an_embedding() {
        let dir = temp_db_path("registry-no-embedding");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let meeting_id = manager.start_meeting("presencial").expect("start_meeting");
        let conn = manager.get_connection().expect("get_connection");

        let mut registry = SpeakerRegistry::default();
        assert_eq!(registry.resolve(&conn, meeting_id, None).unwrap(), None);

        let speakers: i64 = conn
            .query_row("SELECT COUNT(*) FROM meeting_speakers", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(
            speakers, 0,
            "un turno incierto no debe estrenar un hablante fantasma"
        );

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn persist_and_emit_segment_stores_speaker_and_overlap() {
        let dir = temp_db_path("persist-segment-speaker");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let meeting_id = manager.start_meeting("presencial").expect("start_meeting");
        let conn = manager.get_connection().expect("get_connection");

        let speaker_id = insert_speaker(&conn, meeting_id).expect("insert_speaker");
        let turn = CompletedTurn {
            samples: vec![0.0; 20_000],
            started_at_ms: 0,
            ended_at_ms: 1_200,
        };
        let transcribe: &dyn Fn(Vec<f32>) -> Result<String> = &|_| Ok("dale".to_string());

        let segment = persist_and_emit_segment(
            &conn,
            NO_APP,
            meeting_id,
            turn,
            Some(speaker_id),
            true,
            transcribe,
        )
        .expect("persisting should succeed")
        .expect("non-empty transcription");

        assert_eq!(segment.speaker_id, Some(speaker_id));
        assert!(segment.overlapped);

        let (stored_speaker, stored_overlap): (Option<i64>, bool) = conn
            .query_row(
                "SELECT speaker_id, overlapped FROM meeting_segments WHERE id = ?1",
                [segment.id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("readable back");
        assert_eq!(stored_speaker, Some(speaker_id));
        assert!(stored_overlap);

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
            let turn = CompletedTurn {
                samples: vec![0.0; 20_000],
                started_at_ms: 0,
                ended_at_ms: 30_000, // 30 s hablados antes del crash
            };
            let transcribe: &dyn Fn(Vec<f32>) -> Result<String> =
                &|_| Ok("alcanzó a decir esto".to_string());
            persist_and_emit_segment(&conn, NO_APP, meeting_id, turn, None, false, transcribe)
                .expect("persistir")
                .expect("segmento");
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
        let turn = CompletedTurn {
            samples: vec![0.0; 20_000],
            started_at_ms: 0,
            ended_at_ms: 500,
        };
        let transcribe: &dyn Fn(Vec<f32>) -> Result<String> = &|_| Ok("algo".to_string());
        persist_and_emit_segment(&conn, NO_APP, with_content, turn, None, false, transcribe)
            .expect("persistir")
            .expect("segmento");

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
        let turn = CompletedTurn {
            samples: vec![0.0; 20_000],
            started_at_ms: 0,
            ended_at_ms: 900,
        };
        let transcribe: &dyn Fn(Vec<f32>) -> Result<String> = &|_| Ok("hola".to_string());
        let segment =
            persist_and_emit_segment(&conn, NO_APP, meeting_id, turn, Some(a), false, transcribe)
                .expect("persistir")
                .expect("segmento");

        manager.merge_speakers(meeting_id, a, b).expect("fusionar");

        let stored: Option<i64> = conn
            .query_row(
                "SELECT speaker_id FROM meeting_segments WHERE id = ?1",
                [segment.id],
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
            tauri_specta::collect_events![MeetingSegment, MeetingError, MeetingTurnFailed],
        );
        builder.mount_events(app.handle());
        app
    }

    #[test]
    fn each_persisted_segment_emits_meeting_segment_incrementally() {
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
        let speaker_id = insert_speaker(&conn, meeting_id).expect("insert_speaker");

        // Tres turnos consecutivos, como los que produce la captura en vivo.
        for i in 0..3 {
            let turn = CompletedTurn {
                samples: vec![0.0; 20_000],
                started_at_ms: i * 1_000,
                ended_at_ms: i * 1_000 + 800,
            };
            let transcribe: &dyn Fn(Vec<f32>) -> Result<String> =
                &move |_| Ok(format!("turno {i}"));
            persist_and_emit_segment(
                &conn,
                Some(&handle),
                meeting_id,
                turn,
                Some(speaker_id),
                false,
                transcribe,
            )
            .expect("persisting should succeed")
            .expect("non-empty transcription");
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
        assert_eq!(first["speaker_id"], speaker_id);
        assert_eq!(first["started_at_ms"], 0);
        assert_eq!(first["ended_at_ms"], 800);
        assert_eq!(first["overlapped"], false);
        assert!(first["id"].is_number());
        assert_eq!(received[2]["text"], "turno 2");

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn an_empty_transcription_emits_nothing() {
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

        let turn = CompletedTurn {
            samples: vec![0.0; 20_000],
            started_at_ms: 0,
            ended_at_ms: 500,
        };
        let transcribe: &dyn Fn(Vec<f32>) -> Result<String> = &|_| Ok("   ".to_string());
        let result = persist_and_emit_segment(
            &conn,
            Some(&handle),
            meeting_id,
            turn,
            None,
            false,
            transcribe,
        )
        .expect("persisting should succeed");

        assert!(result.is_none());
        assert_eq!(
            *received.lock().unwrap(),
            0,
            "el ruido que el VAD deja pasar no debe ensuciar el transcript en vivo"
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

        let transcribe: &dyn Fn(Vec<f32>) -> Result<String> = &|_| Ok("segmento".to_string());
        // Persistidos fuera de orden a propósito: lo que tiene que ordenar
        // `get_meeting` es `started_at_ms`, no el orden de inserción (que acá
        // es justo el contrario).
        let turn_b = CompletedTurn {
            samples: vec![0.0; 20_000],
            started_at_ms: 5_000,
            ended_at_ms: 6_000,
        };
        let turn_a = CompletedTurn {
            samples: vec![0.0; 20_000],
            started_at_ms: 0,
            ended_at_ms: 1_000,
        };
        let turn_c = CompletedTurn {
            samples: vec![0.0; 20_000],
            started_at_ms: 10_000,
            ended_at_ms: 11_000,
        };
        persist_and_emit_segment(&conn, NO_APP, meeting_id, turn_b, None, false, transcribe)
            .expect("persistir b")
            .expect("segmento b");
        persist_and_emit_segment(&conn, NO_APP, meeting_id, turn_a, None, false, transcribe)
            .expect("persistir a")
            .expect("segmento a");
        persist_and_emit_segment(&conn, NO_APP, meeting_id, turn_c, None, false, transcribe)
            .expect("persistir c")
            .expect("segmento c");

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

        let transcribe: &dyn Fn(Vec<f32>) -> Result<String> = &|_| Ok("hola".to_string());
        let turn_a = CompletedTurn {
            samples: vec![0.0; 20_000],
            started_at_ms: 0,
            ended_at_ms: 1_000,
        };
        let turn_uncertain = CompletedTurn {
            samples: vec![0.0; 20_000],
            started_at_ms: 2_000,
            ended_at_ms: 3_000,
        };
        let segment_a = persist_and_emit_segment(
            &conn,
            NO_APP,
            meeting_id,
            turn_a,
            Some(a),
            false,
            transcribe,
        )
        .expect("persistir")
        .expect("segmento de A");
        let segment_uncertain = persist_and_emit_segment(
            &conn,
            NO_APP,
            meeting_id,
            turn_uncertain,
            None,
            false,
            transcribe,
        )
        .expect("persistir")
        .expect("segmento incierto");

        manager
            .merge_speakers(meeting_id, a, b)
            .expect("fusionar A en B");

        let meeting = manager.get_meeting(meeting_id).expect("get_meeting");

        let resolved_a = meeting
            .segments
            .iter()
            .find(|s| s.id == segment_a.id)
            .expect("el segmento de A sigue presente");
        assert_eq!(
            resolved_a.speaker_id,
            Some(b),
            "el segmento que apuntaba a A debe salir resuelto a B, el destino de la fusión"
        );

        let still_uncertain = meeting
            .segments
            .iter()
            .find(|s| s.id == segment_uncertain.id)
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
    // End-to-end de la atribución con AMBOS modelos reales, sobre el mismo
    // fixture de 4 hablantes que usa `managers/diarization.rs`. Requiere red
    // (baja el modelo de embeddings ~27MB y el wav ~1.8MB), por eso
    // `#[ignore]` — mismo criterio que el test end-to-end de T009. Se corrió
    // a mano en esta tarea; el resultado está en el reporte.
    //
    // Lo que verifica es justo lo que los tests sintéticos NO pueden: que
    // turnos SEPARADOS de la misma persona real caigan en el mismo
    // `speaker_id`, que es la propiedad que hace útil al registro.
    // ------------------------------------------------------------------
    #[tokio::test]
    #[ignore = "requiere red: descarga el modelo de embeddings y un wav de prueba reales"]
    async fn attribution_reidentifies_the_same_real_voice_across_turns() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let embedding_path =
            crate::managers::diarization_models::ensure_embedding_model_downloaded(tmp.path())
                .await
                .expect("modelo de embeddings");
        let segmentation_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("resources/models/pyannote_segmentation_3_0.onnx");

        let wav_bytes = reqwest::get(
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/0-four-speakers-zh.wav",
        )
        .await
        .expect("descargando el wav")
        .bytes()
        .await
        .expect("leyendo el wav");
        let wav_path = tmp.path().join("0-four-speakers-zh.wav");
        std::fs::write(&wav_path, &wav_bytes).expect("escribiendo el wav");
        let mut reader = hound::WavReader::open(&wav_path).expect("abriendo el wav");
        let samples: Vec<f32> = reader
            .samples::<i16>()
            .map(|s| s.expect("sample") as f32 / i16::MAX as f32)
            .collect();

        let engine = DiarizationEngine::load(&segmentation_path, &embedding_path)
            .expect("ambos modelos deben cargar");

        // Diarizar el audio completo da la verdad de referencia: quién habla
        // en cada tramo. Cada tramo se vuelve a alimentar como si fuera un
        // turno independiente del pipeline en vivo.
        let truth = engine
            .diarize(&samples, DIARIZATION_SAMPLE_RATE)
            .expect("diarize completo");
        assert!(!truth.is_empty());

        let dir = temp_db_path("attribution-e2e");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new");
        let meeting_id = manager.start_meeting("presencial").expect("start_meeting");
        let conn = manager.get_connection().expect("get_connection");
        let mut registry = SpeakerRegistry::default();

        let mut assigned: HashMap<usize, Vec<Option<i64>>> = HashMap::new();
        let mut processed = 0usize;
        for turn in &truth {
            let audio = extract_ranges(
                &samples,
                &[(turn.start_ms, turn.end_ms)],
                DIARIZATION_SAMPLE_RATE,
            );
            if audio.len() < MIN_EMBED_SAMPLES {
                continue;
            }
            processed += 1;
            let embedding = embed_piece(&engine, &audio);
            let speaker_id = registry
                .resolve(&conn, meeting_id, embedding.as_deref())
                .expect("resolve");
            assigned.entry(turn.speaker).or_default().push(speaker_id);
        }

        let attributed_total: usize = assigned.values().flatten().flatten().count();
        eprintln!(
            "turnos procesados: {processed}, atribuidos: {attributed_total}, hablantes creados: {}",
            registry.entries.len()
        );

        assert!(
            assigned.len() >= 2,
            "el fixture tiene 4 voces reales: la referencia debe traer al menos 2"
        );
        // Sin esto, el test pasaría en vacío si TODO quedara incierto —
        // que es justo el modo de falla más plausible de este diseño.
        assert!(
            attributed_total * 2 >= processed,
            "al menos la mitad de los turnos debería quedar atribuida, quedaron \
             {attributed_total}/{processed}"
        );
        assert!(
            registry.entries.len() >= 2,
            "el registro debe distinguir al menos dos voces, distinguió {}",
            registry.entries.len()
        );

        for (truth_speaker, ids) in &assigned {
            let attributed: Vec<i64> = ids.iter().flatten().copied().collect();
            if attributed.is_empty() {
                continue;
            }
            let modal = attributed
                .iter()
                .max_by_key(|id| attributed.iter().filter(|x| x == id).count())
                .copied()
                .unwrap();
            let consistent = attributed.iter().filter(|id| **id == modal).count();
            assert!(
                consistent * 100 / attributed.len() >= 80,
                "los turnos del hablante real {truth_speaker} deberían caer mayoritariamente en \
                 un mismo speaker_id (SC-001: >80%), cayeron {consistent}/{}",
                attributed.len()
            );
        }

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    // ------------------------------------------------------------------
    // El modelo se descarga en medio de la reunión: el turno se recarga y
    // se reintenta UNA vez, en vez de perderse en silencio (y con él todos
    // los siguientes, que es lo que pasaba).
    // ------------------------------------------------------------------

    #[test]
    fn a_turn_is_retried_once_after_reloading_an_unloaded_model() {
        let attempts = Arc::new(Mutex::new(Vec::<usize>::new()));
        let reloads = Arc::new(Mutex::new(0usize));

        let attempts_cb = Arc::clone(&attempts);
        let transcribe: &dyn Fn(Vec<f32>) -> Result<String> = &move |samples: Vec<f32>| {
            let mut attempts = attempts_cb.lock().unwrap();
            attempts.push(samples.len());
            if attempts.len() == 1 {
                Err(anyhow::anyhow!("Model is not loaded for transcription."))
            } else {
                Ok("lo que se dijo".to_string())
            }
        };
        let reloads_cb = Arc::clone(&reloads);
        let reload: &dyn Fn() = &move || *reloads_cb.lock().unwrap() += 1;

        let text = transcribe_with_reload(vec![0.5; 1234], transcribe, reload)
            .expect("el reintento tras recargar debería transcribir el turno");

        assert_eq!(text, "lo que se dijo");
        assert_eq!(*reloads.lock().unwrap(), 1, "hay que recargar el modelo");
        assert_eq!(
            *attempts.lock().unwrap(),
            vec![1234, 1234],
            "el reintento tiene que llevar el MISMO audio, no un turno vacío"
        );
    }

    #[test]
    fn a_second_model_failure_is_not_retried_forever() {
        let attempts = Arc::new(Mutex::new(0usize));
        let attempts_cb = Arc::clone(&attempts);
        let transcribe: &dyn Fn(Vec<f32>) -> Result<String> = &move |_| {
            *attempts_cb.lock().unwrap() += 1;
            Err(anyhow::anyhow!("Model is not loaded for transcription."))
        };
        let reload: &dyn Fn() = &|| {};

        assert!(transcribe_with_reload(vec![0.0; 10], transcribe, reload).is_err());
        assert_eq!(
            *attempts.lock().unwrap(),
            2,
            "un reintento por turno: reintentar en bucle trabaría la cola detrás de éste"
        );
    }

    #[test]
    fn an_error_that_is_not_about_the_model_does_not_reload_anything() {
        let reloads = Arc::new(Mutex::new(0usize));
        let transcribe: &dyn Fn(Vec<f32>) -> Result<String> =
            &|_| Err(anyhow::anyhow!("el motor explotó"));
        let reloads_cb = Arc::clone(&reloads);
        let reload: &dyn Fn() = &move || *reloads_cb.lock().unwrap() += 1;

        assert!(transcribe_with_reload(vec![0.0; 10], transcribe, reload).is_err());
        assert_eq!(*reloads.lock().unwrap(), 0);
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
