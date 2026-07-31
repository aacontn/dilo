//! Ventana de reuniones: el módulo completo de grabar/leer transcripts en su
//! propia ventana, separada de la de ajustes (diseño en
//! `docs/superpowers/specs/2026-07-31-notetaker-usable-design.md`, sección 1).
//!
//! **Diferencia con `overlay.rs`:** el overlay es un NSPanel flotante sin
//! foco, y de ahí sale su regla de "crear una vez y jamás destruir" (ver la
//! nota junto a `OVERLAY_GENERATION` en `overlay.rs`). Ésta es una ventana
//! **normal** — con foco, redimensionable, en el Dock — y esa regla no
//! aplica acá. De todos modos sobrevive a que el usuario la cierre: el
//! manejador global de `CloseRequested` en `lib.rs` sólo destruye la ventana
//! `"main"`; cualquier otra (incluida ésta) sólo se esconde. Eso es lo que
//! deja que el estado en curso (una reunión grabando, si hay una) siga vivo
//! en memoria del webview cuando el usuario la reabre — no hace falta
//! reconstruirlo desde el backend.

use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};

const MEETINGS_WINDOW_LABEL: &str = "meetings";

/// Abre la ventana de reuniones, o la trae al frente si ya está abierta
/// (escondida tras un cierre anterior, o simplemente detrás de otras
/// ventanas). Nunca crea una segunda.
#[tauri::command]
#[specta::specta]
pub fn open_meetings_window(app: AppHandle) -> Result<(), String> {
    match app.get_webview_window(MEETINGS_WINDOW_LABEL) {
        Some(window) => {
            window.unminimize().map_err(|e| e.to_string())?;
            window.show().map_err(|e| e.to_string())?;
            window.set_focus().map_err(|e| e.to_string())?;
        }
        None => create_meetings_window(&app)?,
    }

    // El sidebar que abre esta ventana sólo es clickeable con "main" visible,
    // así que la policy ya debería ser Regular — pero si en el futuro se abre
    // por otra vía (p. ej. un flag de CLI) con el ícono del Dock oculto, esto
    // la asegura igual. Mismo patrón que `show_main_window`.
    #[cfg(target_os = "macos")]
    {
        let _ = app.set_activation_policy(tauri::ActivationPolicy::Regular);
    }

    Ok(())
}

fn create_meetings_window(app: &AppHandle) -> Result<(), String> {
    let mut builder = WebviewWindowBuilder::new(
        app,
        MEETINGS_WINDOW_LABEL,
        WebviewUrl::App("src/meetings/index.html".into()),
    )
    .title("Dilo — Reuniones")
    // Más alta que ancha: para leer transcripts, no para verlos de reojo.
    .inner_size(460.0, 760.0)
    .min_inner_size(360.0, 520.0)
    .resizable(true)
    .maximizable(false)
    .transparent(true)
    .visible(false);

    // Mismo tratamiento Liquid Glass que la ventana principal (ver
    // `create_main_window` en lib.rs): traffic lights nativos sobre el
    // vidrio translúcido en macOS; Windows/Linux conservan su barra nativa.
    #[cfg(target_os = "macos")]
    {
        builder = builder
            .title_bar_style(tauri::TitleBarStyle::Overlay)
            .hidden_title(true);
    }

    if let Some(data_dir) = crate::portable::data_dir() {
        builder = builder.data_directory(data_dir.join("webview"));
    }

    let window = builder.build().map_err(|e| e.to_string())?;

    // Igual que `create_main_window`: aplica el tema persistido a la barra de
    // Windows antes de mostrarla, para que no haya un flash del tema
    // equivocado.
    #[cfg(target_os = "windows")]
    crate::shortcut::apply_window_theme(app, crate::settings::get_settings(app).theme);

    window.show().map_err(|e| e.to_string())?;
    window.set_focus().map_err(|e| e.to_string())?;

    Ok(())
}
