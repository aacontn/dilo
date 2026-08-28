use crate::audio_toolkit::{apply_custom_words, filter_transcription_output};
use crate::gemini_stt;
use crate::managers::audio::AudioRecordingManager;
use crate::managers::model::{EngineType, ModelManager};
use crate::settings::{
    get_settings, AppSettings, ModelUnloadTimeout, OrtAcceleratorSetting,
    TranscribeAcceleratorSetting,
};
use anyhow::Result;
use log::{debug, error, info, warn};
use serde::{Deserialize, Serialize};
use specta::Type;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Condvar, Mutex, MutexGuard, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime};
use tauri::{AppHandle, Emitter, Manager};
use tauri_specta::Event;
use transcribe_cpp::{
    Backend, Feature, Model, ModelOptions, RunExtension, RunOptions, Session, StreamOptions, Task,
    TimestampKind, WhisperRunOptions,
};
use transcribe_rs::{
    onnx::{
        canary::CanaryModel,
        cohere::CohereModel,
        gigaam::GigaAMModel,
        moonshine::{MoonshineModel, MoonshineVariant, StreamingModel},
        parakeet::{ParakeetModel, ParakeetParams, TimestampGranularity},
        sense_voice::{SenseVoiceModel, SenseVoiceParams},
        Quantization,
    },
    SpeechModel, TranscribeOptions,
};

const STREAM_PERF_LOG_INTERVAL: Duration = Duration::from_secs(5);
const STREAM_FINALIZE_REPLY_TIMEOUT: Duration = Duration::from_secs(30);

/// Id del proveedor cuya API key usa Gemini 3.5 Transcribe dentro de
/// `settings.post_process_api_keys`. Es la misma clave de Google que ya usa el
/// post-proceso: quien la pegó una vez no la pega de nuevo para dictar.
const GEMINI_API_KEY_ID: &str = "google";

#[derive(Clone, Debug, Serialize)]
pub struct ModelStateEvent {
    pub event_type: String,
    pub model_id: Option<String>,
    pub model_name: Option<String>,
    pub error: Option<String>,
}

/// Un token con marcas de tiempo *reales* — nunca interpoladas sobre la
/// duración del audio. `start_ms`/`end_ms` son milisegundos relativos al
/// inicio del turno de streaming. La Task 4 (alineación con diarización) los
/// cruza contra los tramos de hablante para atribuir cada palabra a quien la
/// dijo; una marca fabricada produciría una atribución que parece funcionar
/// pero está mal — por eso sólo se emiten cuando el motor los entrega de
/// verdad (ver `run_stream_worker`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, Type)]
pub struct TimedToken {
    pub text: String,
    pub start_ms: u64,
    pub end_ms: u64,
}

/// Concatena el texto plano de una secuencia de tokens con tiempo, en orden.
/// Es la garantía de que agregar tokens con tiempo al evento de streaming no
/// cambia el texto que el overlay del dictado (`RecordingOverlay.tsx`) ya
/// consume — ese overlay sigue leyendo sólo `committed`/`tentative`.
///
/// **Sólo para tests** (M3 de la revisión final): la Task 4 iba a ser su
/// consumidor productivo, pero `align::attribute` terminó concatenando token
/// a token mientras agrupa por hablante, así que en producción no la llama
/// nadie. En vez de conservarla viva con un `#[allow(dead_code)]` que
/// prometía un llamador que nunca llegó, queda detrás de `cfg(test)`: los
/// tests de esta sección la siguen usando para verificar que los tokens
/// reconstruyen el texto completo, y no queda código muerto en el binario.
#[cfg(test)]
pub fn plain_text(tokens: &[TimedToken]) -> String {
    tokens.iter().map(|t| t.text.as_str()).collect()
}

/// Live transcription snapshot emitted to the overlay during a streaming run.
/// `committed` is the append-only, flicker-free prefix; `tentative` is the
/// volatile suffix the model may still rewrite.
#[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct StreamTextEvent {
    pub committed: String,
    pub tentative: String,
    /// Tokens con tiempo del turno en curso. Se completa sólo cuando quien
    /// abrió el stream lo hizo con [`StreamPurpose::Meeting`] (ver
    /// `start_stream`) y sólo si el motor los entrega de verdad para el
    /// modelo cargado; `None` en cualquier otro caso, dictado incluido — el
    /// overlay del dictado no lee este campo, así que agregarlo no le cambia
    /// el comportamiento.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tokens: Option<Vec<TimedToken>>,
    /// Hasta qué milisegundo del audio que recibió el motor su transcripción
    /// ya está comprometida (`StreamUpdate::audio_committed_ms`) — el resto
    /// de `tokens` es hipótesis todavía revisable. Se completa bajo la misma
    /// condición que `tokens` (sólo [`StreamPurpose::Meeting`]); `None` en
    /// dictado.
    ///
    /// I3 de la revisión final: reuniones lo necesita para no **cerrar**
    /// (persistir) texto que el ASR todavía puede reescribir. Hasta ahora
    /// ese límite llegaba a `run_stream_worker` y se descartaba, y la
    /// colisión se evitaba por casualidad — porque el margen de estabilidad
    /// del diarizador (`SAFE_TAIL_MARGIN_S`) suele ser mayor que la ventana
    /// tentativa del ASR. Depender de que dos constantes de dos modelos
    /// distintos queden siempre en ese orden es un acoplamiento no
    /// declarado; esto lo vuelve explícito.
    ///
    /// El propio motor lo documenta como *hint* de progreso de la familia,
    /// no como garantía dura, así que quien lo consuma no debe tratarlo como
    /// única red de seguridad — ver `close_boundary_ms` en `meeting.rs`, que
    /// lo cruza con el reloj del diarizador y con un tope de espera.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_committed_ms: Option<u64>,
}

/// Phase of the streaming overlay card, emitted to drive its UI state.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "lowercase")]
pub enum StreamPhase {
    /// Receiving audio / live text (or waiting for the stream to begin). Rust
    /// does not emit this today; the frontend starts in this phase and Rust only
    /// emits transitions away from it.
    Listening,
    /// Finalizing or post-processing — show a spinner.
    Working,
}

/// Semantic kind of "working" phase, used to localize the spinner label.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "lowercase")]
pub enum StreamWorkKind {
    Transcribing,
    Polishing,
}

/// Emitted to switch the streaming overlay to a working spinner.
#[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct StreamPhaseEvent {
    pub phase: StreamPhase,
    /// Present only when `phase` is `Working`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<StreamWorkKind>,
}

/// Quién abre un stream de reconocimiento continuo — dicho explícitamente por
/// el llamador de [`TranscriptionManager::start_stream`], nunca inferido
/// leyendo estado global compartido (p.ej. `is_meeting_capture_active`). Hoy
/// dictado es el único llamador real; la Task 5 va a agregar reuniones como
/// segundo llamador del mismo worker, y en ese momento "¿hay una reunión
/// activa en algún lado?" deja de alcanzar para distinguirlos — por eso la
/// intención viaja como parámetro en vez de ambiente.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StreamPurpose {
    Dictation,
    /// `MeetingManager::start_capture` (`meeting.rs`) — pide marcas por token
    /// y el límite comprometido del audio, que sólo reuniones consume.
    Meeting,
}

/// El propósito del stream vivo cuando **no** es el de quien pide cerrarlo —
/// o sea, cuando cerrarlo sería apagarle el motor a otro. `None` significa
/// "adelante": o no hay stream, o es del mismo propósito.
///
/// Pura a propósito: la regla que impide que un dictado fallido mate una
/// reunión en curso se prueba acá directamente, sin levantar Tauri.
fn foreign_stream_owner(
    owner: Option<StreamPurpose>,
    caller: StreamPurpose,
) -> Option<StreamPurpose> {
    match owner {
        Some(owner) if owner != caller => Some(owner),
        _ => None,
    }
}

/// Núcleo de [`TranscriptionManager::cancel_stream`], sin `AppHandle` ni
/// manager, para poder probar contra un router de verdad que un cancel ajeno
/// no toca nada: ni cierra el canal, ni manda `Cancel`, ni baja la bandera de
/// stream vivo.
fn cancel_stream_on(
    router: &StreamRouter,
    stream_active: &AtomicBool,
    owner: Option<StreamPurpose>,
    caller: StreamPurpose,
) -> bool {
    if let Some(owner) = foreign_stream_owner(owner, caller) {
        warn!(
            "cancel_stream de {:?} ignorado: el stream vivo es de {:?}",
            caller, owner
        );
        return false;
    }
    if let Some(tx) = router.take() {
        let _ = tx.send(StreamCmd::Cancel);
    }
    stream_active.store(false, Ordering::Release);
    true
}

/// Commands sent to the streaming worker thread. Audio frames and the finalize
/// request travel the same channel so FIFO ordering guarantees every fed frame
/// is processed before finalize runs.
enum StreamCmd {
    Feed(Vec<f32>),
    /// Flush the stream and reply with the final text, or `None` if no stream
    /// was ever active (caller should fall back to batch transcription).
    Finalize(mpsc::Sender<Option<String>>),
    Cancel,
}

/// Routes real-time audio frames to the active streaming worker. Shared between
/// the [`TranscriptionManager`] (opens/closes the route) and the audio recorder's
/// per-frame callback (feeds frames). The recorder holds an `Arc<StreamRouter>`
/// directly, so a frame with no stream pending costs a single relaxed atomic
/// load — no Tauri state lookup, no mutex lock.
pub struct StreamRouter {
    /// Command channel to the active streaming worker, present from
    /// `start_stream` until `finalize_stream`/`cancel_stream`.
    tx: Mutex<Option<mpsc::Sender<StreamCmd>>>,
    /// True while a stream is pending or active (channel is open). The audio
    /// callback checks this first to avoid the mutex lock when no stream runs.
    open: Arc<AtomicBool>,
}

impl StreamRouter {
    fn new() -> Self {
        Self {
            tx: Mutex::new(None),
            open: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Open a fresh command channel for a new streaming session, returning the
    /// receiver the worker should drain. Caller must ensure no prior channel is
    /// still open.
    fn open(&self) -> mpsc::Receiver<StreamCmd> {
        let (tx, rx) = mpsc::channel::<StreamCmd>();
        *self.tx.lock().unwrap() = Some(tx);
        self.open.store(true, Ordering::Relaxed);
        rx
    }

    /// Take the sender out (closing the channel to new feeds). Returns the
    /// sender so the caller can send the final `Finalize`/`Cancel` command.
    fn take(&self) -> Option<mpsc::Sender<StreamCmd>> {
        self.open.store(false, Ordering::Relaxed);
        self.tx.lock().unwrap().take()
    }

    /// Drop the channel and mark closed without sending a final command (used
    /// when the worker exits without a finalize/cancel handshake).
    fn clear(&self) {
        self.open.store(false, Ordering::Relaxed);
        *self.tx.lock().unwrap() = None;
    }

    /// Forward a 16 kHz frame to the active streaming worker. Cheap no-op (a
    /// single relaxed atomic load) when no stream is pending.
    pub fn feed(&self, frame: &[f32]) {
        if !self.open.load(Ordering::Relaxed) {
            return;
        }
        if let Some(tx) = self.tx.lock().unwrap().as_ref() {
            let _ = tx.send(StreamCmd::Feed(frame.to_vec()));
        }
    }

    /// Whether a stream is pending or active.
    pub fn is_open(&self) -> bool {
        self.open.load(Ordering::Relaxed)
    }
}

enum LoadedEngine {
    /// Whisper-family models (whisper, breeze-asr, custom .bin/.gguf) via
    /// transcribe-cpp. Holds the live `Session`, which keeps its `Model` alive
    /// internally, so repeated dictation reuses the session without reloading.
    TranscribeCpp(Session),
    Parakeet(ParakeetModel),
    Moonshine(MoonshineModel),
    MoonshineStreaming(StreamingModel),
    SenseVoice(SenseVoiceModel),
    GigaAM(GigaAMModel),
    Canary(CanaryModel),
    Cohere(CohereModel),
    /// Gemini 3.5 Transcribe. Variante sin datos a propósito: no hay modelo ni
    /// sesión que sostener —el motor vive en el servidor— y la API key **no**
    /// se guarda acá. Se relee de los ajustes en cada transcripción, así que
    /// cambiarla surte efecto sin recargar el motor y nunca queda una copia
    /// del secreto viva en memoria más allá de la llamada.
    GeminiTranscribe,
}

/// RAII guard that clears the `is_loading` flag and notifies waiters on drop.
/// Ensures the loading flag is always reset, even on early returns or panics.
///
/// Delegates to [`TranscriptionManager::finish_loading`] rather than poking
/// `is_loading` directly, so a model request that arrived (and got queued,
/// see `decide_model_load_action`) while `switch_active_model` held this
/// guard for its synchronous load gets picked up the same way it would after
/// `initiate_model_load_id`'s own background load — see Causa 2 del reporte
/// de arreglo de reuniones (2026-08-03): before this, a request that raced
/// either kind of in-flight load was silently dropped.
pub struct LoadingGuard {
    manager: TranscriptionManager,
}

impl Drop for LoadingGuard {
    fn drop(&mut self) {
        self.manager.finish_loading();
    }
}

/// RAII guard that clears the streaming worker/lease flags on any worker exit -
/// normal return, early return, or a panic in an engine call that unwinds the
/// detached worker thread. Tokens prevent an older worker from clearing a newer
/// worker's state if a start/finalize race ever slips through.
struct StreamWorkerGuard {
    worker_id: u64,
    active_stream_worker: Arc<AtomicU64>,
    active_engine_lease: Arc<AtomicU64>,
    stream_active: Arc<AtomicBool>,
    /// Dueño del stream vivo (ver `TranscriptionManager::stream_owner`). Se
    /// limpia acá, y **antes** de soltar `active_stream_worker`, para que no
    /// exista un instante en el que un stream nuevo ya pudo arrancar y el
    /// dueño anotado siga siendo el del worker que se está muriendo.
    stream_owner: Arc<Mutex<Option<(u64, StreamPurpose)>>>,
}

impl Drop for StreamWorkerGuard {
    fn drop(&mut self) {
        if self.active_stream_worker.load(Ordering::Acquire) == self.worker_id {
            self.stream_active.store(false, Ordering::Release);
        }
        {
            let mut owner = self.stream_owner.lock().unwrap();
            if matches!(*owner, Some((id, _)) if id == self.worker_id) {
                *owner = None;
            }
        }
        let _ = self.active_engine_lease.compare_exchange(
            self.worker_id,
            0,
            Ordering::AcqRel,
            Ordering::Acquire,
        );
        let _ = self.active_stream_worker.compare_exchange(
            self.worker_id,
            0,
            Ordering::AcqRel,
            Ordering::Acquire,
        );
    }
}

#[derive(Clone)]
pub struct TranscriptionManager {
    engine: Arc<Mutex<Option<LoadedEngine>>>,
    model_manager: Arc<ModelManager>,
    app_handle: AppHandle,
    current_model_id: Arc<Mutex<Option<String>>>,
    last_activity: Arc<AtomicU64>,
    shutdown_signal: Arc<AtomicBool>,
    watcher_handle: Arc<Mutex<Option<thread::JoinHandle<()>>>>,
    is_loading: Arc<Mutex<bool>>,
    loading_condvar: Arc<Condvar>,
    reload_model_on_next_use: Arc<AtomicBool>,
    /// Model id the in-flight load (if any) is loading. `None` whenever
    /// `is_loading` is false. Lets `initiate_model_load_id` tell "the load
    /// already running targets this exact model" (a cheap no-op, unchanged
    /// from before) apart from "a DIFFERENT model was requested" (queued
    /// into `pending_model_id` instead of dropped). Only set by
    /// `initiate_model_load_id`'s own background load — `try_start_loading`
    /// (the slot `switch_active_model` uses for dictation's synchronous
    /// load) leaves it `None`, which is still correct: it just means a
    /// request racing THAT load always queues rather than deduping, at the
    /// cost of one harmless extra no-op once it's replayed.
    loading_target: Arc<Mutex<Option<String>>>,
    /// A model id requested via `initiate_model_load_id` while a different
    /// load was already in flight. `finish_loading` consumes it once that
    /// load ends and starts it. Only the latest request survives — an older
    /// queued id is simply overwritten, since only the last choice matters.
    /// This is Causa 2 del reporte de arreglo de reuniones (2026-08-03): a
    /// meeting's model request no longer disappears silently when it races
    /// the dictation model selector's own load.
    pending_model_id: Arc<Mutex<Option<String>>>,
    /// Routes real-time audio frames to the active streaming worker; see
    /// [`StreamRouter`]. Shared with the audio recorder so per-frame feeds skip
    /// Tauri state and the manager lock.
    router: Arc<StreamRouter>,
    /// True only while a transcribe-cpp `Stream` is actually in flight (set by
    /// the worker once `stream()` succeeds). Used for overlay/UI decisions.
    stream_active: Arc<AtomicBool>,
    /// Streaming uses four independent flags: router open = frames should route,
    /// worker active = no second worker may start, engine lease = engine is out
    /// of the mutex, stream active = UI should show a live session.
    ///
    /// Monotonic id source for stream workers; zero means "no worker".
    next_stream_worker_id: Arc<AtomicU64>,
    /// Nonzero while a stream worker exists, even if it has not leased the engine
    /// yet. This prevents a second worker from starting after finalize/cancel
    /// closes the router but before the first worker has fully exited.
    active_stream_worker: Arc<AtomicU64>,
    /// Nonzero while the streaming worker has taken the engine out of `engine`.
    /// `is_model_loaded()` consults this so the model still reports "loaded"
    /// while the worker holds it.
    active_engine_lease: Arc<AtomicU64>,
    /// Quién abrió el stream vivo y con qué worker — lo fija `start_stream`
    /// con el `purpose` que le pasó el llamador, y lo limpia el propio worker
    /// al salir ([`StreamWorkerGuard`]).
    ///
    /// Existe porque apagar un stream es una operación **con dueño**: un
    /// dictado que falla al abrir el micrófono (típico: hay una reunión
    /// grabando y el `MicrophoneArbiter` le niega el micrófono) llama a
    /// `cancel_stream` en su camino de reversa, y sin esta marca ese cancel
    /// mataba el motor de la reunión en curso — que seguía capturando audio
    /// sin nadie que lo transcribiera (reporte del dueño, 2026-08-04).
    /// `cancel_stream`/`finalize_stream` consultan esto y se niegan a tocar
    /// un stream de otro propósito.
    stream_owner: Arc<Mutex<Option<(u64, StreamPurpose)>>>,
    /// True mientras una reunión tiene el micrófono abierto. La captura de
    /// reunión no pasa por `AudioRecordingManager`, así que las dos rutas de
    /// descarga del modelo (el watcher de inactividad y
    /// [`Self::maybe_unload_immediately`]) no la ven — y descargar el modelo
    /// en medio de una reunión hace perder cada turno posterior. La marca la
    /// pone y la saca `MeetingManager::start_capture`/`stop_capture`.
    meeting_capture_active: Arc<AtomicBool>,
}

/// What `initiate_model_load_id` should do about a request, given the
/// current loading state. Pulled out of the method as a pure function —
/// no `AppHandle`, no locks, no threads — so the "don't drop a request for a
/// different model" rule (Causa 2 del reporte de arreglo de reuniones,
/// 2026-08-03) can be unit-tested directly instead of only through the
/// method's side effects.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ModelLoadAction {
    /// Nothing to do: either no load is in flight and `requested_model_id`
    /// is already current (and no forced reload is pending), or a load IS
    /// in flight and it already targets `requested_model_id`.
    Noop,
    /// No load is in flight (or one is, but a forced reload makes this a
    /// fresh request anyway): start loading `requested_model_id` now.
    Start,
    /// A load is in flight for a DIFFERENT model: remember this request
    /// instead of dropping it. Whoever finishes that load starts this one.
    Queue,
}

fn decide_model_load_action(
    is_loading: bool,
    loading_target: Option<&str>,
    current_model: Option<&str>,
    reload_pending: bool,
    requested_model_id: &str,
) -> ModelLoadAction {
    if is_loading {
        if loading_target == Some(requested_model_id) {
            ModelLoadAction::Noop
        } else {
            ModelLoadAction::Queue
        }
    } else if !reload_pending && current_model == Some(requested_model_id) {
        ModelLoadAction::Noop
    } else {
        ModelLoadAction::Start
    }
}

impl TranscriptionManager {
    pub fn new(app_handle: &AppHandle, model_manager: Arc<ModelManager>) -> Result<Self> {
        let manager = Self {
            engine: Arc::new(Mutex::new(None)),
            model_manager,
            app_handle: app_handle.clone(),
            current_model_id: Arc::new(Mutex::new(None)),
            last_activity: Arc::new(AtomicU64::new(Self::now_ms())),
            shutdown_signal: Arc::new(AtomicBool::new(false)),
            watcher_handle: Arc::new(Mutex::new(None)),
            is_loading: Arc::new(Mutex::new(false)),
            loading_condvar: Arc::new(Condvar::new()),
            reload_model_on_next_use: Arc::new(AtomicBool::new(false)),
            loading_target: Arc::new(Mutex::new(None)),
            pending_model_id: Arc::new(Mutex::new(None)),
            router: Arc::new(StreamRouter::new()),
            stream_active: Arc::new(AtomicBool::new(false)),
            next_stream_worker_id: Arc::new(AtomicU64::new(1)),
            active_stream_worker: Arc::new(AtomicU64::new(0)),
            active_engine_lease: Arc::new(AtomicU64::new(0)),
            stream_owner: Arc::new(Mutex::new(None)),
            meeting_capture_active: Arc::new(AtomicBool::new(false)),
        };

        // Start the idle watcher
        {
            let app_handle_cloned = app_handle.clone();
            let manager_cloned = manager.clone();
            let shutdown_signal = manager.shutdown_signal.clone();
            let handle = thread::spawn(move || {
                debug!("Idle watcher thread started");
                while !shutdown_signal.load(Ordering::Relaxed) {
                    thread::sleep(Duration::from_secs(10)); // Check every 10 seconds

                    // Check shutdown signal again after sleep
                    if shutdown_signal.load(Ordering::Relaxed) {
                        break;
                    }

                    let settings = get_settings(&app_handle_cloned);
                    let timeout = settings.model_unload_timeout;

                    // Skip Immediately — that variant is handled by
                    // maybe_unload_immediately() after each transcription.
                    // Treating it as 0s here would unload the model mid-recording.
                    if timeout == ModelUnloadTimeout::Immediately {
                        continue;
                    }

                    // While recording, keep the idle timer fresh so the
                    // model is never unloaded mid-session. La captura de
                    // reunión no pasa por `AudioRecordingManager` y sería
                    // invisible acá: sin ese segundo chequeo, un silencio
                    // largo en medio de una reunión (una pausa, un café)
                    // cuenta como inactividad, el modelo se descarga y cada
                    // turno posterior falla.
                    let is_recording = manager_cloned.is_meeting_capture_active()
                        || app_handle_cloned
                            .try_state::<Arc<AudioRecordingManager>>()
                            .is_some_and(|a| a.is_recording());
                    if is_recording {
                        manager_cloned.touch_activity();
                        continue;
                    }

                    if let Some(limit_seconds) = timeout.to_seconds() {
                        let last = manager_cloned.last_activity.load(Ordering::Relaxed);
                        let now_ms = TranscriptionManager::now_ms();
                        let idle_ms = now_ms.saturating_sub(last);
                        let limit_ms = limit_seconds * 1000;

                        if idle_ms > limit_ms {
                            // idle -> unload
                            if manager_cloned.is_model_loaded() {
                                let unload_start = std::time::Instant::now();
                                info!(
                                    "Model idle for {}s (limit: {}s), unloading",
                                    idle_ms / 1000,
                                    limit_seconds
                                );
                                match manager_cloned.unload_model() {
                                    Ok(()) => {
                                        let unload_duration = unload_start.elapsed();
                                        info!(
                                            "Model unloaded due to inactivity (took {}ms)",
                                            unload_duration.as_millis()
                                        );
                                    }
                                    Err(e) => {
                                        error!("Failed to unload idle model: {}", e);
                                    }
                                }
                            }
                        }
                    }
                }
                debug!("Idle watcher thread shutting down gracefully");
            });
            *manager.watcher_handle.lock().unwrap() = Some(handle);
        }

        Ok(manager)
    }

    /// Lock the engine mutex, recovering from poison if a previous transcription panicked.
    fn lock_engine(&self) -> MutexGuard<'_, Option<LoadedEngine>> {
        self.engine.lock().unwrap_or_else(|poisoned| {
            warn!("Engine mutex was poisoned by a previous panic, recovering");
            poisoned.into_inner()
        })
    }

    pub fn is_model_loaded(&self) -> bool {
        // The engine may be leased out to the streaming worker (taken out of
        // the mutex). It's still loaded, just in use, so report true.
        self.lock_engine().is_some() || self.active_engine_lease.load(Ordering::Acquire) != 0
    }

    /// Accelerator changes should not disturb the current transcription. Mark
    /// the cached engine stale; the next model-use path reloads it with the
    /// latest settings.
    pub fn reload_model_on_next_use(&self) {
        self.reload_model_on_next_use.store(true, Ordering::Release);
    }

    /// Atomically check whether a model load is in progress and, if not, mark
    /// one as starting. Returns a [`LoadingGuard`] whose [`Drop`] impl will
    /// clear the flag and wake waiters. Returns `None` if a load is already in
    /// progress.
    pub fn try_start_loading(&self) -> Option<LoadingGuard> {
        let mut is_loading = self.is_loading.lock().unwrap();
        if *is_loading {
            return None;
        }
        *is_loading = true;
        Some(LoadingGuard {
            manager: self.clone(),
        })
    }

    pub fn unload_model(&self) -> Result<()> {
        let unload_start = std::time::Instant::now();
        debug!("Starting to unload model");

        {
            let mut engine = self.lock_engine();
            // Dropping the engine frees all resources
            *engine = None;
        }
        {
            let mut current_model = self.current_model_id.lock().unwrap();
            *current_model = None;
        }

        // Emit unloaded event
        let _ = self.app_handle.emit(
            "model-state-changed",
            ModelStateEvent {
                event_type: "unloaded".to_string(),
                model_id: None,
                model_name: None,
                error: None,
            },
        );

        let unload_duration = unload_start.elapsed();
        debug!(
            "Model unloaded manually (took {}ms)",
            unload_duration.as_millis()
        );
        Ok(())
    }

    fn now_ms() -> u64 {
        SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64
    }

    /// Reset the idle timer to now. Pública porque la captura de reunión la
    /// llama desde su propio watchdog: sus turnos no pasan por el camino de
    /// dictado, así que es la única forma de que el watcher de inactividad
    /// sepa que el micrófono está trabajando.
    pub fn touch_activity(&self) {
        self.last_activity.store(Self::now_ms(), Ordering::Relaxed);
    }

    /// Marca (o desmarca) que hay una reunión capturando audio. Ver el campo
    /// `meeting_capture_active`.
    pub fn set_meeting_capture_active(&self, active: bool) {
        self.meeting_capture_active.store(active, Ordering::Release);
    }

    pub fn is_meeting_capture_active(&self) -> bool {
        self.meeting_capture_active.load(Ordering::Acquire)
    }

    /// Espera a que termine una carga de modelo en curso. Mismo patrón que
    /// usa `run_stream_worker`: el condvar avisa cuando el hilo de carga
    /// terminó (haya cargado o haya fallado), sin sondear ni dormir a ciegas.
    ///
    /// Sin llamador desde la Task 5 del plan "reuniones en streaming"
    /// (`.superpowers/sdd/2026-08-04-reuniones-en-streaming/`): el único uso
    /// era el chequeo por turno del viejo camino de transcripción batch de
    /// `MeetingManager` (`managers/meeting.rs`), que esa tarea reemplazó por
    /// un stream continuo — `start_stream` ya espera la carga en curso por
    /// su cuenta (mismo condvar), así que nadie más necesita bloquearse acá
    /// explícitamente. Se conserva pública y sin `#[allow(dead_code)]`
    /// fantasma porque es parte legítima de la API de este manager (mismo
    /// criterio que otros métodos públicos del archivo); se anota para que
    /// quede claro por qué no tiene llamador hoy, no para silenciar el lint.
    #[allow(dead_code)]
    pub fn wait_for_model_load(&self) {
        let mut is_loading = self.is_loading.lock().unwrap();
        while *is_loading {
            is_loading = self.loading_condvar.wait(is_loading).unwrap();
        }
    }

    /// Unloads the model immediately if the setting is enabled and the model is loaded
    pub fn maybe_unload_immediately(&self, context: &str) {
        // Una reunión en curso vuelve a necesitar el modelo en el próximo
        // turno, que llega en segundos: con "Descargar de inmediato" esto
        // descargaba el modelo después de CADA turno y el siguiente fallaba
        // (o pagaba una recarga completa). Mientras la reunión graba, el
        // modelo se queda; `stop_capture` levanta la marca y la próxima
        // transcripción de dictado lo descarga igual que siempre.
        if self.is_meeting_capture_active() {
            debug!(
                "Skipping immediate unload after {}: meeting capture is active",
                context
            );
            return;
        }
        let settings = get_settings(&self.app_handle);
        if settings.model_unload_timeout == ModelUnloadTimeout::Immediately
            && self.is_model_loaded()
        {
            info!("Immediately unloading model after {}", context);
            if let Err(e) = self.unload_model() {
                warn!("Failed to immediately unload model: {}", e);
            }
        }
    }

    pub fn load_model(&self, model_id: &str) -> Result<()> {
        self.load_model_with_device(model_id, None)
    }

    /// Like [`load_model`](Self::load_model), but lets a caller hard-select the
    /// compute device for this one load by its `transcribe_cpp::devices()`
    /// registry index (the index shown by `--list-devices`). `None` keeps the
    /// persisted accelerator setting (which may be Auto). Only affects
    /// transcribe-cpp (whisper-family) models; the selection is not persisted.
    pub fn load_model_with_device(
        &self,
        model_id: &str,
        device_index: Option<usize>,
    ) -> Result<()> {
        apply_accelerator_settings(&self.app_handle);

        let load_start = std::time::Instant::now();
        debug!("Starting to load model: {}", model_id);

        // Emit loading started event
        let _ = self.app_handle.emit(
            "model-state-changed",
            ModelStateEvent {
                event_type: "loading_started".to_string(),
                model_id: Some(model_id.to_string()),
                model_name: None,
                error: None,
            },
        );

        let model_info = self
            .model_manager
            .get_model_info(model_id)
            .ok_or_else(|| anyhow::anyhow!("Model not found: {}", model_id))?;

        if !model_info.is_downloaded {
            let error_msg = "Model not downloaded";
            let _ = self.app_handle.emit(
                "model-state-changed",
                ModelStateEvent {
                    event_type: "loading_failed".to_string(),
                    model_id: Some(model_id.to_string()),
                    model_name: Some(model_info.name.clone()),
                    error: Some(error_msg.to_string()),
                },
            );
            return Err(anyhow::anyhow!(error_msg));
        }

        // Un motor en línea no tiene archivo local y `get_model_path` falla a
        // propósito para él (ver `ModelManager::get_model_path`). Su rama de
        // carga no toca disco, así que ni se pregunta por la ruta.
        let model_path = match model_info.engine_type {
            EngineType::GeminiTranscribe => PathBuf::new(),
            _ => self.model_manager.get_model_path(model_id)?,
        };

        // Drop the current engine BEFORE building the new one so transcribe-cpp
        // frees the previous native context first — avoids holding two models at
        // once (peak memory on large GGUFs). Clear the id too: if the new load
        // fails, status should read "no loaded model", not the dropped engine.
        {
            let mut engine = self.lock_engine();
            *engine = None;
        }
        {
            let mut current_model = self.current_model_id.lock().unwrap();
            *current_model = None;
        }

        // Create appropriate engine based on model type
        let emit_loading_failed = |error_msg: &str| {
            let _ = self.app_handle.emit(
                "model-state-changed",
                ModelStateEvent {
                    event_type: "loading_failed".to_string(),
                    model_id: Some(model_id.to_string()),
                    model_name: Some(model_info.name.clone()),
                    error: Some(error_msg.to_string()),
                },
            );
        };

        let loaded_engine = match model_info.engine_type {
            EngineType::TranscribeCpp => {
                // The whisper backend is chosen at load time (transcribe-cpp has
                // no runtime global). With an explicit `device_index` (the
                // --device-index flag) hard-select that registered device;
                // otherwise re-read the persisted accelerator preference (so an
                // accelerator change marked for reload takes effect here).
                let (backend, gpu_device) = match device_index {
                    Some(index) => resolve_device_index(index).inspect_err(|e| {
                        emit_loading_failed(&e.to_string());
                    })?,
                    None => {
                        let settings = get_settings(&self.app_handle);
                        let accelerator = settings.transcribe_accelerator;
                        (
                            select_transcribe_backend(accelerator),
                            resolve_gpu_device(accelerator, settings.transcribe_gpu_device),
                        )
                    }
                };
                let model_options = ModelOptions {
                    backend,
                    gpu_device,
                };
                let model = Model::load_with(&model_path, &model_options).map_err(|e| {
                    let error_msg = format!("Failed to load whisper model {}: {}", model_id, e);
                    emit_loading_failed(&error_msg);
                    anyhow::anyhow!(error_msg)
                })?;
                // The bound backend may differ from the request (e.g. CPU
                // fallback under Auto); log what actually loaded.
                let bound_backend = model.backend();
                let session = model.session().map_err(|e| {
                    let error_msg = format!(
                        "Failed to create session for whisper model {}: {}",
                        model_id, e
                    );
                    emit_loading_failed(&error_msg);
                    anyhow::anyhow!(error_msg)
                })?;
                // Reconcile the registry's advertised capabilities with the
                // loaded model's real ones (GGUF metadata) so badges/gating
                // reflect runtime truth, not the pre-download probe. The
                // load-completed event below triggers the frontend refresh.
                let caps = session.model().capabilities();
                self.model_manager.set_runtime_capabilities(
                    model_id,
                    caps.supports_streaming,
                    caps.supports_translate,
                    caps.supports_language_detect,
                    caps.languages.clone(),
                );
                info!(
                    "Loaded whisper model '{}' (requested {:?}, gpu_device {}, bound backend '{}', \
                     supports_streaming={}, supports_translate={}, supports_language_detect={})",
                    model_id,
                    backend,
                    gpu_device,
                    bound_backend,
                    caps.supports_streaming,
                    caps.supports_translate,
                    caps.supports_language_detect
                );
                LoadedEngine::TranscribeCpp(session)
            }
            EngineType::Parakeet => {
                let engine =
                    ParakeetModel::load(&model_path, &Quantization::Int8).map_err(|e| {
                        let error_msg =
                            format!("Failed to load parakeet model {}: {}", model_id, e);
                        emit_loading_failed(&error_msg);
                        anyhow::anyhow!(error_msg)
                    })?;
                LoadedEngine::Parakeet(engine)
            }
            EngineType::Moonshine => {
                let engine = MoonshineModel::load(
                    &model_path,
                    MoonshineVariant::Base,
                    &Quantization::default(),
                )
                .map_err(|e| {
                    let error_msg = format!("Failed to load moonshine model {}: {}", model_id, e);
                    emit_loading_failed(&error_msg);
                    anyhow::anyhow!(error_msg)
                })?;
                LoadedEngine::Moonshine(engine)
            }
            EngineType::MoonshineStreaming => {
                let engine = StreamingModel::load(&model_path, 0, &Quantization::default())
                    .map_err(|e| {
                        let error_msg = format!(
                            "Failed to load moonshine streaming model {}: {}",
                            model_id, e
                        );
                        emit_loading_failed(&error_msg);
                        anyhow::anyhow!(error_msg)
                    })?;
                LoadedEngine::MoonshineStreaming(engine)
            }
            EngineType::SenseVoice => {
                let engine =
                    SenseVoiceModel::load(&model_path, &Quantization::Int8).map_err(|e| {
                        let error_msg =
                            format!("Failed to load SenseVoice model {}: {}", model_id, e);
                        emit_loading_failed(&error_msg);
                        anyhow::anyhow!(error_msg)
                    })?;
                LoadedEngine::SenseVoice(engine)
            }
            EngineType::GigaAM => {
                let engine = GigaAMModel::load(&model_path, &Quantization::Int8).map_err(|e| {
                    let error_msg = format!("Failed to load gigaam model {}: {}", model_id, e);
                    emit_loading_failed(&error_msg);
                    anyhow::anyhow!(error_msg)
                })?;
                LoadedEngine::GigaAM(engine)
            }
            EngineType::Canary => {
                let engine = CanaryModel::load(&model_path, &Quantization::Int8).map_err(|e| {
                    let error_msg = format!("Failed to load canary model {}: {}", model_id, e);
                    emit_loading_failed(&error_msg);
                    anyhow::anyhow!(error_msg)
                })?;
                LoadedEngine::Canary(engine)
            }
            EngineType::Cohere => {
                let engine = CohereModel::load(&model_path, &Quantization::Int8).map_err(|e| {
                    let error_msg = format!("Failed to load cohere model {}: {}", model_id, e);
                    emit_loading_failed(&error_msg);
                    anyhow::anyhow!(error_msg)
                })?;
                LoadedEngine::Cohere(engine)
            }
            EngineType::GeminiTranscribe => {
                // Un motor en línea no se carga: no hay archivo ni contexto
                // nativo que abrir. Lo único que puede fallar acá es que no
                // haya API key, y conviene que falle **acá** —la UI ya sabe
                // mostrar el error de carga— y no recién al soltar la tecla,
                // con el audio grabado y nada que hacer con él.
                let key_configured = get_settings(&self.app_handle)
                    .post_process_api_keys
                    .get(GEMINI_API_KEY_ID)
                    .is_some_and(|key| !key.trim().is_empty());
                if !key_configured {
                    let error_msg = "Falta la API key de Google. Pégala en Ajustes → \
                         Transformar → Claves para dictar con Gemini."
                        .to_string();
                    emit_loading_failed(&error_msg);
                    return Err(anyhow::anyhow!(error_msg));
                }
                info!("Motor en línea '{}' listo (sin carga local)", model_id);
                LoadedEngine::GeminiTranscribe
            }
        };

        // Update the current engine and model ID
        {
            let mut engine = self.lock_engine();
            *engine = Some(loaded_engine);
        }
        {
            let mut current_model = self.current_model_id.lock().unwrap();
            *current_model = Some(model_id.to_string());
        }

        // Reset idle timer so the watcher doesn't immediately unload a just-loaded model
        self.touch_activity();

        // Emit loading completed event
        let _ = self.app_handle.emit(
            "model-state-changed",
            ModelStateEvent {
                event_type: "loading_completed".to_string(),
                model_id: Some(model_id.to_string()),
                model_name: Some(model_info.name.clone()),
                error: None,
            },
        );

        let load_duration = load_start.elapsed();
        debug!(
            "Successfully loaded transcription model: {} (took {}ms)",
            model_id,
            load_duration.as_millis()
        );
        Ok(())
    }

    /// Kicks off the model loading in a background thread if it's not already
    /// loaded. Always targets `settings.selected_model` (dictation's model) —
    /// see [`Self::initiate_model_load_id`] for the explicit-id variant that
    /// meeting capture uses instead.
    pub fn initiate_model_load(&self) {
        let model_id = get_settings(&self.app_handle).selected_model;
        self.initiate_model_load_id(model_id);
    }

    /// Like [`Self::initiate_model_load`], but for an explicit `model_id`
    /// instead of always reading `settings.selected_model`.
    ///
    /// Meeting capture (`MeetingManager::start_capture`) uses this to load
    /// its own resolved model (`settings.meeting_model_id`, or dictation's
    /// as a fallback) without disturbing what dictation has selected, and
    /// again at `stop_capture` to switch back. It's also what
    /// `initiate_model_load` itself delegates to.
    ///
    /// Idempotent against the *target* id, not merely "is some model
    /// loaded": if a different model is currently loaded (e.g. a meeting's
    /// model still loaded right after the meeting stopped), this reloads to
    /// `model_id` instead of leaving the wrong one in place — the bug that
    /// motivated splitting this out of the old `initiate_model_load`, whose
    /// blanket `is_model_loaded()` check would have skipped the switch back.
    ///
    /// Also idempotent against a load *already in flight* for this exact
    /// `model_id` — calling this repeatedly for the same target while it's
    /// (being) loaded stays a cheap no-op, which is what lets meeting
    /// capture call it on every turn (Causa 3 del reporte de arreglo) without
    /// real cost. But a call for a DIFFERENT model while another load is in
    /// flight is no longer dropped silently (Causa 2 del mismo reporte): it
    /// is queued in `pending_model_id` and started by `finish_loading` as
    /// soon as the in-flight load ends — see `decide_model_load_action` for
    /// the pure decision behind this, and its unit tests below.
    pub fn initiate_model_load_id(&self, model_id: String) {
        let mut is_loading = self.is_loading.lock().unwrap();
        let reload_pending = self.reload_model_on_next_use.load(Ordering::Acquire);
        let action = {
            let loading_target = self.loading_target.lock().unwrap();
            decide_model_load_action(
                *is_loading,
                loading_target.as_deref(),
                self.get_current_model().as_deref(),
                reload_pending,
                &model_id,
            )
        };

        match action {
            ModelLoadAction::Noop => return,
            ModelLoadAction::Queue => {
                *self.pending_model_id.lock().unwrap() = Some(model_id);
                return;
            }
            ModelLoadAction::Start => {}
        }

        *is_loading = true;
        *self.loading_target.lock().unwrap() = Some(model_id.clone());
        drop(is_loading);

        let self_clone = self.clone();
        thread::spawn(move || {
            if reload_pending {
                self_clone
                    .reload_model_on_next_use
                    .store(false, Ordering::Release);
            }
            if let Err(e) = self_clone.load_model(&model_id) {
                error!("Failed to load model: {}", e);
            }
            self_clone.finish_loading();
        });
    }

    /// Clears the in-flight bookkeeping (`is_loading`, `loading_target`) and
    /// wakes anyone blocked in `wait_for_model_load`, then starts the next
    /// queued request if one arrived while this load was running
    /// (`pending_model_id`). Shared by `initiate_model_load_id`'s own
    /// background thread and by [`LoadingGuard`] (the slot
    /// `switch_active_model` holds for dictation's synchronous load), so a
    /// request queued during either kind of load gets picked up the same
    /// way.
    fn finish_loading(&self) {
        {
            let mut is_loading = self
                .is_loading
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            *is_loading = false;
            let mut loading_target = self
                .loading_target
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            *loading_target = None;
            self.loading_condvar.notify_all();
        }
        let next = self
            .pending_model_id
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take();
        if let Some(next_id) = next {
            self.initiate_model_load_id(next_id);
        }
    }

    pub fn get_current_model(&self) -> Option<String> {
        let current_model = self.current_model_id.lock().unwrap();
        current_model.clone()
    }

    /// The compute backend the currently-loaded engine is bound to, for
    /// diagnostics (e.g. confirming `--device-index` actually bound a GPU rather
    /// than falling back to CPU/auto). transcribe-cpp (whisper-family) reports
    /// its real backend string; ONNX engines report "onnx"; `None` when no
    /// model is loaded.
    pub fn current_backend(&self) -> Option<String> {
        match self.lock_engine().as_ref() {
            Some(LoadedEngine::TranscribeCpp(session)) => {
                Some(session.model().backend().to_string())
            }
            // No hay backend de cómputo local que reportar: corre en Google.
            Some(LoadedEngine::GeminiTranscribe) => Some("cloud".to_string()),
            Some(_) => Some("onnx".to_string()),
            None => None,
        }
    }

    /// Whether a live streaming run is currently in flight.
    pub fn is_streaming(&self) -> bool {
        self.stream_active.load(Ordering::Acquire)
    }

    /// Shared handle to the stream router, used by the audio recorder to feed
    /// real-time frames without going through Tauri state on every frame.
    pub fn stream_router(&self) -> Arc<StreamRouter> {
        Arc::clone(&self.router)
    }

    /// Begin a live streaming transcription on the held engine's session.
    /// Audio frames pushed via [`StreamRouter::feed`] (captured directly by the
    /// audio recorder) are decoded incrementally and emitted to the overlay as
    /// [`StreamTextEvent`].
    ///
    /// `purpose` es quién abre el stream, dicho explícitamente por el llamador
    /// — no se infiere leyendo `is_meeting_capture_active()` (una bandera
    /// global). Hoy dictado y reuniones nunca coexisten porque el
    /// `MicrophoneArbiter` lo impide, así que ambas fuentes coinciden en la
    /// práctica; pero cuando la Task 5 conecte reuniones a este mismo
    /// streaming va a haber dos llamadores reales, y sólo el parámetro
    /// explícito los distingue de forma confiable.
    ///
    /// Non-blocking: spawns a worker that waits for any in-progress model load,
    /// verifies the model supports streaming, then begins the stream. If the
    /// model can't stream, the worker idles until finalize/cancel and reports
    /// `None` so the caller falls back to batch transcription. Frames sent
    /// before the stream begins queue on the channel and are not lost.
    pub fn start_stream(&self, purpose: StreamPurpose) {
        if self.router.is_open() || self.active_stream_worker.load(Ordering::Acquire) != 0 {
            warn!("start_stream called while a stream worker is already active");
            return;
        }
        let worker_id = self.next_stream_worker_id.fetch_add(1, Ordering::Relaxed);
        if self
            .active_stream_worker
            .compare_exchange(0, worker_id, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            warn!("start_stream lost a race with another stream worker");
            return;
        }
        *self.stream_owner.lock().unwrap() = Some((worker_id, purpose));
        let rx = self.router.open();
        self.stream_active.store(false, Ordering::Release);

        let manager = self.clone();
        thread::spawn(move || manager.run_stream_worker(rx, worker_id, purpose));
    }

    fn run_stream_worker(
        &self,
        rx: mpsc::Receiver<StreamCmd>,
        worker_id: u64,
        purpose: StreamPurpose,
    ) {
        let _worker = StreamWorkerGuard {
            worker_id,
            active_stream_worker: Arc::clone(&self.active_stream_worker),
            active_engine_lease: Arc::clone(&self.active_engine_lease),
            stream_active: Arc::clone(&self.stream_active),
            stream_owner: Arc::clone(&self.stream_owner),
        };

        // Wait for any in-progress model load to finish (start_stream races the
        // background load kicked off when recording starts).
        {
            let mut is_loading = self.is_loading.lock().unwrap();
            while *is_loading {
                is_loading = self.loading_condvar.wait(is_loading).unwrap();
            }
        }

        let model_id = self.get_current_model().unwrap_or_default();

        // Take the engine out of the mutex so we own it during streaming,
        // structurally excluding any concurrent batch transcription (which
        // transcribe-cpp's compute_lock would refuse anyway). Returned when the
        // worker exits, or dropped if the model was switched/unloaded mid-stream.
        if self
            .active_engine_lease
            .compare_exchange(0, worker_id, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            warn!("Live preview: another worker already holds the transcription engine");
            self.router.clear();
            drain_until_finalize(rx);
            return;
        }
        let mut engine = match self.lock_engine().take() {
            Some(e) => e,
            None => {
                info!(
                    "Live preview: model '{}' was unloaded before streaming could begin; \
                     falling back to batch transcription",
                    model_id
                );
                let _ = self.active_engine_lease.compare_exchange(
                    worker_id,
                    0,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                );
                self.router.clear();
                drain_until_finalize(rx);
                return;
            }
        };

        // Only transcribe-cpp models expose streaming; ONNX engines fall back to
        // batch. The loaded session (not the ModelManager copy) is the source of
        // truth for run-path capabilities.
        let (supports_streaming, supports_translate, languages) = match &engine {
            LoadedEngine::TranscribeCpp(session) => {
                let model = session.model();
                let caps = model.capabilities();
                info!(
                    "Live preview: model '{}' arch='{}' variant='{}' supports_streaming={} \
                     supports_translate={} languages={:?}",
                    model_id,
                    model.arch(),
                    model.variant(),
                    caps.supports_streaming,
                    caps.supports_translate,
                    caps.languages,
                );
                (
                    caps.supports_streaming,
                    caps.supports_translate,
                    caps.languages,
                )
            }
            _ => {
                info!(
                    "Live preview: model '{}' is not a transcribe-cpp model; \
                     streaming is unavailable, using batch transcription",
                    model_id
                );
                (false, false, Vec::new())
            }
        };

        if !supports_streaming {
            self.return_engine(engine, &model_id);
            self.router.clear();
            drain_until_finalize(rx);
            return;
        }

        // Build run options mirroring the offline transcribe-cpp path: task +
        // language gated against what the model actually advertises.
        let settings = get_settings(&self.app_handle);
        let effective_language =
            effective_language_for_model(&settings, self.model_manager.as_ref(), &model_id);
        let run_plan = transcribe_cpp_run_plan(
            settings.translate_to_english,
            &effective_language,
            &languages,
            supports_translate,
        );
        // Marcas por token: sólo cuando quien abrió el stream dijo que era una
        // reunión (Task 4 las necesita para alinear con la diarización). El
        // dictado (`StreamPurpose::Dictation`, el único llamador real hoy) se
        // queda con `TimestampKind::Auto` — el default de siempre — así que su
        // comportamiento no cambia un bit. Deliberadamente NO se lee
        // `is_meeting_capture_active()` aquí: esa bandera es ambiente global
        // compartido, y la Task 5 va a hacer que dictado y reuniones sean dos
        // llamadores reales de este mismo worker.
        let is_meeting = matches!(purpose, StreamPurpose::Meeting);
        let run_options = RunOptions {
            task: run_plan.task,
            language: run_plan.language,
            target_language: run_plan.target_language,
            timestamps: if is_meeting {
                TimestampKind::Token
            } else {
                TimestampKind::Auto
            },
            ..Default::default()
        };

        // Run the stream on the held session. The Stream borrows the session
        // (and thus the engine) for its lifetime, so the feed/finalize loop
        // lives in a labeled block — when it exits, the borrow is released and
        // the engine can be moved into return_engine().
        let mut finalize_reply: Option<mpsc::Sender<Option<String>>> = None;
        let mut finalize_result: Option<Option<String>> = None;
        let stream_started = 'stream: {
            let session = match &mut engine {
                LoadedEngine::TranscribeCpp(s) => s,
                _ => break 'stream false,
            };

            // Read the backend string before beginning the stream — the
            // `Stream` borrows `session` mutably for its lifetime, so we can't
            // call `session.model()` once it exists.
            let backend = session.model().backend();

            // StreamOptions::default() uses CommitPolicy::Auto and lets the
            // family pick its own streaming strategy (no family-specific ext).
            let mut stream = match session.stream(&run_options, &StreamOptions::default()) {
                Ok(s) => s,
                Err(e) => {
                    error!("Failed to begin stream: {}", e);
                    break 'stream false;
                }
            };

            self.stream_active.store(true, Ordering::Release);
            self.touch_activity();
            info!(
                "Live streaming transcription started (model '{}', backend '{}')",
                model_id, backend
            );

            let mut perf = StreamPerf::new();
            while let Ok(cmd) = rx.recv() {
                match cmd {
                    StreamCmd::Feed(pcm) => {
                        self.touch_activity();
                        perf.record_feed(pcm.len());
                        let feed_start = Instant::now();
                        match stream.feed(&pcm) {
                            Ok(update) => {
                                perf.record_compute(feed_start.elapsed());
                                perf.record_update(
                                    update.revision,
                                    update.input_received_ms,
                                    update.audio_committed_ms,
                                    update.buffered_ms,
                                );
                                if update.committed_changed || update.tentative_changed {
                                    let text = stream.text();
                                    perf.record_emit();
                                    // `snapshot()` materializa segmentos/palabras/tokens
                                    // desde el motor — un costo extra que sólo vale la
                                    // pena pagar en reuniones, nunca en dictado.
                                    let (tokens, committed_ms) = if is_meeting {
                                        (
                                            Some(timed_tokens_from_snapshot(&stream)),
                                            Some(update.audio_committed_ms.max(0) as u64),
                                        )
                                    } else {
                                        (None, None)
                                    };
                                    self.emit_stream_text(
                                        &text.committed,
                                        &text.tentative,
                                        tokens,
                                        committed_ms,
                                    );
                                }
                                perf.maybe_log();
                            }
                            Err(e) => {
                                perf.record_compute(feed_start.elapsed());
                                warn!("stream feed failed: {}", e);
                            }
                        }
                    }
                    StreamCmd::Finalize(reply) => {
                        let finalize_start = Instant::now();
                        let result = match stream.finalize() {
                            // After finalize the committed prefix holds the full
                            // text; display() = committed + tentative is the safe read.
                            Ok(update) => {
                                perf.record_compute(finalize_start.elapsed());
                                perf.record_update(
                                    update.revision,
                                    update.input_received_ms,
                                    update.audio_committed_ms,
                                    update.buffered_ms,
                                );
                                Some(stream.text().display())
                            }
                            Err(e) => {
                                perf.record_compute(finalize_start.elapsed());
                                error!(
                                    "stream finalize failed: {}; falling back to batch transcription",
                                    e
                                );
                                None
                            }
                        };
                        let chars = match &result {
                            Some(text) => text.len(),
                            _ => 0,
                        };
                        perf.log_finalized(chars);
                        finalize_reply = Some(reply);
                        finalize_result = Some(result);
                        break;
                    }
                    StreamCmd::Cancel => {
                        stream.reset();
                        break;
                    }
                }
            }

            true
        };
        // `stream` + the `&mut engine` borrow are released here.

        if !stream_started {
            // Stream never began (model doesn't support streaming or begin
            // failed); drain so the finalize handshake still completes and the
            // caller falls back to batch transcription. Return the engine first
            // so the fallback can immediately use it.
            self.return_engine(engine, &model_id);
            drain_until_finalize(rx);
            return;
        }

        self.return_engine(engine, &model_id);
        if let (Some(reply), Some(result)) = (finalize_reply, finalize_result) {
            let _ = reply.send(result);
        }
        // `_worker` drops here, clearing this worker's active/lease flags after
        // the engine has been returned to the pool.
    }

    /// Return the leased engine to the mutex, unless the model was switched or
    /// unloaded during transcription (in which case the stale engine is dropped).
    fn return_engine(&self, engine: LoadedEngine, expected_model_id: &str) {
        let still_current =
            self.current_model_id.lock().unwrap().as_deref() == Some(expected_model_id);
        if still_current {
            *self.lock_engine() = Some(engine);
        } else {
            info!(
                "Model changed/unloaded during transcription; dropping stale engine (was '{}')",
                expected_model_id
            );
            // `engine` drops here, freeing its resources.
        }
    }

    /// Dueño del stream vivo, si hay uno (ver [`Self::stream_owner`]).
    fn stream_owner_purpose(&self) -> Option<StreamPurpose> {
        self.stream_owner
            .lock()
            .unwrap()
            .map(|(_, purpose)| purpose)
    }

    /// Flush the active stream and return its final, post-filtered text.
    ///
    /// `caller` es quién pide cerrar: si el stream vivo lo abrió otro
    /// propósito (dictado contra reunión), esto devuelve `Ok(None)` sin
    /// tocarlo — el texto de una reunión no es el dictado de nadie, y
    /// cerrarlo dejaría a la reunión capturando audio sin transcribir.
    ///
    /// `Ok(None)` means no usable stream was active and the caller may fall back
    /// to batch transcription. `Err` means finalize itself failed or timed out.
    /// A timeout may still leave the worker holding the engine, so callers
    /// should surface it instead of immediately starting a batch fallback.
    pub fn finalize_stream(&self, caller: StreamPurpose) -> Result<Option<String>> {
        if let Some(owner) = foreign_stream_owner(self.stream_owner_purpose(), caller) {
            warn!(
                "finalize_stream de {:?} ignorado: el stream vivo es de {:?}",
                caller, owner
            );
            return Ok(None);
        }
        let Some(tx) = self.router.take() else {
            return Ok(None);
        };
        let (reply_tx, reply_rx) = mpsc::channel();
        if tx.send(StreamCmd::Finalize(reply_tx)).is_err() {
            return Ok(None);
        }
        let raw = match reply_rx.recv_timeout(STREAM_FINALIZE_REPLY_TIMEOUT) {
            Ok(Some(text)) => text,
            Ok(None) => return Ok(None),
            Err(mpsc::RecvTimeoutError::Disconnected) => return Ok(None),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                self.stream_active.store(false, Ordering::Release);
                return Err(anyhow::anyhow!(
                    "Timed out waiting {:?} for live transcription to finalize",
                    STREAM_FINALIZE_REPLY_TIMEOUT
                ));
            }
        };

        let settings = get_settings(&self.app_handle);
        // Streaming models do not receive a decode prompt, so custom words
        // always go through the shared fuzzy post-correction path.
        // El streaming en vivo sólo existe en transcribe-cpp, así que acá nunca
        // hay texto de Gemini: el filtro local de muletillas corre siempre.
        let filtered = post_process_transcription_text(raw, &settings, false, false);

        self.maybe_unload_immediately("streaming transcription");
        Ok(Some(filtered))
    }

    /// Abandon any active stream without producing text (e.g. on cancel).
    ///
    /// `caller` es quién cancela. Un stream abierto por otro propósito no se
    /// toca: el caso real es un dictado que no consigue el micrófono porque
    /// hay una reunión grabando y, al deshacer su propio arranque, apagaba el
    /// motor de esa reunión (reporte del dueño, 2026-08-04). Devuelve si de
    /// verdad canceló algo.
    pub fn cancel_stream(&self, caller: StreamPurpose) -> bool {
        cancel_stream_on(
            &self.router,
            &self.stream_active,
            self.stream_owner_purpose(),
            caller,
        )
    }

    /// Emit a working-phase event to the streaming overlay (spinner + label).
    pub fn emit_stream_working(&self, kind: StreamWorkKind) {
        let _ = StreamPhaseEvent {
            phase: StreamPhase::Working,
            kind: Some(kind),
        }
        .emit(&self.app_handle);
    }

    fn emit_stream_text(
        &self,
        committed: &str,
        tentative: &str,
        tokens: Option<Vec<TimedToken>>,
        audio_committed_ms: Option<u64>,
    ) {
        let _ = StreamTextEvent {
            committed: committed.to_string(),
            tentative: tentative.to_string(),
            tokens,
            audio_committed_ms,
        }
        .emit(&self.app_handle);
    }

    /// Dicta con Gemini 3.5 Transcribe: audio adentro, texto listo para pegar.
    ///
    /// Se llama **sin** el mutex del motor tomado (ver el desvío al principio
    /// de [`Self::transcribe`]). El error tipado de `gemini_stt` viaja entero
    /// dentro del `anyhow` —no se aplana a texto— para que quien decide la
    /// caída al modelo local pueda `downcast_ref::<GeminiSttError>()` y
    /// distinguir "no hay red" de "la clave no sirve".
    fn transcribe_with_gemini(
        &self,
        audio: &[f32],
        settings: &AppSettings,
        started: Instant,
    ) -> Result<String> {
        // La key se relee acá, en el momento de usarla: nunca se guarda en la
        // variante del motor ni se loguea (el `SecretMap` ya redacta su Debug).
        let key = settings
            .post_process_api_keys
            .get(GEMINI_API_KEY_ID)
            .map(|key| key.trim().to_string())
            .filter(|key| !key.is_empty())
            .ok_or_else(|| anyhow::Error::new(gemini_stt::GeminiSttError::MissingKey))?;

        // `gemini_stt::transcribe` es async y esto es sincrónico, pero
        // `tauri::async_runtime::block_on` NO se puede llamar directamente
        // desde acá: el camino real de dictado corre dentro de un
        // `async_runtime::spawn` (`actions.rs`), y tokio entra en pánico
        // ("Cannot start a runtime from within a runtime") si se bloquea uno
        // de sus hilos. Un hilo propio y de vida corta no está en el contexto
        // del runtime, así que ahí el `block_on` es legítimo. `thread::scope`
        // evita clonar el audio y la key sólo para cruzar el `spawn`.
        let outcome = thread::scope(|scope| {
            scope
                .spawn(|| {
                    tauri::async_runtime::block_on(gemini_stt::transcribe(
                        audio,
                        &key,
                        settings.gemini_smart_mode,
                        &settings.custom_words,
                    ))
                })
                .join()
        });

        let raw = match outcome {
            Ok(Ok(text)) => text,
            Ok(Err(err)) => return Err(anyhow::Error::new(err)),
            Err(_) => {
                return Err(anyhow::anyhow!(
                    "El dictado con Gemini se cayó de forma inesperada"
                ))
            }
        };

        // `apply_custom_words` sigue corriendo aunque las palabras ya hayan
        // viajado como vocabulario: el biasing en origen no siempre pilla
        // todo, y la corrección difusa local es inofensiva sobre lo que ya
        // salió bien. El filtro de muletillas, en cambio, sobra cuando el
        // modo smart ya limpió — ver `should_skip_filler_filter`.
        let filtered = post_process_transcription_text(
            raw,
            settings,
            false,
            should_skip_filler_filter(&EngineType::GeminiTranscribe, settings.gemini_smart_mode),
        );

        let elapsed_secs = started.elapsed().as_secs_f64();
        let audio_secs = audio.len() as f64 / 16_000.0;
        info!(
            "Dictado con Gemini completado en {:.2}s para {:.2}s de audio (smart={})",
            elapsed_secs, audio_secs, settings.gemini_smart_mode
        );
        if filtered.is_empty() {
            info!("Transcription result is empty");
        } else {
            info!("Transcription result: {}", filtered);
        }

        // Nada que descargar (no hay modelo en memoria), pero el motor local
        // que quedó cargado antes de cambiar a Gemini sí puede irse: se
        // respeta la misma preferencia de siempre.
        self.maybe_unload_immediately("transcripción en línea");

        Ok(filtered)
    }

    pub fn transcribe(&self, audio: Vec<f32>) -> Result<String> {
        #[cfg(debug_assertions)]
        if std::env::var("HANDY_FORCE_TRANSCRIPTION_FAILURE").is_ok() {
            return Err(anyhow::anyhow!(
                "Simulated transcription failure (HANDY_FORCE_TRANSCRIPTION_FAILURE)"
            ));
        }

        // Update last activity timestamp
        self.touch_activity();

        let st = std::time::Instant::now();
        let audio_len = audio.len();

        debug!("Audio vector length: {}", audio_len);

        if audio.is_empty() {
            debug!("Empty audio vector");
            self.maybe_unload_immediately("empty audio");
            return Ok(String::new());
        }

        // Check if model is loaded, if not try to load it
        {
            // If the model is loading, wait for it to complete.
            let mut is_loading = self.is_loading.lock().unwrap();
            while *is_loading {
                is_loading = self.loading_condvar.wait(is_loading).unwrap();
            }

            let engine_guard = self.lock_engine();
            if engine_guard.is_none() {
                return Err(anyhow::anyhow!("Model is not loaded for transcription."));
            }
        }

        // Get current settings for configuration
        let settings = get_settings(&self.app_handle);

        // El motor en línea se atiende ANTES del camino local, y sin el mutex
        // del motor tomado: la llamada a la API puede tardar hasta 45 s, y
        // dejar `lock_engine()` agarrado todo ese rato congelaría cualquier
        // otra cosa que lo pida (el watcher de inactividad, un cambio de
        // modelo, el próximo dictado). Este `matches!` toma el candado sólo
        // para mirar la variante y lo suelta en el mismo statement.
        if matches!(*self.lock_engine(), Some(LoadedEngine::GeminiTranscribe)) {
            return self.transcribe_with_gemini(&audio, &settings, st);
        }

        // Validate selected language against the model's supported languages.
        // If the language isn't supported, fall back to "auto" to prevent errors.
        // Validate against the model that's actually loaded (which can differ
        // from settings.selected_model when a caller loaded a specific model —
        // e.g. the --transcribe-file path's --model), not the persisted
        // selection.
        let active_model = self
            .get_current_model()
            .unwrap_or_else(|| settings.selected_model.clone());
        // Resolve the persisted language *intent* into the language this model
        // will actually use. The coercion is capability-aware (a must-pick model
        // never receives "auto") and computed fresh here — it is never written
        // back to settings, so the intent survives switching models and back.
        let validated_language =
            effective_language_for_model(&settings, self.model_manager.as_ref(), &active_model);
        if validated_language != settings.selected_language {
            debug!(
                "Language intent '{}' resolved to '{}' for model '{}'",
                settings.selected_language, validated_language, active_model
            );
        }

        // (`model_takes_initial_prompt` — informational, logged where the
        // capabilities are probed; the whisper run extension and the
        // fuzzy-correction skip are gated on `model_is_whisper` instead,
        // since non-whisper archs can advertise Feature::InitialPrompt
        // while rejecting the whisper-kind extension.)
        // Whether the loaded model is actually whisper-family (arch string).
        // Non-whisper archs (e.g. Voxtral Small) can advertise
        // Feature::InitialPrompt yet reject the whisper-kind run extension
        // with INVALID_ARG, so the whisper extension must be gated on the
        // arch, not on the feature (see #1601).
        let mut model_is_whisper = false;

        // Perform transcription with the appropriate engine.
        // We use catch_unwind to prevent engine panics from poisoning the mutex,
        // which would make the app hang indefinitely on subsequent operations.
        let result = {
            let mut engine_guard = self.lock_engine();

            // Take the engine out so we own it during transcription.
            // If the engine panics, we simply don't put it back (effectively unloading it)
            // instead of poisoning the mutex.
            let mut engine = match engine_guard.take() {
                Some(e) => e,
                None => {
                    return Err(anyhow::anyhow!(
                        "Model failed to load after auto-load attempt. Please check your model settings."
                    ));
                }
            };

            // Release the lock before transcribing — no mutex held during the engine call
            drop(engine_guard);

            // Probe live transcribe-cpp capabilities once (cheap GGUF-metadata
            // reads); the loaded session is the source of truth, not the
            // ModelManager copy. The whisper run extension is kind-tagged, so
            // non-whisper archs (parakeet, voxtral, …) reject it with
            // INVALID_ARG; attach it — and translate — only where supported.
            let mut model_supports_translate = false;
            let mut model_languages: Vec<String> = Vec::new();
            if let LoadedEngine::TranscribeCpp(session) = &engine {
                let model = session.model();
                let caps = model.capabilities();
                let model_takes_initial_prompt = model.supports(Feature::InitialPrompt);
                model_is_whisper = model.arch() == "whisper";
                model_supports_translate = caps.supports_translate;
                model_languages = caps.languages;
                debug!(
                    "transcribe-cpp model '{}' on '{}': initial_prompt={}, translate={}, languages={:?}",
                    settings.selected_model,
                    model.backend(),
                    model_takes_initial_prompt,
                    model_supports_translate,
                    model_languages
                );
            }

            let transcribe_result = catch_unwind(AssertUnwindSafe(|| -> Result<String> {
                match &mut engine {
                    LoadedEngine::TranscribeCpp(session) => {
                        // Custom words become the initial prompt ONLY for models
                        // that accept one (whisper family). Attaching the
                        // whisper run extension to a non-whisper arch is rejected
                        // with INVALID_ARG, so skip it there and let the fuzzy
                        // post-correction handle custom words instead.
                        let family = if settings.custom_words.is_empty() || !model_is_whisper {
                            None
                        } else {
                            Some(RunExtension::Whisper(WhisperRunOptions {
                                initial_prompt: Some(settings.custom_words.join(", ")),
                                ..Default::default()
                            }))
                        };

                        let run_plan = transcribe_cpp_run_plan(
                            settings.translate_to_english,
                            &validated_language,
                            &model_languages,
                            model_supports_translate,
                        );

                        let run_options = RunOptions {
                            task: run_plan.task,
                            language: run_plan.language,
                            target_language: run_plan.target_language,
                            family,
                            ..Default::default()
                        };

                        debug!(
                            "transcribe-cpp run: task={:?}, language={:?}, initial_prompt={}",
                            run_options.task,
                            run_options.language,
                            run_options.family.is_some()
                        );

                        session
                            .run(&audio, &run_options)
                            .map(|t| t.text)
                            .map_err(|e| {
                                anyhow::anyhow!("transcribe-cpp transcription failed: {}", e)
                            })
                    }
                    LoadedEngine::Parakeet(parakeet_engine) => {
                        // Reuniones piden granularidad por token (real, no
                        // interpolada — transcribe-rs la arma por token igual
                        // que por segmento, sólo cambia cómo agrupa
                        // `.segments`); dictado se queda con `Segment` como
                        // hasta ahora. `.text` no cambia con la granularidad
                        // elegida en ningún caso — este `match` sólo extrae
                        // `.text`, así que el dictado queda bit a bit igual.
                        let granularity = if self.is_meeting_capture_active() {
                            TimestampGranularity::Token
                        } else {
                            TimestampGranularity::Segment
                        };
                        let params = ParakeetParams {
                            timestamp_granularity: Some(granularity),
                            ..Default::default()
                        };
                        parakeet_engine
                            .transcribe_with(&audio, &params)
                            .map(|r| r.text)
                            .map_err(|e| anyhow::anyhow!("Parakeet transcription failed: {}", e))
                    }
                    LoadedEngine::Moonshine(moonshine_engine) => moonshine_engine
                        .transcribe(&audio, &TranscribeOptions::default())
                        .map(|r| r.text)
                        .map_err(|e| anyhow::anyhow!("Moonshine transcription failed: {}", e)),
                    LoadedEngine::MoonshineStreaming(streaming_engine) => streaming_engine
                        .transcribe(&audio, &TranscribeOptions::default())
                        .map(|r| r.text)
                        .map_err(|e| {
                            anyhow::anyhow!("Moonshine streaming transcription failed: {}", e)
                        }),
                    LoadedEngine::SenseVoice(sense_voice_engine) => {
                        let language = match normalize_cjk_language(&validated_language) {
                            "zh" => Some("zh".to_string()),
                            "en" => Some("en".to_string()),
                            "ja" => Some("ja".to_string()),
                            "ko" => Some("ko".to_string()),
                            "yue" => Some("yue".to_string()),
                            _ => None,
                        };
                        let params = SenseVoiceParams {
                            language,
                            use_itn: Some(true),
                        };
                        sense_voice_engine
                            .transcribe_with(&audio, &params)
                            .map(|r| r.text)
                            .map_err(|e| anyhow::anyhow!("SenseVoice transcription failed: {}", e))
                    }
                    LoadedEngine::GigaAM(gigaam_engine) => gigaam_engine
                        .transcribe(&audio, &TranscribeOptions::default())
                        .map(|r| r.text)
                        .map_err(|e| anyhow::anyhow!("GigaAM transcription failed: {}", e)),
                    LoadedEngine::Canary(canary_engine) => {
                        let lang = if validated_language == "auto" {
                            None
                        } else {
                            Some(validated_language.clone())
                        };
                        let options = TranscribeOptions {
                            language: lang,
                            translate: settings.translate_to_english,
                            ..Default::default()
                        };
                        canary_engine
                            .transcribe(&audio, &options)
                            .map(|r| r.text)
                            .map_err(|e| anyhow::anyhow!("Canary transcription failed: {}", e))
                    }
                    LoadedEngine::Cohere(cohere_engine) => {
                        let lang = if validated_language == "auto" {
                            None
                        } else {
                            Some(normalize_cjk_language(&validated_language).to_string())
                        };
                        let options = TranscribeOptions {
                            language: lang,
                            ..Default::default()
                        };
                        cohere_engine
                            .transcribe(&audio, &options)
                            .map(|r| r.text)
                            .map_err(|e| anyhow::anyhow!("Cohere transcription failed: {}", e))
                    }
                    // Inalcanzable: el desvío del principio de `transcribe`
                    // devuelve antes de tomar el motor. Está para que agregar
                    // otro motor en línea sin su rama no compile en silencio.
                    LoadedEngine::GeminiTranscribe => Err(anyhow::anyhow!(
                        "El motor en línea no se transcribe por el camino local"
                    )),
                }
            }));

            match transcribe_result {
                Ok(inner_result) => {
                    // Success or normal error: return the engine unless a model
                    // switch/unload invalidated it while it was in use.
                    self.return_engine(engine, &active_model);
                    inner_result?
                }
                Err(panic_payload) => {
                    // Engine panicked — do NOT put it back (it's in an unknown state).
                    // The engine is dropped here, effectively unloading it.
                    let panic_msg = if let Some(s) = panic_payload.downcast_ref::<&str>() {
                        s.to_string()
                    } else if let Some(s) = panic_payload.downcast_ref::<String>() {
                        s.clone()
                    } else {
                        "unknown panic".to_string()
                    };
                    error!(
                        "Transcription engine panicked: {}. Model has been unloaded.",
                        panic_msg
                    );

                    // Clear the model ID so it will be reloaded on next attempt
                    {
                        let mut current_model = self
                            .current_model_id
                            .lock()
                            .unwrap_or_else(|e| e.into_inner());
                        *current_model = None;
                    }

                    let _ = self.app_handle.emit(
                        "model-state-changed",
                        ModelStateEvent {
                            event_type: "unloaded".to_string(),
                            model_id: None,
                            model_name: None,
                            error: Some(format!("Engine panicked: {}", panic_msg)),
                        },
                    );

                    return Err(anyhow::anyhow!(
                        "Transcription engine panicked: {}. The model has been unloaded and will reload on next attempt.",
                        panic_msg
                    ));
                }
            }
        };

        // Apply fuzzy word correction if custom words are configured — UNLESS the
        // words were already handed to the model as an initial prompt (whisper
        // family). We don't pass a prompt to non-whisper models (it requires the
        // whisper-kind run extension), so they still get fuzzy correction here,
        // same as the ONNX engines.
        // Camino local: Gemini se desvió antes de llegar acá, así que el piso
        // local de muletillas se aplica siempre.
        let filtered_result =
            post_process_transcription_text(result, &settings, model_is_whisper, false);

        let et = std::time::Instant::now();
        let translation_note = if settings.translate_to_english {
            " (translated)"
        } else {
            ""
        };
        // Real-time factor. Input PCM is 16 kHz mono, so audio length in seconds
        // is samples / 16000. `speedup` is audio_secs / elapsed_secs — e.g. 4.00x
        // means transcribed 4x faster than real time
        let elapsed_secs = (et - st).as_secs_f64();
        let audio_secs = audio_len as f64 / 16_000.0;
        let speedup = real_time_factor(audio_secs, elapsed_secs);
        info!(
            "Transcription completed in {:.2}s for {:.2}s of audio ({:.2}x real-time){}",
            elapsed_secs, audio_secs, speedup, translation_note
        );

        let final_result = filtered_result;

        if final_result.is_empty() {
            info!("Transcription result is empty");
        } else {
            info!("Transcription result: {}", final_result);
        }

        self.maybe_unload_immediately("transcription");

        Ok(final_result)
    }
}

struct StreamPerf {
    feed_count: u64,
    emit_count: u64,
    streamed_samples: u64,
    stream_compute_elapsed: Duration,
    last_log: Instant,
    latest_revision: i32,
    latest_input_received_ms: i64,
    latest_audio_committed_ms: i64,
    latest_buffered_ms: i64,
}

impl StreamPerf {
    fn new() -> Self {
        Self {
            feed_count: 0,
            emit_count: 0,
            streamed_samples: 0,
            stream_compute_elapsed: Duration::ZERO,
            last_log: Instant::now(),
            latest_revision: 0,
            latest_input_received_ms: 0,
            latest_audio_committed_ms: 0,
            latest_buffered_ms: 0,
        }
    }

    fn record_feed(&mut self, samples: usize) {
        self.feed_count += 1;
        self.streamed_samples += samples as u64;
    }

    fn record_compute(&mut self, elapsed: Duration) {
        self.stream_compute_elapsed += elapsed;
    }

    fn record_update(
        &mut self,
        revision: i32,
        input_received_ms: i64,
        audio_committed_ms: i64,
        buffered_ms: i64,
    ) {
        self.latest_revision = revision;
        self.latest_input_received_ms = input_received_ms;
        self.latest_audio_committed_ms = audio_committed_ms;
        self.latest_buffered_ms = buffered_ms;
    }

    fn record_emit(&mut self) {
        self.emit_count += 1;
    }

    fn maybe_log(&mut self) {
        if self.last_log.elapsed() < STREAM_PERF_LOG_INTERVAL {
            return;
        }

        let audio_secs = self.audio_secs();
        let compute_secs = self.compute_secs();
        debug!(
            "Live preview perf: {:.2}s streamed audio, {:.2}s model compute ({:.2}x real-time), \
             input_received={:.2}s, committed_audio={:.2}s, buffered={}ms, revision={}, \
             {} frames fed, {} updates emitted",
            audio_secs,
            compute_secs,
            real_time_factor(audio_secs, compute_secs),
            self.latest_input_received_ms as f64 / 1000.0,
            self.latest_audio_committed_ms as f64 / 1000.0,
            self.latest_buffered_ms,
            self.latest_revision,
            self.feed_count,
            self.emit_count,
        );
        self.last_log = Instant::now();
    }

    fn log_finalized(&self, chars: usize) {
        let audio_secs = self.audio_secs();
        let compute_secs = self.compute_secs();
        info!(
            "Live preview finalized in {:.2}s model compute for {:.2}s streamed audio ({:.2}x real-time): \
             input_received={:.2}s, committed_audio={:.2}s, buffered={}ms, revision={}, \
             {} frames fed, {} updates emitted, {} chars",
            compute_secs,
            audio_secs,
            real_time_factor(audio_secs, compute_secs),
            self.latest_input_received_ms as f64 / 1000.0,
            self.latest_audio_committed_ms as f64 / 1000.0,
            self.latest_buffered_ms,
            self.latest_revision,
            self.feed_count,
            self.emit_count,
            chars
        );
    }

    fn audio_secs(&self) -> f64 {
        self.streamed_samples as f64 / 16_000.0
    }

    fn compute_secs(&self) -> f64 {
        self.stream_compute_elapsed.as_secs_f64()
    }
}

fn real_time_factor(audio_secs: f64, compute_secs: f64) -> f64 {
    if compute_secs > 0.0 {
        audio_secs / compute_secs
    } else {
        0.0
    }
}

fn normalize_cjk_language(language: &str) -> &str {
    match language {
        "zh-Hans" | "zh-Hant" => "zh",
        other => other,
    }
}

/// Resolve the persisted language intent into the language a specific model can
/// use without writing the coerced value back to settings.
fn effective_language_for_model(
    settings: &AppSettings,
    model_manager: &ModelManager,
    model_id: &str,
) -> String {
    match model_manager.get_model_info(model_id) {
        Some(info) => crate::managers::model::effective_language(
            &settings.selected_language,
            &info.supported_languages,
            info.supports_language_detection,
        ),
        None => settings.selected_language.clone(),
    }
}

struct TranscribeCppRunPlan {
    task: Task,
    language: Option<String>,
    target_language: Option<String>,
}

/// Build the transcribe-cpp language/task options shared by batch and live
/// streaming paths.
fn transcribe_cpp_run_plan(
    translate_to_english: bool,
    effective_language: &str,
    model_languages: &[String],
    model_supports_translate: bool,
) -> TranscribeCppRunPlan {
    let requested_language = match effective_language {
        "auto" => None,
        other => Some(normalize_cjk_language(other).to_string()),
    };
    // Only pass a language the loaded model actually advertises (per
    // capabilities().languages); otherwise auto-detect rather than failing with
    // UNSUPPORTED_LANGUAGE. Language-agnostic models report an empty list, so
    // they always stay on auto.
    let language = requested_language.filter(|lang| model_languages.iter().any(|l| l == lang));
    let (task, target_language) = cpp_translation_task(
        translate_to_english,
        model_supports_translate,
        language.as_deref(),
    );

    TranscribeCppRunPlan {
        task,
        language,
        target_language,
    }
}

/// Si el filtro local de muletillas sobra para lo que devolvió este motor.
///
/// Gemini en modo `smart` ya sacó las muletillas, los tartamudeos y las
/// autocorrecciones en el propio motor, con el contexto de la frase entera.
/// El filtro local trabaja por lista de palabras y no tiene ese contexto: si
/// corre encima de un texto ya limpio, lo único que puede hacer es morder
/// texto bueno ("o sea" que sí formaba parte de la frase, un "ya" que era la
/// respuesta). Cualquier otro caso —Gemini en literal, o un motor local— se
/// queda con el piso de siempre.
pub(crate) fn should_skip_filler_filter(engine: &EngineType, smart_mode: bool) -> bool {
    matches!(engine, EngineType::GeminiTranscribe) && smart_mode
}

fn post_process_transcription_text(
    raw: String,
    settings: &AppSettings,
    custom_words_already_prompted: bool,
    skip_filler_filter: bool,
) -> String {
    let corrected = if !settings.custom_words.is_empty() && !custom_words_already_prompted {
        apply_custom_words(
            &raw,
            &settings.custom_words,
            settings.word_correction_threshold,
        )
    } else {
        raw
    };

    if skip_filler_filter {
        return corrected;
    }

    filter_transcription_output(
        &corrected,
        &settings.app_language,
        &settings.custom_filler_words,
    )
}

/// Decide a transcribe-cpp run's task + translation target from settings.
///
/// "Translate to English" only fires where the model advertises translation.
/// Unlike transcribe-rs (which forces the target to English itself when its
/// `translate` flag is set), transcribe-cpp requires an explicit
/// `target_language`: a null target defaults to the *source*, so a non-English
/// source silently becomes e.g. es→es and Canary rejects the unadvertised pair.
/// An English source is skipped entirely — en→en is not a real translation, and
/// it's reachable by default since auto-detect-less models coerce intent to "en".
///
/// Returns `(task, target_language)` ready to drop into `RunOptions`.
fn cpp_translation_task(
    translate_to_english: bool,
    model_supports_translate: bool,
    source_language: Option<&str>,
) -> (Task, Option<String>) {
    let translate_to_en =
        translate_to_english && model_supports_translate && source_language != Some("en");
    if translate_to_en {
        (Task::Translate, Some("en".to_string()))
    } else {
        (Task::Transcribe, None)
    }
}

/// Drain a stream command channel, ignoring fed audio, until the caller
/// finalizes or cancels. Used when streaming can't actually run (model not
/// loaded / not streaming-capable) so the finalize handshake still completes
/// and the caller falls back to batch transcription.
fn drain_until_finalize(rx: mpsc::Receiver<StreamCmd>) {
    while let Ok(cmd) = rx.recv() {
        match cmd {
            StreamCmd::Feed(_) => {}
            StreamCmd::Finalize(reply) => {
                let _ = reply.send(None);
                break;
            }
            StreamCmd::Cancel => break,
        }
    }
}

/// Extrae los tokens con tiempo *reales* de la hipótesis actual de un stream
/// activo. Requiere que el stream se haya abierto con `timestamps:
/// TimestampKind::Token` (ver `run_stream_worker`) — si no, el motor
/// simplemente no llena `Transcript.tokens` y esto devuelve un vector vacío
/// en vez de inventar marcas. Confirmado con audio real: el motor GGUF
/// (transcribe-cpp, familia Nemotron/parakeet) sí entrega `t0_ms`/`t1_ms`
/// por token cuando se pide esta granularidad.
fn timed_tokens_from_snapshot(stream: &transcribe_cpp::Stream<'_>) -> Vec<TimedToken> {
    stream
        .snapshot()
        .tokens
        .into_iter()
        .map(|token| TimedToken {
            text: token.text,
            start_ms: token.t0_ms.max(0) as u64,
            end_ms: token.t1_ms.max(0) as u64,
        })
        .collect()
}

/// Initialize the transcribe-cpp native backend once at startup: route native +
/// ggml diagnostics into the `log` facade and register compute backend modules.
/// In a static build (macOS Metal) `init_backends_default` is a harmless no-op;
/// in a `dynamic-backends` build it loads the per-ISA CPU / GPU modules. Must run
/// before the first model load.
pub fn init_transcribe_backend() {
    transcribe_cpp::init_logging();
    match transcribe_cpp::init_backends_default() {
        Ok(()) => {
            let devices = transcribe_cpp::devices();
            info!(
                "transcribe-cpp initialized with {} compute device(s): [{}]",
                devices.len(),
                devices
                    .iter()
                    .map(|d| format!("{} ({})", d.name, d.kind))
                    .collect::<Vec<_>>()
                    .join(", ")
            );
        }
        Err(e) => warn!("Failed to initialize transcribe-cpp backends: {}", e),
    }
}

/// Human-readable list of the transcribe-cpp compute devices registered at
/// startup, for the `--list-devices` flag. The reported `index` is the
/// value to pass to `--device-index`. Backends must be initialized first
/// (see [`init_transcribe_backend`]).
pub fn describe_compute_devices() -> Vec<String> {
    transcribe_cpp::devices()
        .into_iter()
        .map(|d| {
            let idx = d
                .index
                .map(|i| i.to_string())
                .unwrap_or_else(|| "-".to_string());
            let name = if d.description.is_empty() {
                d.name
            } else {
                d.description
            };
            let vram_mb = d.memory_total / (1024 * 1024);
            format!(
                "index={} kind={} name={} vram={}MB",
                idx, d.kind, name, vram_mb
            )
        })
        .collect()
}

/// Resolve a `--list-devices` registry index to the (backend, gpu_device) pair
/// for a transcribe-cpp model load (the `--device-index` flag). The
/// backend is set explicitly from the device's kind, so there's no "index 0 =
/// auto" ambiguity. Errors if the index isn't a registered, loadable device.
fn resolve_device_index(index: usize) -> Result<(Backend, i32)> {
    let device = transcribe_cpp::devices()
        .into_iter()
        .find(|d| d.index == Some(index))
        .ok_or_else(|| {
            anyhow::anyhow!("No compute device with index {index} (see --list-devices)")
        })?;
    let backend = match device.kind.as_str() {
        "cpu" => Backend::Cpu,
        "metal" => Backend::Metal,
        "cuda" => Backend::Cuda,
        "vulkan" => Backend::Vulkan,
        other => {
            return Err(anyhow::anyhow!(
                "Device index {index} has kind '{other}', which cannot host a model"
            ))
        }
    };
    // gpu_device is a registry index used only by GPU backends; CPU ignores it.
    let gpu_device = if matches!(backend, Backend::Cpu) {
        0
    } else {
        index as i32
    };
    Ok((backend, gpu_device))
}

/// Map Dilo's whisper accelerator setting to a transcribe-cpp [`Backend`].
///
/// `Auto` lets the library pick the best device (with CPU fallback). `Cpu` forces
/// strict CPU. `Gpu` requests the platform GPU backend, but only if a device for
/// it is actually registered — otherwise it falls back to `Auto` so the load
/// never fails outright on a machine without that GPU backend.
fn select_transcribe_backend(setting: TranscribeAcceleratorSetting) -> Backend {
    match setting {
        TranscribeAcceleratorSetting::Cpu => Backend::Cpu,
        TranscribeAcceleratorSetting::Auto => Backend::Auto,
        TranscribeAcceleratorSetting::Gpu => {
            #[cfg(target_os = "macos")]
            let candidates = [Backend::Metal];
            #[cfg(not(target_os = "macos"))]
            let candidates = [Backend::Cuda, Backend::Vulkan];

            match candidates
                .into_iter()
                .find(|&b| transcribe_cpp::backend_available(b))
            {
                Some(b) => b,
                None => {
                    warn!("No GPU backend available for transcribe.cpp; falling back to Auto");
                    Backend::Auto
                }
            }
        }
    }
}

/// Resolve the user's stored GPU device choice into a [`ModelOptions::gpu_device`]
/// registry index for the next model load.
///
/// Settings store a registry index into [`transcribe_cpp::devices`] (`-1` is the
/// UI's auto/CPU sentinel); transcribe-cpp treats `0` as "auto / first match" and
/// rejects an out-of-range or non-GPU index. So an explicit selection is honored
/// only when the user chose the GPU accelerator and the stored index still
/// resolves to a registered GPU device — otherwise fall back to `0` so a stale
/// selection can never fail the load.
fn resolve_gpu_device(setting: TranscribeAcceleratorSetting, gpu_device: i32) -> i32 {
    if setting != TranscribeAcceleratorSetting::Gpu || gpu_device <= 0 {
        return 0;
    }
    let still_valid = transcribe_cpp::devices()
        .iter()
        .any(|d| d.index == Some(gpu_device as usize) && d.kind != "cpu" && d.kind != "accel");
    if still_valid {
        gpu_device
    } else {
        warn!(
            "Stored transcribe GPU device index {} is no longer available; using auto",
            gpu_device
        );
        0
    }
}

/// Apply the user's ORT accelerator preference to the transcribe-rs global.
/// Called on startup and before loading a model.
///
/// The transcribe.cpp (whisper-family) backend is no longer set here: it is
/// chosen at model-load time from [`select_transcribe_backend`], so changing the
/// accelerator only needs a model reload (see `reload_model_on_next_use`).
pub fn apply_accelerator_settings(app: &tauri::AppHandle) {
    use transcribe_rs::accel;

    let settings = get_settings(app);

    info!(
        "transcribe.cpp accelerator preference: {:?} (applied on next model load)",
        settings.transcribe_accelerator
    );

    let ort_pref = match settings.ort_accelerator {
        OrtAcceleratorSetting::Auto => accel::OrtAccelerator::Auto,
        OrtAcceleratorSetting::Cpu => accel::OrtAccelerator::CpuOnly,
        OrtAcceleratorSetting::Cuda => accel::OrtAccelerator::Cuda,
        OrtAcceleratorSetting::DirectMl => accel::OrtAccelerator::DirectMl,
        OrtAcceleratorSetting::Rocm => accel::OrtAccelerator::Rocm,
    };
    accel::set_ort_accelerator(ort_pref);
    info!("ORT accelerator set to: {}", ort_pref);
}

#[derive(Serialize, Clone, Debug, Type)]
pub struct GpuDeviceOption {
    pub id: i32,
    pub name: String,
    pub total_vram_mb: usize,
}

static GPU_DEVICES: OnceLock<Vec<GpuDeviceOption>> = OnceLock::new();

fn cached_gpu_devices() -> &'static [GpuDeviceOption] {
    // GPU compute devices transcribe-cpp registered at startup. `id` is the
    // device's registry index (`Device::index`, not a re-counted position) so it
    // feeds straight back as `ModelOptions::gpu_device` (see `resolve_gpu_device`).
    // `total_vram_mb` is the backend-reported capacity, 0 when unreported (some
    // Metal/Vulkan drivers).
    GPU_DEVICES.get_or_init(|| {
        transcribe_cpp::devices()
            .into_iter()
            .filter(|d| d.kind != "cpu" && d.kind != "accel")
            .map(|d| GpuDeviceOption {
                id: d.index.unwrap_or(0) as i32,
                name: if d.description.is_empty() {
                    d.name
                } else {
                    d.description
                },
                total_vram_mb: (d.memory_total / (1024 * 1024)) as usize,
            })
            .collect()
    })
}

#[derive(Serialize, Clone, Debug, Type)]
pub struct AvailableAccelerators {
    pub transcribe: Vec<String>,
    pub ort: Vec<String>,
    pub gpu_devices: Vec<GpuDeviceOption>,
}

/// Return which accelerators are compiled into this build.
pub fn get_available_accelerators() -> AvailableAccelerators {
    use transcribe_rs::accel::OrtAccelerator;

    let ort_options: Vec<String> = OrtAccelerator::available()
        .into_iter()
        .map(|a| a.to_string())
        .collect();

    let transcribe_options = vec!["auto".to_string(), "cpu".to_string(), "gpu".to_string()];

    AvailableAccelerators {
        transcribe: transcribe_options,
        ort: ort_options,
        gpu_devices: cached_gpu_devices().to_vec(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn languages(codes: &[&str]) -> Vec<String> {
        codes.iter().map(|code| (*code).to_string()).collect()
    }

    // ---------- Filtro local de muletillas vs. el smart de Gemini ----------

    #[test]
    fn smart_gemini_skips_local_filler_filter_but_verbatim_does_not() {
        assert!(should_skip_filler_filter(
            &EngineType::GeminiTranscribe,
            true
        ));
        assert!(!should_skip_filler_filter(
            &EngineType::GeminiTranscribe,
            false
        ));
        assert!(!should_skip_filler_filter(&EngineType::Parakeet, true));
    }

    // ---------- Dueño del stream (bug crítico del 2026-08-04) ----------

    #[test]
    fn un_dictado_no_puede_cancelar_el_stream_de_una_reunion() {
        // El caso real: hay una reunión grabando, el dueño aprieta el atajo
        // de dictado, el árbitro le niega el micrófono y el camino de reversa
        // del dictado llama a cancelar. Ese cancel NO puede tocar el motor de
        // la reunión: si lo apaga, la reunión sigue capturando audio y nadie
        // transcribe.
        let router = StreamRouter::new();
        let rx = router.open();
        let stream_active = AtomicBool::new(true);

        let cancelled = cancel_stream_on(
            &router,
            &stream_active,
            Some(StreamPurpose::Meeting),
            StreamPurpose::Dictation,
        );

        assert!(!cancelled, "el dictado no debe cancelar un stream ajeno");
        assert!(router.is_open(), "el canal de la reunión sigue abierto");
        assert!(
            stream_active.load(Ordering::Acquire),
            "la reunión sigue marcada como transcribiendo en vivo"
        );
        assert!(
            matches!(rx.try_recv(), Err(mpsc::TryRecvError::Empty)),
            "al worker de la reunión no le llegó ningún comando"
        );
        // Y el router sigue sirviendo audio a la reunión.
        router.feed(&[0.0, 0.1]);
        assert!(
            matches!(rx.try_recv(), Ok(StreamCmd::Feed(_))),
            "el audio de la reunión sigue llegando al motor"
        );
    }

    #[test]
    fn el_dueno_del_stream_si_puede_cancelarlo() {
        let router = StreamRouter::new();
        let rx = router.open();
        let stream_active = AtomicBool::new(true);

        let cancelled = cancel_stream_on(
            &router,
            &stream_active,
            Some(StreamPurpose::Meeting),
            StreamPurpose::Meeting,
        );

        assert!(cancelled);
        assert!(!router.is_open());
        assert!(!stream_active.load(Ordering::Acquire));
        assert!(matches!(rx.try_recv(), Ok(StreamCmd::Cancel)));
    }

    #[test]
    fn sin_stream_vivo_cualquiera_puede_cancelar() {
        // Sin dueño anotado no hay nada que proteger: el cancel tiene que
        // seguir limpiando por si quedó un canal abierto (es lo que evita que
        // el próximo `start_stream` se encuentre el puesto ocupado).
        let router = StreamRouter::new();
        let stream_active = AtomicBool::new(false);
        assert!(cancel_stream_on(
            &router,
            &stream_active,
            None,
            StreamPurpose::Dictation
        ));
    }

    #[test]
    fn la_regla_de_dueno_es_simetrica() {
        // Ni la reunión apaga el dictado ni al revés; cada uno sí el suyo.
        assert_eq!(
            foreign_stream_owner(Some(StreamPurpose::Meeting), StreamPurpose::Dictation),
            Some(StreamPurpose::Meeting)
        );
        assert_eq!(
            foreign_stream_owner(Some(StreamPurpose::Dictation), StreamPurpose::Meeting),
            Some(StreamPurpose::Dictation)
        );
        assert_eq!(
            foreign_stream_owner(Some(StreamPurpose::Dictation), StreamPurpose::Dictation),
            None
        );
        assert_eq!(foreign_stream_owner(None, StreamPurpose::Meeting), None);
    }

    // ---------- TimedToken / plain_text (Task 3: marcas por token) ----------

    #[test]
    fn los_tokens_con_tiempo_conservan_el_texto_plano() {
        // El overlay del dictado consume `committed`/`tentative` como texto.
        // Agregar tokens con tiempo no puede cambiar lo que ese camino ve.
        let tokens = vec![
            TimedToken {
                text: "hola".into(),
                start_ms: 0,
                end_ms: 300,
            },
            TimedToken {
                text: " mundo".into(),
                start_ms: 300,
                end_ms: 700,
            },
        ];
        assert_eq!(plain_text(&tokens), "hola mundo");
    }

    // ------------------------------------------------------------------
    // Sonda manual (requiere el .gguf real de Nemotron Streaming y un WAV
    // 16 kHz mono con voz en disco -- no corre en CI). Deja reproducible la
    // evidencia de que `timed_tokens_from_snapshot` devuelve marcas por
    // token *reales* del motor (no interpoladas): la corrí a mano una vez
    // con el modelo ya descargado localmente y una frase sintetizada con
    // `say` -- 44 tokens con t0_ms/t1_ms crecientes y coherentes con el
    // audio. Ver task-3-report.md para esos números. El mismo patrón que
    // `push_incremental_sobre_audio_real` en
    // `managers/diarization/sortformer.rs` (env vars + `#[ignore]`).
    // ------------------------------------------------------------------

    #[test]
    #[ignore = "requiere DILO_NEMOTRON_WAV (WAV 16 kHz mono con voz real) y \
                DILO_NEMOTRON_MODEL_PATH (el .gguf de Nemotron Streaming) en disco \
                -- ver task-3-report.md"]
    fn token_timestamps_del_stream_son_reales_no_interpoladas() -> anyhow::Result<()> {
        use anyhow::Context;

        let wav_path = std::env::var("DILO_NEMOTRON_WAV")
            .context("seteá DILO_NEMOTRON_WAV con la ruta a un WAV de 16 kHz mono con voz")?;
        let model_path = std::env::var("DILO_NEMOTRON_MODEL_PATH")
            .context("seteá DILO_NEMOTRON_MODEL_PATH con la ruta al .gguf de Nemotron Streaming")?;
        // El motor rechazó `language: None` (auto-detect) contra este
        // modelo en mis pruebas -- necesita un código BCP-47 exacto de los
        // que declara `Capabilities::languages` (p.ej. "es-ES", no "es").
        let language =
            std::env::var("DILO_NEMOTRON_LANGUAGE").unwrap_or_else(|_| "es-ES".to_string());

        {
            let reader = hound::WavReader::open(&wav_path)
                .with_context(|| format!("abriendo {wav_path}"))?;
            let spec = reader.spec();
            if spec.sample_rate != 16_000 || spec.channels != 1 {
                anyhow::bail!(
                    "{wav_path}: se esperaba 16 kHz mono, es {} Hz / {} canal(es)",
                    spec.sample_rate,
                    spec.channels
                );
            }
        }
        let audio = crate::audio_toolkit::read_wav_samples(&wav_path)?;

        transcribe_cpp::init_logging();
        let _ = transcribe_cpp::init_backends_default();
        let model = transcribe_cpp::Model::load(&model_path)
            .with_context(|| format!("cargando {model_path}"))?;
        let mut session = model.session().context("abriendo sesión")?;

        let run_options = RunOptions {
            timestamps: TimestampKind::Token,
            language: Some(language),
            ..Default::default()
        };
        let mut stream = session
            .stream(&run_options, &StreamOptions::default())
            .context("abriendo stream")?;
        stream.feed(&audio).context("feed")?;
        stream.finalize().context("finalize")?;

        // La misma función que usa `run_stream_worker` en producción --
        // ejercitarla acá es lo que hace reproducible la evidencia, no una
        // reimplementación paralela.
        let tokens = timed_tokens_from_snapshot(&stream);
        assert!(
            !tokens.is_empty(),
            "el motor no devolvió tokens con tiempo para este modelo/audio -- \
             si esto pasa de verdad, NO fabricar marcas interpolando: repórtalo."
        );
        for t in &tokens {
            assert!(
                t.end_ms >= t.start_ms,
                "token {t:?} con end_ms < start_ms -- marca no monotónica"
            );
        }

        println!("texto reconstruido: {:?}", plain_text(&tokens));
        for t in &tokens {
            println!("  {:>6}ms - {:>6}ms  {:?}", t.start_ms, t.end_ms, t.text);
        }
        Ok(())
    }

    #[test]
    fn tokens_vacios_dan_texto_vacio() {
        assert_eq!(plain_text(&[]), "");
    }

    #[test]
    fn transcribe_cpp_run_plan_maps_chinese_variants() {
        let plan = transcribe_cpp_run_plan(false, "zh-Hant", &languages(&["zh"]), true);

        assert!(matches!(plan.task, Task::Transcribe));
        assert_eq!(plan.language.as_deref(), Some("zh"));
        assert_eq!(plan.target_language, None);
    }

    #[test]
    fn transcribe_cpp_run_plan_skips_english_translation() {
        let plan = transcribe_cpp_run_plan(true, "en", &languages(&["en", "es"]), true);

        assert!(matches!(plan.task, Task::Transcribe));
        assert_eq!(plan.language.as_deref(), Some("en"));
        assert_eq!(plan.target_language, None);
    }

    #[test]
    fn transcribe_cpp_run_plan_translates_supported_non_english() {
        let plan = transcribe_cpp_run_plan(true, "es", &languages(&["en", "es"]), true);

        assert!(matches!(plan.task, Task::Translate));
        assert_eq!(plan.language.as_deref(), Some("es"));
        assert_eq!(plan.target_language.as_deref(), Some("en"));
    }

    #[test]
    fn transcribe_cpp_run_plan_requires_model_translation_support() {
        let plan = transcribe_cpp_run_plan(true, "es", &languages(&["en", "es"]), false);

        assert!(matches!(plan.task, Task::Transcribe));
        assert_eq!(plan.language.as_deref(), Some("es"));
        assert_eq!(plan.target_language, None);
    }

    // ---------- decide_model_load_action (Causa 2, reporte de arreglo de
    // reuniones 2026-08-03: no descartar en silencio una petición de un
    // modelo distinto al que ya se está cargando) ----------

    #[test]
    fn decide_model_load_action_noop_when_already_current() {
        // El camino de dictado más común: nada cargando, y el modelo pedido
        // ya es el que está cargado. Tiene que seguir siendo barato — es lo
        // que permite llamar esto en cada turno de una reunión sin costo.
        assert_eq!(
            decide_model_load_action(false, None, Some("whisper-small"), false, "whisper-small"),
            ModelLoadAction::Noop
        );
    }

    #[test]
    fn decide_model_load_action_starts_when_different_from_current() {
        assert_eq!(
            decide_model_load_action(false, None, Some("whisper-small"), false, "parakeet-tdt"),
            ModelLoadAction::Start
        );
    }

    #[test]
    fn decide_model_load_action_starts_when_no_model_loaded_yet() {
        assert_eq!(
            decide_model_load_action(false, None, None, false, "whisper-small"),
            ModelLoadAction::Start
        );
    }

    #[test]
    fn decide_model_load_action_starts_on_forced_reload_even_if_current() {
        // Accelerator change: mismo id, pero `reload_model_on_next_use` fuerza
        // una recarga igual.
        assert_eq!(
            decide_model_load_action(false, None, Some("whisper-small"), true, "whisper-small"),
            ModelLoadAction::Start
        );
    }

    #[test]
    fn decide_model_load_action_noop_when_already_loading_same_target() {
        // Pedir el modelo que YA se está cargando (o cargándose) tiene que
        // seguir siendo un no-op barato — lo pide explícitamente el reporte.
        assert_eq!(
            decide_model_load_action(true, Some("whisper-small"), None, false, "whisper-small"),
            ModelLoadAction::Noop
        );
    }

    #[test]
    fn decide_model_load_action_queues_different_model_while_loading() {
        // El bug central de Causa 2: una reunión pide su propio modelo
        // mientras el selector de dictado ya está cargando otro distinto.
        // Antes esto se descartaba en silencio (`return` sin más); ahora se
        // encola.
        assert_eq!(
            decide_model_load_action(true, Some("whisper-small"), None, false, "parakeet-tdt"),
            ModelLoadAction::Queue
        );
    }

    #[test]
    fn decide_model_load_action_queues_when_loading_target_unknown() {
        // `try_start_loading` (el camino síncrono de `switch_active_model`)
        // no registra `loading_target` — con el target en `None` cualquier
        // petición concurrente se encola en vez de asumirse redundante.
        assert_eq!(
            decide_model_load_action(true, None, None, false, "whisper-small"),
            ModelLoadAction::Queue
        );
    }
}

impl Drop for TranscriptionManager {
    fn drop(&mut self) {
        // Skip shutdown unless this is the very last clone. TranscriptionManager
        // is cloned by initiate_model_load() and the watcher thread — those
        // clones dropping must not kill the watcher. The watcher thread holds
        // its own clone, so engine's strong_count is always >= 2 while the
        // watcher is alive. When it reaches 1, only this instance remains
        // and we can safely shut down.
        if Arc::strong_count(&self.engine) > 1 {
            return;
        }

        // Signal the watcher thread to shutdown
        self.shutdown_signal.store(true, Ordering::Relaxed);

        // Wait for the thread to finish gracefully.
        // Use match instead of unwrap to avoid panicking if the mutex is
        // poisoned — a panic inside Drop calls abort().
        let mut guard = match self.watcher_handle.lock() {
            Ok(g) => g,
            Err(e) => {
                warn!("Recovered poisoned watcher_handle mutex during TranscriptionManager drop — a panic occurred earlier this session");
                e.into_inner()
            }
        };
        if let Some(handle) = guard.take() {
            if let Err(e) = handle.join() {
                warn!("Failed to join idle watcher thread: {:?}", e);
            } else {
                debug!("Idle watcher thread joined successfully");
            }
        }
    }
}
