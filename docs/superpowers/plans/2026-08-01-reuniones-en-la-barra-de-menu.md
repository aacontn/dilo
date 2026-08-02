# Reuniones en la barra de menú — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que el ícono de la barra de menú abra un popover de vidrio con la sesión de reunión en curso, las últimas 4 reuniones y dos puertas —a la ventana de reuniones y a la de ajustes— sin tocar el dictado.

**Architecture:** El popover es una **ventana webview normal** de Tauri, sin decoraciones, posicionada bajo el ícono a partir del rectángulo que entrega `TrayIconEvent`, que se esconde al perder el foco. El clic izquierdo del ícono la conmuta; el derecho conserva el menú actual. Su contenido es una entrada de Vite propia (`src/popover/`), como ya lo son el overlay y la ventana de reuniones.

**Tech Stack:** Rust + Tauri 2 (`TrayIconBuilder`, `WebviewWindowBuilder`), React + TypeScript + Tailwind, Zustand, i18next, `bun test` para el frontend y `cargo test --lib` para Rust.

## Global Constraints

- **El dictado no cambia.** Todo es aditivo; quien nunca abra el popover no debe notar diferencia en reposo ni en latencia.
- **Sin dependencias nuevas** — ni en `Cargo.toml` ni en `package.json`.
- **Copy es-first, autoral, tuteo chileno.** Nunca voseo ("preferís", "elegí", "mirá"). El locale `es` es copia de marca escrita a mano: **no se genera a máquina**. Claves presentes en los 21 idiomas o `bun run check:translations` falla.
- **Nada de `Co-Authored-By` ni atribución de IA** en los mensajes de commit.
- **El popover es sólo macOS.** En Windows y Linux el clic izquierdo conserva el menú actual, intacto.
- **El catálogo de modelos no se toca**: no se borra ninguno de los existentes.
- Respeta `prefers-reduced-motion` como el resto de la app.
- Gates antes de cada commit: `cargo fmt`, `cargo clippy --all-targets` (0 warnings nuevos), `cargo test --lib`, `bun run build`, `bun run lint`, `bun run check:translations`.

## Estructura de archivos

| Archivo | Responsabilidad |
| --- | --- |
| `src-tauri/src/popover.rs` *(nuevo)* | Ciclo de vida de la ventana popover: crear, mostrar posicionada, esconder, conmutar. Incluye la geometría pura y sus tests. |
| `src-tauri/src/lib.rs` *(modificar)* | Registrar el módulo, la ventana en el builder del tray, y el manejador de foco que la esconde. |
| `src-tauri/src/tray.rs` *(modificar)* | Nada de menú nuevo; sólo lo que haga falta para que el clic izquierdo conmute en macOS. |
| `src-tauri/capabilities/default.json` *(modificar)* | Añadir la etiqueta `"popover"` a `windows`. **Sin esto los eventos y comandos se rechazan en silencio en producción.** |
| `src/popover/index.html`, `main.tsx`, `PopoverWindow.tsx` *(nuevos)* | Entrada de Vite y cascarón visual del popover. |
| `src/components/popover/PopoverBody.tsx` *(nuevo)* | Las cuatro zonas: ranura de avisos, sesión en curso, últimas reuniones, dos puertas. |
| `src/components/popover/recentMeetings.ts` *(nuevo)* | Selección pura de las 4 más recientes — lógica testeable sin DOM. |
| `vite.config.ts` *(modificar)* | Registrar la nueva entrada. |
| `src/i18n/locales/*/translation.json` *(modificar)* | Claves nuevas bajo `popover.` en los 21 idiomas. |

---

### Task 1: La geometría del popover

Posicionar bajo el ícono sin salirse de la pantalla. Es matemática pura, así que se resuelve y se prueba antes de tocar ninguna ventana.

**Files:**
- Create: `src-tauri/src/popover.rs`
- Modify: `src-tauri/src/lib.rs` (añadir `mod popover;` junto a los otros `mod`)

**Interfaces:**
- Consumes: nada.
- Produces: `pub struct PopoverGeometry { pub x: f64, pub y: f64 }` y
  `pub fn popover_position(icon: TrayRect, size: PopoverSize, work_area: WorkArea) -> PopoverGeometry`,
  donde `TrayRect { x, y, width, height }`, `PopoverSize { width, height }` y
  `WorkArea { x, y, width, height }` son structs públicos de este módulo, todos con campos `f64`.

- [ ] **Step 1: Escribir los tests que fallan**

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn area() -> WorkArea {
        WorkArea { x: 0.0, y: 0.0, width: 1440.0, height: 900.0 }
    }

    fn size() -> PopoverSize {
        PopoverSize { width: 360.0, height: 480.0 }
    }

    #[test]
    fn centra_el_popover_bajo_el_icono() {
        let icon = TrayRect { x: 700.0, y: 0.0, width: 24.0, height: 24.0 };
        let pos = popover_position(icon, size(), area());
        // centro del ícono 712 - mitad del popover 180 = 532
        assert_eq!(pos.x, 532.0);
        // borde inferior del ícono 24 + el respiro
        assert_eq!(pos.y, 24.0 + POPOVER_GAP);
    }

    #[test]
    fn no_se_sale_por_la_derecha() {
        // Ícono pegado al borde derecho: centrar lo dejaría fuera de pantalla.
        let icon = TrayRect { x: 1430.0, y: 0.0, width: 24.0, height: 24.0 };
        let pos = popover_position(icon, size(), area());
        assert_eq!(pos.x, 1440.0 - 360.0 - POPOVER_MARGIN);
    }

    #[test]
    fn no_se_sale_por_la_izquierda() {
        let icon = TrayRect { x: 2.0, y: 0.0, width: 24.0, height: 24.0 };
        let pos = popover_position(icon, size(), area());
        assert_eq!(pos.x, POPOVER_MARGIN);
    }

    #[test]
    fn respeta_un_area_de_trabajo_desplazada() {
        // Segunda pantalla a la derecha de la principal: el origen no es 0.
        // Alfonso trabaja con dos pantallas, así que este caso es el suyo.
        let shifted = WorkArea { x: 1440.0, y: 0.0, width: 1920.0, height: 1080.0 };
        let icon = TrayRect { x: 1450.0, y: 0.0, width: 24.0, height: 24.0 };
        let pos = popover_position(icon, size(), shifted);
        assert_eq!(pos.x, 1440.0 + POPOVER_MARGIN);
    }
}
```

- [ ] **Step 2: Correr los tests y verificar que fallan**

Run: `cargo test --manifest-path src-tauri/Cargo.toml --lib popover::`
Expected: FAIL — `cannot find function popover_position`

- [ ] **Step 3: Escribir la implementación mínima**

```rust
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
pub fn popover_position(
    icon: TrayRect,
    size: PopoverSize,
    work_area: WorkArea,
) -> PopoverGeometry {
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
```

Y en `src-tauri/src/lib.rs`, junto a los otros `mod`:

```rust
mod popover;
```

- [ ] **Step 4: Correr los tests y verificar que pasan**

Run: `cargo test --manifest-path src-tauri/Cargo.toml --lib popover::`
Expected: PASS — 4 passed

- [ ] **Step 5: Gates y commit**

```bash
cargo fmt --manifest-path src-tauri/Cargo.toml
cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets
git add src-tauri/src/popover.rs src-tauri/src/lib.rs
git commit -m "feat(popover): geometría del popover bajo el ícono de la barra"
```

---

### Task 2: La ventana popover

Crear, mostrar posicionada y esconder. Sin contenido todavía: una ventana vacía que aparece donde debe.

**Files:**
- Modify: `src-tauri/src/popover.rs`
- Modify: `src-tauri/capabilities/default.json`
- Create: `src/popover/index.html`, `src/popover/main.tsx`, `src/popover/PopoverWindow.tsx`
- Modify: `vite.config.ts`

**Interfaces:**
- Consumes: `popover_position`, `TrayRect`, `PopoverSize`, `WorkArea` de la Task 1.
- Produces:
  - `pub const POPOVER_WINDOW_LABEL: &str = "popover";`
  - `pub const POPOVER_WIDTH: f64 = 360.0;` y `pub const POPOVER_HEIGHT: f64 = 480.0;`
  - `pub fn toggle_popover(app: &AppHandle, icon: TrayRect)` — muestra posicionada si está escondida, esconde si está visible.
  - `pub fn hide_popover(app: &AppHandle)`

- [ ] **Step 1: Añadir la etiqueta a las capabilities**

En `src-tauri/capabilities/default.json`, la lista `windows`:

```json
  "windows": ["main", "recording_overlay", "meetings", "popover"],
```

**Por qué primero:** una ventana ausente de esta lista funciona en `tauri dev` y falla en producción — los comandos y eventos se rechazan sin error visible. Ya pasó con `"meetings"`.

- [ ] **Step 2: Registrar la entrada en Vite**

En `vite.config.ts`, junto a las entradas existentes de `main`, `overlay` y `meetings`:

```ts
        popover: resolve(__dirname, "src/popover/index.html"),
```

- [ ] **Step 3: Crear el cascarón del frontend**

`src/popover/index.html` — copia de `src/meetings/index.html` cambiando el `<script>` a `/src/popover/main.tsx` y el `<title>` a `Dilo — Reuniones`.

`src/popover/main.tsx`:

```tsx
import React from "react";
import ReactDOM from "react-dom/client";
import PopoverWindow from "./PopoverWindow";
import { syncThemeFromSettings } from "@/lib/utils/theme";
import "@/i18n";

syncThemeFromSettings();

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <PopoverWindow />
  </React.StrictMode>,
);
```

`src/popover/PopoverWindow.tsx`:

```tsx
import React from "react";

/**
 * Cascarón del popover de la barra de menú. El contenido llega en la Task 4;
 * acá sólo el vidrio, que sigue el ajuste de tema de Dilo (ver §2 del diseño:
 * el ícono sigue al sistema por legibilidad, el popover sigue a la app).
 */
const PopoverWindow: React.FC = () => (
  <div className="dilo-shell h-screen w-screen select-none cursor-default p-3" />
);

export default PopoverWindow;
```

**Nota:** `syncThemeFromSettings()` es la misma función que ya usa `src/meetings/main.tsx`; si su ruta difiere, cópiala de ahí en vez de inventarla.

- [ ] **Step 4: Escribir el test que falla**

En `src-tauri/src/popover.rs`, dentro de `mod tests`:

```rust
    #[test]
    fn el_tamano_del_popover_cabe_en_una_pantalla_chica() {
        // 1280x800 es el Mac más chico que soportamos; el popover no puede
        // ocupar más de la mitad del alto útil ni salirse a lo ancho.
        let small = WorkArea { x: 0.0, y: 0.0, width: 1280.0, height: 800.0 };
        assert!(POPOVER_WIDTH + POPOVER_MARGIN * 2.0 < small.width);
        assert!(POPOVER_HEIGHT < small.height / 2.0 + 100.0);
    }
```

- [ ] **Step 5: Correr el test y verificar que falla**

Run: `cargo test --manifest-path src-tauri/Cargo.toml --lib popover::`
Expected: FAIL — `cannot find value POPOVER_WIDTH`

- [ ] **Step 6: Implementar la ventana**

En `src-tauri/src/popover.rs`:

```rust
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};

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

pub fn hide_popover(app: &AppHandle) {
    if let Some(window) = app.get_webview_window(POPOVER_WINDOW_LABEL) {
        let _ = window.hide();
    }
}

fn position_and_show(app: &AppHandle, window: &tauri::WebviewWindow, icon: TrayRect) {
    let work_area = current_work_area(app, window);
    let pos = popover_position(
        icon,
        PopoverSize { width: POPOVER_WIDTH, height: POPOVER_HEIGHT },
        work_area,
    );

    let _ = window.set_position(tauri::Position::Logical(tauri::LogicalPosition {
        x: pos.x,
        y: pos.y,
    }));
    let _ = window.show();
    let _ = window.set_focus();
}

/// Área utilizable del monitor donde está el popover. Si no se puede
/// determinar, cae a la pantalla principal; si tampoco, a un tamaño
/// conservador — es preferible un popover mal centrado a ninguno.
fn current_work_area(app: &AppHandle, window: &tauri::WebviewWindow) -> WorkArea {
    let monitor = window
        .current_monitor()
        .ok()
        .flatten()
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
        None => WorkArea { x: 0.0, y: 0.0, width: 1440.0, height: 900.0 },
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
```

- [ ] **Step 7: Esconder al perder el foco**

En `src-tauri/src/lib.rs`, en el `match` de `WindowEvent` (junto a `CloseRequested` y `ThemeChanged`):

```rust
            tauri::WindowEvent::Focused(false) => {
                // El popover es efímero: al hacer clic fuera se va, como
                // cualquier menú del sistema. Sólo aplica a esa ventana; las
                // demás siguen vivas al perder el foco.
                if window.label() == popover::POPOVER_WINDOW_LABEL {
                    let _ = window.hide();
                }
            }
```

- [ ] **Step 8: Correr los tests y verificar que pasan**

Run: `cargo test --manifest-path src-tauri/Cargo.toml --lib popover::`
Expected: PASS — 5 passed

- [ ] **Step 9: Gates y commit**

```bash
cargo fmt --manifest-path src-tauri/Cargo.toml
cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets
bun run build
git add -A
git commit -m "feat(popover): ventana del popover, posicionada bajo el ícono y efímera"
```

---

### Task 3: El clic del ícono

Izquierdo conmuta el popover en macOS; derecho conserva el menú. En Windows y Linux nada cambia.

**Files:**
- Modify: `src-tauri/src/lib.rs:311-322` (el `TrayIconBuilder`)
- Modify: `src-tauri/src/popover.rs` (la función de decisión y sus tests)

**Interfaces:**
- Consumes: `toggle_popover`, `TrayRect` de la Task 2.
- Produces: `pub enum TrayClick { Popover, Menu }` y
  `pub fn tray_click_action(button: TrayButton, popover_supported: bool) -> TrayClick`,
  donde `pub enum TrayButton { Left, Right }`.

- [ ] **Step 1: Escribir los tests que fallan**

```rust
    #[test]
    fn el_clic_izquierdo_abre_el_popover_donde_hay_soporte() {
        assert_eq!(tray_click_action(TrayButton::Left, true), TrayClick::Popover);
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
```

- [ ] **Step 2: Correr los tests y verificar que fallan**

Run: `cargo test --manifest-path src-tauri/Cargo.toml --lib popover::`
Expected: FAIL — `cannot find function tray_click_action`

- [ ] **Step 3: Implementar la decisión**

```rust
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
```

- [ ] **Step 4: Correr los tests y verificar que pasan**

Run: `cargo test --manifest-path src-tauri/Cargo.toml --lib popover::`
Expected: PASS — 8 passed

- [ ] **Step 5: Cablear el builder del tray**

En `src-tauri/src/lib.rs`, en el `TrayIconBuilder`, cambiar la línea

```rust
        .show_menu_on_left_click(true)
```

por

```rust
        // En macOS el clic izquierdo abre el popover (ver `popover.rs`); el
        // derecho conserva el menú de siempre. En Windows y Linux, donde no
        // hay popover, el izquierdo sigue abriendo el menú como hasta ahora.
        .show_menu_on_left_click(!popover::popover_supported())
        .on_tray_icon_event(|tray, event| {
            let tauri::tray::TrayIconEvent::Click { button, button_state, rect, .. } = event
            else {
                return;
            };
            if button_state != tauri::tray::MouseButtonState::Up {
                return;
            }
            let tray_button = match button {
                tauri::tray::MouseButton::Left => popover::TrayButton::Left,
                _ => popover::TrayButton::Right,
            };
            if popover::tray_click_action(tray_button, popover::popover_supported())
                != popover::TrayClick::Popover
            {
                return;
            }
            let app = tray.app_handle();
            let scale = tray
                .try_get_window()
                .and_then(|w| w.scale_factor().ok())
                .unwrap_or(1.0);
            let position = rect.position.to_logical::<f64>(scale);
            let size = rect.size.to_logical::<f64>(scale);
            popover::toggle_popover(
                app,
                popover::TrayRect {
                    x: position.x,
                    y: position.y,
                    width: size.width,
                    height: size.height,
                },
            );
        })
```

**Si la API de `rect`/`scale` no calza** con la versión de Tauri del repo, resuelve la escala como lo hace `overlay.rs` al posicionar la pastilla y deja un comentario explicando la diferencia. No inventes una constante de escala.

- [ ] **Step 6: Verificar que el menú derecho sigue vivo**

Run: `cargo build --manifest-path src-tauri/Cargo.toml`
Expected: compila sin warnings nuevos. Comprobación manual anotada para la Task 5.

- [ ] **Step 7: Gates y commit**

```bash
cargo fmt --manifest-path src-tauri/Cargo.toml
cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets
git add -A
git commit -m "feat(popover): el clic izquierdo del ícono abre el popover en macOS"
```

---

### Task 4: Las cuatro zonas

El contenido: ranura de avisos vacía, sesión en curso, últimas 4 reuniones y las dos puertas.

**Files:**
- Modify: `src/components/meeting/meetingFormat.ts` (extraer `isPastMeeting`)
- Modify: `src/components/meeting/MeetingsList.tsx:20-21` (importarlo en vez de definirlo)
- Create: `src/components/popover/PopoverBody.tsx`
- Modify: `src/popover/PopoverWindow.tsx`
- Test: `tests/unit/meetingSession.test.ts` (añadir el describe nuevo — ya cubre `meetingFormat`)
- Modify: los 21 `src/i18n/locales/*/translation.json`

**Interfaces:**
- Consumes: `commands.listMeetings(limit, offset)`, `commands.openMeetingsWindow()` y `commands.returnToMainWindow()` de `@/bindings` (los tres ya existen); `useMeetingStore` de `@/stores/meetingStore`; los tipos `MeetingSummary` y `PaginatedMeetings` de `@/bindings`.
- Produces: `export const isPastMeeting: (meeting: MeetingSummary) => boolean` y
  `export const RECENT_MEETINGS_LIMIT = 4;`, ambos desde
  `src/components/meeting/meetingFormat.ts`.

**Dos hechos del backend que mandan sobre este diseño** (verificados, no supuestos):

1. `list_meetings` ya devuelve `ORDER BY started_at DESC, id DESC` y acota el
   límite. **No hay que ordenar en el frontend** — sería duplicar la regla.
2. `list_meetings` **incluye la reunión en curso**. `MeetingsList` la filtra hoy
   con un `isPastMeeting` privado. El popover necesita la misma regla, así que se
   extrae a un módulo compartido en vez de copiarla — dos copias de la misma
   regla se separan sola.

Por eso el popover pide **`RECENT_MEETINGS_LIMIT + 1`** filas: si hay una
grabando ocupa la primera, y sin el `+1` mostraría sólo 3.

- [ ] **Step 1: Escribir el test que falla**

En `tests/unit/meetingSession.test.ts`, añadir al final:

```ts
import {
  isPastMeeting,
  RECENT_MEETINGS_LIMIT,
} from "@/components/meeting/meetingFormat";

describe("isPastMeeting", () => {
  test("deja pasar las terminadas", () => {
    expect(isPastMeeting({ ...summary(1), status: "ready" })).toBe(true);
  });

  test("deja pasar las interrumpidas: son legibles aunque incompletas", () => {
    expect(isPastMeeting({ ...summary(1), status: "interrupted" })).toBe(true);
  });

  test("saca la que está grabando ahora", () => {
    expect(isPastMeeting({ ...summary(1), status: "recording" })).toBe(false);
  });

  test("pedir una fila de más deja 4 pasadas aunque una esté grabando", () => {
    const rows = [
      { ...summary(5), status: "recording" },
      summary(4),
      summary(3),
      summary(2),
      summary(1),
    ];
    expect(rows.filter(isPastMeeting).slice(0, RECENT_MEETINGS_LIMIT)).toHaveLength(4);
  });
});
```

- [ ] **Step 2: Correr el test y verificar que falla**

Run: `bun test tests/unit/meetingSession.test.ts`
Expected: FAIL — `isPastMeeting` no se exporta desde `meetingFormat`

- [ ] **Step 3: Extraer la regla compartida**

En `src/components/meeting/meetingFormat.ts`, añadir:

```ts
import type { MeetingSummary } from "@/bindings";

/**
 * Cuántas reuniones muestra el popover de la barra. Número fijo y no "las que
 * quepan": así el popover no cambia de alto según lo que haya (§2 del diseño).
 */
export const RECENT_MEETINGS_LIMIT = 4;

/**
 * La reunión en curso viaja en el mismo listado que las pasadas —
 * `list_meetings` no la excluye—, así que quien muestre "reuniones pasadas"
 * tiene que filtrarla. Vive acá y no en un componente porque la usan dos: el
 * registro completo y el popover.
 */
export const isPastMeeting = (meeting: MeetingSummary): boolean =>
  meeting.status !== "recording";
```

Y en `src/components/meeting/MeetingsList.tsx`, borrar la definición local
(líneas 15-21, con su comentario) e importarla:

```ts
import { appendMeetingPage, isPastMeeting } from "./meetingFormat";
```

- [ ] **Step 4: Correr el test y verificar que pasa**

Run: `bun test tests/unit/meetingSession.test.ts`
Expected: PASS — incluidos los 4 nuevos

- [ ] **Step 5: Añadir la copia en inglés y español**

En `src/i18n/locales/en/translation.json`, un bloque nuevo `popover`:

```json
  "popover": {
    "idle": "No meeting is being recorded",
    "recording": "Recording",
    "recentTitle": "Recent meetings",
    "recentEmpty": "Nothing recorded yet",
    "loadFailed": "Couldn't load your meetings",
    "openTranscript": "Open transcript",
    "openDilo": "Open Dilo",
    "openFailed": "Couldn't open the window"
  },
```

En `src/i18n/locales/es/translation.json` — **escrita a mano, tuteo chileno, sin voseo**:

```json
  "popover": {
    "idle": "No hay ninguna reunión grabándose",
    "recording": "Grabando",
    "recentTitle": "Reuniones recientes",
    "recentEmpty": "Todavía no grabas ninguna",
    "loadFailed": "No se pudieron cargar tus reuniones",
    "openTranscript": "Abrir transcript",
    "openDilo": "Abrir Dilo",
    "openFailed": "No se pudo abrir la ventana"
  },
```

Para los 19 idiomas restantes, traduce estas ocho claves respetando el registro
de cada locale. **No copies el inglés como relleno** — `check:translations` sólo
verifica que la clave exista, así que el relleno pasa el gate y llega al usuario.

- [ ] **Step 6: Construir el cuerpo del popover**

`src/components/popover/PopoverBody.tsx`:

```tsx
import React, { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import { ArrowUpRight, Settings2 } from "lucide-react";
import { commands, type MeetingSummary } from "@/bindings";
import { useMeetingStore } from "@/stores/meetingStore";
import {
  isPastMeeting,
  RECENT_MEETINGS_LIMIT,
} from "@/components/meeting/meetingFormat";

/**
 * Las cuatro zonas del popover (§2 del diseño). La primera queda vacía a
 * propósito: es donde el proyecto de detección de reuniones pondrá su aviso,
 * y dejarla declarada evita rediseñar el popover entero cuando llegue.
 */
export const PopoverBody: React.FC = () => {
  const { t } = useTranslation();
  const activeMeetingId = useMeetingStore((s) => s.activeMeetingId);
  const [recent, setRecent] = useState<MeetingSummary[]>([]);

  // Una fila de más: `list_meetings` incluye la que está grabando, y sin el
  // +1 el filtro dejaría sólo 3.
  useEffect(() => {
    void (async () => {
      const result = await commands.listMeetings(RECENT_MEETINGS_LIMIT + 1, 0);
      if (result.status === "ok") {
        setRecent(
          result.data.meetings
            .filter(isPastMeeting)
            .slice(0, RECENT_MEETINGS_LIMIT),
        );
      } else {
        toast.error(t("popover.loadFailed"), { description: result.error });
      }
    })();
  }, [activeMeetingId, t]);

  const open = async (which: "transcript" | "dilo") => {
    const result =
      which === "transcript"
        ? await commands.openMeetingsWindow()
        : await commands.returnToMainWindow();
    if (result.status === "error") {
      toast.error(t("popover.openFailed"), { description: result.error });
    }
  };

  return (
    <div className="flex h-full flex-col gap-3">
      {/* 1 · Ranura de avisos — vacía hasta que exista la detección. */}
      <div data-testid="popover-notice-slot" />

      {/* 2 · La sesión en curso. */}
      <section className="glass-surface rounded-xl p-3">
        <p className="text-sm text-muted-text">
          {activeMeetingId ? t("popover.recording") : t("popover.idle")}
        </p>
      </section>

      {/* 3 · Las últimas reuniones. */}
      <section className="flex-1 overflow-y-auto">
        <h2 className="mb-2 text-xs uppercase tracking-wide text-muted-text">
          {t("popover.recentTitle")}
        </h2>
        {recent.length === 0 ? (
          <p className="text-sm text-muted-text">{t("popover.recentEmpty")}</p>
        ) : (
          <ul className="flex flex-col gap-1">
            {recent.map((m) => (
              <li key={m.id} className="truncate text-sm">
                {m.title}
              </li>
            ))}
          </ul>
        )}
      </section>

      {/* 4 · Las dos puertas. */}
      <footer className="flex gap-2">
        <button
          type="button"
          onClick={() => void open("transcript")}
          className="flex flex-1 items-center justify-center gap-1.5 rounded-lg px-2 py-1.5 text-sm text-muted-text transition-colors hover:bg-white/10 hover:text-text"
        >
          <ArrowUpRight className="size-4 shrink-0" />
          {t("popover.openTranscript")}
        </button>
        <button
          type="button"
          onClick={() => void open("dilo")}
          className="flex flex-1 items-center justify-center gap-1.5 rounded-lg px-2 py-1.5 text-sm text-muted-text transition-colors hover:bg-white/10 hover:text-text"
        >
          <Settings2 className="size-4 shrink-0" />
          {t("popover.openDilo")}
        </button>
      </footer>
    </div>
  );
};
```

- [ ] **Step 7: Montar el cuerpo en la ventana**

`src/popover/PopoverWindow.tsx`:

```tsx
import React from "react";
import { Toaster } from "sonner";
import { PopoverBody } from "@/components/popover/PopoverBody";

const PopoverWindow: React.FC = () => (
  <>
    <Toaster
      theme="system"
      toastOptions={{
        unstyled: true,
        classNames: {
          toast:
            "glass-toast rounded-xl px-4 py-3 flex items-center gap-3 text-sm",
          title: "font-medium",
          description: "text-muted-text",
        },
      }}
    />
    <div className="dilo-shell h-screen w-screen select-none cursor-default p-3">
      <PopoverBody />
    </div>
  </>
);

export default PopoverWindow;
```

- [ ] **Step 8: Correr las compuertas**

```bash
bun test tests/unit
bun run build
bun run lint
bun run check:translations
```

Expected: todo verde, 21 idiomas completos, y **el registro de reuniones sigue
pasando sus tests** — la extracción de `isPastMeeting` no debe cambiar su
comportamiento.

- [ ] **Step 9: Verificar que no se coló voseo**

Run:
```bash
grep -nE "preferís|querés|podés|tenés|elegí |mirá|ponele|sabés|hacé|vos " src/i18n/locales/es/translation.json
```
Expected: sin resultados. Si aparece alguno, reescribe esa línea en tuteo chileno.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat(popover): las cuatro zonas del popover y sus dos puertas"
```

---


### Task 5: Verificación en la app

Lo que ningún test unitario puede probar: que el popover se vea y se comporte.

**Files:** ninguno — es una pasada de verificación. Los arreglos que salgan van con su propio commit.

**Interfaces:**
- Consumes: todo lo anterior.
- Produces: nada.

- [ ] **Step 1: Compilar y correr la app**

```bash
bun run tauri dev
```

**Avisar a Alfonso antes de correr esto:** compilar el crate satura los cores por minutos y le degrada el dictado que usa en vivo (de ~1 s a 17 s). No lanzarlo sin avisar.

- [ ] **Step 2: Recorrer la lista de verificación del diseño**

- [ ] El ícono cambia de estado al empezar y terminar una grabación.
- [ ] El clic izquierdo abre el popover; el derecho abre el menú de siempre.
- [ ] El popover aparece bajo el ícono, centrado, sin salirse de la pantalla.
- [ ] Con el ícono cerca del borde derecho, el popover se empuja hacia adentro.
- [ ] En la segunda pantalla, aparece en la pantalla correcta.
- [ ] Al hacer clic fuera, el popover se esconde.
- [ ] "Abrir transcript" abre Reuniones y esconde Ajustes.
- [ ] "Abrir Dilo" abre Ajustes y esconde Reuniones.
- [ ] El popover sigue el tema de Dilo; cambiar el tema lo cambia.
- [ ] El dictado sigue funcionando igual, con el popover cerrado y abierto.

- [ ] **Step 3: Commit de los arreglos que salgan**

Uno por arreglo, con prefijo `fix(popover):` y el mensaje explicando *por qué*, no *qué*.

---

## Lo que este plan NO construye

Anotado para que nadie lo dé por hecho:

- **La detección de reuniones.** La ranura queda vacía. Los eventos `MeetingCallDetected` y `MeetingCallEnded` ya existen declarados en `managers/meeting.rs` pero **nadie los emite**; llenarlos es el proyecto del anexo del diseño, y necesita su propio spec.
- **El transcript vivo dentro del popover.** La zona 2 muestra el estado de la sesión, no el texto corriendo. El streaming es la mejora pendiente de §2 del diseño del notetaker.
- **Paridad en Windows y Linux.**

## Lo que ya está hecho — no rehacer

El diseño incluye en su Alcance el **botón de volver a Dilo** dentro de la
ventana de reuniones. **Ya está construido y committeado** (`463a8e1c`), porque
no dependía de nada de este plan:

- `return_to_main_window` en `src-tauri/src/meeting_window.rs` — muestra Ajustes
  y esconde Reuniones si existe.
- El botón en `src/meetings/MeetingsWindow.tsx`, bajo la franja de arrastre para
  no chocar con los semáforos de macOS.
- `meeting.backToDilo` y `meeting.backFailed` en los 21 idiomas.

La Task 4 **reusa** ese comando para la puerta "Abrir Dilo". No lo reimplementes.
