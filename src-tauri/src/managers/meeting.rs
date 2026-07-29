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
    vad::{
        SmoothedVad, VAD_OFFLINE_HANGOVER_FRAMES, VAD_ONSET_FRAMES, VAD_PREFILL_FRAMES,
        VAD_STREAMING_HANGOVER_FRAMES,
    },
    AudioRecorder, SileroVad, VadPolicy,
};
use crate::managers::audio::{MicOwner, MicrophoneArbiter, VAD_THRESHOLD};
use crate::managers::diarization::{
    cosine_similarity, DiarizationEngine, DiarizedSegment, CLUSTER_THRESHOLD,
};
use crate::managers::diarization_models;
use crate::managers::transcription::TranscriptionManager;
use anyhow::{bail, Result};
use chrono::{Local, Utc};
use log::{debug, error, info, warn};
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use rusqlite_migration::{Migrations, M};
use serde::{Deserialize, Serialize};
use specta::Type;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
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
#[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct MeetingError {
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
/// How often the watchdog thread checks for a silence gap.
#[allow(dead_code)]
const WATCHDOG_POLL_INTERVAL: Duration = Duration::from_millis(100);
/// Turns shorter than this are zero-padded before transcription, mirroring
/// `AudioRecordingManager::stop_recording`'s short-buffer padding (some
/// engines need a minimum input duration to run at all).
#[allow(dead_code)]
const MIN_TURN_SAMPLES: usize = 16_000; // 1s @ 16kHz

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

// --- T013: diarización incremental (atribución de hablante por turno) ---
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
// La pieza que cierra esa brecha es [`SpeakerRegistry`]: por cada turno se
// calcula un embedding de voz (`DiarizationEngine::embed`, el mismo vector
// CAM++ de 192 dims que el pipeline usa para clusterizar) y se compara por
// similitud coseno contra los centroides de los hablantes ya vistos EN ESTA
// reunión. Es la versión incremental del mismo juicio que hace el
// clustering aglomerativo de T009, por eso sus umbrales se derivan de
// `CLUSTER_THRESHOLD` en vez de ser números nuevos: el mismo par de voces
// debe agruparse igual por los dos caminos.
//
// # Cómo se cumple FR-004 (marcar incierto en vez de adivinar)
//
// Hay cuatro caminos distintos a `speaker_id = NULL`, todos deliberados:
//
// 1. **El turno tiene dos voces** (`mixed`): dos hablantes locales con
//    duración comparable dentro del mismo turno. El texto transcrito es de
//    los dos, así que no hay un hablante correcto que asignar.
// 2. **Hubo habla superpuesta** (`overlapped` del propio motor, FR-004):
//    los tramos superpuestos se excluyen del audio que va al embedding, y
//    si no queda suficiente audio limpio el turno queda sin atribuir.
// 3. **Poco audio limpio** (< [`MIN_EMBED_SAMPLES`]): un embedding sobre
//    medio segundo de voz no es confiable; preferimos no atribuir.
// 4. **Similitud ambigua**: la mejor coincidencia cae en la banda de
//    incertidumbre alrededor del umbral, o hay dos hablantes conocidos casi
//    igual de parecidos (margen chico). Asignar el "menos malo" es
//    justamente lo que FR-004 prohíbe.
//
// Un turno sin atribuir NO actualiza ningún centroide ni crea un hablante
// nuevo: un caso dudoso no debe mover la referencia contra la que se
// comparan los turnos siguientes.
//
// # Degradación honesta cuando el motor no está listo
//
// El modelo de embeddings (~27 MB) se descarga en runtime (T008) y ambos
// modelos tardan en cargar. `start_capture` dispara esa preparación en un
// hilo aparte y NO bloquea el micrófono esperándola: los turnos que
// completen antes de que el motor esté listo se persisten con
// `speaker_id = NULL` (incierto), que es exactamente lo que significa. La
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

/// Si el segundo hablante local de un turno acumula al menos esta fracción
/// de la duración del dominante, el turno se considera de dos voces
/// (`mixed`) y queda sin atribuir.
const SECONDARY_SPEAKER_RATIO: f32 = 0.25;

/// El hablante dominante de un turno y el audio limpio que le pertenece.
#[derive(Debug, PartialEq)]
struct DominantSpeaker {
    /// Índice de hablante local a la llamada de `diarize` de ESTE turno —
    /// sirve para recortar audio, no como identidad entre turnos.
    speaker: usize,
    /// Rangos `[inicio, fin)` en milisegundos, relativos al turno, del
    /// hablante dominante y sin superposición.
    clean_ranges: Vec<(u64, u64)>,
    /// Hubo habla superpuesta en algún punto del turno (FR-004).
    overlapped: bool,
    /// Dos hablantes con presencia comparable en el mismo turno.
    mixed: bool,
}

/// Elige el hablante dominante de los segmentos que devolvió `diarize` para
/// un turno, y marca superposición/mezcla. Función pura: es la parte de la
/// atribución que se puede testear sin cargar 34 MB de modelos ONNX.
fn choose_dominant_speaker(segments: &[DiarizedSegment]) -> Option<DominantSpeaker> {
    if segments.is_empty() {
        return None;
    }

    let mut duration_by_speaker: HashMap<usize, u64> = HashMap::new();
    for seg in segments {
        let duration = seg.end_ms.saturating_sub(seg.start_ms);
        *duration_by_speaker.entry(seg.speaker).or_insert(0) += duration;
    }

    let mut ranked: Vec<(usize, u64)> = duration_by_speaker.into_iter().collect();
    // Desempate por índice de hablante para que la elección sea
    // determinista (el orden de un HashMap no lo es).
    ranked.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));

    let (speaker, dominant_duration) = ranked[0];
    if dominant_duration == 0 {
        return None;
    }

    let mixed = ranked
        .get(1)
        .is_some_and(|(_, d)| *d as f32 >= dominant_duration as f32 * SECONDARY_SPEAKER_RATIO);

    let overlapped = segments.iter().any(|s| s.overlapped);

    let clean_ranges = segments
        .iter()
        .filter(|s| s.speaker == speaker && !s.overlapped && s.end_ms > s.start_ms)
        .map(|s| (s.start_ms, s.end_ms))
        .collect();

    Some(DominantSpeaker {
        speaker,
        clean_ranges,
        overlapped,
        mixed,
    })
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

/// Resultado de diarizar UN turno: el embedding del hablante dominante
/// (cuando se pudo calcular con confianza) y si hubo superposición.
#[derive(Debug, Default)]
struct TurnAttribution {
    embedding: Option<Vec<f32>>,
    overlapped: bool,
}

/// Diariza el audio de un turno y devuelve, si corresponde, el embedding de
/// voz de su hablante dominante. `None` en `embedding` significa "incierto"
/// (FR-004) — ver los cuatro caminos documentados arriba.
///
/// Nunca devuelve error: una falla del motor de diarización degrada a
/// "segmento sin hablante", que es un transcript peor pero correcto,
/// mientras que propagar el error perdería el segmento entero (el texto ya
/// transcrito) por un problema de atribución.
fn attribute_turn(engine: &DiarizationEngine, samples: &[f32]) -> TurnAttribution {
    let segments = match engine.diarize(samples, DIARIZATION_SAMPLE_RATE) {
        Ok(s) => s,
        Err(e) => {
            warn!("Diarización del turno falló, queda sin atribuir: {}", e);
            return TurnAttribution::default();
        }
    };

    let Some(dominant) = choose_dominant_speaker(&segments) else {
        return TurnAttribution::default();
    };

    if dominant.mixed {
        debug!("Turno con dos voces de duración comparable: queda sin atribuir (FR-004)");
        return TurnAttribution {
            embedding: None,
            // Dos voces en el mismo turno ES el caso de superposición que la
            // UI tiene que mostrar como incierto.
            overlapped: true,
        };
    }

    let clean = extract_ranges(samples, &dominant.clean_ranges, DIARIZATION_SAMPLE_RATE);
    if clean.len() < MIN_EMBED_SAMPLES {
        debug!(
            "Turno con sólo {} samples limpios del hablante local {}: queda sin atribuir",
            clean.len(),
            dominant.speaker
        );
        return TurnAttribution {
            embedding: None,
            overlapped: dominant.overlapped,
        };
    }

    match engine.embed(&clean, DIARIZATION_SAMPLE_RATE) {
        Ok(embedding) => TurnAttribution {
            embedding: Some(embedding),
            overlapped: dominant.overlapped,
        },
        Err(e) => {
            warn!("Embedding del turno falló, queda sin atribuir: {}", e);
            TurnAttribution {
                embedding: None,
                overlapped: dominant.overlapped,
            }
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

/// State for one in-progress meeting capture session — the microphone-open,
/// VAD-active window between `start_capture` and `stop_capture`. Deliberately
/// separate from dictation's `RecordingState` (see the coexistence note
/// above): a meeting isn't triggered by a shortcut binding, runs far longer,
/// and drives its own recorder/threads rather than the shared dictation one.
#[allow(dead_code)]
struct CaptureSession {
    meeting_id: i64,
    recorder: AudioRecorder,
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

            let audio_cb = {
                let accumulator = Arc::clone(&accumulator);
                move |frame: &[f32]| {
                    let now_ms = capture_started.elapsed().as_millis() as i64;
                    accumulator.lock().unwrap().push_speech(frame, now_ms);
                }
            };

            let mut recorder = build_meeting_recorder(&vad_path, audio_cb)?;
            recorder
                .open(None)
                .map_err(|e| anyhow::anyhow!("Failed to open microphone for meeting: {}", e))?;
            if let Err(e) = recorder.start(VadPolicy::Offline) {
                let _ = recorder.close();
                bail!("Failed to start meeting capture: {}", e);
            }

            let shutdown = Arc::new(AtomicBool::new(false));

            let watchdog_handle = {
                let accumulator = Arc::clone(&accumulator);
                let shutdown = Arc::clone(&shutdown);
                let turn_tx = turn_tx.clone();
                thread::spawn(move || {
                    while !shutdown.load(Ordering::Relaxed) {
                        thread::sleep(WATCHDOG_POLL_INTERVAL);
                        let now_ms = capture_started.elapsed().as_millis() as i64;
                        let completed = accumulator
                            .lock()
                            .unwrap()
                            .take_if_silent(TURN_SILENCE_GAP, now_ms);
                        if let Some(turn) = completed {
                            let _ = turn_tx.send(turn);
                        }
                    }
                })
            };

            let transcriber_handle = {
                let db_path = self.db_path.clone();
                let app_handle = app_handle.clone();
                let transcription_manager = Arc::clone(&transcription_manager);
                let diarization_engine = self.diarization_engine.clone();
                thread::spawn(move || {
                    let conn = match Connection::open(&db_path) {
                        Ok(c) => c,
                        Err(e) => {
                            error!(
                                "Meeting {}: failed to open db connection for transcriber thread: {}",
                                meeting_id, e
                            );
                            return;
                        }
                    };
                    // El registro de hablantes vive acá, en el único hilo que
                    // atribuye segmentos de esta sesión: sin locks, y sin
                    // sobrevivir a la sesión (un hablante es local a una
                    // reunión, `data-model.md`).
                    let mut registry = SpeakerRegistry::default();
                    while let Ok(turn) = turn_rx.recv() {
                        // Diarizar ANTES de transcribir: `persist_and_emit_segment`
                        // consume `turn` (y le agrega padding a los turnos
                        // cortos, que falsearía la duración del audio que ve
                        // el motor de diarización).
                        let attribution = match diarization_engine.as_deref() {
                            Some(engine) if engine.is_loaded() => {
                                attribute_turn(engine, &turn.samples)
                            }
                            // Motor todavía cargando (o no disponible): el
                            // segmento se guarda sin hablante, que es
                            // exactamente lo que significa `NULL`.
                            _ => TurnAttribution::default(),
                        };
                        let speaker_id = match registry.resolve(
                            &conn,
                            meeting_id,
                            attribution.embedding.as_deref(),
                        ) {
                            Ok(id) => id,
                            Err(e) => {
                                warn!(
                                    "Meeting {}: no se pudo resolver el hablante del turno, \
                                     queda sin atribuir: {}",
                                    meeting_id, e
                                );
                                None
                            }
                        };

                        let transcribe =
                            |samples: Vec<f32>| transcription_manager.transcribe(samples);
                        match persist_and_emit_segment(
                            &conn,
                            Some(&app_handle),
                            meeting_id,
                            turn,
                            speaker_id,
                            attribution.overlapped,
                            &transcribe,
                        ) {
                            Ok(_) => {}
                            Err(e) => error!(
                                "Meeting {}: failed to persist a transcribed segment: {}",
                                meeting_id, e
                            ),
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
        let _ = session.recorder.stop();

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

        let _ = session.recorder.close();

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

    /// Secuencia completa de detención, pensada para correr fuera del hilo
    /// del comando: detiene la captura (bloquea hasta que el hilo
    /// transcriptor drena y persiste los turnos en cola — puede tardar
    /// segundos) y recién ahí marca la reunión como lista.
    ///
    /// Que no haya captura activa NO es un error acá: la reunión pudo
    /// haberse creado sin abrir el micrófono (o el proceso pudo perderla), y
    /// el estado igual tiene que poder cerrarse.
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
    use tauri::Listener;

    /// `None` con runtime explícito: `persist_and_emit_segment` es genérica
    /// sobre el runtime de Tauri (ver su doc comment), así que los tests que
    /// no verifican la emisión tienen que decir de qué runtime hablan.
    const NO_APP: Option<&AppHandle> = None;

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
    // T013: atribución de hablante por turno.
    //
    // Las dos mitades de la atribución se testean por separado y sin
    // modelos ONNX: `choose_dominant_speaker`/`extract_ranges` (qué audio
    // representa al hablante de este turno) son funciones puras sobre los
    // `DiarizedSegment` que devuelve el motor, y `SpeakerRegistry` (¿ya
    // habíamos oído esta voz?) es aritmética de coseno sobre embeddings.
    // Los embeddings sintéticos de acá abajo son vectores unitarios en 2D
    // con ángulos elegidos para caer a propósito en cada lado de los
    // umbrales; el camino con voces reales lo cubre el test `#[ignore]`
    // del final, que sí carga los dos modelos.
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
    fn choose_dominant_speaker_is_none_without_segments() {
        assert!(choose_dominant_speaker(&[]).is_none());
    }

    #[test]
    fn choose_dominant_speaker_picks_the_longest_and_keeps_only_its_clean_audio() {
        let segments = vec![
            seg(0, 0, 3_000, false),
            seg(1, 3_000, 3_200, false),
            seg(0, 3_200, 5_000, false),
        ];

        let dominant = choose_dominant_speaker(&segments).expect("hay segmentos");
        assert_eq!(dominant.speaker, 0);
        assert_eq!(dominant.clean_ranges, vec![(0, 3_000), (3_200, 5_000)]);
        assert!(!dominant.overlapped);
        assert!(
            !dominant.mixed,
            "200ms contra 4800ms no es una segunda voz con presencia comparable"
        );
    }

    #[test]
    fn choose_dominant_speaker_marks_two_comparable_voices_as_mixed() {
        let segments = vec![seg(0, 0, 2_000, false), seg(1, 2_000, 3_800, false)];

        let dominant = choose_dominant_speaker(&segments).expect("hay segmentos");
        assert!(
            dominant.mixed,
            "dos voces de duración comparable en el mismo turno deben marcarlo como mezclado"
        );
    }

    #[test]
    fn choose_dominant_speaker_excludes_overlapped_audio_from_the_embedding() {
        let segments = vec![
            seg(0, 0, 2_000, false),
            seg(0, 2_000, 2_500, true),
            seg(0, 2_500, 4_000, false),
        ];

        let dominant = choose_dominant_speaker(&segments).expect("hay segmentos");
        assert!(dominant.overlapped, "FR-004: la superposición se propaga");
        assert_eq!(
            dominant.clean_ranges,
            vec![(0, 2_000), (2_500, 4_000)],
            "el tramo superpuesto tiene dos voces mezcladas: no puede alimentar el embedding"
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
        let builder = tauri_specta::Builder::<tauri::test::MockRuntime>::new()
            .events(tauri_specta::collect_events![MeetingSegment]);
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
            let attribution = attribute_turn(&engine, &audio);
            let speaker_id = registry
                .resolve(&conn, meeting_id, attribution.embedding.as_deref())
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
}
