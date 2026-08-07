pub mod audio;
pub mod history;
pub mod meeting;
pub mod models;
pub mod system;
pub mod transcription;
pub mod tts;

use crate::settings::{get_settings, write_settings, AppSettings, LogLevel};
use crate::utils::cancel_current_operation;
use tauri::{AppHandle, Manager};
use tauri_plugin_opener::OpenerExt;

#[tauri::command]
#[specta::specta]
pub fn cancel_operation(app: AppHandle) {
    cancel_current_operation(&app);
}

/// Copia la última transcripción completa al portapapeles. Mismo camino que
/// usa el ítem "Copiar última transcripción" del menú de la bandeja
/// (`tray::copy_last_transcript`) — lo que cambia es el llamador: el popover
/// tiene ventana, así que puede mostrar un toast si no había nada que copiar.
#[tauri::command]
#[specta::specta]
pub fn copy_last_transcript(app: AppHandle) -> Result<(), String> {
    crate::tray::copy_last_transcript(&app)
}

/// Estado actual del ícono de la bandeja (reposo/grabando/transcribiendo),
/// para que el popover pueda pintarlo apenas monta. Los cambios posteriores
/// llegan por el evento `TrayIconStateChanged` que emite `change_tray_icon`.
#[tauri::command]
#[specta::specta]
pub fn get_tray_icon_state(app: AppHandle) -> crate::tray::TrayIconState {
    app.state::<crate::tray::CurrentTrayIconState>().get()
}

/// Versión de Dilo para mostrar en la interfaz — mismo texto que ya se veía
/// como primer ítem (deshabilitado) del menú nativo de la bandeja y como su
/// tooltip (`tray::tray_tooltip`/`version_label`). El popover lo reusa tal
/// cual en vez de recalcularlo del lado del frontend, para que los dos
/// lugares digan siempre lo mismo (incluido el sufijo "(Dev)" en debug).
#[tauri::command]
#[specta::specta]
pub fn get_app_version() -> String {
    crate::tray::tray_tooltip()
}

/// Cierra la app. El menú nativo de la bandeja ya tenía este mismo camino
/// (`on_menu_event`, id `"quit"`) — este comando le da al popover un botón
/// "Salir" propio ahora que en macOS no queda ningún menú nativo detrás
/// (ver `popover::tray_click_action`): sin esto, cerrar Dilo desde la
/// bandeja dejaba de tener ninguna vía en absoluto.
#[tauri::command]
#[specta::specta]
pub fn quit_app(app: AppHandle) -> Result<(), String> {
    app.exit(0);
    Ok(())
}

/// Avisos de cruce a la nube que ocurrieron sin ninguna ventana escuchando
/// el evento. La ventana los pide al montar y los muestra como toasts; la
/// llamada los consume, así que no se repiten al reabrir.
#[tauri::command]
#[specta::specta]
pub fn take_pending_fallback_notices(app: AppHandle) -> Vec<crate::actions::PostProcessFallback> {
    app.state::<crate::actions::PendingFallbackNotices>()
        .take_all()
}

/// Avisos del modo asistente (proveedor sin configurar, LLM caído, TTS
/// caído, atajo apretado con el modo apagado) que ocurrieron sin ninguna
/// ventana escuchando el evento `assistant-error` — el caso normal al usar
/// el atajo del asistente, que abre la ventana principal cerrada. Ver
/// `assistant::PendingAssistantNotices`.
#[tauri::command]
#[specta::specta]
pub fn take_pending_assistant_notices(
    app: AppHandle,
) -> Vec<crate::assistant::AssistantErrorEvent> {
    app.state::<crate::assistant::PendingAssistantNotices>()
        .take_all()
}

#[tauri::command]
#[specta::specta]
pub fn is_portable() -> bool {
    crate::portable::is_portable()
}

#[tauri::command]
#[specta::specta]
pub fn get_app_dir_path(app: AppHandle) -> Result<String, String> {
    let app_data_dir = crate::portable::app_data_dir(&app)
        .map_err(|e| format!("Failed to get app data directory: {}", e))?;

    Ok(app_data_dir.to_string_lossy().to_string())
}

#[tauri::command]
#[specta::specta]
pub fn get_app_settings(app: AppHandle) -> Result<AppSettings, String> {
    // Este es el pedido que el frontend hace al montar y en cada refresco, y
    // el hook del aviso lo llama a propósito **después** de poner su listener:
    // es el único momento en que se puede garantizar que hay alguien
    // escuchando. Ver `settings::emit_pending_shortcut_notice`.
    crate::settings::emit_pending_shortcut_notice(&app);
    Ok(get_settings(&app))
}

#[tauri::command]
#[specta::specta]
pub fn get_default_settings() -> Result<AppSettings, String> {
    Ok(crate::settings::get_default_settings())
}

#[tauri::command]
#[specta::specta]
pub fn get_log_dir_path(app: AppHandle) -> Result<String, String> {
    let log_dir = crate::portable::app_log_dir(&app)
        .map_err(|e| format!("Failed to get log directory: {}", e))?;

    Ok(log_dir.to_string_lossy().to_string())
}

#[specta::specta]
#[tauri::command]
pub fn set_log_level(app: AppHandle, level: LogLevel) -> Result<(), String> {
    let tauri_log_level: tauri_plugin_log::LogLevel = level.into();
    let log_level: log::Level = tauri_log_level.into();
    // Update the file log level atomic so the filter picks up the new level
    crate::FILE_LOG_LEVEL.store(
        log_level.to_level_filter() as u8,
        std::sync::atomic::Ordering::Relaxed,
    );

    let mut settings = get_settings(&app);
    settings.log_level = level;
    write_settings(&app, settings);

    Ok(())
}

#[specta::specta]
#[tauri::command]
pub fn open_recordings_folder(app: AppHandle) -> Result<(), String> {
    let app_data_dir = crate::portable::app_data_dir(&app)
        .map_err(|e| format!("Failed to get app data directory: {}", e))?;

    let recordings_dir = app_data_dir.join("recordings");

    let path = recordings_dir.to_string_lossy().as_ref().to_string();
    app.opener()
        .open_path(path, None::<String>)
        .map_err(|e| format!("Failed to open recordings folder: {}", e))?;

    Ok(())
}

#[specta::specta]
#[tauri::command]
pub fn open_log_dir(app: AppHandle) -> Result<(), String> {
    let log_dir = crate::portable::app_log_dir(&app)
        .map_err(|e| format!("Failed to get log directory: {}", e))?;

    let path = log_dir.to_string_lossy().as_ref().to_string();
    app.opener()
        .open_path(path, None::<String>)
        .map_err(|e| format!("Failed to open log directory: {}", e))?;

    Ok(())
}

#[specta::specta]
#[tauri::command]
pub fn open_app_data_dir(app: AppHandle) -> Result<(), String> {
    let app_data_dir = crate::portable::app_data_dir(&app)
        .map_err(|e| format!("Failed to get app data directory: {}", e))?;

    let path = app_data_dir.to_string_lossy().as_ref().to_string();
    app.opener()
        .open_path(path, None::<String>)
        .map_err(|e| format!("Failed to open app data directory: {}", e))?;

    Ok(())
}

/// Check if Apple Intelligence is available on this device.
/// Called by the frontend when the user selects Apple Intelligence provider.
#[specta::specta]
#[tauri::command]
pub fn check_apple_intelligence_available() -> bool {
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        crate::apple_intelligence::check_apple_intelligence_availability()
    }
    #[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
    {
        false
    }
}

/// Try to initialize Enigo (keyboard/mouse simulation).
/// On macOS, this will return an error if accessibility permissions are not granted.
#[specta::specta]
#[tauri::command]
pub fn initialize_enigo(app: AppHandle) -> Result<(), String> {
    use crate::input::EnigoState;

    // Check if already initialized
    if app.try_state::<EnigoState>().is_some() {
        log::debug!("Enigo already initialized");
        return Ok(());
    }

    // Try to initialize
    match EnigoState::new() {
        Ok(enigo_state) => {
            app.manage(enigo_state);
            log::info!("Enigo initialized successfully after permission grant");
            Ok(())
        }
        Err(e) => {
            if cfg!(target_os = "macos") {
                log::warn!(
                    "Failed to initialize Enigo: {} (accessibility permissions may not be granted)",
                    e
                );
            } else {
                log::warn!("Failed to initialize Enigo: {}", e);
            }
            Err(format!("Failed to initialize input system: {}", e))
        }
    }
}

/// Marker state to track if shortcuts have been initialized.
pub struct ShortcutsInitialized;

/// Initialize keyboard shortcuts.
/// On macOS, this should be called after accessibility permissions are granted.
/// This is idempotent - calling it multiple times is safe.
#[specta::specta]
#[tauri::command]
pub fn initialize_shortcuts(app: AppHandle) -> Result<(), String> {
    // Check if already initialized
    if app.try_state::<ShortcutsInitialized>().is_some() {
        log::debug!("Shortcuts already initialized");
        return Ok(());
    }

    // Initialize shortcuts
    crate::shortcut::init_shortcuts(&app);

    // Mark as initialized
    app.manage(ShortcutsInitialized);

    log::info!("Shortcuts initialized successfully");
    Ok(())
}
