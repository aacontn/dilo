//! La ventana popover de la barra de menú (diseño en
//! `docs/superpowers/specs/2026-08-01-reuniones-en-la-barra-de-menu-design.md`).
//!
//! **No es un NSPanel.** El overlay del dictado sí lo es, y de ahí sale su
//! regla de "crear una vez y jamás destruir" (ver `OVERLAY_GENERATION` en
//! `overlay.rs`). El popover necesita foco para ser interactivo —hay botones
//! adentro—, así que es una ventana normal sin decoraciones que se esconde al
//! perder el foco. Esa regla no aplica acá.

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

/// Centra el popover bajo el ícono y lo empuja hacia adentro si se saldría.
pub fn popover_position(icon: TrayRect, size: PopoverSize, work_area: WorkArea) -> PopoverGeometry {
    let centered = icon.x + icon.width / 2.0 - size.width / 2.0;

    let min_x = work_area.x + POPOVER_MARGIN;
    let max_x = work_area.x + work_area.width - size.width - POPOVER_MARGIN;

    // `max` antes que `min`: en una pantalla más angosta que el popover,
    // `max_x` queda por debajo de `min_x` y preferimos pegarlo al borde
    // izquierdo a dejarlo con x negativo.
    let x = centered.min(max_x).max(min_x);

    PopoverGeometry {
        x,
        y: icon.y + icon.height + POPOVER_GAP,
    }
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
}
