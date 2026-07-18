use crate::input;
use crate::settings;
use crate::settings::{OverlayPosition, OverlayStyle};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize};

#[cfg(not(target_os = "macos"))]
use log::debug;

#[cfg(not(target_os = "macos"))]
use tauri::WebviewWindowBuilder;

#[cfg(target_os = "macos")]
use tauri::WebviewUrl;

#[cfg(target_os = "macos")]
use tauri_nspanel::{tauri_panel, CollectionBehavior, PanelBuilder, PanelLevel, StyleMask};

#[cfg(target_os = "linux")]
use gtk_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};

#[cfg(target_os = "linux")]
use std::env;

#[cfg(target_os = "macos")]
tauri_panel! {
    panel!(RecordingOverlayPanel {
        config: {
            can_become_key_window: false,
            is_floating_panel: true
        }
    })
}

// Native overlay window sizes (logical points). One window is reused for every
// state and resized in `show_overlay_state`; each size need only be at least as
// large as the card it hosts (the `--ov-*` vars in RecordingOverlay.css). The
// card is CSS-anchored flush to the screen edge, so window height doesn't move
// where the card sits — only OVERLAY_TOP_OFFSET / OVERLAY_BOTTOM_OFFSET do. Keep
// these in sync with the CSS card geometry.
//
// Compact overlay (Minimal / transcribing / processing): the 40h pill animates
// width from 172 (--ov-rest-w) to 216 (--ov-work-w) and expands from center, so
// the window must fit the widest state plus a little slack — PLUS the shadow
// pad on every side (`.ov-stage` padding = OVERLAY_SHADOW_PAD), which keeps the
// CSS drop shadow of the glass card from clipping at the window edge.
const OVERLAY_WIDTH: f64 = 256.0 + 2.0 * OVERLAY_SHADOW_PAD;
const OVERLAY_HEIGHT: f64 = 46.0 + 2.0 * OVERLAY_SHADOW_PAD;

// Actual is 394x118, just a little extra (+ shadow pad per side)
const OVERLAY_STREAM_WIDTH: f64 = 400.0 + 2.0 * OVERLAY_SHADOW_PAD;
const OVERLAY_STREAM_HEIGHT: f64 = 120.0 + 2.0 * OVERLAY_SHADOW_PAD;

/// Overlay window size (logical) for a given UI state.
fn overlay_dimensions(state: &str) -> (f64, f64) {
    if state == "streaming" {
        (OVERLAY_STREAM_WIDTH, OVERLAY_STREAM_HEIGHT)
    } else {
        (OVERLAY_WIDTH, OVERLAY_HEIGHT)
    }
}

static LAST_MIC_LEVEL_EMIT: AtomicU64 = AtomicU64::new(0);
const EMIT_THROTTLE_MS: u64 = 33; // ~30 FPS

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

// Lazy-overlay lifecycle: the window is created on first show and only HIDDEN
// afterwards, never destroyed. A resting app that hasn't dictated yet keeps no
// overlay webview alive; after first use the hidden webview stays (~40 MB).
//
// Destroying is deliberately off the table: `WebviewWindow::destroy()` on a
// window converted to NSPanel over-releases it (double-free between
// tauri-nspanel's retained handle and tao's close path) and aborts on a later
// autorelease-pool drain — crash seconds after the destroy, on the main
// thread's run-loop observer. Upstream never destroys its overlay for the
// same reason. Every show bumps the generation; the pending 300 ms hide (for
// the fade-out) only fires if its captured generation is still current.
static OVERLAY_GENERATION: AtomicU64 = AtomicU64::new(0);

// Page-load handshake for the lazily-created webview: the show that creates the
// window runs before the overlay page has registered its event listeners, so a
// plain `show-overlay` emit would be lost. The show path queues the payload here
// and `on_page_load` re-emits it once the page can hear it.
#[derive(Clone, serde::Serialize)]
struct ShowOverlayPayload {
    state: String,
    /// "top" | "bottom" — effective edge (anchor or preset); the webview flips
    /// the card's CSS anchoring and the Live panel's growth direction with it.
    edge: String,
}

impl ShowOverlayPayload {
    fn new(state: &str, edge: OverlayPosition) -> Self {
        ShowOverlayPayload {
            state: state.to_string(),
            edge: match edge {
                OverlayPosition::Top => "top",
                OverlayPosition::Bottom => "bottom",
            }
            .to_string(),
        }
    }
}

static PENDING_OVERLAY_STATE: Mutex<Option<ShowOverlayPayload>> = Mutex::new(None);

fn set_pending_overlay_state(payload: Option<ShowOverlayPayload>) {
    if let Ok(mut pending) = PENDING_OVERLAY_STATE.lock() {
        *pending = payload;
    }
}

fn emit_pending_overlay_state(window: &tauri::webview::WebviewWindow) {
    let payload = PENDING_OVERLAY_STATE
        .lock()
        .ok()
        .and_then(|mut pending| pending.take());
    if let Some(payload) = payload {
        let _ = window.emit("show-overlay", payload);
    }
}

// Screen-edge offsets apply to the WINDOW edge; the visible card sits inset
// OVERLAY_SHADOW_PAD from it, so each offset is the historical visual distance
// minus the pad (negative = only the shadow region hangs past the screen edge).
#[cfg(target_os = "macos")]
const OVERLAY_TOP_OFFSET: f64 = 34.0; // 46 visuales: 34 + pad 12
#[cfg(any(target_os = "windows", target_os = "linux"))]
const OVERLAY_TOP_OFFSET: f64 = -8.0; // 4 visuales: la ventana sobresale solo sombra

#[cfg(target_os = "macos")]
const OVERLAY_BOTTOM_OFFSET: f64 = 3.0; // 15 visuales

#[cfg(any(target_os = "windows", target_os = "linux"))]
const OVERLAY_BOTTOM_OFFSET: f64 = 28.0; // 40 visuales

#[cfg(target_os = "linux")]
fn update_gtk_layer_shell_anchors(overlay_window: &tauri::webview::WebviewWindow) {
    let window_clone = overlay_window.clone();
    let _ = overlay_window.run_on_main_thread(move || {
        // Try to get the GTK window from the Tauri webview
        if let Ok(gtk_window) = window_clone.gtk_window() {
            let settings = settings::get_settings(window_clone.app_handle());
            match settings.overlay_position {
                OverlayPosition::Top => {
                    gtk_window.set_anchor(Edge::Top, true);
                    gtk_window.set_anchor(Edge::Bottom, false);
                }
                OverlayPosition::Bottom => {
                    gtk_window.set_anchor(Edge::Bottom, true);
                    gtk_window.set_anchor(Edge::Top, false);
                }
            }
        }
    });
}

/// Returns true when the environment variable is set to a truthy value
/// (e.g. "1", "true", "yes", "on").
/// "0", "false", "no", "off" and empty string are treated as falsy (case-insensitive).
/// Returns false when the variable is not set.
#[cfg(target_os = "linux")]
fn env_flag_enabled(name: &str) -> bool {
    match env::var(name) {
        Ok(v) => !matches!(
            v.trim().to_ascii_lowercase().as_str(),
            "" | "0" | "false" | "no" | "off"
        ),
        Err(_) => false,
    }
}

/// Initializes GTK layer shell for Linux overlay window
/// Returns true if layer shell was successfully initialized, false otherwise
#[cfg(target_os = "linux")]
fn init_gtk_layer_shell(overlay_window: &tauri::webview::WebviewWindow) -> bool {
    // DILO_NO_GTK_LAYER_SHELL is the current name; HANDY_NO_GTK_LAYER_SHELL is
    // accepted for back-compat with configs carried over from upstream.
    if env_flag_enabled("DILO_NO_GTK_LAYER_SHELL") || env_flag_enabled("HANDY_NO_GTK_LAYER_SHELL") {
        debug!("Skipping GTK layer shell init (DILO_NO_GTK_LAYER_SHELL is enabled)");
        return false;
    }

    if !gtk_layer_shell::is_supported() {
        return false;
    }

    // Try to get the GTK window from the Tauri webview
    if let Ok(gtk_window) = overlay_window.gtk_window() {
        // Initialize layer shell
        gtk_window.init_layer_shell();
        gtk_window.set_layer(Layer::Overlay);
        gtk_window.set_keyboard_mode(KeyboardMode::None);
        gtk_window.set_exclusive_zone(0);

        update_gtk_layer_shell_anchors(overlay_window);

        return true;
    }
    false
}

/// Forces a window to be topmost using Win32 API (Windows only)
/// This is more reliable than Tauri's set_always_on_top which can be overridden
#[cfg(target_os = "windows")]
fn force_overlay_topmost(overlay_window: &tauri::webview::WebviewWindow) {
    use windows::Win32::UI::WindowsAndMessaging::{
        SetWindowPos, HWND_TOPMOST, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SWP_SHOWWINDOW,
    };

    // Clone because run_on_main_thread takes 'static
    let overlay_clone = overlay_window.clone();

    // Make sure the Win32 call happens on the UI thread
    let _ = overlay_clone.clone().run_on_main_thread(move || {
        if let Ok(hwnd) = overlay_clone.hwnd() {
            unsafe {
                // Force Z-order: make this window topmost without changing size/pos or stealing focus
                let _ = SetWindowPos(
                    hwnd,
                    Some(HWND_TOPMOST),
                    0,
                    0,
                    0,
                    0,
                    SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW,
                );
            }
        }
    });
}

fn get_monitor_with_cursor(app_handle: &AppHandle) -> Option<tauri::Monitor> {
    if let Some(mouse_location) = input::get_cursor_position(app_handle) {
        if let Ok(monitors) = app_handle.available_monitors() {
            for monitor in monitors {
                // Tauri's monitor position/size are physical pixels, but enigo
                // may return logical coordinates (confirmed on macOS via
                // NSEvent::mouseLocation; on Windows, GetCursorPos behavior
                // depends on the process DPI-awareness context). Dividing by
                // scale_factor normalizes to logical, which is safe regardless:
                // if enigo returns logical it matches directly, and if it returns
                // physical on a scale=1 monitor the division is a no-op.
                let scale = monitor.scale_factor();
                let pos = PhysicalPosition::new(
                    (monitor.position().x as f64 / scale) as i32,
                    (monitor.position().y as f64 / scale) as i32,
                );
                let size = PhysicalSize::new(
                    (monitor.size().width as f64 / scale) as u32,
                    (monitor.size().height as f64 / scale) as u32,
                );
                if is_mouse_within_monitor(mouse_location, &pos, &size) {
                    return Some(monitor);
                }
            }
        }
    }

    app_handle.primary_monitor().ok().flatten()
}

fn is_mouse_within_monitor(
    mouse_pos: (i32, i32),
    monitor_pos: &PhysicalPosition<i32>,
    monitor_size: &PhysicalSize<u32>,
) -> bool {
    let (mouse_x, mouse_y) = mouse_pos;
    let PhysicalPosition {
        x: monitor_x,
        y: monitor_y,
    } = *monitor_pos;
    let PhysicalSize {
        width: monitor_width,
        height: monitor_height,
    } = *monitor_size;

    mouse_x >= monitor_x
        && mouse_x < (monitor_x + monitor_width as i32)
        && mouse_y >= monitor_y
        && mouse_y < (monitor_y + monitor_height as i32)
}

/// Returns overlay position in logical coordinates (points on macOS), plus the
/// effective edge (drives the Live panel's growth direction in the webview).
///
/// Uses monitor position/size directly rather than work_area(), which can
/// return incorrect coordinates on macOS for monitors with negative positions.
/// The per-platform OVERLAY_TOP_OFFSET / OVERLAY_BOTTOM_OFFSET constants
/// already account for system chrome (menu bar, taskbar).
///
/// We must use LogicalPosition (not PhysicalPosition) because Tauri/tao
/// converts PhysicalPosition using the scale factor of the monitor the window
/// is *currently* on, which is wrong when moving cross-monitor.
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

    let x = mon.x + (mon.w - width) / 2.0;
    let y = match settings.overlay_position {
        OverlayPosition::Top => mon.y + OVERLAY_TOP_OFFSET,
        OverlayPosition::Bottom => mon.y + mon.h - height - OVERLAY_BOTTOM_OFFSET,
    };

    Some((x, y, settings.overlay_position))
}

/// Current overlay window size in logical units (points), for repositioning
/// without assuming a fixed size (compact vs. streaming).
fn current_overlay_logical_size(window: &tauri::webview::WebviewWindow) -> Option<(f64, f64)> {
    let size = window.inner_size().ok()?;
    let scale = window.scale_factor().ok()?;
    Some((size.width as f64 / scale, size.height as f64 / scale))
}

/// Creates the recording overlay window, hidden. Called lazily from
/// `show_overlay_state`; afterwards it is only hidden, never destroyed
/// (see the lifecycle note by `OVERLAY_GENERATION`).
#[cfg(not(target_os = "macos"))]
fn create_recording_overlay(app_handle: &AppHandle) {
    // On Linux (Wayland), monitor detection often fails, but we don't need exact coordinates
    // for Layer Shell as we use anchors. On other platforms, we require a monitor.
    #[cfg(not(target_os = "linux"))]
    {
        let position = calculate_overlay_position(app_handle, OVERLAY_WIDTH, OVERLAY_HEIGHT);
        if position.is_none() {
            debug!("Failed to determine overlay position, not creating overlay window");
            return;
        }
    }

    // Position starts unset — update_overlay_position() sets the correct
    // LogicalPosition before the overlay is shown.
    let mut builder = WebviewWindowBuilder::new(
        app_handle,
        "recording_overlay",
        tauri::WebviewUrl::App("src/overlay/index.html".into()),
    )
    .title("Recording")
    .resizable(false)
    .inner_size(OVERLAY_WIDTH, OVERLAY_HEIGHT)
    .shadow(false)
    .maximizable(false)
    .minimizable(false)
    .closable(false)
    .accept_first_mouse(true)
    .decorations(false)
    .always_on_top(true)
    .skip_taskbar(true)
    .transparent(true)
    .focusable(false)
    .focused(false)
    .visible(false)
    .on_page_load(|window, payload| {
        if matches!(payload.event(), tauri::webview::PageLoadEvent::Finished) {
            emit_pending_overlay_state(&window);
        }
    });

    if let Some(data_dir) = crate::portable::data_dir() {
        builder = builder.data_directory(data_dir.join("webview"));
    }

    #[allow(unused_variables)]
    match builder.build() {
        Ok(window) => {
            #[cfg(target_os = "linux")]
            {
                // Try to initialize GTK layer shell, ignore errors if compositor doesn't support it
                if init_gtk_layer_shell(&window) {
                    debug!("GTK layer shell initialized for overlay window");
                } else {
                    debug!("GTK layer shell not available, falling back to regular window");
                }
            }

            debug!("Recording overlay window created successfully (hidden)");
        }
        Err(e) => {
            debug!("Failed to create recording overlay window: {}", e);
        }
    }
}

/// Creates the recording overlay panel, hidden (macOS). Called lazily from
/// `show_overlay_state`; afterwards it is only hidden, never destroyed
/// (see the lifecycle note by `OVERLAY_GENERATION`).
#[cfg(target_os = "macos")]
fn create_recording_overlay(app_handle: &AppHandle) {
    if let Some((x, y, _edge)) =
        calculate_overlay_position(app_handle, OVERLAY_WIDTH, OVERLAY_HEIGHT)
    {
        // PanelBuilder creates a Tauri window then converts it to NSPanel.
        // The window remains registered, so get_webview_window() still works.
        match PanelBuilder::<_, RecordingOverlayPanel>::new(app_handle, "recording_overlay")
            .url(WebviewUrl::App("src/overlay/index.html".into()))
            .title("Recording")
            .position(tauri::Position::Logical(tauri::LogicalPosition { x, y }))
            .level(PanelLevel::Status)
            .size(tauri::Size::Logical(tauri::LogicalSize {
                width: OVERLAY_WIDTH,
                height: OVERLAY_HEIGHT,
            }))
            .has_shadow(false)
            .transparent(true)
            .no_activate(true)
            .corner_radius(0.0)
            .style_mask(StyleMask::empty().borderless().nonactivating_panel())
            .with_window(|w| {
                w.decorations(false)
                    .transparent(true)
                    .focusable(false)
                    .on_page_load(|window, payload| {
                        if matches!(payload.event(), tauri::webview::PageLoadEvent::Finished) {
                            emit_pending_overlay_state(&window);
                        }
                    })
            })
            .collection_behavior(
                CollectionBehavior::new()
                    .can_join_all_spaces()
                    .full_screen_auxiliary(),
            )
            .build()
        {
            Ok(panel) => {
                panel.hide();
            }
            Err(e) => {
                log::error!("Failed to create recording overlay panel: {}", e);
            }
        }
    }
}

fn show_overlay_state(app_handle: &AppHandle, state: &str) {
    // La creación del NSPanel (setFloatingPanel/setWindowLevel) y las llamadas
    // crudas de tauri-nspanel exigen el hilo principal de AppKit, pero este
    // show llega desde el hilo del atajo/transcripción — sin el marshal, macOS
    // aborta con SIGTRAP ("Must only be used from the main thread").
    let app = app_handle.clone();
    let state = state.to_string();
    let _ = app_handle.run_on_main_thread(move || show_overlay_state_on_main(&app, &state));
}

fn show_overlay_state_on_main(app_handle: &AppHandle, state: &str) {
    // Whether the overlay shows at all is governed by overlay_style; position
    // only chooses Top vs Bottom placement.
    let settings = settings::get_settings(app_handle);
    if settings.overlay_style == OverlayStyle::None {
        return;
    }

    // Invalidate any pending destroy timer from an earlier hide.
    OVERLAY_GENERATION.fetch_add(1, Ordering::Relaxed);

    // Size for this state (compact vs. streaming) and resolve where the window
    // goes — dragged anchor of the cursor's monitor, or the Top/Bottom preset —
    // plus the effective edge the webview needs for its layout direction.
    let (width, height) = overlay_dimensions(state);
    let position = calculate_overlay_position(app_handle, width, height);
    let edge = position
        .map(|(_, _, edge)| edge)
        .unwrap_or(settings.overlay_position);
    let payload = ShowOverlayPayload::new(state, edge);

    // Queue the payload for the page-load handshake: if the window below is
    // freshly created (or still loading), the direct emit at the end of this
    // function fires before the page's listeners exist and would be lost.
    set_pending_overlay_state(Some(payload.clone()));

    // Get-or-create: the overlay window only lives while recording (plus a
    // short idle period), so a resting app keeps no overlay webview alive.
    let overlay_window = match app_handle.get_webview_window("recording_overlay") {
        Some(window) => window,
        None => {
            create_recording_overlay(app_handle);
            match app_handle.get_webview_window("recording_overlay") {
                Some(window) => window,
                None => return,
            }
        }
    };

    #[cfg(target_os = "linux")]
    update_gtk_layer_shell_anchors(&overlay_window);

    let size_started = std::time::Instant::now();
    let _ = overlay_window.set_size(tauri::Size::Logical(tauri::LogicalSize { width, height }));
    let size_elapsed = size_started.elapsed();

    let pos_started = std::time::Instant::now();
    let mut set_pos_elapsed = std::time::Duration::ZERO;
    if let Some((x, y, _edge)) = position {
        let set_pos_started = std::time::Instant::now();
        let _ =
            overlay_window.set_position(tauri::Position::Logical(tauri::LogicalPosition { x, y }));
        set_pos_elapsed = set_pos_started.elapsed();
    }
    let pos_calc_elapsed = pos_started.elapsed() - set_pos_elapsed;

    let show_started = std::time::Instant::now();
    let _ = overlay_window.show();
    let show_elapsed = show_started.elapsed();

    // On Windows, aggressively re-assert "topmost" in the native Z-order after showing
    #[cfg(target_os = "windows")]
    force_overlay_topmost(&overlay_window);

    let _ = overlay_window.emit("show-overlay", payload);
    log::debug!(
        "overlay '{}': set_size={:?} pos_calc={:?} set_pos={:?} show={:?}",
        state,
        size_elapsed,
        pos_calc_elapsed,
        set_pos_elapsed,
        show_elapsed
    );
}

/// Shows the recording overlay window with fade-in animation
pub fn show_recording_overlay(app_handle: &AppHandle) {
    show_overlay_state(app_handle, "recording");
}

/// Shows the larger streaming overlay that displays live transcription text
pub fn show_streaming_overlay(app_handle: &AppHandle) {
    show_overlay_state(app_handle, "streaming");
}

/// Shows the transcribing overlay window
pub fn show_transcribing_overlay(app_handle: &AppHandle) {
    show_overlay_state(app_handle, "transcribing");
}

/// Shows the processing overlay window
pub fn show_processing_overlay(app_handle: &AppHandle) {
    show_overlay_state(app_handle, "processing");
}

/// Updates the overlay window position based on current settings
pub fn update_overlay_position(app_handle: &AppHandle) {
    if let Some(overlay_window) = app_handle.get_webview_window("recording_overlay") {
        #[cfg(target_os = "linux")]
        {
            update_gtk_layer_shell_anchors(&overlay_window);
        }

        // Use the window's current size so centering stays correct whether the
        // overlay is in compact or streaming layout.
        let (width, height) = current_overlay_logical_size(&overlay_window)
            .unwrap_or((OVERLAY_WIDTH, OVERLAY_HEIGHT));
        if let Some((x, y, _edge)) = calculate_overlay_position(app_handle, width, height) {
            let _ = overlay_window
                .set_position(tauri::Position::Logical(tauri::LogicalPosition { x, y }));
        }
    }
}

/// Hides the recording overlay window with a fade-out animation. The window
/// is kept (hidden) for reuse — destroying a panel-converted window aborts;
/// see the lifecycle note by `OVERLAY_GENERATION`.
pub fn hide_recording_overlay(app_handle: &AppHandle) {
    // Always hide the overlay regardless of settings - if setting was changed while recording,
    // we still want to hide it properly
    set_pending_overlay_state(None);
    if let Some(overlay_window) = app_handle.get_webview_window("recording_overlay") {
        // Emit event to trigger fade-out animation
        let _ = overlay_window.emit("hide-overlay", ());
        // Hide the window after a short delay to allow the animation to
        // complete, then destroy it once it has idled. Both steps abort if a
        // new show reclaimed the window (generation bumped) in the meantime.
        let generation = OVERLAY_GENERATION.load(Ordering::Relaxed);
        let window_clone = overlay_window.clone();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(Duration::from_millis(300)).await;
            if OVERLAY_GENERATION.load(Ordering::Relaxed) != generation {
                return;
            }
            // Solo esconder — ver la nota del ciclo de vida junto a
            // OVERLAY_GENERATION: destruir la ventana-panel sobre-libera el
            // NSPanel y aborta en un drain posterior del autorelease pool.
            let _ = window_clone.hide();
        });
    }
}

// Cached "overlay is enabled" flag, kept in sync with overlay_style. Avoids
// reading the Tauri store on every audio callback (~24 Hz during recording).
// Defaults to false so the audio path doesn't emit until lib.rs::setup
// populates the cache from initial settings.
static OVERLAY_ENABLED: AtomicBool = AtomicBool::new(false);

/// Update the cached overlay-enabled flag. Called from `lib.rs` at
/// startup after settings load, and from `change_overlay_style_setting`
/// whenever the user changes whether the overlay is shown.
pub fn update_overlay_enabled_cache(enabled: bool) {
    OVERLAY_ENABLED.store(enabled, Ordering::Relaxed);
}

pub fn emit_levels(app_handle: &AppHandle, levels: &[f32]) {
    // Skip emission when the overlay is disabled. The recording_overlay
    // window is created at boot regardless of overlay_style, so without this
    // guard a hidden overlay's WebKit subprocess still
    // processes every event. Each event drives some kind of WebKit
    // C++ allocation that accumulates without bound (mechanism not
    // directly characterized; see issue #1279 for the investigation).
    // For users with `overlay_style: none` (the Linux default) this skip
    // eliminates the upstream driver of that accumulation.
    if !OVERLAY_ENABLED.load(Ordering::Relaxed) {
        return;
    }

    // Throttle to ~30 FPS. Even with the overlay enabled, the raw audio
    // callback fires far faster than the UI needs; capping emission rate
    // cuts the per-frame `eval_script`/IPC volume that drives the wry
    // memory growth in issue #1279 (upstream tauri-apps/wry#1489).
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;
    let last = LAST_MIC_LEVEL_EMIT.load(Ordering::Relaxed);
    if now.saturating_sub(last) < EMIT_THROTTLE_MS {
        return;
    }
    LAST_MIC_LEVEL_EMIT.store(now, Ordering::Relaxed);

    // Target only the overlay window. In Tauri 2 both `AppHandle::emit`
    // and `WebviewWindow::emit` broadcast to all webviews; Tauri's
    // listener filter then skips webviews with no registered listener
    // for the event, so the settings webview never received `mic-level`.
    // But the previous dual-call pattern still produced two `eval_script`
    // calls to the overlay per audio callback (one from each .emit()).
    // `emit_to` with the overlay's window label produces a single
    // eval_script call per callback, cutting the per-callback WebKit
    // dispatch work in half.
    let _ = app_handle.emit_to("recording_overlay", "mic-level", levels);
}
