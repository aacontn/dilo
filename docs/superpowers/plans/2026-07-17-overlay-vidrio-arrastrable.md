# Overlay de vidrio arrastrable — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rediseñar el overlay de grabación como pastilla de vidrio con ondas mango→rojo, y permitir arrastrarla a cualquier parte con memoria de posición por pantalla.

**Architecture:** El frontend (webview `src/overlay/`) solo detecta el gesto (mousedown + umbral 4px) e invoca un comando; el arrastre real lo hace el OS vía `start_dragging()` de Tauri. Rust persiste la posición al soltar (debounce sobre `WindowEvent::Moved` con flag de drag activo) como **ancla por monitor** en settings (`overlay_custom_positions`), y el show del overlay resuelve ancla→preset con clamping. El restyle es CSS puro sobre los tokens del tema.

**Tech Stack:** Tauri 2 (Rust), React/TS, tauri-specta (bindings), tauri-plugin-store (settings), CSS con `color-mix` + tokens de `theme.css`/`brand.css`.

**Spec:** `docs/superpowers/specs/2026-07-17-overlay-vidrio-arrastrable-design.md`

## Global Constraints

- Copy es-first, tuteo, sin filler corporativo; el locale `es` es autoral (no machine-translate). Todo string de UI pasa por i18n.
- Núcleo Rust cerca de upstream Handy: commits enfocados con prefijos convencionales (`feat:`, `style:`, `refactor:`…), mensaje centrado en el porqué.
- Antes de commitear: `bun run lint` + `bun run format` (Prettier + cargo fmt); Rust sin `unwrap` en paths de producción.
- TS estricto, sin `any`.
- **Desviación aprobada del spec:** el vidrio es **simulado** (tinte translúcido, sin `backdrop-filter`): WebKit no puede muestrear el escritorio detrás de una ventana transparente de Tauri; blur real exigiría vibrancy nativa con ventanas de tamaño fijo (rompe los morfos animados). Tinte pastilla ~72% / panel Live ~86% en vez de 14%/35% del spec (sin blur, 14% es ilegible).
- Linux con GTK layer-shell: sin arrastre (la ventana está anclada por el compositor); el resto del feature no debe romper ese path.

## Estructura de archivos

- **Modify** `src-tauri/src/settings.rs` — tipo `OverlayAnchor`, campo `overlay_custom_positions`, tests serde.
- **Modify** `src-tauri/src/overlay.rs` — geometría pura de anclas (+tests), resolución custom→preset, edge en payload, comando `start_overlay_drag`, persistencia al soltar, `clear_custom_overlay_positions`, padding de sombra.
- **Modify** `src-tauri/src/shortcut/mod.rs` — `change_overlay_position_setting` limpia anclas.
- **Modify** `src-tauri/src/lib.rs` — registro del comando, handler `Moved`, ítem de tray.
- **Modify** `src-tauri/src/tray.rs` — ítem "Restablecer posición del overlay".
- **Modify** `src/i18n/locales/*/translation.json` (22 locales) — clave `tray.resetOverlayPosition`.
- **Modify** `src/overlay/RecordingOverlay.tsx` — payload `{state, edge}`, gesto de arrastre, quitar `.sdot`.
- **Modify** `src/overlay/RecordingOverlay.css` — restyle vidrio + brasa, padding de sombra.
- **Test** `src-tauri` unit tests inline (`#[cfg(test)]` en settings.rs y overlay.rs); verificación de UI en vivo.

---

### Task 1: Settings — `OverlayAnchor` + `overlay_custom_positions`

**Files:**
- Modify: `src-tauri/src/settings.rs` (enum `OverlayPosition` ~línea 110; struct `AppSettings` ~línea 340; `get_default_settings()` ~línea 826; tests al final)

**Interfaces:**
- Produces: `pub struct OverlayAnchor { pub x_frac: f64, pub edge: OverlayPosition, pub edge_offset: f64 }` y `AppSettings.overlay_custom_positions: HashMap<String, OverlayAnchor>`. Task 2/3/4 los consumen desde `crate::settings`.

- [ ] **Step 1: Escribir tests que fallan** — al final de `src-tauri/src/settings.rs`, dentro del `mod tests` existente (`#[cfg(test)]`):

```rust
    #[test]
    fn overlay_custom_positions_defaults_to_empty_map() {
        // Un store viejo (sin la clave) debe deserializar con mapa vacío, no fallar.
        let settings: AppSettings = serde_json::from_value(serde_json::json!({
            "overlay_position": "bottom"
        }))
        .expect("store viejo sin overlay_custom_positions debe deserializar");
        assert!(settings.overlay_custom_positions.is_empty());
        assert!(get_default_settings().overlay_custom_positions.is_empty());
    }

    #[test]
    fn overlay_anchor_roundtrips_via_serde() {
        let mut settings = get_default_settings();
        settings.overlay_custom_positions.insert(
            "Built-in Retina Display".to_string(),
            OverlayAnchor {
                x_frac: 0.25,
                edge: OverlayPosition::Top,
                edge_offset: 120.0,
            },
        );
        let json = serde_json::to_value(&settings).expect("serialize");
        let back: AppSettings = serde_json::from_value(json).expect("deserialize");
        let anchor = &back.overlay_custom_positions["Built-in Retina Display"];
        assert_eq!(anchor.edge, OverlayPosition::Top);
        assert!((anchor.x_frac - 0.25).abs() < f64::EPSILON);
        assert!((anchor.edge_offset - 120.0).abs() < f64::EPSILON);
    }
```

- [ ] **Step 2: Verificar que fallan**

Run: `cd src-tauri && cargo test overlay_custom -- --nocapture`
Expected: FAIL de compilación — `overlay_custom_positions` / `OverlayAnchor` no existen.

- [ ] **Step 3: Implementación mínima**

Justo después del enum `OverlayStyle` (~línea 132) agregar:

```rust
/// Posición personalizada del overlay para un monitor, guardada al soltar un
/// arrastre. Se ancla al borde superior o inferior del monitor (no a una
/// esquina) para que la tarjeta no salte cuando la ventana cambia de tamaño
/// entre compacto y streaming.
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Type)]
pub struct OverlayAnchor {
    /// Centro horizontal de la ventana como fracción [0,1] del ancho del monitor.
    pub x_frac: f64,
    /// Borde del monitor al que está anclada (reutiliza Top/Bottom).
    pub edge: OverlayPosition,
    /// Puntos lógicos desde el borde `edge` del monitor al borde homólogo de la ventana.
    pub edge_offset: f64,
}
```

En `AppSettings`, inmediatamente después de `pub overlay_style: OverlayStyle,` (~línea 466):

```rust
    /// Posiciones arrastradas del overlay, por monitor (clave: nombre del
    /// monitor o fallback tamaño@posición). Vacío = usar el preset
    /// `overlay_position`. Se limpia desde el tray ("Restablecer posición")
    /// o al re-elegir Arriba/Abajo en Configuración.
    #[serde(default)]
    pub overlay_custom_positions: HashMap<String, OverlayAnchor>,
```

En `get_default_settings()` (~línea 935, junto a `overlay_style`):

```rust
        overlay_custom_positions: HashMap::new(),
```

`use std::collections::HashMap;` ya existe en settings.rs (lo usa `get_bindings`); si no está al tope del archivo, agregarlo.

- [ ] **Step 4: Verificar que pasan**

Run: `cd src-tauri && cargo test overlay_custom overlay_anchor`
Expected: 2 passed.

- [ ] **Step 5: Commit**

```bash
git add src-tauri/src/settings.rs
git commit -m "feat(overlay): ancla de posición personalizada por monitor en settings"
```

---

### Task 2: Geometría pura de anclas en overlay.rs (+tests)

**Files:**
- Modify: `src-tauri/src/overlay.rs` (nuevas fns puras + `mod tests` nuevo al final)

**Interfaces:**
- Consumes: `settings::{OverlayAnchor, OverlayPosition}` (Task 1).
- Produces (para Task 3/4):
  - `pub(crate) struct MonRect { pub x: f64, pub y: f64, pub w: f64, pub h: f64 }` (rect lógico de monitor)
  - `fn resolve_anchor_position(mon: &MonRect, anchor: &OverlayAnchor, w: f64, h: f64) -> (f64, f64)`
  - `fn anchor_from_drop(mon: &MonRect, x: f64, y: f64, w: f64, h: f64) -> OverlayAnchor`
  - `const OVERLAY_SHADOW_PAD: f64 = 12.0;`

- [ ] **Step 1: Tests que fallan** — al final de `overlay.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::{OverlayAnchor, OverlayPosition};

    const MON: MonRect = MonRect {
        x: 0.0,
        y: 0.0,
        w: 1440.0,
        h: 900.0,
    };

    #[test]
    fn drop_in_top_half_anchors_to_top_edge() {
        // Ventana de 280x70 soltada con su centro en y=200 (mitad superior).
        let a = anchor_from_drop(&MON, 300.0, 165.0, 280.0, 70.0);
        assert_eq!(a.edge, OverlayPosition::Top);
        assert!((a.edge_offset - 165.0).abs() < 0.5);
        // centro x = 300 + 140 = 440 → 440/1440
        assert!((a.x_frac - 440.0 / 1440.0).abs() < 1e-6);
    }

    #[test]
    fn drop_in_bottom_half_anchors_to_bottom_edge() {
        let a = anchor_from_drop(&MON, 300.0, 700.0, 280.0, 70.0);
        assert_eq!(a.edge, OverlayPosition::Bottom);
        // borde inferior ventana = 770 → offset = 900-770 = 130
        assert!((a.edge_offset - 130.0).abs() < 0.5);
    }

    #[test]
    fn resolve_roundtrips_the_drop_position_across_sizes() {
        // La misma ancla coloca el borde anclado en el mismo lugar aunque la
        // ventana cambie de alto (compacto 70 vs streaming 144).
        let a = anchor_from_drop(&MON, 300.0, 700.0, 280.0, 70.0);
        let (_, y_compact) = resolve_anchor_position(&MON, &a, 280.0, 70.0);
        let (_, y_stream) = resolve_anchor_position(&MON, &a, 424.0, 144.0);
        assert!((y_compact + 70.0 - (y_stream + 144.0)).abs() < 0.5); // mismo borde inferior
        assert!((y_compact - 700.0).abs() < 0.5);
    }

    #[test]
    fn resolve_clamps_offscreen_anchor_to_visible_area() {
        // Ancla corrupta / de otra resolución: la tarjeta (ventana menos el pad
        // de sombra) debe quedar dentro del monitor.
        let a = OverlayAnchor {
            x_frac: 1.4,
            edge: OverlayPosition::Bottom,
            edge_offset: 5000.0,
        };
        let (x, y) = resolve_anchor_position(&MON, &a, 280.0, 70.0);
        assert!(x + OVERLAY_SHADOW_PAD >= MON.x - 0.5);
        assert!(x + 280.0 - OVERLAY_SHADOW_PAD <= MON.x + MON.w + 0.5);
        assert!(y + OVERLAY_SHADOW_PAD >= MON.y - 0.5);
        assert!(y + 70.0 - OVERLAY_SHADOW_PAD <= MON.y + MON.h + 0.5);
    }
}
```

- [ ] **Step 2: Verificar que fallan**

Run: `cd src-tauri && cargo test overlay::tests`
Expected: FAIL de compilación — `MonRect`, `anchor_from_drop`, `resolve_anchor_position`, `OVERLAY_SHADOW_PAD` no existen.

- [ ] **Step 3: Implementación** — cerca de los consts de tamaño (~línea 47):

```rust
/// Padding (puntos lógicos) entre la tarjeta y el borde de la ventana, para
/// que la sombra CSS del vidrio no se recorte. Debe calzar con el
/// `padding: 12px` de `.ov-stage` en RecordingOverlay.css.
pub(crate) const OVERLAY_SHADOW_PAD: f64 = 12.0;

/// Rect lógico de un monitor (posición/tamaño divididos por scale factor).
#[derive(Debug, Clone, Copy)]
pub(crate) struct MonRect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl MonRect {
    fn from_monitor(monitor: &tauri::Monitor) -> Self {
        let scale = monitor.scale_factor();
        MonRect {
            x: monitor.position().x as f64 / scale,
            y: monitor.position().y as f64 / scale,
            w: monitor.size().width as f64 / scale,
            h: monitor.size().height as f64 / scale,
        }
    }
}

/// Clave estable para el mapa de posiciones custom. Nombre del monitor; si el
/// backend no lo entrega, tamaño@posición física como fallback.
fn monitor_key(monitor: &tauri::Monitor) -> String {
    match monitor.name() {
        Some(name) if !name.is_empty() => name.clone(),
        _ => format!(
            "{}x{}@{},{}",
            monitor.size().width,
            monitor.size().height,
            monitor.position().x,
            monitor.position().y
        ),
    }
}

/// La tarjeta (ventana inset OVERLAY_SHADOW_PAD) debe quedar completa dentro
/// del monitor; la ventana puede sobresalir hasta el pad (solo sombra afuera).
fn clamp_window_to_monitor(mon: &MonRect, x: f64, y: f64, w: f64, h: f64) -> (f64, f64) {
    let min_x = mon.x - OVERLAY_SHADOW_PAD;
    let max_x = (mon.x + mon.w) - w + OVERLAY_SHADOW_PAD;
    let min_y = mon.y - OVERLAY_SHADOW_PAD;
    let max_y = (mon.y + mon.h) - h + OVERLAY_SHADOW_PAD;
    (x.clamp(min_x, max_x.max(min_x)), y.clamp(min_y, max_y.max(min_y)))
}

/// Posición (lógica) de la ventana para un ancla guardada, clampeada.
fn resolve_anchor_position(
    mon: &MonRect,
    anchor: &crate::settings::OverlayAnchor,
    w: f64,
    h: f64,
) -> (f64, f64) {
    let x = mon.x + anchor.x_frac * mon.w - w / 2.0;
    let y = match anchor.edge {
        OverlayPosition::Top => mon.y + anchor.edge_offset,
        OverlayPosition::Bottom => mon.y + mon.h - anchor.edge_offset - h,
    };
    clamp_window_to_monitor(mon, x, y, w, h)
}

/// Ancla a partir de dónde quedó la ventana al soltar el arrastre. El borde se
/// decide por la mitad del monitor en que quedó el centro de la ventana.
fn anchor_from_drop(mon: &MonRect, x: f64, y: f64, w: f64, h: f64) -> crate::settings::OverlayAnchor {
    let cx = x + w / 2.0;
    let cy = y + h / 2.0;
    let edge = if cy < mon.y + mon.h / 2.0 {
        OverlayPosition::Top
    } else {
        OverlayPosition::Bottom
    };
    let edge_offset = match edge {
        OverlayPosition::Top => (y - mon.y).max(0.0),
        OverlayPosition::Bottom => ((mon.y + mon.h) - (y + h)).max(0.0),
    };
    crate::settings::OverlayAnchor {
        x_frac: ((cx - mon.x) / mon.w).clamp(0.0, 1.0),
        edge,
        edge_offset,
    }
}
```

- [ ] **Step 4: Verificar que pasan**

Run: `cd src-tauri && cargo test overlay::tests`
Expected: 4 passed. (Los helpers aún sin usar en runtime pueden dar warnings `dead_code`; se consumen en Task 3 — si clippy molesta, `#[allow(dead_code)]` temporal que Task 3 elimina.)

- [ ] **Step 5: Commit**

```bash
git add src-tauri/src/overlay.rs
git commit -m "feat(overlay): geometría pura de anclas por monitor con clamping"
```

---

### Task 3: Show path — resolver ancla→preset, edge en el payload, padding de ventana

**Files:**
- Modify: `src-tauri/src/overlay.rs` (consts de tamaño/offset, `calculate_overlay_position`, `show_overlay_state_on_main`, `update_overlay_position`, `PENDING_OVERLAY_STATE`)
- Modify: `src/overlay/RecordingOverlay.tsx` (listener `show-overlay`)
- Modify: `src/overlay/RecordingOverlay.css` (padding del stage)

**Interfaces:**
- Consumes: Task 1 (`overlay_custom_positions`), Task 2 (`MonRect`, `resolve_anchor_position`, `monitor_key`, `OVERLAY_SHADOW_PAD`).
- Produces: evento `show-overlay` con payload `{ state: string, edge: "top" | "bottom" }`; `calculate_overlay_position(app, w, h) -> Option<(f64, f64, OverlayPosition)>`. Task 4 reutiliza este show path intacto.

- [ ] **Step 1: Rust — tamaños y offsets con pad de sombra** (la ventana crece 24pt en ambas dimensiones; los offsets de pantalla se descuentan 12 para que la tarjeta quede exactamente donde hoy):

```rust
const OVERLAY_WIDTH: f64 = 280.0; // 256 + 2*OVERLAY_SHADOW_PAD
const OVERLAY_HEIGHT: f64 = 70.0; // 46 + 2*OVERLAY_SHADOW_PAD

const OVERLAY_STREAM_WIDTH: f64 = 424.0; // 400 + 24
const OVERLAY_STREAM_HEIGHT: f64 = 144.0; // 120 + 24
```

y los offsets (la tarjeta está inset 12 desde el borde de la ventana, así que restar el pad mantiene la distancia visual actual):

```rust
#[cfg(target_os = "macos")]
const OVERLAY_TOP_OFFSET: f64 = 34.0; // 46 visuales: 34 + pad 12
#[cfg(any(target_os = "windows", target_os = "linux"))]
const OVERLAY_TOP_OFFSET: f64 = -8.0; // 4 visuales: la ventana sobresale solo sombra

#[cfg(target_os = "macos")]
const OVERLAY_BOTTOM_OFFSET: f64 = 3.0; // 15 visuales

#[cfg(any(target_os = "windows", target_os = "linux"))]
const OVERLAY_BOTTOM_OFFSET: f64 = 28.0; // 40 visuales
```

Actualizar el comentario del bloque (las medidas CSS `--ov-*` + pad y la nota de sincronía).

- [ ] **Step 2: Rust — `calculate_overlay_position` devuelve también el edge y prioriza anclas:**

```rust
/// Posición lógica de la ventana + borde efectivo (para la dirección de
/// crecimiento del panel Live). Ancla custom del monitor si existe; si no,
/// el preset Arriba/Abajo.
fn calculate_overlay_position(
    app_handle: &AppHandle,
    width: f64,
    height: f64,
) -> Option<(f64, f64, OverlayPosition)> {
    let monitor = get_monitor_with_cursor(app_handle)?;
    let mon = MonRect::from_monitor(&monitor);
    if mon.w <= 0.0 || mon.h <= 0.0 {
        return None;
    }
    let settings = settings::get_settings(app_handle);

    if let Some(anchor) = settings.overlay_custom_positions.get(&monitor_key(&monitor)) {
        let (x, y) = resolve_anchor_position(&mon, anchor, width, height);
        return Some((x, y, anchor.edge));
    }

    let x = mon.x + (mon.w - width) / 2.0;
    let y = match settings.overlay_position {
        OverlayPosition::Top => mon.y + OVERLAY_TOP_OFFSET,
        OverlayPosition::Bottom => mon.y + mon.h - height - OVERLAY_BOTTOM_OFFSET,
    };
    Some((x, y, settings.overlay_position))
}
```

Ajustar los dos call sites: en `create_recording_overlay` (no-macOS, solo chequea `is_none()`) y el de macOS `if let Some((x, y)) = …` → `if let Some((x, y, _edge)) = …`. En `update_overlay_position`, igual: `if let Some((x, y, _edge)) = …`.

- [ ] **Step 3: Rust — payload con edge.** Reemplazar el `PENDING_OVERLAY_STATE` de `Option<String>` por el payload completo y emitirlo en ambos puntos:

```rust
#[derive(Clone, serde::Serialize)]
struct ShowOverlayPayload {
    state: String,
    edge: String, // "top" | "bottom"
}

static PENDING_OVERLAY_STATE: Mutex<Option<ShowOverlayPayload>> = Mutex::new(None);

fn set_pending_overlay_state(payload: Option<ShowOverlayPayload>) { /* igual que hoy, con el nuevo tipo */ }

fn emit_pending_overlay_state(window: &tauri::webview::WebviewWindow) {
    let payload = PENDING_OVERLAY_STATE.lock().ok().and_then(|mut p| p.take());
    if let Some(payload) = payload {
        let _ = window.emit("show-overlay", payload);
    }
}
```

En `show_overlay_state_on_main`: calcular `(x, y, edge)` UNA vez antes del get-or-create (guardando el resultado), construir `let payload = ShowOverlayPayload { state: state.to_string(), edge: match edge { OverlayPosition::Top => "top", OverlayPosition::Bottom => "bottom" }.to_string() };`, pasarlo a `set_pending_overlay_state(Some(payload.clone()))` y al `overlay_window.emit("show-overlay", payload)` final. Si `calculate_overlay_position` devuelve `None`, usar el preset de settings como edge (el window igual se muestra sin reposicionar, como hoy).

- [ ] **Step 4: Frontend — leer el edge del payload.** En `RecordingOverlay.tsx`, reemplazar el listener `show-overlay` (se elimina la lectura de `getAppSettings`; `syncLanguageFromSettings` se queda):

```tsx
      const unlistenShow = await listen<{ state: OverlayState; edge: "top" | "bottom" }>(
        "show-overlay",
        async (event) => {
          await syncLanguageFromSettings();
          setPosition(event.payload.edge);
          const overlayState = event.payload.state;
          setState(overlayState);
          if (overlayState === "recording" || overlayState === "streaming") {
            setStreamText({ committed: "", tentative: "" });
          }
          if (overlayState === "streaming") {
            setPhase("listening");
            setWorkKind("transcribing");
            setElapsed(0);
            setSession((s) => s + 1); // remount the card fresh for this session
          }
          setIsVisible(true);
        },
      );
```

El import de `commands` sigue siendo necesario (cancel + drag en Task 4).

- [ ] **Step 5: CSS — padding del stage.** En `RecordingOverlay.css`, `.ov-stage` gana el pad (y comentario de sincronía con `OVERLAY_SHADOW_PAD`):

```css
.ov-stage {
  position: fixed;
  inset: 0;
  /* Deja aire para la sombra del vidrio; debe calzar con OVERLAY_SHADOW_PAD
     (overlay.rs). La tarjeta queda inset 12px desde cada borde de la ventana. */
  padding: 12px;
  display: flex;
  justify-content: center;
  align-items: flex-end;
  font-family: var(--s-font);
}
```

- [ ] **Step 6: Compilar + smoke test**

Run: `cd src-tauri && cargo test overlay` (los tests de Task 2 siguen verdes) y luego `bun run tauri dev` unos segundos: grabar con el atajo → el pill aparece en el MISMO lugar visual que antes (offsets compensados), estados working y Live funcionan, top/bottom del setting respetados.
Expected: sin regresión visual de posición; consola sin errores del overlay.

- [ ] **Step 7: Commit**

```bash
git add src-tauri/src/overlay.rs src/overlay/RecordingOverlay.tsx src/overlay/RecordingOverlay.css
git commit -m "feat(overlay): show path resuelve anclas custom y publica el edge efectivo"
```

---

### Task 4: Arrastre — comando, persistencia al soltar, gesto en el frontend

**Files:**
- Modify: `src-tauri/src/overlay.rs` (flag de drag, `start_overlay_drag`, `on_overlay_moved`, persistencia)
- Modify: `src-tauri/src/lib.rs` (registro en `collect_commands!`, brazo `Moved` en `on_window_event`)
- Modify: `src/overlay/RecordingOverlay.tsx` (mousedown + umbral)
- Modify: `src/overlay/RecordingOverlay.css` (cursor)
- Regenerated: `src/bindings.ts` (tauri-specta, al correr en dev)

**Interfaces:**
- Consumes: Task 2 (`anchor_from_drop`, `monitor_key`, `MonRect`), Task 1 (mapa en settings).
- Produces: comando specta `start_overlay_drag` → `commands.startOverlayDrag()` en bindings; `pub fn on_overlay_moved(window: &tauri::Window)` llamado desde lib.rs; `pub(crate) fn cancel_pending_drag()` usado por el show path.

- [ ] **Step 1: Rust — estado de drag y persistencia en overlay.rs:**

```rust
// --- Arrastre del overlay ---
// El frontend invoca `start_overlay_drag` (tras un umbral de 4px); el OS mueve
// la ventana. Mientras el flag está activo, cada WindowEvent::Moved re-arma un
// debounce; cuando el movimiento cesa ~500ms se persiste la posición final
// como ancla del monitor donde quedó el centro de la ventana. Un show
// programático cancela cualquier drag pendiente (sus set_position no deben
// persistirse como si fueran del usuario).
static OVERLAY_DRAGGING: AtomicBool = AtomicBool::new(false);
static OVERLAY_MOVE_SEQ: AtomicU64 = AtomicU64::new(0);
const DRAG_SETTLE_MS: u64 = 500;

pub(crate) fn cancel_pending_drag() {
    OVERLAY_DRAGGING.store(false, Ordering::Relaxed);
    OVERLAY_MOVE_SEQ.fetch_add(1, Ordering::Relaxed);
}

/// Inicia el arrastre nativo del overlay. Invocado desde el webview del
/// overlay con el mouse presionado (requisito de `start_dragging`).
#[tauri::command]
#[specta::specta]
pub fn start_overlay_drag(app: AppHandle) {
    #[cfg(target_os = "linux")]
    if LAYER_SHELL_ACTIVE.load(Ordering::Relaxed) {
        return; // layer-shell ancla la ventana: no hay arrastre posible
    }
    if let Some(window) = app.get_webview_window("recording_overlay") {
        OVERLAY_DRAGGING.store(true, Ordering::Relaxed);
        if let Err(e) = window.start_dragging() {
            log::warn!("start_dragging del overlay falló: {}", e);
            cancel_pending_drag();
        }
    }
}

/// Handler de WindowEvent::Moved del overlay (ver on_window_event en lib.rs).
pub fn on_overlay_moved(app_handle: &AppHandle) {
    if !OVERLAY_DRAGGING.load(Ordering::Relaxed) {
        return; // movimiento programático (show/update), no del usuario
    }
    let seq = OVERLAY_MOVE_SEQ.fetch_add(1, Ordering::Relaxed) + 1;
    let app = app_handle.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_millis(DRAG_SETTLE_MS)).await;
        if OVERLAY_MOVE_SEQ.load(Ordering::Relaxed) != seq
            || !OVERLAY_DRAGGING.swap(false, Ordering::Relaxed)
        {
            return; // llegó otro Moved (sigue arrastrando) o un show lo canceló
        }
        persist_dropped_position(&app);
    });
}

/// Lee dónde quedó la ventana y guarda el ancla bajo el monitor que contiene
/// su centro. Si nada la contiene (soltada entre pantallas), no se guarda.
fn persist_dropped_position(app_handle: &AppHandle) {
    let Some(window) = app_handle.get_webview_window("recording_overlay") else {
        return;
    };
    let (Ok(pos), Ok(scale)) = (window.outer_position(), window.scale_factor()) else {
        return;
    };
    let Some((w, h)) = current_overlay_logical_size(&window) else {
        return;
    };
    let x = pos.x as f64 / scale;
    let y = pos.y as f64 / scale;
    let (cx, cy) = (x + w / 2.0, y + h / 2.0);

    let Ok(monitors) = app_handle.available_monitors() else {
        return;
    };
    for monitor in monitors {
        let mon = MonRect::from_monitor(&monitor);
        if mon.w <= 0.0 || mon.h <= 0.0 {
            continue;
        }
        if cx >= mon.x && cx < mon.x + mon.w && cy >= mon.y && cy < mon.y + mon.h {
            let anchor = anchor_from_drop(&mon, x, y, w, h);
            let mut settings = settings::get_settings(app_handle);
            settings
                .overlay_custom_positions
                .insert(monitor_key(&monitor), anchor);
            settings::write_settings(app_handle, settings);
            log::debug!("overlay drop persistido en '{}'", monitor_key(&monitor));
            return;
        }
    }
    log::debug!("overlay drop fuera de todo monitor; no se persiste");
}
```

Notas: `AtomicBool` ya está importado en overlay.rs; `LAYER_SHELL_ACTIVE` es un `static AtomicBool` nuevo `#[cfg(target_os = "linux")]` que `init_gtk_layer_shell` setea a `true` cuando retorna `true` (una línea antes del `return true;`). En `show_overlay_state_on_main`, llamar `cancel_pending_drag();` justo antes del bloque de `set_size`/`set_position`.

- [ ] **Step 2: lib.rs — registrar comando y evento Moved.** En `collect_commands![…]` agregar `overlay::start_overlay_drag,` (junto a los demás). En `.on_window_event(…)` agregar el brazo:

```rust
            tauri::WindowEvent::Moved(_) => {
                if window.label() == "recording_overlay" {
                    overlay::on_overlay_moved(window.app_handle());
                }
            }
```

(Confirmar el patrón exacto del closure existente: recibe `window` y `event`; `use` de `overlay` ya existe en lib.rs.)

- [ ] **Step 3: Frontend — gesto con umbral en RecordingOverlay.tsx:**

```tsx
  // Arrastre: toda la tarjeta es zona de agarre salvo los controles
  // interactivos (✕ y el scroll del texto Live). El drag nativo recién parte
  // cuando el press se movió >4px — un press quieto no hace nada.
  const DRAG_THRESHOLD_PX = 4;
  const handleDragMouseDown = (e: React.MouseEvent) => {
    if (e.button !== 0) return;
    if ((e.target as HTMLElement).closest(".sx, .stext-cap")) return;
    const startX = e.clientX;
    const startY = e.clientY;
    const onMove = (ev: MouseEvent) => {
      if (
        Math.hypot(ev.clientX - startX, ev.clientY - startY) >=
        DRAG_THRESHOLD_PX
      ) {
        cleanup();
        void commands.startOverlayDrag();
      }
    };
    const cleanup = () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", cleanup);
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", cleanup);
  };
```

Agregar `onMouseDown={handleDragMouseDown}` a los DOS `.scard` (el del branch streaming y el compacto).

- [ ] **Step 4: CSS — cursor de agarre.** En `.scard` agregar `cursor: grab;` y tras el bloque `.sx:active` existente:

```css
.stext-cap {
  cursor: auto; /* el texto Live scrollea, no agarra */
}
```

(Nota: `.stext-cap` ya tiene un bloque de reglas — agregar `cursor: auto;` ahí en vez de duplicar el selector.)

- [ ] **Step 5: Regenerar bindings + probar en vivo**

Run: `bun run tauri dev` (tauri-specta regenera `src/bindings.ts` en debug; verificar con `grep startOverlayDrag src/bindings.ts`).
Probar: grabar → arrastrar la pastilla desde cualquier zona (no ✕) → se mueve fluida; soltar → en `~/Library/Application Support/[bundle]/settings_store.json` (o vía logs debug) aparece `overlay_custom_positions` con el monitor; cerrar y reabrir la app → graba de nuevo → aparece donde quedó; la ✕ sigue cancelando con clic.
Expected: todo lo anterior; el clic simple (sin mover >4px) no arrastra.

- [ ] **Step 6: Commit**

```bash
git add src-tauri/src/overlay.rs src-tauri/src/lib.rs src/overlay/RecordingOverlay.tsx src/overlay/RecordingOverlay.css src/bindings.ts
git commit -m "feat(overlay): arrastre nativo con persistencia de ancla al soltar"
```

---

### Task 5: Reset — tray + re-elección del preset + i18n

**Files:**
- Modify: `src-tauri/src/overlay.rs` (`clear_custom_overlay_positions`)
- Modify: `src-tauri/src/shortcut/mod.rs` (`change_overlay_position_setting` ~línea 575)
- Modify: `src-tauri/src/tray.rs` (ítem de menú) y `src-tauri/src/lib.rs` (handler)
- Modify: `src/i18n/locales/*/translation.json` — los 22 locales (build.rs genera `""` para claves faltantes → ítem vacío, por eso van todos)

**Interfaces:**
- Consumes: Task 1 (mapa), overlay::update_overlay_position existente.
- Produces: `pub fn clear_custom_overlay_positions(app: &AppHandle)` en overlay.rs; clave i18n `tray.resetOverlayPosition` → campo generado `strings.reset_overlay_position`.

- [ ] **Step 1: overlay.rs — limpiar y reposicionar:**

```rust
/// Borra las posiciones arrastradas de todas las pantallas; el overlay vuelve
/// al preset Arriba/Abajo. Lo llaman el tray y el cambio del setting de
/// posición ("re-elegir Abajo" también resetea).
pub fn clear_custom_overlay_positions(app_handle: &AppHandle) {
    let mut settings = settings::get_settings(app_handle);
    if settings.overlay_custom_positions.is_empty() {
        return;
    }
    settings.overlay_custom_positions.clear();
    settings::write_settings(app_handle, settings);
    update_overlay_position(app_handle);
}
```

- [ ] **Step 2: shortcut/mod.rs — el preset siempre limpia.** En `change_overlay_position_setting`, después de `settings.overlay_position = parsed;` agregar:

```rust
    // Elegir un preset (aunque sea el mismo valor) descarta las posiciones
    // arrastradas: es el gesto natural de "resetear" desde Configuración.
    settings.overlay_custom_positions.clear();
```

- [ ] **Step 3: i18n — clave `tray.resetOverlayPosition` en los 22 locales.** en y es son autorales; el resto traducción razonable:

| locale | valor |
|---|---|
| en | `"Reset Overlay Position"` |
| es | `"Restablecer posición del overlay"` |
| ar | `"إعادة تعيين موضع الشريط"` |
| bg | `"Нулиране на позицията на индикатора"` |
| cs | `"Obnovit pozici overlaye"` |
| de | `"Overlay-Position zurücksetzen"` |
| fr | `"Réinitialiser la position de l'overlay"` |
| he | `"איפוס מיקום השכבה"` |
| it | `"Ripristina posizione overlay"` |
| ja | `"オーバーレイ位置をリセット"` |
| ko | `"오버레이 위치 초기화"` |
| ne | `"ओभरले स्थिति रिसेट गर्नुहोस्"` |
| nl | `"Overlaypositie herstellen"` |
| pl | `"Zresetuj pozycję nakładki"` |
| pt | `"Redefinir posição do overlay"` |
| ru | `"Сбросить позицию оверлея"` |
| sv | `"Återställ overlayens position"` |
| tr | `"Kaplama konumunu sıfırla"` |
| uk | `"Скинути позицію оверлея"` |
| vi | `"Đặt lại vị trí lớp phủ"` |
| zh | `"重置悬浮窗位置"` |
| zh-TW | `"重設懸浮窗位置"` |

Agregar la clave dentro del objeto `"tray"` de cada `src/i18n/locales/<loc>/translation.json`, junto a `"copyLastTranscript"`.

- [ ] **Step 4: tray.rs — ítem del menú.** Tras la creación de `copy_last_transcript_i` (~línea 203):

```rust
    let reset_overlay_i = MenuItem::with_id(
        app,
        "reset_overlay_position",
        &strings.reset_overlay_position,
        true,
        None::<&str>,
    )
    .expect("failed to create reset overlay position item");
```

Insertarlo en AMBOS menús (recording/transcribing e idle), justo después de `&copy_last_transcript_i,`:

```rust
                    &copy_last_transcript_i,
                    &reset_overlay_i,
```

- [ ] **Step 5: lib.rs — handler del tray.** En `on_menu_event`, junto a `"copy_last_transcript"`:

```rust
            "reset_overlay_position" => {
                overlay::clear_custom_overlay_positions(app);
            }
```

- [ ] **Step 6: Probar**

Run: `cd src-tauri && cargo build` (build.rs regenera tray_translations; debe compilar con el campo nuevo). Luego `bun run tauri dev`: arrastrar la pastilla → tray → "Restablecer posición del overlay" → siguiente grabación aparece en el preset. Repetir arrastre → Configuración → re-elegir "Abajo" → también resetea.
Expected: ambos caminos de reset funcionan; menú del tray muestra el texto es/en según idioma del sistema.

- [ ] **Step 7: Commit**

```bash
git add src-tauri/src/overlay.rs src-tauri/src/shortcut/mod.rs src-tauri/src/tray.rs src-tauri/src/lib.rs src/i18n/locales
git commit -m "feat(overlay): restablecer posición desde el tray y al re-elegir preset"
```

---

### Task 6: Restyle — vidrio + ondas brasa

**Files:**
- Modify: `src/overlay/RecordingOverlay.css` (tokens y reglas)
- Modify: `src/overlay/RecordingOverlay.tsx` (quitar `.sdot`)

**Interfaces:**
- Consumes: tokens de `theme.css` (`--color-background`, `--color-text`, `--color-logo-primary`) y `brand.css` (`--dilo-mango`, `--dilo-rojo`).
- Produces: solo cambios visuales; ninguna API.

- [ ] **Step 1: TSX — eliminar el punto rojo.** En `listeningRow`, quitar `<span className="sdot" />` dejando la zona izquierda vacía (equilibra la grilla de 3 columnas):

```tsx
  const listeningRow = (showTimer: boolean, showCancel: boolean) => (
    <div className="sbase">
      <div className="sbase-l" />
      {waveform}
      <div className="sbase-r">
        {showTimer && <span className="stimer">{fmtTime(elapsed)}</span>}
        {showCancel && cancelBtn}
      </div>
    </div>
  );
```

- [ ] **Step 2: CSS — reemplazar el bloque de tokens `:root` completo por:**

```css
:root {
  --s-font:
    "Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  /* Vidrio simulado: tinte del fondo del tema, translúcido. (backdrop-filter
     no puede muestrear el escritorio tras una ventana transparente de Tauri,
     así que no hay blur real; el vidrio lo venden tinte + hairline +
     highlight + sombra.) El panel Live usa un tinte más opaco para que el
     transcript se lea sobre fondos ruidosos. */
  --s-surface: color-mix(in srgb, var(--color-background) 72%, transparent);
  --s-surface-live: color-mix(in srgb, var(--color-background) 86%, transparent);
  /* Accent = brand mango; flips automatically via --color-logo-primary. */
  --s-accent: var(--color-logo-primary);
  --s-accent-soft: color-mix(
    in srgb,
    var(--color-background-ui) 16%,
    transparent
  );
  /* Ondas "brasa": gradiente mango→rojo con glow tenue solo en las barras
     (elección de diseño: la pastilla no brilla ni respira). */
  --s-wave-lo: var(--dilo-mango);
  --s-wave-hi: var(--dilo-rojo);
  --s-wave-glow: color-mix(in srgb, #ff7a3c 50%, transparent);
  /* Neutrales derivados del tema para leerse sobre vidrio en ambos modos. */
  --s-muted: color-mix(in srgb, var(--color-text) 62%, transparent);
  --s-faint: color-mix(in srgb, var(--color-text) 45%, transparent);
  --s-border: color-mix(in srgb, var(--color-text) 20%, transparent);
  --s-hair: color-mix(in srgb, var(--color-text) 10%, transparent);
  --s-highlight: color-mix(in srgb, #ffffff 32%, transparent);
  --s-shadow: 0 8px 28px rgba(0, 0, 0, 0.35);

  /* Card geometry — single source of truth for the visible overlay sizes. The
     native overlay window (overlay.rs) is sized from these PLUS the shadow pad
     (12px per side = .ov-stage padding = OVERLAY_SHADOW_PAD). Keep overlay.rs
     in sync when these change. */
  --ov-rest-w: 172px;
  --ov-pill-w: 184px;
  --ov-work-w: 216px;
  --ov-open-w: 392px;
  --ov-base-h: 40px;
  --ov-cap-max-h: 64px;
}
@media (prefers-color-scheme: dark) {
  :root {
    --s-accent-soft: color-mix(
      in srgb,
      var(--color-logo-primary) 20%,
      transparent
    );
    /* En dark el highlight superior baja para no verse plateado. */
    --s-highlight: color-mix(in srgb, #ffffff 14%, transparent);
    --s-shadow: 0 8px 28px rgba(0, 0, 0, 0.55);
  }
}
```

(Se eliminan `--s-rec`/`--s-rec-soft` y los grises fijos `#6e6e6e`/`#9a9a9a`/dark; todo neutral deriva de `--color-text`.)

- [ ] **Step 3: CSS — tarjeta de vidrio.** En `.scard`, reemplazar fondo/borde planos y sumar sombra + highlight + cursor (la transición gana `background`):

```css
.scard {
  width: var(--ov-pill-w);
  border-radius: 24px;
  overflow: hidden;
  display: flex;
  flex-direction: column;
  flex: none;
  transform-origin: bottom center;
  cursor: grab;
  background: var(--s-surface);
  border: 1px solid var(--s-border);
  box-shadow:
    var(--s-shadow),
    inset 0 1px 0 var(--s-highlight);
  animation: scard-pop 460ms cubic-bezier(0.22, 1, 0.36, 1);
  transition:
    width 460ms cubic-bezier(0.22, 1, 0.36, 1),
    border-radius 460ms cubic-bezier(0.22, 1, 0.36, 1),
    background 300ms ease;
  will-change: transform, width, opacity;
}
```

y el panel abierto más opaco:

```css
.scard.open {
  width: var(--ov-open-w);
  border-radius: 16px;
  background: var(--s-surface-live);
}
```

- [ ] **Step 4: CSS — ondas brasa y limpieza del dot.** Eliminar los bloques `.sdot` y `@keyframes sdot-pulse` completos. Reemplazar `.swave i`:

```css
.swave i {
  width: 4px;
  min-height: 3px;
  max-height: 18px;
  border-radius: 2px;
  background: linear-gradient(to top, var(--s-wave-lo), var(--s-wave-hi));
  box-shadow: 0 0 7px var(--s-wave-glow);
  transition: height 80ms linear;
}
```

- [ ] **Step 5: CSS — ajustes menores coherentes.** `.stext-cap` agrega `cursor: auto;` (si no quedó de Task 4). El caret y spinner ya usan `--s-accent` (mango) — sin cambios. Verificar que nada más refiere `--s-rec`:

Run: `grep -n "s-rec" src/overlay/RecordingOverlay.css`
Expected: sin resultados.

- [ ] **Step 6: Probar en vivo (claro y oscuro)**

Run: `bun run tauri dev` → grabar sobre fondo claro y oscuro, y con el sistema en tema claro y oscuro (System Settings → Appearance): pastilla translúcida legible, ondas gradiente con glow, sin punto rojo; estados transcribiendo/puliendo y panel Live coherentes; transcript legible en el panel.
Expected: los 4 estados se ven según el spec; timer/✕ legibles en ambos temas.

- [ ] **Step 7: Commit**

```bash
git add src/overlay/RecordingOverlay.css src/overlay/RecordingOverlay.tsx
git commit -m "style(overlay): vidrio con ondas mango→rojo, adiós punto rojo"
```

---

### Task 7: Verificación integral y cierre

**Files:**
- Modify (si algo falla): los de las tasks anteriores.
- Modify: `docs/superpowers/specs/2026-07-17-overlay-vidrio-arrastrable-design.md` (nota de la desviación del vidrio simulado)

- [ ] **Step 1: Suites y linters**

Run:
```bash
cd src-tauri && cargo test && cargo clippy -- -D warnings && cd ..
bun run lint && bun run format:check && bun run build
```
Expected: todo verde (si `format:check` acusa, correr `bun run format` y re-chequear).

- [ ] **Step 2: Los 7 chequeos del spec, en vivo** (`bun run tauri dev`):

1. Estilo nuevo en los 4 estados, tema claro y oscuro, fondo claro y oscuro.
2. Arrastrar en cada estado; ✕ cancela con clic; scroll del Live intacto.
3. Arrastrar → cerrar app → reabrir → dictar → aparece donde quedó.
4. Con 2 pantallas: posición distinta por pantalla; respeta la del cursor.
5. Reset desde tray y re-elección de Arriba/Abajo → vuelve al preset.
6. Ancla cerca del borde + cambiar resolución (o simular con un ancla editada fuera de rango en el settings store) → aparece clampeada.
7. Arrastrar mientras se dicta en un editor → el foco no se pierde (el texto sigue entrando).

Expected: los 7 pasan; anotar cualquier desvío y corregir antes de cerrar.

- [ ] **Step 3: Actualizar el spec con la desviación aprobada del vidrio**

En la sección Visual del spec, reemplazar la línea del `backdrop-filter` por la realidad implementada (vidrio simulado, tintes 72%/86%, motivo técnico), marcando que fue la desviación acordada en el plan.

- [ ] **Step 4: Commit final**

```bash
git add -A
git commit -m "docs(specs): overlay de vidrio — nota de vidrio simulado (sin backdrop-filter)"
```

## Self-review del plan

- **Cobertura del spec:** visual (Task 6), arrastre + umbral + foco (Task 4), persistencia/ancla/multi-monitor (Tasks 1–4), reset tray + preset (Task 5), edge del panel Live (Task 3), clamping y bordes (Task 2), Linux layer-shell (Task 4 guard), verificación (Task 7). Desviación del blur documentada en Global Constraints y cerrada en Task 7.
- **Placeholders:** ninguno; todo paso con código lo trae completo.
- **Consistencia de tipos:** `OverlayAnchor {x_frac, edge, edge_offset}` idéntico en Tasks 1/2/4; `calculate_overlay_position → (f64, f64, OverlayPosition)` usado igual en Task 3; `startOverlayDrag` = camelCase specta de `start_overlay_drag`.
