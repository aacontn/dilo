use crate::actions::resolve_action;
use crate::managers::audio::AudioRecordingManager;
use log::{debug, error, warn};
use std::sync::mpsc::{self, Sender};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager};

const DEBOUNCE: Duration = Duration::from_millis(30);
const RELEASE_GRACE: Duration = Duration::from_millis(50);

// Manos libres (estilo Wispr Flow): un press más corto que TAP_MAX es un
// "toque"; al soltarlo, el stop espera DOUBLE_TAP_WINDOW por un segundo toque
// que deja la grabación abierta sin sostener la tecla. AUTOREPEAT_GAP separa
// ese segundo toque humano del par sintético release+press que emite el
// auto-repeat de X11 mientras la tecla sigue sostenida (spec:
// docs/superpowers/specs/2026-07-18-manos-libres-design.md).
const TAP_MAX: Duration = Duration::from_millis(300);
const DOUBLE_TAP_WINDOW: Duration = Duration::from_millis(350);
const AUTOREPEAT_GAP: Duration = Duration::from_millis(80);

/// Estado fino del push-to-talk; dueño exclusivo: el hilo coordinador.
#[derive(Debug, Default)]
struct PttState {
    /// Manos libres activo: doble toque dejó la grabación abierta.
    locked: bool,
    /// Instante del press que inició la grabación en curso.
    press_at: Option<Instant>,
    /// Instante del release que armó el stop diferido vigente.
    released_at: Option<Instant>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PttAction {
    Passthrough,
    /// Stop diferido; el Duration es la espera (grace normal o ventana de doble toque).
    DeferRelease(Duration),
    /// Par sintético del auto-repeat: cancelar el stop y seguir grabando.
    CancelRelease,
    /// Segundo toque humano dentro de la ventana: entrar a manos libres.
    LockHandsFree,
    /// Press estando en manos libres: cortar y transcribir.
    StopLocked,
    /// Release estando en manos libres: no hace nada.
    IgnoreRelease,
}

struct PendingRelease {
    binding_id: String,
    hotkey_string: String,
    deadline: Instant,
}

/// Commands processed sequentially by the coordinator thread.
enum Command {
    Input {
        binding_id: String,
        hotkey_string: String,
        is_pressed: bool,
        push_to_talk: bool,
    },
    Cancel {
        recording_was_active: bool,
    },
    ProcessingFinished,
}

/// Pipeline lifecycle, owned exclusively by the coordinator thread.
enum Stage {
    Idle,
    Recording(String), // binding_id
    Processing,
}

fn classify_ptt_event(
    state: &PttState,
    pending_release_binding: Option<&str>,
    is_pressed: bool,
    push_to_talk: bool,
    binding_id: &str,
    recording_binding: Option<&str>,
    now: Instant,
) -> PttAction {
    if !push_to_talk {
        return PttAction::Passthrough;
    }

    if is_pressed {
        if state.locked && recording_binding == Some(binding_id) {
            return PttAction::StopLocked;
        }
        if pending_release_binding == Some(binding_id) {
            // Un press casi pegado al release es el par sintético del
            // auto-repeat; con separación humana es el segundo toque. La grace
            // normal (50ms) es más corta que AUTOREPEAT_GAP, así que un hold
            // largo jamás puede terminar en lock por esta rama.
            let synthetic = state
                .released_at
                .is_some_and(|t| now.duration_since(t) < AUTOREPEAT_GAP);
            return if synthetic || recording_binding != Some(binding_id) {
                // Par sintético del auto-repeat, o ya no hay grabación que
                // bloquear: solo cancelar el stop pendiente.
                PttAction::CancelRelease
            } else {
                PttAction::LockHandsFree
            };
        }
        PttAction::Passthrough
    } else if state.locked && recording_binding == Some(binding_id) {
        PttAction::IgnoreRelease
    } else if recording_binding == Some(binding_id) && pending_release_binding.is_none() {
        let was_tap = state
            .press_at
            .is_some_and(|t| now.duration_since(t) <= TAP_MAX);
        PttAction::DeferRelease(if was_tap {
            DOUBLE_TAP_WINDOW
        } else {
            RELEASE_GRACE
        })
    } else {
        PttAction::Passthrough
    }
}

/// Serialises all transcription lifecycle events through a single thread
/// to eliminate race conditions between keyboard shortcuts, signals, and
/// the async transcribe-paste pipeline.
pub struct TranscriptionCoordinator {
    tx: Sender<Command>,
}

pub fn is_transcribe_binding(id: &str) -> bool {
    id == "transcribe"
        || id == "transcribe_with_post_process"
        || crate::actions::mode_prompt_id(id).is_some()
}

impl TranscriptionCoordinator {
    pub fn new(app: AppHandle) -> Self {
        let (tx, rx) = mpsc::channel();

        thread::spawn(move || {
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let mut stage = Stage::Idle;
                let mut last_press: Option<Instant> = None;
                let mut pending_release: Option<PendingRelease> = None;
                let mut ptt = PttState::default();

                loop {
                    let cmd = if let Some(pending) = &pending_release {
                        match rx.recv_timeout(
                            pending.deadline.saturating_duration_since(Instant::now()),
                        ) {
                            Ok(cmd) => cmd,
                            Err(mpsc::RecvTimeoutError::Timeout) => {
                                if let Some(pending) = pending_release.take() {
                                    if matches!(&stage, Stage::Recording(id) if id == &pending.binding_id)
                                    {
                                        stop(
                                            &app,
                                            &mut stage,
                                            &pending.binding_id,
                                            &pending.hotkey_string,
                                        );
                                    }
                                }
                                continue;
                            }
                            Err(mpsc::RecvTimeoutError::Disconnected) => break,
                        }
                    } else {
                        match rx.recv() {
                            Ok(cmd) => cmd,
                            Err(_) => break,
                        }
                    };

                    match cmd {
                        Command::Input {
                            binding_id,
                            hotkey_string,
                            is_pressed,
                            push_to_talk,
                        } => {
                            let pending_release_binding = pending_release
                                .as_ref()
                                .map(|pending| pending.binding_id.as_str());
                            let recording_binding = match &stage {
                                Stage::Recording(id) => Some(id.as_str()),
                                _ => None,
                            };

                            let now = Instant::now();
                            match classify_ptt_event(
                                &ptt,
                                pending_release_binding,
                                is_pressed,
                                push_to_talk,
                                &binding_id,
                                recording_binding,
                                now,
                            ) {
                                PttAction::CancelRelease => {
                                    pending_release = None;
                                    ptt.released_at = None;
                                    continue;
                                }
                                PttAction::LockHandsFree => {
                                    pending_release = None;
                                    ptt.released_at = None;
                                    ptt.locked = true;
                                    debug!("Manos libres: doble toque de '{binding_id}'");
                                    continue;
                                }
                                PttAction::StopLocked => {
                                    ptt.locked = false;
                                    stop(&app, &mut stage, &binding_id, &hotkey_string);
                                    continue;
                                }
                                PttAction::IgnoreRelease => continue,
                                PttAction::DeferRelease(grace) => {
                                    pending_release = Some(PendingRelease {
                                        binding_id,
                                        hotkey_string,
                                        deadline: now + grace,
                                    });
                                    ptt.released_at = Some(now);
                                    continue;
                                }
                                PttAction::Passthrough => {}
                            }

                            // Debounce rapid-fire press events (key repeat / double-tap).
                            // Push-to-talk releases may be deferred above to absorb X11 auto-repeat.
                            if is_pressed {
                                let now = Instant::now();
                                if last_press.is_some_and(|t| now.duration_since(t) < DEBOUNCE) {
                                    debug!("Debounced press for '{binding_id}'");
                                    continue;
                                }
                                last_press = Some(now);
                            }

                            if push_to_talk {
                                if is_pressed && matches!(stage, Stage::Idle) {
                                    start(&app, &mut stage, &binding_id, &hotkey_string);
                                    // Base para distinguir toque (posible doble
                                    // toque → manos libres) de hold sostenido.
                                    ptt = PttState {
                                        locked: false,
                                        press_at: Some(now),
                                        released_at: None,
                                    };
                                } else if !is_pressed
                                    && matches!(&stage, Stage::Recording(id) if id == &binding_id)
                                {
                                    stop(&app, &mut stage, &binding_id, &hotkey_string);
                                }
                            } else if is_pressed {
                                match &stage {
                                    Stage::Idle => {
                                        start(&app, &mut stage, &binding_id, &hotkey_string);
                                    }
                                    Stage::Recording(id) if id == &binding_id => {
                                        stop(&app, &mut stage, &binding_id, &hotkey_string);
                                    }
                                    _ => {
                                        debug!("Ignoring press for '{binding_id}': pipeline busy")
                                    }
                                }
                            }
                        }
                        Command::Cancel {
                            recording_was_active,
                        } => {
                            pending_release = None;
                            ptt = PttState::default();
                            // Don't reset during processing — wait for the pipeline to finish.
                            if !matches!(stage, Stage::Processing)
                                && (recording_was_active || matches!(stage, Stage::Recording(_)))
                            {
                                stage = Stage::Idle;
                            }
                        }
                        Command::ProcessingFinished => {
                            stage = Stage::Idle;
                        }
                    }
                }
                debug!("Transcription coordinator exited");
            }));
            if let Err(e) = result {
                error!("Transcription coordinator panicked: {e:?}");
            }
        });

        Self { tx }
    }

    /// Send a keyboard/signal input event for a transcribe binding.
    /// For signal-based toggles, use `is_pressed: true` and `push_to_talk: false`.
    pub fn send_input(
        &self,
        binding_id: &str,
        hotkey_string: &str,
        is_pressed: bool,
        push_to_talk: bool,
    ) {
        if self
            .tx
            .send(Command::Input {
                binding_id: binding_id.to_string(),
                hotkey_string: hotkey_string.to_string(),
                is_pressed,
                push_to_talk,
            })
            .is_err()
        {
            warn!("Transcription coordinator channel closed");
        }
    }

    pub fn notify_cancel(&self, recording_was_active: bool) {
        if self
            .tx
            .send(Command::Cancel {
                recording_was_active,
            })
            .is_err()
        {
            warn!("Transcription coordinator channel closed");
        }
    }

    pub fn notify_processing_finished(&self) {
        if self.tx.send(Command::ProcessingFinished).is_err() {
            warn!("Transcription coordinator channel closed");
        }
    }
}

fn start(app: &AppHandle, stage: &mut Stage, binding_id: &str, hotkey_string: &str) {
    let Some(action) = resolve_action(binding_id) else {
        warn!("No action for binding '{binding_id}'");
        return;
    };
    action.start(app, binding_id, hotkey_string);
    if app
        .try_state::<Arc<AudioRecordingManager>>()
        .is_some_and(|a| a.is_recording())
    {
        *stage = Stage::Recording(binding_id.to_string());
    } else {
        debug!("Start for '{binding_id}' did not begin recording; staying idle");
    }
}

fn stop(app: &AppHandle, stage: &mut Stage, binding_id: &str, hotkey_string: &str) {
    let Some(action) = resolve_action(binding_id) else {
        warn!("No action for binding '{binding_id}'");
        return;
    };
    action.stop(app, binding_id, hotkey_string);
    *stage = Stage::Processing;
}

#[cfg(test)]
mod tests {
    use super::*;

    /// PttState con press hace `pressed_ms` y release hace `released_ms`.
    fn ptt_state(
        locked: bool,
        pressed_ms: Option<u64>,
        released_ms: Option<u64>,
    ) -> (PttState, Instant) {
        let now = Instant::now();
        (
            PttState {
                locked,
                press_at: pressed_ms.map(|ms| now - Duration::from_millis(ms)),
                released_at: released_ms.map(|ms| now - Duration::from_millis(ms)),
            },
            now,
        )
    }

    #[test]
    fn release_after_long_hold_defers_with_normal_grace() {
        let (state, now) = ptt_state(false, Some(500), None);
        assert_eq!(
            classify_ptt_event(
                &state,
                None,
                false,
                true,
                "transcribe",
                Some("transcribe"),
                now
            ),
            PttAction::DeferRelease(RELEASE_GRACE)
        );
    }

    #[test]
    fn release_after_tap_waits_for_a_second_tap() {
        let (state, now) = ptt_state(false, Some(120), None);
        assert_eq!(
            classify_ptt_event(
                &state,
                None,
                false,
                true,
                "transcribe",
                Some("transcribe"),
                now
            ),
            PttAction::DeferRelease(DOUBLE_TAP_WINDOW)
        );
    }

    #[test]
    fn second_human_tap_within_window_locks_hands_free() {
        // Segundo press 150ms después del release del toque: humano → lock.
        let (state, now) = ptt_state(false, Some(300), Some(150));
        assert_eq!(
            classify_ptt_event(
                &state,
                Some("transcribe"),
                true,
                true,
                "transcribe",
                Some("transcribe"),
                now
            ),
            PttAction::LockHandsFree
        );
    }

    #[test]
    fn autorepeat_pair_cancels_release_without_locking() {
        // Press 10ms después del release: par sintético del auto-repeat X11.
        let (state, now) = ptt_state(false, Some(600), Some(10));
        assert_eq!(
            classify_ptt_event(
                &state,
                Some("transcribe"),
                true,
                true,
                "transcribe",
                Some("transcribe"),
                now
            ),
            PttAction::CancelRelease
        );
    }

    #[test]
    fn press_while_hands_free_stops_recording() {
        let (state, now) = ptt_state(true, Some(5000), None);
        assert_eq!(
            classify_ptt_event(
                &state,
                None,
                true,
                true,
                "transcribe",
                Some("transcribe"),
                now
            ),
            PttAction::StopLocked
        );
    }

    #[test]
    fn release_while_hands_free_is_ignored() {
        let (state, now) = ptt_state(true, Some(5000), None);
        assert_eq!(
            classify_ptt_event(
                &state,
                None,
                false,
                true,
                "transcribe",
                Some("transcribe"),
                now
            ),
            PttAction::IgnoreRelease
        );
    }

    #[test]
    fn toggle_mode_press_and_release_pass_through() {
        let (state, now) = ptt_state(false, Some(100), Some(150));
        assert_eq!(
            classify_ptt_event(
                &state,
                Some("transcribe"),
                true,
                false,
                "transcribe",
                Some("transcribe"),
                now
            ),
            PttAction::Passthrough
        );
        assert_eq!(
            classify_ptt_event(
                &state,
                None,
                false,
                false,
                "transcribe",
                Some("transcribe"),
                now
            ),
            PttAction::Passthrough
        );
    }

    #[test]
    fn press_for_different_binding_than_pending_release_passes_through() {
        let (state, now) = ptt_state(false, Some(300), Some(150));
        assert_eq!(
            classify_ptt_event(
                &state,
                Some("transcribe"),
                true,
                true,
                "transcribe_with_post_process",
                Some("transcribe"),
                now
            ),
            PttAction::Passthrough
        );
    }

    #[test]
    fn press_matching_pending_release_cancels_without_recording_state() {
        // Sin grabación activa no hay nada que dejar en manos libres, aunque
        // el gap sea humano: solo se cancela el stop pendiente.
        let (state, now) = ptt_state(false, Some(300), Some(150));
        assert_eq!(
            classify_ptt_event(
                &state,
                Some("transcribe"),
                true,
                true,
                "transcribe",
                None,
                now
            ),
            PttAction::CancelRelease
        );
    }

    // ---------------------------------------------------------------------
    // Sequence-level regression coverage for issue #1539.
    //
    // Under X11 key auto-repeat, holding a push-to-talk key does not emit one
    // long press. It emits the initial press followed by a stream of
    // synthesized release/press pairs, then a single genuine release on key-up.
    // Before the fix, every synthesized release passed straight through and
    // stopped recording, so holding the key "rapidly toggled" recording on and
    // off. The fix defers each release for a short grace window and cancels it
    // when the matching auto-repeat press arrives.
    //
    // The unit tests above assert `classify_ptt_event` in isolation. The
    // simulator below threads that classifier through the same `pending_release`
    // / `stage` state transitions the coordinator loop performs (lines that
    // handle `Command::Input` and the `recv_timeout` grace expiry), so a whole
    // event burst can be exercised deterministically without a Tauri AppHandle
    // or real timers.
    // ---------------------------------------------------------------------

    const BINDING: &str = "transcribe";

    #[derive(Clone, Copy)]
    enum Ev {
        /// A key-down event (real initial press or a synthesized auto-repeat press).
        Press,
        /// A key-up event (synthesized auto-repeat release or the genuine key-up).
        Release,
        /// The deferred-stop window elapsed with no cancelling press arriving.
        Grace,
        /// Avanza el reloj simulado (ms) — separa toques humanos de pares sintéticos.
        Wait(u64),
    }

    #[derive(Debug, PartialEq, Eq)]
    enum SimStage {
        Idle,
        Recording,
        Processing,
    }

    struct SimResult {
        starts: u32,
        stops: u32,
        stage: SimStage,
    }

    /// Mirror of the coordinator loop's decision logic for a single push-to-talk
    /// binding: it calls the real `classify_ptt_event` and applies the exact same
    /// Defer / Cancel / debounce / start / stop transitions.
    fn simulate(events: &[Ev]) -> SimResult {
        let t0 = Instant::now();
        let at = |ms: u64| t0 + Duration::from_millis(ms);

        let mut stage = SimStage::Idle;
        let mut pending: Option<String> = None;
        let mut last_press_ms: Option<u64> = None;
        let mut clock_ms: u64 = 0;
        let mut starts = 0u32;
        let mut stops = 0u32;
        let debounce_ms = DEBOUNCE.as_millis() as u64;
        // Espejo del PttState del loop real.
        let mut locked = false;
        let mut press_ms: Option<u64> = None;
        let mut released_ms: Option<u64> = None;

        for ev in events {
            // Auto-repeat events arrive a few ms apart, well inside DEBOUNCE.
            clock_ms += 5;

            match ev {
                Ev::Wait(ms) => {
                    clock_ms += ms;
                }
                Ev::Grace => {
                    // Coordinator's `RecvTimeoutError::Timeout` arm: fire the
                    // deferred release iff we are still recording that binding.
                    if let Some(pending_binding) = pending.take() {
                        if stage == SimStage::Recording && pending_binding == BINDING {
                            stage = SimStage::Processing;
                            stops += 1;
                        }
                    }
                    released_ms = None;
                }
                Ev::Press | Ev::Release => {
                    let is_pressed = matches!(ev, Ev::Press);
                    let pending_binding = pending.as_deref();
                    let recording_binding = if stage == SimStage::Recording {
                        Some(BINDING)
                    } else {
                        None
                    };
                    let state = PttState {
                        locked,
                        press_at: press_ms.map(at),
                        released_at: released_ms.map(at),
                    };

                    match classify_ptt_event(
                        &state,
                        pending_binding,
                        is_pressed,
                        true, // push_to_talk
                        BINDING,
                        recording_binding,
                        at(clock_ms),
                    ) {
                        PttAction::CancelRelease => {
                            pending = None;
                            released_ms = None;
                            continue;
                        }
                        PttAction::LockHandsFree => {
                            pending = None;
                            released_ms = None;
                            locked = true;
                            continue;
                        }
                        PttAction::StopLocked => {
                            locked = false;
                            stage = SimStage::Processing;
                            stops += 1;
                            continue;
                        }
                        PttAction::IgnoreRelease => continue,
                        PttAction::DeferRelease(_) => {
                            pending = Some(BINDING.to_string());
                            released_ms = Some(clock_ms);
                            continue;
                        }
                        PttAction::Passthrough => {}
                    }

                    if is_pressed {
                        if last_press_ms.is_some_and(|t| clock_ms - t < debounce_ms) {
                            continue;
                        }
                        last_press_ms = Some(clock_ms);
                    }

                    if is_pressed && stage == SimStage::Idle {
                        stage = SimStage::Recording;
                        starts += 1;
                        locked = false;
                        press_ms = Some(clock_ms);
                        released_ms = None;
                    } else if !is_pressed && stage == SimStage::Recording {
                        stage = SimStage::Processing;
                        stops += 1;
                    }
                }
            }
        }

        SimResult {
            starts,
            stops,
            stage,
        }
    }

    /// Initial press plus several synthesized release/press pairs, as X11 emits
    /// while a push-to-talk key is held down.
    fn autorepeat_burst() -> Vec<Ev> {
        let mut events = vec![Ev::Press];
        for _ in 0..6 {
            events.push(Ev::Release);
            events.push(Ev::Press);
        }
        events
    }

    /// Regression for #1539: a burst of X11 auto-repeat release/press pairs must
    /// not stop recording. Before the fix the first synthesized release stopped
    /// recording immediately (stops == 1, stage left Recording), which produced
    /// the rapid on/off toggling. With the fix the releases are coalesced and
    /// recording stays continuously active for the whole burst.
    #[test]
    fn x11_autorepeat_burst_does_not_toggle_recording() {
        let result = simulate(&autorepeat_burst());
        assert_eq!(result.starts, 1, "recording should start exactly once");
        assert_eq!(
            result.stops, 0,
            "synthesized auto-repeat releases must not stop recording mid-burst"
        );
        assert_eq!(
            result.stage,
            SimStage::Recording,
            "recording must remain active across the entire auto-repeat burst"
        );
    }

    /// Complements the burst test: once the key is genuinely released and the
    /// grace window elapses with no re-press, recording stops exactly once. This
    /// proves the debounce only coalesces synthesized releases and does not wedge
    /// the coordinator or swallow the real key-up.
    #[test]
    fn genuine_release_after_grace_stops_recording_once() {
        let mut events = autorepeat_burst();
        events.push(Ev::Release); // genuine key-up
        events.push(Ev::Grace); // grace window elapses, no cancelling press
        let result = simulate(&events);
        assert_eq!(result.starts, 1, "recording should start exactly once");
        assert_eq!(
            result.stops, 1,
            "a genuine release should stop recording exactly once"
        );
        assert_eq!(result.stage, SimStage::Processing);
    }

    /// Manos libres: toque, segundo toque dentro de la ventana (gap humano),
    /// la grabación queda abierta sin tecla sostenida, y un toque final corta.
    #[test]
    fn double_tap_enters_hands_free_and_single_tap_stops() {
        let result = simulate(&[
            Ev::Press, // toque 1: parte a grabar
            Ev::Wait(100),
            Ev::Release, // suelto rápido (< TAP_MAX) → espera segundo toque
            Ev::Wait(150),
            Ev::Press, // toque 2 (gap humano > AUTOREPEAT_GAP) → manos libres
            Ev::Wait(20),
            Ev::Release,    // release del toque 2: ignorado
            Ev::Wait(5000), // dicta largo con las manos libres
            Ev::Press,      // un toque: corta y transcribe
        ]);
        assert_eq!(result.starts, 1, "una sola grabación continua");
        assert_eq!(
            result.stops,
            0 + 1,
            "el toque final corta exactamente una vez"
        );
        assert_eq!(result.stage, SimStage::Processing);
    }

    /// Un toque solitario se comporta como hoy: al vencer la ventana de doble
    /// toque sin segundo toque, para y transcribe.
    #[test]
    fn lone_tap_stops_when_double_tap_window_expires() {
        let result = simulate(&[Ev::Press, Ev::Wait(100), Ev::Release, Ev::Grace]);
        assert_eq!(result.starts, 1);
        assert_eq!(result.stops, 1);
        assert_eq!(result.stage, SimStage::Processing);
    }
}
