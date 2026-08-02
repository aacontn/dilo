//! La ventana popover de la barra de menú (diseño en
//! `docs/superpowers/specs/2026-08-01-reuniones-en-la-barra-de-menu-design.md`).
//!
//! **No es un NSPanel.** El overlay del dictado sí lo es, y de ahí sale su
//! regla de "crear una vez y jamás destruir" (ver `OVERLAY_GENERATION` en
//! `overlay.rs`). El popover necesita foco para ser interactivo —hay botones
//! adentro—, así que es una ventana normal sin decoraciones que se esconde al
//! perder el foco. Esa regla no aplica acá.

use tauri::{AppHandle, Manager, Rect, WebviewUrl, WebviewWindowBuilder};

/// Respiro entre el borde inferior del ícono y el techo del popover.
pub const POPOVER_GAP: f64 = 6.0;

/// Margen mínimo contra el borde de la pantalla.
pub const POPOVER_MARGIN: f64 = 8.0;

/// Rectángulo del ícono en la barra, tal como lo entrega `TrayIconEvent`.
#[derive(Debug, Clone, Copy)]
pub struct TrayRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrayButton {
    Left,
    Right,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrayClick {
    Popover,
    Menu,
}

/// Qué hace un clic en el ícono. Pura y testeable: `popover_supported` entra
/// como parámetro en vez de consultarse acá, para poder probar las dos
/// plataformas desde cualquiera.
pub fn tray_click_action(button: TrayButton, popover_supported: bool) -> TrayClick {
    match (button, popover_supported) {
        (TrayButton::Left, true) => TrayClick::Popover,
        _ => TrayClick::Menu,
    }
}

/// True donde el popover existe. Hoy sólo macOS (§4 del diseño).
pub fn popover_supported() -> bool {
    cfg!(target_os = "macos")
}

/// Convierte el `rect` de `TrayIconEvent::Click` (físico) a `TrayRect`
/// (lógico, el contrato de este módulo — ver `current_work_area` más abajo).
///
/// El punto crítico: no hay una API que entregue "el scale factor de este
/// evento". `tray-icon` 0.21 arma `rect` en macOS a partir del
/// `backingScaleFactor()` de la `NSWindow` del ícono (su
/// `platform_impl::macos::get_tray_rect`), que es el scale del **monitor
/// donde vive el ícono en ese instante** — no una constante ni el scale de
/// la ventana principal, que puede estar en otra pantalla. Igual que
/// `get_monitor_with_cursor` en `overlay.rs` resuelve el monitor antes de
/// confiar en un scale factor, acá resolvemos el monitor cuyos límites
/// físicos contienen el punto del rect y usamos su `scale_factor()`. A
/// diferencia de aquella función —que normaliza un punto de origen ambiguo
/// dividiendo por el scale antes de comparar—, acá el punto ya es físico sin
/// ambigüedad, así que se compara directo contra `Monitor::position()` /
/// `size()` (también físicas, sin conversión).
///
/// Si ningún monitor contiene el punto (no debería pasar, pero mejor que un
/// panic), cae a escala 1.0: en una pantalla 1x el resultado es correcto de
/// todas formas, y en Retina es preferible un popover mal ubicado a ninguno.
pub fn logical_tray_rect(app: &AppHandle, rect: Rect) -> TrayRect {
    // `to_physical(1.0)` sólo hace de cast cuando la variante ya es física
    // (el caso real en macOS); sirve para tener un punto con el que buscar
    // el monitor antes de conocer el scale real.
    let raw_pos = rect.position.to_physical::<f64>(1.0);

    let scale = app
        .available_monitors()
        .ok()
        .into_iter()
        .flatten()
        .find(|m| {
            let mp = m.position();
            let ms = m.size();
            raw_pos.x >= mp.x as f64
                && raw_pos.x < mp.x as f64 + ms.width as f64
                && raw_pos.y >= mp.y as f64
                && raw_pos.y < mp.y as f64 + ms.height as f64
        })
        .map(|m| m.scale_factor())
        .unwrap_or(1.0);

    let pos = rect.position.to_logical::<f64>(scale);
    let size = rect.size.to_logical::<f64>(scale);

    TrayRect {
        x: pos.x,
        y: pos.y,
        width: size.width,
        height: size.height,
    }
}

#[derive(Debug, Clone, Copy)]
pub struct PopoverSize {
    pub width: f64,
    pub height: f64,
}

/// Área utilizable de la pantalla donde vive el ícono. `x`/`y` no son cero
/// cuando el monitor no es el principal.
#[derive(Debug, Clone, Copy)]
pub struct WorkArea {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PopoverGeometry {
    pub x: f64,
    pub y: f64,
}

/// Centra el popover bajo el ícono y lo empuja hacia adentro en ambos ejes si se saldría.
pub fn popover_position(icon: TrayRect, size: PopoverSize, work_area: WorkArea) -> PopoverGeometry {
    let centered = icon.x + icon.width / 2.0 - size.width / 2.0;

    let min_x = work_area.x + POPOVER_MARGIN;
    let max_x = work_area.x + work_area.width - size.width - POPOVER_MARGIN;

    // `max` antes que `min`: en una pantalla más angosta que el popover,
    // `max_x` queda por debajo de `min_x` y preferimos pegarlo al borde
    // izquierdo a dejarlo con x negativo.
    let x = centered.min(max_x).max(min_x);

    let below = icon.y + icon.height + POPOVER_GAP;
    let min_y = work_area.y + POPOVER_MARGIN;
    let max_y = work_area.y + work_area.height - size.height - POPOVER_MARGIN;

    // Mismo orden que en X y por la misma razón: en una pantalla más baja que
    // el popover, `max_y` cae bajo `min_y` y preferimos pegarlo arriba a
    // dejarlo fuera de pantalla.
    let y = below.min(max_y).max(min_y);

    PopoverGeometry { x, y }
}

pub const POPOVER_WINDOW_LABEL: &str = "popover";
pub const POPOVER_WIDTH: f64 = 360.0;
pub const POPOVER_HEIGHT: f64 = 480.0;

/// Conmuta el popover: si está visible lo esconde, si no lo muestra bajo el
/// ícono. Se **esconde**, nunca se destruye, para no pagar el arranque del
/// webview en cada clic.
pub fn toggle_popover(app: &AppHandle, icon: TrayRect) {
    if let Some(window) = app.get_webview_window(POPOVER_WINDOW_LABEL) {
        if window.is_visible().unwrap_or(false) {
            let _ = window.hide();
            return;
        }
        position_and_show(app, &window, icon);
        return;
    }

    match create_popover_window(app) {
        Ok(window) => position_and_show(app, &window, icon),
        Err(e) => log::error!("No se pudo crear el popover: {e}"),
    }
}

fn position_and_show(app: &AppHandle, window: &tauri::WebviewWindow, icon: TrayRect) {
    let work_area = current_work_area(app, window, icon);
    let pos = popover_position(
        icon,
        PopoverSize {
            width: POPOVER_WIDTH,
            height: POPOVER_HEIGHT,
        },
        work_area,
    );

    let _ = window.set_position(tauri::Position::Logical(tauri::LogicalPosition {
        x: pos.x,
        y: pos.y,
    }));
    let _ = window.show();
    let _ = window.set_focus();
}

/// Área utilizable del monitor donde está el popover.
///
/// Se resuelve desde el **centro del ícono**, no desde la ventana: una
/// ventana recién creada aterriza donde el sistema la puso por defecto
/// (típicamente la pantalla principal), no necesariamente donde está el
/// ícono — con dos pantallas de escalas distintas la primera apertura
/// calcularía la geometría contra la pantalla equivocada. Mismo problema que
/// resuelve `get_monitor_with_cursor` en `overlay.rs`, pero desde el punto
/// del ícono en vez del cursor.
///
/// `TrayRect` ya llega en coordenadas lógicas (puntos), que es lo que
/// `AppHandle::monitor_from_point` espera en macOS: por debajo llama a
/// `CGDisplayBounds`, que —como `NSEvent::mouseLocation`, la misma fuente que
/// ya usa `overlay.rs`— reporta en puntos, no en píxeles físicos.
///
/// Si no se puede resolver por el punto (por ejemplo si `monitor_from_point`
/// no está implementado en la plataforma), cae al monitor de la ventana; si
/// tampoco, a la pantalla principal; si tampoco, a un tamaño conservador —
/// es preferible un popover mal centrado a ninguno.
fn current_work_area(app: &AppHandle, window: &tauri::WebviewWindow, icon: TrayRect) -> WorkArea {
    let center_x = icon.x + icon.width / 2.0;
    let center_y = icon.y + icon.height / 2.0;

    let monitor = app
        .monitor_from_point(center_x, center_y)
        .ok()
        .flatten()
        .or_else(|| window.current_monitor().ok().flatten())
        .or_else(|| app.primary_monitor().ok().flatten());

    match monitor {
        Some(m) => {
            let scale = m.scale_factor();
            let size = m.size().to_logical::<f64>(scale);
            let position = m.position().to_logical::<f64>(scale);
            WorkArea {
                x: position.x,
                y: position.y,
                width: size.width,
                height: size.height,
            }
        }
        None => WorkArea {
            x: 0.0,
            y: 0.0,
            width: 1440.0,
            height: 900.0,
        },
    }
}

fn create_popover_window(app: &AppHandle) -> Result<tauri::WebviewWindow, String> {
    let mut builder = WebviewWindowBuilder::new(
        app,
        POPOVER_WINDOW_LABEL,
        WebviewUrl::App("src/popover/index.html".into()),
    )
    .inner_size(POPOVER_WIDTH, POPOVER_HEIGHT)
    .resizable(false)
    .decorations(false)
    .transparent(true)
    .always_on_top(true)
    .skip_taskbar(true)
    .visible(false);

    if let Some(data_dir) = crate::portable::data_dir() {
        builder = builder.data_directory(data_dir.join("webview"));
    }

    builder.build().map_err(|e| e.to_string())
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

    fn size() -> PopoverSize {
        PopoverSize {
            width: 360.0,
            height: 480.0,
        }
    }

    #[test]
    fn centra_el_popover_bajo_el_icono() {
        let icon = TrayRect {
            x: 700.0,
            y: 0.0,
            width: 24.0,
            height: 24.0,
        };
        let pos = popover_position(icon, size(), area());
        // centro del ícono 712 - mitad del popover 180 = 532
        assert_eq!(pos.x, 532.0);
        // borde inferior del ícono 24 + el respiro
        assert_eq!(pos.y, 24.0 + POPOVER_GAP);
    }

    #[test]
    fn no_se_sale_por_la_derecha() {
        // Ícono pegado al borde derecho: centrar lo dejaría fuera de pantalla.
        let icon = TrayRect {
            x: 1430.0,
            y: 0.0,
            width: 24.0,
            height: 24.0,
        };
        let pos = popover_position(icon, size(), area());
        assert_eq!(pos.x, 1440.0 - 360.0 - POPOVER_MARGIN);
    }

    #[test]
    fn no_se_sale_por_la_izquierda() {
        let icon = TrayRect {
            x: 2.0,
            y: 0.0,
            width: 24.0,
            height: 24.0,
        };
        let pos = popover_position(icon, size(), area());
        assert_eq!(pos.x, POPOVER_MARGIN);
    }

    #[test]
    fn respeta_un_area_de_trabajo_desplazada() {
        // Segunda pantalla a la derecha de la principal: el origen no es 0.
        // Alfonso trabaja con dos pantallas, así que este caso es el suyo.
        let shifted = WorkArea {
            x: 1440.0,
            y: 0.0,
            width: 1920.0,
            height: 1080.0,
        };
        let icon = TrayRect {
            x: 1450.0,
            y: 0.0,
            width: 24.0,
            height: 24.0,
        };
        let pos = popover_position(icon, size(), shifted);
        assert_eq!(pos.x, 1440.0 + POPOVER_MARGIN);
    }

    #[test]
    fn sube_el_popover_si_no_cabe_bajo_el_icono() {
        // Barra de menú abajo (Windows/Linux): el ícono está al pie de la
        // pantalla y colgar el popover bajo él lo dejaría fuera.
        let icon = TrayRect {
            x: 700.0,
            y: 880.0,
            width: 24.0,
            height: 24.0,
        };
        let pos = popover_position(icon, size(), area());
        assert_eq!(pos.y, 900.0 - 480.0 - POPOVER_MARGIN);
    }

    #[test]
    fn no_se_sale_por_arriba_en_una_pantalla_muy_baja() {
        // Pantalla más baja que el popover: pegado arriba, nunca en negativo.
        let short = WorkArea {
            x: 0.0,
            y: 0.0,
            width: 1440.0,
            height: 300.0,
        };
        let icon = TrayRect {
            x: 700.0,
            y: 0.0,
            width: 24.0,
            height: 24.0,
        };
        let pos = popover_position(icon, size(), short);
        assert_eq!(pos.y, POPOVER_MARGIN);
    }

    #[test]
    fn en_una_pantalla_mas_angosta_que_el_popover_se_pega_a_la_izquierda() {
        let narrow = WorkArea {
            x: 0.0,
            y: 0.0,
            width: 200.0,
            height: 900.0,
        };
        let icon = TrayRect {
            x: 100.0,
            y: 0.0,
            width: 24.0,
            height: 24.0,
        };
        let pos = popover_position(icon, size(), narrow);
        assert_eq!(pos.x, POPOVER_MARGIN);
    }

    #[test]
    fn el_tamano_del_popover_cabe_en_una_pantalla_chica() {
        // 1280x800 es el Mac más chico que soportamos; el popover no puede
        // ocupar más de la mitad del alto útil ni salirse a lo ancho.
        let small = WorkArea {
            x: 0.0,
            y: 0.0,
            width: 1280.0,
            height: 800.0,
        };
        assert!(POPOVER_WIDTH + POPOVER_MARGIN * 2.0 < small.width);
        assert!(POPOVER_HEIGHT < small.height / 2.0 + 100.0);
    }

    #[test]
    fn el_clic_izquierdo_abre_el_popover_donde_hay_soporte() {
        assert_eq!(
            tray_click_action(TrayButton::Left, true),
            TrayClick::Popover
        );
    }

    #[test]
    fn el_clic_derecho_siempre_abre_el_menu() {
        assert_eq!(tray_click_action(TrayButton::Right, true), TrayClick::Menu);
        assert_eq!(tray_click_action(TrayButton::Right, false), TrayClick::Menu);
    }

    #[test]
    fn sin_soporte_de_popover_el_izquierdo_conserva_el_menu() {
        // Windows y Linux: el comportamiento de hoy no se toca.
        assert_eq!(tray_click_action(TrayButton::Left, false), TrayClick::Menu);
    }
}
