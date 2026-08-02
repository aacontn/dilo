use crate::managers::history::{HistoryEntry, HistoryManager};
use crate::managers::model::ModelManager;
use crate::managers::transcription::TranscriptionManager;
use crate::settings;
use crate::tray_i18n::get_tray_translations;
use log::{debug, error, info, warn};
use serde::{Deserialize, Serialize};
use specta::Type;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tauri::image::Image;
use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::TrayIcon;
use tauri::{AppHandle, Manager, Theme};
use tauri_plugin_clipboard_manager::ClipboardExt;
use tauri_specta::Event;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "snake_case")]
pub enum TrayIconState {
    Idle,
    Recording,
    Transcribing,
}

/// Broadcast global cada vez que `change_tray_icon` decide un nuevo estado —
/// el mismo embudo por el que pasan el dictado (`actions.rs`, `assistant.rs`)
/// y una reunión grabando (`set_meeting_recording`, vía `effective_tray_state`).
///
/// El popover lo escucha para pintar "en reposo / dictando / transcribiendo"
/// sin depender de los eventos del overlay (`show-overlay`/`hide-overlay`),
/// que **no se emiten en absoluto** si el usuario apagó el overlay
/// (`overlay_style == None`) — ese hueco habría dejado el estado del popover
/// pegado en "en reposo" para quien desactivó el overlay pero sigue dictando.
#[derive(Clone, Copy, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct TrayIconStateChanged {
    pub state: TrayIconState,
}

/// Tauri managed state holding the last icon state set via `change_tray_icon`.
pub struct CurrentTrayIconState(pub Mutex<TrayIconState>);

impl CurrentTrayIconState {
    pub fn new() -> Self {
        Self(Mutex::new(TrayIconState::Idle))
    }

    pub fn get(&self) -> TrayIconState {
        *self.0.lock().unwrap()
    }

    fn set(&self, state: TrayIconState) {
        *self.0.lock().unwrap() = state;
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum AppTheme {
    Dark,
    Light,
    Colored, // Pink/colored theme for Linux
}

/// Gets the current app theme, with Linux defaulting to Colored theme
pub fn get_current_theme(app: &AppHandle) -> AppTheme {
    if cfg!(target_os = "linux") {
        // On Linux, always use the colored theme
        AppTheme::Colored
    } else {
        // On Windows the tray icon sits on the taskbar, which follows the
        // *system* theme (SystemUsesLightTheme), not the app theme. With the
        // "Custom" personalization mode the two can differ (e.g. dark taskbar
        // + light apps), and the window theme would pick an icon that is
        // invisible against the taskbar.
        #[cfg(target_os = "windows")]
        if let Some(theme) = windows_taskbar_theme() {
            return theme;
        }

        // On other platforms, map system theme to our app theme
        if let Some(main_window) = app.get_webview_window("main") {
            match main_window.theme().unwrap_or(Theme::Dark) {
                Theme::Light => AppTheme::Light,
                Theme::Dark => AppTheme::Dark,
                _ => AppTheme::Dark, // Default fallback
            }
        } else {
            AppTheme::Dark
        }
    }
}

/// Reads the Windows taskbar theme from the registry.
///
/// Returns None if the value is missing (older Windows 10 builds default to a
/// dark taskbar there, but falling back to the window theme is safer than
/// guessing).
#[cfg(target_os = "windows")]
fn windows_taskbar_theme() -> Option<AppTheme> {
    use winreg::enums::HKEY_CURRENT_USER;
    use winreg::RegKey;

    let personalize = RegKey::predef(HKEY_CURRENT_USER)
        .open_subkey("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize")
        .ok()?;
    let system_uses_light: u32 = personalize.get_value("SystemUsesLightTheme").ok()?;
    Some(if system_uses_light == 1 {
        AppTheme::Light
    } else {
        AppTheme::Dark
    })
}

/// Gets the appropriate icon path for the given theme and state
pub fn get_icon_path(theme: AppTheme, state: TrayIconState) -> &'static str {
    match (theme, state) {
        // Dark theme uses light icons
        (AppTheme::Dark, TrayIconState::Idle) => "resources/tray_idle.png",
        (AppTheme::Dark, TrayIconState::Recording) => "resources/tray_recording.png",
        (AppTheme::Dark, TrayIconState::Transcribing) => "resources/tray_transcribing.png",
        // Light theme uses dark icons
        (AppTheme::Light, TrayIconState::Idle) => "resources/tray_idle_dark.png",
        (AppTheme::Light, TrayIconState::Recording) => "resources/tray_recording_dark.png",
        (AppTheme::Light, TrayIconState::Transcribing) => "resources/tray_transcribing_dark.png",
        // Colored theme uses pink icons (for Linux)
        (AppTheme::Colored, TrayIconState::Idle) => "resources/handy.png",
        (AppTheme::Colored, TrayIconState::Recording) => "resources/recording.png",
        (AppTheme::Colored, TrayIconState::Transcribing) => "resources/transcribing.png",
    }
}

/// True mientras una reunión está capturando audio. Ver
/// [`set_meeting_recording`].
static MEETING_RECORDING: AtomicBool = AtomicBool::new(false);

/// Qué ícono corresponde de verdad: mientras una reunión graba, gana la
/// reunión.
///
/// Los dos caminos escriben el mismo estado de bandeja y el del dictado
/// vuelve a `Idle` al terminar cada dictado (y `utils::reset` lo pone en
/// `Idle` en varios caminos de error). Como la reunión puede durar horas sin
/// ninguna ventana abierta, dejar que esos `Idle` la pisen borraría la única
/// señal de que el micrófono sigue abierto. El dictado y la reunión no
/// pueden coexistir de todos modos (el árbitro del micrófono lo impide), así
/// que esta preferencia no le saca ninguna indicación al dictado.
fn effective_tray_state(requested: TrayIconState, meeting_recording: bool) -> TrayIconState {
    if meeting_recording {
        TrayIconState::Recording
    } else {
        requested
    }
}

/// Enciende (o apaga) la señal de "hay una reunión grabando" en la bandeja.
/// Es el único indicador que queda cuando la ventana de reuniones está
/// cerrada y el micrófono sigue abierto.
pub fn set_meeting_recording(app: &AppHandle, recording: bool) {
    MEETING_RECORDING.store(recording, Ordering::Relaxed);
    if app.try_state::<TrayIcon>().is_none() {
        // Sin bandeja (--no-tray, o un arranque headless) no hay ícono que
        // cambiar; la marca igual queda puesta para el resto.
        return;
    }
    change_tray_icon(
        app,
        if recording {
            TrayIconState::Recording
        } else {
            TrayIconState::Idle
        },
    );
}

pub fn change_tray_icon(app: &AppHandle, icon: TrayIconState) {
    let tray = app.state::<TrayIcon>();
    let theme = get_current_theme(app);
    let icon = effective_tray_state(icon, MEETING_RECORDING.load(Ordering::Relaxed));

    // Store current state
    app.state::<CurrentTrayIconState>().set(icon);
    // El popover (y cualquier otra ventana) se entera de este mismo cambio
    // sin depender del overlay del dictado — ver el doc comment de
    // `TrayIconStateChanged`.
    let _ = TrayIconStateChanged { state: icon }.emit(app);

    let icon_path = get_icon_path(theme, icon);

    let icon_started = std::time::Instant::now();
    if let Err(err) = load_tray_icon(
        app.path()
            .resolve(icon_path, tauri::path::BaseDirectory::Resource),
    )
    .and_then(|image| tray.set_icon(Some(image)))
    {
        error!("Failed to update tray icon '{icon_path}': {err}");
    }
    let icon_elapsed = icon_started.elapsed();

    // Update menu based on state
    let menu_started = std::time::Instant::now();
    update_tray_menu(app, None);
    debug!(
        "tray icon change ({:?}): icon={} set_icon={:?} menu={:?}",
        icon,
        icon_path,
        icon_elapsed,
        menu_started.elapsed()
    );
}

/// Re-applies the last known tray state — for when only the *theme* changed
/// and the state itself (idle/recording/transcribing) should be preserved.
pub fn refresh_tray_icon(app: &AppHandle) {
    let icon = app.state::<CurrentTrayIconState>().get();
    change_tray_icon(app, icon);
}

fn load_tray_icon(resolved_icon_path: tauri::Result<PathBuf>) -> tauri::Result<Image<'static>> {
    let resolved_icon_path = resolved_icon_path?;
    Image::from_path(&resolved_icon_path).map(Image::to_owned)
}

pub fn tray_tooltip() -> String {
    version_label()
}

fn version_label() -> String {
    if cfg!(debug_assertions) {
        format!("Dilo v{} (Dev)", env!("CARGO_PKG_VERSION"))
    } else {
        format!("Dilo v{}", env!("CARGO_PKG_VERSION"))
    }
}

pub fn update_tray_menu(app: &AppHandle, locale: Option<&str>) {
    let state = app.state::<CurrentTrayIconState>().get();
    let settings = settings::get_settings(app);

    let locale = locale.unwrap_or(&settings.app_language);
    let strings = get_tray_translations(Some(locale.to_string()));

    // Platform-specific accelerators
    #[cfg(target_os = "macos")]
    let (settings_accelerator, quit_accelerator) = (Some("Cmd+,"), Some("Cmd+Q"));
    #[cfg(not(target_os = "macos"))]
    let (settings_accelerator, quit_accelerator) = (Some("Ctrl+,"), Some("Ctrl+Q"));

    // Create common menu items
    let version_label = version_label();
    let version_i = MenuItem::with_id(app, "version", &version_label, false, None::<&str>)
        .expect("failed to create version item");
    let settings_i = MenuItem::with_id(
        app,
        "settings",
        &strings.settings,
        true,
        settings_accelerator,
    )
    .expect("failed to create settings item");
    let check_updates_i = MenuItem::with_id(
        app,
        "check_updates",
        &strings.check_updates,
        settings.update_checks_enabled,
        None::<&str>,
    )
    .expect("failed to create check updates item");
    let copy_last_transcript_i = MenuItem::with_id(
        app,
        "copy_last_transcript",
        &strings.copy_last_transcript,
        true,
        None::<&str>,
    )
    .expect("failed to create copy last transcript item");
    let model_loaded = app.state::<Arc<TranscriptionManager>>().is_model_loaded();
    let quit_i = MenuItem::with_id(app, "quit", &strings.quit, true, quit_accelerator)
        .expect("failed to create quit item");
    let separator = || PredefinedMenuItem::separator(app).expect("failed to create separator");

    // Build model submenu — label is the active model name
    let model_manager = app.state::<Arc<ModelManager>>();
    let models = model_manager.get_available_models();
    let current_model_id = &settings.selected_model;

    let mut downloaded: Vec<_> = models.into_iter().filter(|m| m.is_downloaded).collect();
    downloaded.sort_by(|a, b| a.name.cmp(&b.name));

    let submenu_label = downloaded
        .iter()
        .find(|m| m.id == *current_model_id)
        .map(|m| m.name.clone())
        .unwrap_or_else(|| strings.model.clone());

    let model_submenu = {
        let submenu = Submenu::with_id(app, "model_submenu", &submenu_label, true)
            .expect("failed to create model submenu");

        for model in &downloaded {
            let is_active = model.id == *current_model_id;
            let item_id = format!("model_select:{}", model.id);
            let item =
                CheckMenuItem::with_id(app, &item_id, &model.name, true, is_active, None::<&str>)
                    .expect("failed to create model item");
            let _ = submenu.append(&item);
        }

        submenu
    };

    let unload_model_i = MenuItem::with_id(
        app,
        "unload_model",
        &strings.unload_model,
        model_loaded,
        None::<&str>,
    )
    .expect("failed to create unload model item");

    let menu = match state {
        TrayIconState::Recording | TrayIconState::Transcribing => {
            let cancel_i = MenuItem::with_id(app, "cancel", &strings.cancel, true, None::<&str>)
                .expect("failed to create cancel item");
            Menu::with_items(
                app,
                &[
                    &version_i,
                    &separator(),
                    &cancel_i,
                    &separator(),
                    &copy_last_transcript_i,
                    &separator(),
                    &settings_i,
                    &check_updates_i,
                    &separator(),
                    &quit_i,
                ],
            )
            .expect("failed to create menu")
        }
        TrayIconState::Idle => Menu::with_items(
            app,
            &[
                &version_i,
                &separator(),
                &copy_last_transcript_i,
                &separator(),
                &model_submenu,
                &unload_model_i,
                &separator(),
                &settings_i,
                &check_updates_i,
                &separator(),
                &quit_i,
            ],
        )
        .expect("failed to create menu"),
    };

    let tray = app.state::<TrayIcon>();
    let _ = tray.set_menu(Some(menu));
    let _ = tray.set_icon_as_template(true);
    let _ = tray.set_tooltip(Some(version_label));
}

fn last_transcript_text(entry: &HistoryEntry) -> &str {
    entry
        .post_processed_text
        .as_deref()
        .unwrap_or(&entry.transcription_text)
}

pub fn set_tray_visibility(app: &AppHandle, visible: bool) {
    let tray = app.state::<TrayIcon>();
    if let Err(e) = tray.set_visible(visible) {
        error!("Failed to set tray visibility: {}", e);
    } else {
        info!("Tray visibility set to: {}", visible);
    }
}

/// Copia la última transcripción completa al portapapeles.
///
/// Devuelve `Err` describiendo por qué no copió nada (sin historial todavía,
/// última transcripción vacía, o falla del portapapeles) para que un llamador
/// con UI —el popover— pueda avisarlo; el menú de la bandeja (`lib.rs`,
/// `on_menu_event`) ignora el resultado y sólo deja el log de arriba, porque
/// ahí no hay ventana visible que muestre un toast.
pub fn copy_last_transcript(app: &AppHandle) -> Result<(), String> {
    let history_manager = app.state::<Arc<HistoryManager>>();
    let entry = match history_manager.get_latest_completed_entry() {
        Ok(Some(entry)) => entry,
        Ok(None) => {
            warn!("No completed transcription history entries available for tray copy.");
            return Err("no_history".to_string());
        }
        Err(err) => {
            error!(
                "Failed to fetch last completed transcription entry: {}",
                err
            );
            return Err(err.to_string());
        }
    };

    let text = last_transcript_text(&entry);
    if text.trim().is_empty() {
        warn!("Last completed transcription is empty; skipping tray copy.");
        return Err("empty".to_string());
    }

    if let Err(err) = app.clipboard().write_text(text) {
        error!("Failed to copy last transcript to clipboard: {}", err);
        return Err(err.to_string());
    }

    info!("Copied last transcript to clipboard.");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{effective_tray_state, last_transcript_text, load_tray_icon, TrayIconState};
    use crate::managers::history::HistoryEntry;

    fn build_entry(transcription: &str, post_processed: Option<&str>) -> HistoryEntry {
        HistoryEntry {
            id: 1,
            file_name: "handy-1.wav".to_string(),
            timestamp: 0,
            saved: false,
            title: "Recording".to_string(),
            transcription_text: transcription.to_string(),
            post_processed_text: post_processed.map(|text| text.to_string()),
            post_process_prompt: None,
            post_process_requested: false,
        }
    }

    #[test]
    fn uses_post_processed_text_when_available() {
        let entry = build_entry("raw", Some("processed"));
        assert_eq!(last_transcript_text(&entry), "processed");
    }

    #[test]
    fn falls_back_to_raw_transcription() {
        let entry = build_entry("raw", None);
        assert_eq!(last_transcript_text(&entry), "raw");
    }

    #[test]
    fn a_meeting_keeps_the_recording_icon_even_when_dictation_asks_for_idle() {
        assert_eq!(
            effective_tray_state(TrayIconState::Idle, true),
            TrayIconState::Recording
        );
        assert_eq!(
            effective_tray_state(TrayIconState::Transcribing, true),
            TrayIconState::Recording
        );
    }

    #[test]
    fn without_a_meeting_the_requested_state_is_respected() {
        assert_eq!(
            effective_tray_state(TrayIconState::Idle, false),
            TrayIconState::Idle
        );
        assert_eq!(
            effective_tray_state(TrayIconState::Transcribing, false),
            TrayIconState::Transcribing
        );
    }

    #[test]
    fn tray_icon_resolution_failure_is_returned_instead_of_panicking() {
        assert!(load_tray_icon(Err(tauri::Error::UnknownPath)).is_err());
    }

    #[test]
    fn tray_icon_returns_err_when_file_does_not_exist() {
        let dir = tempfile::tempdir().expect("failed to create tempdir");
        let missing = dir.path().join("does_not_exist.png");
        assert!(load_tray_icon(Ok(missing)).is_err());
    }
}
