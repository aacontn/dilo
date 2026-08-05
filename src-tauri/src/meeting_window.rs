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

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_store::StoreExt;

use crate::popover::WorkArea;

pub(crate) const MEETINGS_WINDOW_LABEL: &str = "meetings";

// Panel alto anclado a un costado (referencia: Wispr Flow), no la ventana
// chica y flotante de antes — reporte del dueño, 2026-08-02. El ancho se
// mantiene cercano al de siempre: es un panel de lectura, no una ventana
// ancha. El alto se calcula en `anchored_geometry` a partir del monitor.
const MEETINGS_WINDOW_WIDTH: f64 = 460.0;
const MEETINGS_WINDOW_MIN_HEIGHT: f64 = 520.0;

// Márgenes verticales del anclaje inicial. No se usa `Monitor::work_area()`
// para calcularlos dinámicamente: `popover.rs` ya documenta (ver
// `work_area_for_monitor`) que esa API da coordenadas incorrectas en macOS
// para monitores con posición negativa (el caso real de dos pantallas de
// Alfonso), y `overlay.rs` esquiva el mismo problema con offsets fijos
// (`OVERLAY_TOP_OFFSET`/`OVERLAY_BOTTOM_OFFSET`) en vez de consultar el
// sistema. Mismo criterio acá: un margen fijo que despeja la barra de menú
// de macOS, no una medición exacta.
#[cfg(target_os = "macos")]
const MEETINGS_WINDOW_TOP_MARGIN: f64 = 30.0;
#[cfg(not(target_os = "macos"))]
const MEETINGS_WINDOW_TOP_MARGIN: f64 = 8.0;
const MEETINGS_WINDOW_BOTTOM_MARGIN: f64 = 8.0;

/// Geometría en curso de la ventana, en coordenadas lógicas.
#[derive(Debug, Clone, Copy, PartialEq)]
struct WindowGeometry {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

/// Geometría inicial: alta y anclada al borde derecho del monitor donde está
/// el cursor (misma resolución de monitor que usa el overlay de grabación,
/// vía `overlay::get_monitor_with_cursor` — evita el bug de dos pantallas
/// con escalas distintas descrito en `popover::logical_tray_rect`).
fn anchored_geometry(work_area: WorkArea) -> WindowGeometry {
    let width = MEETINGS_WINDOW_WIDTH.min(work_area.width);
    let height = (work_area.height - MEETINGS_WINDOW_TOP_MARGIN - MEETINGS_WINDOW_BOTTOM_MARGIN)
        .max(MEETINGS_WINDOW_MIN_HEIGHT.min(work_area.height));

    WindowGeometry {
        x: work_area.x + work_area.width - width,
        y: work_area.y + MEETINGS_WINDOW_TOP_MARGIN,
        width,
        height,
    }
}

fn current_work_area(app: &AppHandle) -> WorkArea {
    let monitor = crate::overlay::get_monitor_with_cursor(app)
        .or_else(|| app.primary_monitor().ok().flatten());

    match monitor {
        Some(m) => crate::popover::work_area_for_monitor(&m),
        None => crate::popover::FALLBACK_WORK_AREA,
    }
}

/// Geometría guardada la última vez que el usuario movió o redimensionó la
/// ventana. Vive en el mismo store que el resto de los ajustes (mismo
/// patrón que `settings::get_settings`/`write_settings`), bajo una clave
/// propia — no es un ajuste editable desde la interfaz, así que no entra al
/// struct `AppSettings` ni a los bindings generados para el frontend.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
struct SavedWindowBounds {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

const MEETINGS_WINDOW_BOUNDS_KEY: &str = "meeting_window_bounds";

fn load_saved_bounds(app: &AppHandle) -> Option<SavedWindowBounds> {
    let store = app
        .store(crate::portable::store_path(
            crate::settings::SETTINGS_STORE_PATH,
        ))
        .ok()?;
    let value = store.get(MEETINGS_WINDOW_BOUNDS_KEY)?.clone();
    serde_json::from_value(value).ok()
}

/// Guarda la geometría actual. Se llama desde el manejador global de
/// `WindowEvent::Moved`/`Resized` en `lib.rs`, filtrado por
/// `MEETINGS_WINDOW_LABEL` — mismo lugar donde ya se manejan casos
/// especiales por ventana (ver el match de `popover::POPOVER_WINDOW_LABEL`
/// ahí mismo).
pub(crate) fn save_current_bounds(window: &tauri::Window) {
    let Ok(scale) = window.scale_factor() else {
        return;
    };
    let Ok(position) = window.outer_position() else {
        return;
    };
    let Ok(size) = window.inner_size() else {
        return;
    };
    let logical_position = position.to_logical::<f64>(scale);
    let logical_size = size.to_logical::<f64>(scale);

    let bounds = SavedWindowBounds {
        x: logical_position.x,
        y: logical_position.y,
        width: logical_size.width,
        height: logical_size.height,
    };

    let Ok(store) = window.app_handle().store(crate::portable::store_path(
        crate::settings::SETTINGS_STORE_PATH,
    )) else {
        return;
    };
    store.set(
        MEETINGS_WINDOW_BOUNDS_KEY,
        serde_json::to_value(bounds).unwrap(),
    );
}

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
            // Esta ventana se esconde en vez de cerrarse (ver la nota del
            // módulo), así que su React monta UNA sola vez en toda la vida
            // del proceso: volver a mostrarla no vuelve a preguntarle al
            // backend qué reunión está grabando. Recuperar el foco tampoco
            // alcanza — si ya estaba enfocada, o si el sistema no reporta el
            // cambio, no llega ningún evento. Por eso "mostrarse" se avisa
            // explícitamente (reporte del dueño, 2026-08-04: la ventana
            // decía "listo para grabar" con la reunión corriendo).
            crate::utils::emit_window_shown(&app, MEETINGS_WINDOW_LABEL);
        }
        None => create_meetings_window(&app)?,
    }

    // El sidebar que abre esta ventana sólo es clickeable con "main" visible,
    // así que la policy ya debería ser la correcta — pero si en el futuro se
    // abre por otra vía (p. ej. un flag de CLI), esto la asegura igual. Mismo
    // patrón que `show_main_window`: la decide `apply_dock_policy`, que
    // respeta el ajuste "sólo barra de menú" en vez de forzar `Regular`.
    #[cfg(target_os = "macos")]
    crate::apply_dock_policy(&app, true);

    // Reuniones toma el relevo: la ventana de ajustes se esconde para no
    // dejar dos ventanas de Dilo compitiendo en pantalla mientras grabas.
    // Se **esconde**, no se destruye: así vuelve entera desde la bandeja o
    // el Dock, sin perder la sección en la que estabas.
    //
    // Es seguro para el ícono del Dock: la guarda de `CloseRequested` en
    // `lib.rs` sólo pasa a `Accessory` cuando no queda ninguna ventana
    // relevante visible, y ésta acaba de quedar visible (ver
    // `no_relevant_window_visible`).
    if let Some(main) = app.get_webview_window("main") {
        if let Err(e) = main.hide() {
            // No es fatal: la de reuniones ya está arriba y usable.
            log::warn!("No se pudo esconder la ventana principal: {e}");
        }
    }

    Ok(())
}

/// El camino de vuelta: muestra Ajustes y esconde Reuniones. Es el inverso
/// exacto de `open_meetings_window`, y existe porque esa función esconde la
/// ventana principal — sin esto el usuario queda sin puerta de regreso salvo
/// la bandeja.
///
/// Vive en Rust y no en el frontend a propósito: el intercambio de ventanas
/// ya se decide acá, y hacerlo desde el webview exigiría permisos de ventana
/// nuevos en `capabilities/default.json` para repetir la misma lógica.
///
/// Reuniones se **esconde**, no se cierra: si hay una reunión grabando, su
/// estado vive en el webview (ver la nota del módulo) y debe sobrevivir al
/// viaje de ida y vuelta.
#[tauri::command]
#[specta::specta]
pub fn return_to_main_window(app: AppHandle) -> Result<(), String> {
    // Primero mostrar, después esconder: al revés, entre medio no queda
    // ninguna ventana visible y la guarda del Dock podría mandar la app a
    // Accessory.
    crate::show_main_window(&app);

    if let Some(meetings) = app.get_webview_window(MEETINGS_WINDOW_LABEL) {
        if let Err(e) = meetings.hide() {
            // No es fatal: Ajustes ya está al frente, que es lo que se pidió.
            log::warn!("No se pudo esconder la ventana de reuniones: {e}");
        }
    }

    Ok(())
}

fn create_meetings_window(app: &AppHandle) -> Result<(), String> {
    // Si el usuario ya movió o redimensionó la ventana antes, se respeta esa
    // geometría en vez de volver a anclar — anclar es sólo la posición
    // inicial, no una cárcel (reporte del dueño, 2026-08-02). Sin geometría
    // guardada (primera vez), se calcula el anclaje: panel alto, anclado al
    // borde derecho del monitor donde está el cursor en este instante.
    let geometry = match load_saved_bounds(app) {
        Some(bounds) => WindowGeometry {
            x: bounds.x,
            y: bounds.y,
            width: bounds.width,
            height: bounds.height,
        },
        None => anchored_geometry(current_work_area(app)),
    };

    let mut builder = WebviewWindowBuilder::new(
        app,
        MEETINGS_WINDOW_LABEL,
        WebviewUrl::App("src/meetings/index.html".into()),
    )
    .title("Dilo — Reuniones")
    .inner_size(geometry.width, geometry.height)
    .position(geometry.x, geometry.y)
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

#[cfg(test)]
mod tests {
    use super::*;

    fn area() -> WorkArea {
        WorkArea {
            x: 0.0,
            y: 0.0,
            width: 1440.0,
            height: 900.0,
        }
    }

    #[test]
    fn se_ancla_al_borde_derecho_del_monitor() {
        let geometry = anchored_geometry(area());
        assert_eq!(geometry.x, 1440.0 - MEETINGS_WINDOW_WIDTH);
        assert_eq!(geometry.width, MEETINGS_WINDOW_WIDTH);
    }

    #[test]
    fn el_alto_ocupa_el_area_util_menos_los_margenes() {
        let geometry = anchored_geometry(area());
        assert_eq!(
            geometry.height,
            900.0 - MEETINGS_WINDOW_TOP_MARGIN - MEETINGS_WINDOW_BOTTOM_MARGIN
        );
        assert_eq!(geometry.y, MEETINGS_WINDOW_TOP_MARGIN);
    }

    #[test]
    fn respeta_un_area_de_trabajo_desplazada() {
        // Segunda pantalla a la derecha de la principal — el caso real de
        // Alfonso (dos pantallas), mismo escenario que prueba `popover.rs`.
        let shifted = WorkArea {
            x: 1440.0,
            y: 0.0,
            width: 1920.0,
            height: 1080.0,
        };
        let geometry = anchored_geometry(shifted);
        assert_eq!(geometry.x, 1440.0 + 1920.0 - MEETINGS_WINDOW_WIDTH);
        assert_eq!(geometry.y, MEETINGS_WINDOW_TOP_MARGIN);
    }

    #[test]
    fn en_un_monitor_mas_angosto_que_el_panel_el_ancho_no_se_sale() {
        let narrow = WorkArea {
            x: 0.0,
            y: 0.0,
            width: 300.0,
            height: 900.0,
        };
        let geometry = anchored_geometry(narrow);
        assert_eq!(geometry.width, 300.0);
        assert_eq!(geometry.x, 0.0);
    }

    #[test]
    fn en_un_monitor_mas_bajo_que_el_minimo_no_baja_del_minimo() {
        let short = WorkArea {
            x: 0.0,
            y: 0.0,
            width: 1440.0,
            height: 400.0,
        };
        let geometry = anchored_geometry(short);
        assert_eq!(geometry.height, MEETINGS_WINDOW_MIN_HEIGHT.min(400.0));
    }
}
