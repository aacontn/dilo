use crate::managers::audio::AudioRecordingManager;
use crate::managers::transcription::TranscriptionManager;
use crate::shortcut;
use crate::TranscriptionCoordinator;
use log::info;
use std::sync::Arc;
use tauri::{AppHandle, Manager};

// Re-export all utility modules for easy access
// pub use crate::audio_feedback::*;
pub use crate::clipboard::*;
pub use crate::overlay::*;
pub use crate::tray::*;

/// Centralized cancellation function that can be called from anywhere in the app.
/// Handles cancelling both recording and transcription operations and updates UI state.
pub fn cancel_current_operation(app: &AppHandle) {
    info!("Initiating operation cancellation...");

    // Unregister the cancel shortcut asynchronously
    shortcut::unregister_cancel_shortcut(app);

    // Cancel any ongoing recording
    let audio_manager = app.state::<Arc<AudioRecordingManager>>();
    let recording_was_active = audio_manager.is_recording();
    audio_manager.cancel_recording();

    // Abandon any live streaming transcription
    let tm = app.state::<Arc<TranscriptionManager>>();
    tm.cancel_stream();

    // Update tray icon and hide overlay
    change_tray_icon(app, crate::tray::TrayIconState::Idle);
    hide_recording_overlay(app);

    // Unload model if immediate unload is enabled
    tm.maybe_unload_immediately("cancellation");

    // Notify coordinator so it can keep lifecycle state coherent.
    if let Some(coordinator) = app.try_state::<TranscriptionCoordinator>() {
        coordinator.notify_cancel(recording_was_active);
    }

    info!("Operation cancellation completed - returned to idle state");
}

/// Evento con el que Rust le avisa a una ventana que **acaba de mostrarse**.
///
/// Las ventanas que se esconden en vez de cerrarse (el popover y la de
/// reuniones — ver las notas de módulo de `popover.rs` y
/// `meeting_window.rs`) montan su React una sola vez en toda la vida del
/// proceso, así que un `useEffect` de montaje no vuelve a correr cuando el
/// usuario las reabre. Tauri no tiene un evento de ventana para esto
/// (`WindowEvent` no incluye "shown") y el foco no alcanza: si la ventana ya
/// estaba enfocada, mostrarla no cambia nada que el sistema reporte.
pub const WINDOW_SHOWN_EVENT: &str = "window-shown";

/// Avisa a `label` que acaba de mostrarse. Se llama **después** de `show()`.
pub fn emit_window_shown(app: &AppHandle, label: &str) {
    use tauri::Emitter;

    if let Err(e) = app.emit_to(label, WINDOW_SHOWN_EVENT, ()) {
        log::warn!("No se pudo avisar que la ventana {label} se mostró: {e}");
    }
}

/// Estado de una ventana candidata a recibir un aviso, tal como lo ve el
/// sistema en este instante.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NoticeWindow<'a> {
    pub label: &'a str,
    pub visible: bool,
    pub focused: bool,
}

/// Ventanas donde un aviso puede verse, de la que está más "encima" a la
/// más de fondo. El popover se dibuja sobre todo lo demás y sólo está
/// visible mientras el usuario lo tiene abierto; Reuniones va antes que
/// Ajustes porque abrir Reuniones **esconde** Ajustes
/// (`meeting_window::open_meetings_window`), así que cuando las dos están
/// vivas la de adelante es Reuniones.
const NOTICE_WINDOW_PRIORITY: [&str; 3] = [
    crate::popover::POPOVER_WINDOW_LABEL,
    crate::meeting_window::MEETINGS_WINDOW_LABEL,
    "main",
];

/// A qué ventana mandarle un aviso que debe verse **una sola vez**.
///
/// El toast de `recording-error` vivía sólo en la ventana de Ajustes, y
/// abrir Reuniones la esconde: los cuatro rechazos del dictado del reporte
/// del 2026-08-04 se dibujaron en una ventana que el dueño no estaba
/// mirando. Ahora el listener es compartido y está montado en las tres
/// ventanas (`hooks/useRecordingErrorToast.ts`), así que el que elige es
/// este lado: el aviso va a UNA sola, la que el usuario tiene delante, en
/// vez de repetirse en cada ventana visible.
///
/// Prefiere la que tiene el foco; si ninguna lo tiene (el caso normal al
/// dictar: el foco está en la app donde se escribe), la primera visible por
/// prioridad. `None` = no hay ninguna ventana a la vista.
pub fn pick_notice_window<'a>(candidates: &[NoticeWindow<'a>]) -> Option<&'a str> {
    candidates
        .iter()
        .find(|w| w.visible && w.focused)
        .or_else(|| candidates.iter().find(|w| w.visible))
        .map(|w| w.label)
}

/// Emite un aviso a la ventana que el usuario tiene delante (ver
/// [`pick_notice_window`]). Sin ninguna ventana visible cae al broadcast de
/// siempre: nadie lo va a ver igual, pero no se pierde para un webview vivo
/// que estuviera escuchando.
pub fn emit_ui_notice<S: serde::Serialize + Clone>(app: &AppHandle, event: &str, payload: S) {
    use tauri::Emitter;

    let candidates: Vec<NoticeWindow<'_>> = NOTICE_WINDOW_PRIORITY
        .iter()
        .filter_map(|label| {
            app.get_webview_window(label).map(|window| NoticeWindow {
                label,
                visible: window.is_visible().unwrap_or(false),
                focused: window.is_focused().unwrap_or(false),
            })
        })
        .collect();

    match pick_notice_window(&candidates) {
        Some(label) => {
            let _ = app.emit_to(label, event, payload);
        }
        None => {
            let _ = app.emit(event, payload);
        }
    }
}

/// Check if using the Wayland display server protocol
#[cfg(target_os = "linux")]
pub fn is_wayland() -> bool {
    std::env::var("WAYLAND_DISPLAY").is_ok()
        || std::env::var("XDG_SESSION_TYPE")
            .map(|v| v.to_lowercase() == "wayland")
            .unwrap_or(false)
}

/// Check if running on KDE Plasma desktop environment
#[cfg(target_os = "linux")]
pub fn is_kde_plasma() -> bool {
    std::env::var("XDG_CURRENT_DESKTOP")
        .map(|v| v.to_uppercase().contains("KDE"))
        .unwrap_or(false)
        || std::env::var("KDE_SESSION_VERSION").is_ok()
}

/// Check if running on KDE Plasma with Wayland
#[cfg(target_os = "linux")]
pub fn is_kde_wayland() -> bool {
    is_wayland() && is_kde_plasma()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn window(label: &str, visible: bool, focused: bool) -> NoticeWindow<'_> {
        NoticeWindow {
            label,
            visible,
            focused,
        }
    }

    #[test]
    fn sin_ninguna_ventana_visible_no_hay_a_quien_avisarle() {
        assert_eq!(
            pick_notice_window(&[
                window("popover", false, false),
                window("main", false, false)
            ]),
            None
        );
    }

    #[test]
    fn con_una_sola_visible_el_aviso_va_ahi_aunque_no_tenga_el_foco() {
        // El caso normal al dictar: el foco está en la app donde se escribe,
        // no en Dilo. Sin esto el aviso no se mostraría en ningún lado.
        assert_eq!(
            pick_notice_window(&[
                window("popover", false, false),
                window("meetings", true, false),
                window("main", false, false),
            ]),
            Some("meetings")
        );
    }

    #[test]
    fn con_dos_visibles_gana_una_sola_y_es_la_de_mas_prioridad() {
        // Reuniones y Ajustes pueden estar visibles a la vez (volver a Dilo
        // desde la bandeja no esconde Reuniones). El aviso no debe dibujarse
        // dos veces.
        assert_eq!(
            pick_notice_window(&[window("meetings", true, false), window("main", true, false)]),
            Some("meetings")
        );
    }

    #[test]
    fn la_que_tiene_el_foco_gana_aunque_este_mas_abajo_en_la_prioridad() {
        assert_eq!(
            pick_notice_window(&[window("meetings", true, false), window("main", true, true)]),
            Some("main")
        );
    }

    #[test]
    fn una_ventana_con_foco_pero_escondida_no_cuenta() {
        // macOS deja el foco reportado en una ventana recién escondida hasta
        // que otra lo toma; un aviso ahí no lo ve nadie.
        assert_eq!(
            pick_notice_window(&[window("main", false, true), window("meetings", true, false)]),
            Some("meetings")
        );
    }
}
