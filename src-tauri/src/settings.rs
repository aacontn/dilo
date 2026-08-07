use log::{debug, warn};
use serde::de::{self, Visitor};
use serde::{Deserialize, Deserializer, Serialize};
use specta::Type;
use std::collections::HashMap;
use std::fmt;
use tauri::AppHandle;
use tauri_plugin_store::StoreExt;

pub const APPLE_INTELLIGENCE_PROVIDER_ID: &str = "apple_intelligence";
pub const APPLE_INTELLIGENCE_DEFAULT_MODEL_ID: &str = "Apple Intelligence";

#[derive(Serialize, Debug, Clone, Copy, PartialEq, Eq, Type)]
#[serde(rename_all = "lowercase")]
pub enum LogLevel {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
}

// Custom deserializer to handle both old numeric format (1-5) and new string format ("trace", "debug", etc.)
impl<'de> Deserialize<'de> for LogLevel {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct LogLevelVisitor;

        impl<'de> Visitor<'de> for LogLevelVisitor {
            type Value = LogLevel;

            fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                formatter.write_str("a string or integer representing log level")
            }

            fn visit_str<E: de::Error>(self, value: &str) -> Result<LogLevel, E> {
                match value.to_lowercase().as_str() {
                    "trace" => Ok(LogLevel::Trace),
                    "debug" => Ok(LogLevel::Debug),
                    "info" => Ok(LogLevel::Info),
                    "warn" => Ok(LogLevel::Warn),
                    "error" => Ok(LogLevel::Error),
                    _ => Err(E::unknown_variant(
                        value,
                        &["trace", "debug", "info", "warn", "error"],
                    )),
                }
            }

            fn visit_u64<E: de::Error>(self, value: u64) -> Result<LogLevel, E> {
                match value {
                    1 => Ok(LogLevel::Trace),
                    2 => Ok(LogLevel::Debug),
                    3 => Ok(LogLevel::Info),
                    4 => Ok(LogLevel::Warn),
                    5 => Ok(LogLevel::Error),
                    _ => Err(E::invalid_value(de::Unexpected::Unsigned(value), &"1-5")),
                }
            }
        }

        deserializer.deserialize_any(LogLevelVisitor)
    }
}

impl From<LogLevel> for tauri_plugin_log::LogLevel {
    fn from(level: LogLevel) -> Self {
        match level {
            LogLevel::Trace => tauri_plugin_log::LogLevel::Trace,
            LogLevel::Debug => tauri_plugin_log::LogLevel::Debug,
            LogLevel::Info => tauri_plugin_log::LogLevel::Info,
            LogLevel::Warn => tauri_plugin_log::LogLevel::Warn,
            LogLevel::Error => tauri_plugin_log::LogLevel::Error,
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone, Type)]
pub struct ShortcutBinding {
    pub id: String,
    pub name: String,
    pub description: String,
    pub default_binding: String,
    pub current_binding: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, Type)]
pub struct LLMPrompt {
    pub id: String,
    pub name: String,
    pub prompt: String,
    /// Atajo global opcional del modo (binding dinámico `mode:<id>`).
    #[serde(default)]
    pub shortcut: Option<String>,
    /// Proveedor propio de este modo. `None` = usa el global
    /// (`post_process_provider_id`), que es el comportamiento histórico y por
    /// eso no necesita migración.
    #[serde(default)]
    pub provider_id: Option<String>,
    /// Modelo propio de este modo. `None` = el que esté configurado para su
    /// proveedor en `post_process_models`.
    #[serde(default)]
    pub model: Option<String>,
}

/// Una nota dictada que no pudo sincronizarse todavía (sin conexión, error del
/// proveedor, etc.). Se guarda para reintentar el envío a sus `targets`.
#[derive(Serialize, Deserialize, Debug, Clone, Type)]
pub struct PendingNote {
    pub title: String,
    pub body: String,
    /// Destinos pendientes: `"apple"` / `"notion"`.
    pub targets: Vec<String>,
    #[serde(default)]
    pub last_error: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, Clone, Type)]
pub struct PostProcessProvider {
    pub id: String,
    pub label: String,
    pub base_url: String,
    #[serde(default)]
    pub allow_base_url_edit: bool,
    #[serde(default)]
    pub models_endpoint: Option<String>,
    #[serde(default)]
    pub supports_structured_output: bool,
    /// Calculado al cargar settings (ver `ensure_post_process_defaults`), no
    /// editable por el usuario. Está en la struct para que el frontend lo lea
    /// del binding en vez de repetir la regla en TypeScript.
    #[serde(default)]
    pub is_local: bool,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Type)]
#[serde(rename_all = "lowercase")]
pub enum OverlayPosition {
    Top,
    // `none` is retired: overlay visibility is owned by `OverlayStyle` now. The
    // alias keeps legacy stores (`"overlay_position": "none"`) deserializing
    // instead of failing the whole load; the one-time overlay migration reads the
    // raw stored string to recover the old "hidden" intent as `OverlayStyle::None`.
    #[serde(alias = "none")]
    Bottom,
}

/// Which recording overlay to display. `Minimal` and `Live` share one base
/// (the pill); `Live` grows into the panel that shows live transcription text.
/// `None` hides the overlay entirely. Decoupled from whether the model runs in
/// streaming mode (that is driven purely by model capability).
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Type)]
#[serde(rename_all = "lowercase")]
pub enum OverlayStyle {
    None,
    Minimal,
    Live,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Type, Default)]
#[serde(rename_all = "snake_case")]
pub enum ModelUnloadTimeout {
    Never,
    Immediately,
    #[default]
    Min2,
    Min5,
    Min10,
    Min15,
    Hour1,
    Sec15, // Debug mode only
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Type)]
#[serde(rename_all = "snake_case")]
pub enum PasteMethod {
    CtrlV,
    Direct,
    None,
    ShiftInsert,
    CtrlShiftV,
    ExternalScript,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Type, Default)]
#[serde(rename_all = "snake_case")]
pub enum ClipboardHandling {
    #[default]
    DontModify,
    CopyToClipboard,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Type, Default)]
#[serde(rename_all = "snake_case")]
pub enum AutoSubmitKey {
    #[default]
    Enter,
    CtrlEnter,
    CmdEnter,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Type)]
#[serde(rename_all = "snake_case")]
pub enum RecordingRetentionPeriod {
    Never,
    PreserveLimit,
    Days3,
    Weeks2,
    Months3,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Type)]
#[serde(rename_all = "snake_case")]
pub enum KeyboardImplementation {
    Tauri,
    HandyKeys,
}

impl Default for KeyboardImplementation {
    fn default() -> Self {
        #[cfg(target_os = "linux")]
        return KeyboardImplementation::Tauri;
        #[cfg(not(target_os = "linux"))]
        return KeyboardImplementation::HandyKeys;
    }
}

impl Default for PasteMethod {
    fn default() -> Self {
        // Default to CtrlV for macOS and Windows, Direct for Linux
        #[cfg(target_os = "linux")]
        return PasteMethod::Direct;
        #[cfg(not(target_os = "linux"))]
        return PasteMethod::CtrlV;
    }
}

impl ModelUnloadTimeout {
    pub fn to_minutes(self) -> Option<u64> {
        match self {
            ModelUnloadTimeout::Never => None,
            ModelUnloadTimeout::Immediately => Some(0), // Special case for immediate unloading
            ModelUnloadTimeout::Min2 => Some(2),
            ModelUnloadTimeout::Min5 => Some(5),
            ModelUnloadTimeout::Min10 => Some(10),
            ModelUnloadTimeout::Min15 => Some(15),
            ModelUnloadTimeout::Hour1 => Some(60),
            ModelUnloadTimeout::Sec15 => Some(0), // Special case for debug - handled separately
        }
    }

    pub fn to_seconds(self) -> Option<u64> {
        match self {
            ModelUnloadTimeout::Never => None,
            ModelUnloadTimeout::Immediately => Some(0), // Special case for immediate unloading
            ModelUnloadTimeout::Sec15 => Some(15),
            _ => self.to_minutes().map(|m| m * 60),
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Type)]
#[serde(rename_all = "snake_case")]
pub enum SoundTheme {
    Marimba,
    Pop,
    Custom,
}

impl SoundTheme {
    fn as_str(&self) -> &'static str {
        match self {
            SoundTheme::Marimba => "marimba",
            SoundTheme::Pop => "pop",
            SoundTheme::Custom => "custom",
        }
    }

    pub fn to_start_path(self) -> String {
        format!("resources/{}_start.wav", self.as_str())
    }

    pub fn to_stop_path(self) -> String {
        format!("resources/{}_stop.wav", self.as_str())
    }
}

/// UI appearance mode. `System` follows the OS `prefers-color-scheme`; `Light`
/// and `Dark` force one of the two palettes Dilo already ships.
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Type)]
#[serde(rename_all = "snake_case")]
pub enum Theme {
    System,
    Light,
    Dark,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Type, Default)]
#[serde(rename_all = "snake_case")]
pub enum TypingTool {
    #[default]
    Auto,
    Wtype,
    Kwtype,
    Dotool,
    Ydotool,
    Xdotool,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Type, Default)]
#[serde(rename_all = "snake_case")]
pub enum TranscribeAcceleratorSetting {
    #[default]
    Auto,
    Cpu,
    Gpu,
}

/// Motor de síntesis de voz de salida activo. Hoy solo existe `Supertonic`
/// (local); ya es un `enum` — no un `String` opaco como `VoiceId` — para no
/// tener que migrar el esquema de settings cuando se sume un proveedor de
/// nube (Deepgram/ElevenLabs, fase 1b — ver `docs/plans/dilo-v2-voz.md`).
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Type, Default)]
#[serde(rename_all = "snake_case")]
pub enum TtsEngineSetting {
    #[default]
    Supertonic,
}

/// Fuente de audio para grabar reuniones. `SystemAudio` (el audio que sale
/// del computador) es el default: en una reunión online el micrófono sólo
/// capta tu voz y un eco pobre de los parlantes, no las voces de los demás,
/// que viajan por el sistema — decisión de producto del dueño ("ya habíamos
/// decidido hacerlo por el audio del computador, no del micrófono; sólo
/// opción para presencial"). `Microphone` es la opción para reuniones
/// presenciales.
///
/// **Reinterpretado por el cableado de audio de reuniones (M2 del reporte de
/// seguimiento).** Antes de esa tarea, esta era una perilla GLOBAL e
/// independiente del tipo de reunión (`kind`, `"presencial"`/`"virtual"`),
/// y las dos podían quedar incoherentes entre sí — la interfaz podía decir
/// "reunión online" mientras `start_capture` grababa con audio del sistema
/// contra este ajuste sin importarle el `kind` real de esa reunión. Ahora la
/// fuente se deduce SIEMPRE del `kind` que el usuario eligió para esa
/// reunión en particular (`managers::meeting::resolve_meeting_audio_source`,
/// que ya no lee este campo en absoluto). Este ajuste sigue existiendo sólo
/// para recordar la última elección y preseleccionarla la próxima vez que se
/// abre el selector de tipo de reunión (`RecordingControls.tsx`:
/// `SystemAudio` ~ "online", `Microphone` ~ "presencial") — se mantienen el
/// nombre del campo y sus dos variantes sin cambios a propósito, para que un
/// `settings.json` guardado con una versión anterior siga cargando igual sin
/// ninguna migración.
///
/// Ver `managers::meeting::resolve_meeting_audio_source` para cómo se
/// resuelve la fuente real de una reunión, incluyendo cuando el audio del
/// sistema no está disponible en esta máquina (fuera de macOS, o macOS
/// anterior a 14.2).
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Type, Default)]
#[serde(rename_all = "snake_case")]
pub enum MeetingAudioSource {
    #[default]
    SystemAudio,
    Microphone,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Type, Default)]
#[serde(rename_all = "snake_case")]
pub enum OrtAcceleratorSetting {
    #[default]
    Auto,
    Cpu,
    Cuda,
    #[serde(rename = "directml")]
    DirectMl,
    Rocm,
}

#[derive(Clone, Serialize, Deserialize, Type)]
#[serde(transparent)]
pub(crate) struct SecretMap(HashMap<String, String>);

impl fmt::Debug for SecretMap {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let redacted: HashMap<&String, &str> = self
            .0
            .iter()
            .map(|(k, v)| (k, if v.is_empty() { "" } else { "[REDACTED]" }))
            .collect();
        redacted.fmt(f)
    }
}

impl std::ops::Deref for SecretMap {
    type Target = HashMap<String, String>;
    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl std::ops::DerefMut for SecretMap {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.0
    }
}

/* still handy for composing the initial JSON in the store ------------- */
/// The container-level `serde(default)` (backed by the `Default` impl below)
/// guarantees every field — including ones added in the future — falls back to
/// its `get_default_settings()` value when missing from a stored settings
/// object, so a partial store can never fail the whole load (#1619).
/// Field-level defaults below take precedence where present.
#[derive(Serialize, Deserialize, Debug, Clone, Type)]
#[serde(default)]
pub struct AppSettings {
    /// Internal settings schema marker for one-time migrations. Fresh installs
    /// start at the current version; existing stores missing this key are
    /// treated as version 0 and migrated forward.
    #[serde(default = "default_settings_schema_version")]
    pub settings_schema_version: u32,
    /// Defaults to empty on partial stores; the load path merges in the
    /// default bindings for any missing keys before the settings are used.
    #[serde(default)]
    pub bindings: HashMap<String, ShortcutBinding>,
    #[serde(default = "default_push_to_talk")]
    pub push_to_talk: bool,
    #[serde(default)]
    pub audio_feedback: bool,
    #[serde(default = "default_audio_feedback_volume")]
    pub audio_feedback_volume: f32,
    #[serde(default = "default_sound_theme")]
    pub sound_theme: SoundTheme,
    #[serde(default = "default_start_hidden")]
    pub start_hidden: bool,
    #[serde(default = "default_autostart_enabled")]
    pub autostart_enabled: bool,
    #[serde(default = "default_update_checks_enabled")]
    pub update_checks_enabled: bool,
    #[serde(default = "default_show_whats_new_on_update")]
    pub show_whats_new_on_update: bool,
    /// The app version whose What's New the user has already seen. Fresh installs
    /// default to the current version (nothing is "new" to them). Existing users
    /// upgrading from before this key existed are blanked by the migration so they
    /// see the current release's notes — see `apply_settings_migrations`.
    #[serde(default = "default_whats_new_last_seen_version")]
    pub whats_new_last_seen_version: String,
    #[serde(default = "default_model")]
    pub selected_model: String,
    #[serde(default)]
    pub onboarding_completed: bool,
    #[serde(default = "default_always_on_microphone")]
    pub always_on_microphone: bool,
    #[serde(default)]
    pub selected_microphone: Option<String>,
    #[serde(default)]
    pub clamshell_microphone: Option<String>,
    #[serde(default)]
    pub selected_output_device: Option<String>,
    #[serde(default = "default_translate_to_english")]
    pub translate_to_english: bool,
    #[serde(default = "default_selected_language")]
    pub selected_language: String,
    #[serde(default = "default_overlay_position")]
    pub overlay_position: OverlayPosition,
    #[serde(default = "default_debug_mode")]
    pub debug_mode: bool,
    #[serde(default = "default_log_level")]
    pub log_level: LogLevel,
    #[serde(default)]
    pub custom_words: Vec<String>,
    #[serde(default)]
    pub model_unload_timeout: ModelUnloadTimeout,
    #[serde(default = "default_word_correction_threshold")]
    pub word_correction_threshold: f64,
    #[serde(default = "default_history_limit")]
    pub history_limit: usize,
    #[serde(default = "default_recording_retention_period")]
    pub recording_retention_period: RecordingRetentionPeriod,
    #[serde(default)]
    pub paste_method: PasteMethod,
    #[serde(default)]
    pub clipboard_handling: ClipboardHandling,
    #[serde(default = "default_auto_submit")]
    pub auto_submit: bool,
    #[serde(default)]
    pub auto_submit_key: AutoSubmitKey,
    #[serde(default = "default_post_process_enabled")]
    pub post_process_enabled: bool,
    #[serde(default = "default_post_process_provider_id")]
    pub post_process_provider_id: String,
    #[serde(default = "default_post_process_providers")]
    pub post_process_providers: Vec<PostProcessProvider>,
    #[serde(default = "default_post_process_api_keys")]
    pub post_process_api_keys: SecretMap,
    #[serde(default = "default_post_process_models")]
    pub post_process_models: HashMap<String, String>,
    /// Los modos de transformación. Cada uno es prompt + tecla + proveedor, y
    /// se invoca por su propia tecla (binding `mode:<id>`): no hay "modo
    /// activo". El campo `post_process_selected_prompt_id` que lo elegía se
    /// retiró en 0.2.3 — ver `migrate_active_mode_to_mode_shortcuts`.
    #[serde(default = "default_post_process_prompts")]
    pub post_process_prompts: Vec<LLMPrompt>,
    #[serde(default)]
    pub mute_while_recording: bool,
    #[serde(default)]
    pub append_trailing_space: bool,
    #[serde(default = "default_app_language")]
    pub app_language: String,
    #[serde(default = "default_theme")]
    pub theme: Theme,
    #[serde(default)]
    pub experimental_enabled: bool,
    #[serde(default)]
    pub lazy_stream_close: bool,
    #[serde(default)]
    pub keyboard_implementation: KeyboardImplementation,
    #[serde(default = "default_show_tray_icon")]
    pub show_tray_icon: bool,
    /// macOS: si Dilo aparece en el Dock (y en Cmd-Tab) o vive sólo en la
    /// barra de menú (`ActivationPolicy::Accessory`). Por omisión `true` —
    /// el comportamiento de siempre; esconder el Dock es una elección del
    /// usuario, no un cambio que se le hace sin avisar. La bandeja manda: sin
    /// ella el Dock es la única puerta para volver a Ajustes, así que el
    /// ícono se queda aunque esta bandera diga que no.
    #[serde(default = "default_show_dock_icon")]
    pub show_dock_icon: bool,
    #[serde(default = "default_paste_delay_ms")]
    pub paste_delay_ms: u64,
    #[serde(default = "default_paste_delay_after_ms")]
    pub paste_delay_after_ms: u64,
    #[serde(default = "default_typing_tool")]
    pub typing_tool: TypingTool,
    #[serde(default)]
    pub external_script_path: Option<String>,
    #[serde(default)]
    pub custom_filler_words: Option<Vec<String>>,
    #[serde(default)]
    pub transcribe_accelerator: TranscribeAcceleratorSetting,
    #[serde(default)]
    pub ort_accelerator: OrtAcceleratorSetting,
    #[serde(default = "default_transcribe_gpu_device")]
    pub transcribe_gpu_device: i32,
    #[serde(default)]
    pub extra_recording_buffer_ms: u64,
    #[serde(default = "default_vad_enabled")]
    pub vad_enabled: bool,
    /// Which recording overlay to show: None / Minimal / Live. Streaming mode is
    /// not gated on this — that follows model capability. Migrated from the old
    /// `overlay_position` (position `none` → style `None`).
    #[serde(default = "default_overlay_style")]
    pub overlay_style: OverlayStyle,
    /// Carpeta donde se guardan las notas rápidas locales. `None` → default
    /// `~/Documents/Dilo/Notas` (resuelto en el momento de escribir).
    #[serde(default)]
    pub notes_folder: Option<String>,
    /// Sincronizar notas con la app Notas de Apple.
    #[serde(default)]
    pub notes_apple_enabled: bool,
    /// Carpeta destino dentro de Apple Notes.
    #[serde(default = "default_notes_apple_folder")]
    pub notes_apple_folder: String,
    /// Sincronizar notas con Notion.
    #[serde(default)]
    pub notes_notion_enabled: bool,
    /// Página/base padre de Notion donde crear las notas.
    #[serde(default)]
    pub notes_notion_parent: String,
    /// Secretos de sincronización de notas (clave `"notion"` = token).
    #[serde(default = "default_notes_secrets")]
    pub notes_secrets: SecretMap,
    /// Notas dictadas cuya sincronización quedó pendiente de reintento.
    #[serde(default)]
    pub notes_pending: Vec<PendingNote>,
    /// Motor de voz de salida activo. Ver [`TtsEngineSetting`].
    #[serde(default)]
    pub tts_engine: TtsEngineSetting,
    /// Voz elegida dentro del motor activo — id opaco (`"F5"`, `"M2"`, etc.
    /// para Supertonic, ver `tts::VoiceId`). Default de fábrica: F5
    /// (`tts::supertonic::DEFAULT_VOICE`).
    #[serde(default = "default_tts_voice")]
    pub tts_voice: String,
    /// Modo asistente hablado: el atajo dedicado (binding `voice_assistant`)
    /// manda la transcripción al LLM de post-proceso configurado y dice la
    /// respuesta en voz alta en vez de pegarla (ver `assistant.rs`). Apagado
    /// por defecto — activarlo es explícito, aunque el atajo ya viene sin
    /// tecla asignada (igual que `quick_note`).
    #[serde(default)]
    pub voice_assistant_enabled: bool,
    /// Fuente de audio para grabar reuniones — ver [`MeetingAudioSource`].
    /// Un `settings.json` viejo no trae esta clave: `#[serde(default)]` la
    /// resuelve a `SystemAudio` sin tocar el resto del archivo.
    #[serde(default)]
    pub meeting_audio_source: MeetingAudioSource,
    /// Modelo de transcripción propio para reuniones, separado del de
    /// dictado (`selected_model`). `None` (o vacío) significa **heredar**:
    /// la reunión usa el mismo modelo que el dictado, y quien nunca entra al
    /// selector de reuniones del popover no nota que este campo existe —
    /// mismo patrón que `LLMPrompt::provider_id` en `resolve_mode_provider`
    /// (un modo de post-proceso hereda el proveedor global salvo que elija
    /// uno propio). `#[serde(default)]` (`None`) para que un `settings.json`
    /// viejo cargue igual sin tocar el resto del archivo.
    ///
    /// Se resuelve una sola vez, al empezar la captura
    /// (`MeetingManager::start_capture`), y esa reunión entera —incluido
    /// cualquier reintento tras una descarga de modelo por inactividad— usa
    /// siempre ese mismo id, nunca `selected_model` directamente (que es el
    /// del dictado y puede cambiar bajo los pies mientras la reunión graba).
    #[serde(default)]
    pub meeting_model_id: Option<String>,
}

fn default_model() -> String {
    "".to_string()
}

const CURRENT_SETTINGS_SCHEMA_VERSION: u32 = 1;

fn default_settings_schema_version() -> u32 {
    CURRENT_SETTINGS_SCHEMA_VERSION
}

fn default_push_to_talk() -> bool {
    true
}

fn default_always_on_microphone() -> bool {
    false
}

fn default_translate_to_english() -> bool {
    false
}

fn default_start_hidden() -> bool {
    false
}

fn default_autostart_enabled() -> bool {
    false
}

fn default_update_checks_enabled() -> bool {
    // v0.1.0 sin updater propio; reactivar al firmar releases
    false
}

fn default_show_whats_new_on_update() -> bool {
    true
}

fn default_whats_new_last_seen_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

fn default_selected_language() -> String {
    "auto".to_string()
}

fn default_overlay_position() -> OverlayPosition {
    // Position only matters when the overlay is shown; whether it shows at all is
    // `overlay_style` (Linux defaults that to None). So a single default suffices.
    OverlayPosition::Bottom
}

fn default_overlay_style() -> OverlayStyle {
    // Linux hides the overlay by default (layer-shell quirks); other platforms
    // show the minimal pill. Position is independent and only selects top vs.
    // bottom placement.
    #[cfg(target_os = "linux")]
    return OverlayStyle::None;
    #[cfg(not(target_os = "linux"))]
    return OverlayStyle::Minimal;
}

fn default_vad_enabled() -> bool {
    true
}

fn default_debug_mode() -> bool {
    false
}

fn default_log_level() -> LogLevel {
    LogLevel::Debug
}

fn default_word_correction_threshold() -> f64 {
    0.18
}

fn default_paste_delay_ms() -> u64 {
    60
}

fn default_paste_delay_after_ms() -> u64 {
    60
}

fn default_auto_submit() -> bool {
    false
}

fn default_history_limit() -> usize {
    5
}

fn default_recording_retention_period() -> RecordingRetentionPeriod {
    RecordingRetentionPeriod::PreserveLimit
}

fn default_audio_feedback_volume() -> f32 {
    1.0
}

fn default_sound_theme() -> SoundTheme {
    SoundTheme::Marimba
}

fn default_theme() -> Theme {
    Theme::System
}

fn default_post_process_enabled() -> bool {
    false
}

fn default_app_language() -> String {
    tauri_plugin_os::locale()
        .map(|l| l.replace('_', "-"))
        .unwrap_or_else(|| "en".to_string())
}

fn default_show_tray_icon() -> bool {
    true
}

fn default_show_dock_icon() -> bool {
    true
}

fn default_post_process_provider_id() -> String {
    "openai".to_string()
}

/// Si el destino de un proveedor es la propia máquina del usuario.
///
/// **Se calcula, no se guarda como verdad.** Apple Intelligence lo es por
/// definición (corre en el chip). `custom` es el único cuyo destino define el
/// usuario: viene apuntando a Ollama en `localhost:11434`, pero si lo cambia a
/// un servidor remoto tiene que dejar de decir LOCAL sin depender de que
/// alguien se acuerde de actualizar una bandera.
pub fn provider_is_local(provider: &PostProcessProvider) -> bool {
    if provider.id == APPLE_INTELLIGENCE_PROVIDER_ID {
        return true;
    }
    is_loopback_url(&provider.base_url)
}

fn is_loopback_url(base_url: &str) -> bool {
    let lowered = base_url.to_ascii_lowercase();
    let host = lowered
        .split("://")
        .nth(1)
        .unwrap_or(&lowered)
        .split('/')
        .next()
        .unwrap_or("");
    let host = host.rsplit_once(':').map_or(host, |(h, _)| h);
    let host = host.trim_start_matches('[').trim_end_matches(']');

    host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "0.0.0.0"
}

fn default_post_process_providers() -> Vec<PostProcessProvider> {
    let mut providers = vec![
        PostProcessProvider {
            id: "openai".to_string(),
            label: "OpenAI".to_string(),
            base_url: "https://api.openai.com/v1".to_string(),
            allow_base_url_edit: false,
            models_endpoint: Some("/models".to_string()),
            supports_structured_output: true,
            is_local: false,
        },
        PostProcessProvider {
            id: "zai".to_string(),
            label: "Z.AI".to_string(),
            base_url: "https://api.z.ai/api/paas/v4".to_string(),
            allow_base_url_edit: false,
            models_endpoint: Some("/models".to_string()),
            supports_structured_output: true,
            is_local: false,
        },
        PostProcessProvider {
            id: "openrouter".to_string(),
            label: "OpenRouter".to_string(),
            base_url: "https://openrouter.ai/api/v1".to_string(),
            allow_base_url_edit: false,
            models_endpoint: Some("/models".to_string()),
            supports_structured_output: true,
            is_local: false,
        },
        PostProcessProvider {
            id: "anthropic".to_string(),
            label: "Anthropic".to_string(),
            base_url: "https://api.anthropic.com/v1".to_string(),
            allow_base_url_edit: false,
            models_endpoint: Some("/models".to_string()),
            supports_structured_output: false,
            is_local: false,
        },
        PostProcessProvider {
            id: "groq".to_string(),
            label: "Groq".to_string(),
            base_url: "https://api.groq.com/openai/v1".to_string(),
            allow_base_url_edit: false,
            models_endpoint: Some("/models".to_string()),
            supports_structured_output: false,
            is_local: false,
        },
        PostProcessProvider {
            id: "cerebras".to_string(),
            label: "Cerebras".to_string(),
            base_url: "https://api.cerebras.ai/v1".to_string(),
            allow_base_url_edit: false,
            models_endpoint: Some("/models".to_string()),
            supports_structured_output: true,
            is_local: false,
        },
        // Gemini vía su capa de compatibilidad con OpenAI, así que entra por
        // el mismo cliente que el resto (nada de SDK propio de Google).
        PostProcessProvider {
            id: "google".to_string(),
            label: "Google Gemini".to_string(),
            base_url: "https://generativelanguage.googleapis.com/v1beta/openai".to_string(),
            allow_base_url_edit: false,
            models_endpoint: Some("/models".to_string()),
            supports_structured_output: true,
            is_local: false,
        },
    ];

    // Note: We always include Apple Intelligence on macOS ARM64 without checking availability
    // at startup. The availability check is deferred to when the user actually tries to use it
    // (in actions.rs). This prevents crashes on macOS 26.x beta where accessing
    // SystemLanguageModel.default during early app initialization causes SIGABRT.
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        providers.push(PostProcessProvider {
            id: APPLE_INTELLIGENCE_PROVIDER_ID.to_string(),
            label: "Apple Intelligence".to_string(),
            base_url: "apple-intelligence://local".to_string(),
            allow_base_url_edit: false,
            models_endpoint: None,
            supports_structured_output: true,
            is_local: true,
        });
    }

    // AWS Bedrock via Mantle (OpenAI-compatible endpoint)
    providers.push(PostProcessProvider {
        id: "bedrock_mantle".to_string(),
        label: "AWS Bedrock (Mantle)".to_string(),
        base_url: "https://bedrock-mantle.us-east-1.api.aws/v1".to_string(),
        allow_base_url_edit: false,
        models_endpoint: Some("/models".to_string()),
        supports_structured_output: true,
        is_local: false,
    });

    // Custom provider always comes last. Su default apunta a Ollama en
    // localhost, así que `is_local` se calcula del mismo `base_url` en vez de
    // hardcodearse en falso — si no, un settings.json nuevo (sin pasar por
    // `ensure_post_process_defaults`, que sí lo recalcula) mostraría Custom
    // como online cuando en realidad corre en la propia máquina.
    let custom_base_url = "http://localhost:11434/v1".to_string();
    providers.push(PostProcessProvider {
        id: "custom".to_string(),
        label: "Custom".to_string(),
        is_local: is_loopback_url(&custom_base_url),
        base_url: custom_base_url,
        allow_base_url_edit: true,
        models_endpoint: Some("/models".to_string()),
        supports_structured_output: false,
    });

    providers
}

fn default_post_process_api_keys() -> SecretMap {
    let mut map = HashMap::new();
    for provider in default_post_process_providers() {
        map.insert(provider.id, String::new());
    }
    SecretMap(map)
}

fn default_model_for_provider(provider_id: &str) -> String {
    if provider_id == APPLE_INTELLIGENCE_PROVIDER_ID {
        return APPLE_INTELLIGENCE_DEFAULT_MODEL_ID.to_string();
    }
    String::new()
}

fn default_post_process_models() -> HashMap<String, String> {
    let mut map = HashMap::new();
    for provider in default_post_process_providers() {
        map.insert(
            provider.id.clone(),
            default_model_for_provider(&provider.id),
        );
    }
    map
}

fn dilo_post_process_presets() -> Vec<LLMPrompt> {
    vec![
        LLMPrompt {
            id: "dilo-clean".to_string(),
            name: "Limpio".to_string(),
            prompt: "Clean this speech transcript. Fix punctuation, capitalization and obvious transcription errors. Keep the original language, meaning, tone and order.\n\nRemove filler words when they act as filler, but keep them when they carry meaning. In Spanish this matters a lot: drop discourse-marker uses of 'o sea', 'este', 'tipo', 'como que', 'digamos', 'a ver', 'pues', 'bueno', 'la verdad', and regional tics ('po', '¿cachái?', '¿viste?', '¿me entendés?', 'güey/wey', 'che', 'pana', 'vale') — but NEVER when they are content ('este archivo', 'tipo de dato', 'pues bien' as connector). When unsure, keep the word.\n\nKeep technical/English terms exactly as spoken (commit, deploy, endpoint, pull request, backend, boolean); do not translate or Spanish-ize them. Do not add information or answer questions. Return only the cleaned text.\n\n<transcript>\n${output}\n</transcript>".to_string(),
            shortcut: None,
            provider_id: None,
            model: None,
        },
        LLMPrompt {
            id: "dilo-prompt".to_string(),
            name: "Prompt".to_string(),
            prompt: "Turn this spoken draft into a clear, effective prompt for an AI coding assistant. Preserve every requirement and piece of context, organize it into readable paragraphs or bullets when useful, and keep the original language. Do not execute or answer the prompt. Return only the improved prompt.\n\n<transcript>\n${output}\n</transcript>".to_string(),
            shortcut: None,
            provider_id: None,
            model: None,
        },
        LLMPrompt {
            id: "dilo-message".to_string(),
            name: "Mensaje".to_string(),
            prompt: "Rewrite this speech transcript as a concise natural chat message. Remove filler words, fix punctuation, preserve the speaker's casual tone and original language, and do not add facts. Return only the message.\n\n<transcript>\n${output}\n</transcript>".to_string(),
            shortcut: None,
            provider_id: None,
            model: None,
        },
        LLMPrompt {
            id: "dilo-email".to_string(),
            name: "Correo".to_string(),
            prompt: "Rewrite this speech transcript as a clear professional email body. Preserve the original language, intent and facts; improve structure and readability without sounding corporate or adding a subject line. Return only the email body.\n\n<transcript>\n${output}\n</transcript>".to_string(),
            shortcut: None,
            provider_id: None,
            model: None,
        },
        LLMPrompt {
            id: "dilo-code".to_string(),
            name: "Código".to_string(),
            prompt: "Clean this developer dictation while preserving exact technical meaning. Keep code identifiers, commands, file paths, versions and conventional commit syntax intact. Format code, paths and lists only when clearly implied. Keep the original language and return only the cleaned text.\n\n<transcript>\n${output}\n</transcript>".to_string(),
            shortcut: None,
            provider_id: None,
            model: None,
        },
    ]
}

/// Tecla de fábrica del modo Limpio: la que hasta la 0.2.2 era "transformar".
/// Una instalación nueva tiene así algo funcionando de inmediato, sin tener
/// que asignar nada.
const DEFAULT_CLEAN_MODE_SHORTCUT: &str = "fn+F17";

/// Los modos de fábrica **de una instalación nueva**: los mismos presets, con
/// la tecla de Limpio ya puesta.
///
/// A propósito no es lo que usa `ensure_post_process_defaults` para rellenar
/// un store existente: ahí los presets entran sin tecla, porque quedarse con
/// una combinación que la persona ya usa para otra cosa sería robarle un
/// atajo en una actualización.
fn default_post_process_prompts() -> Vec<LLMPrompt> {
    let mut prompts = dilo_post_process_presets();
    if let Some(clean) = prompts.iter_mut().find(|prompt| prompt.id == "dilo-clean") {
        clean.shortcut = Some(DEFAULT_CLEAN_MODE_SHORTCUT.to_string());
    }
    prompts
}

fn default_transcribe_gpu_device() -> i32 {
    -1 // auto
}

fn default_typing_tool() -> TypingTool {
    TypingTool::Auto
}

fn default_notes_apple_folder() -> String {
    "Dilo".to_string()
}

fn default_notes_secrets() -> SecretMap {
    SecretMap(HashMap::new())
}

fn default_tts_voice() -> String {
    crate::tts::supertonic::DEFAULT_VOICE.to_string()
}

fn ensure_post_process_defaults(settings: &mut AppSettings) -> bool {
    let mut changed = false;
    for provider in default_post_process_providers() {
        // Use match to do a single lookup - either sync existing or add new
        match settings
            .post_process_providers
            .iter_mut()
            .find(|p| p.id == provider.id)
        {
            Some(existing) => {
                // Sync supports_structured_output field for existing providers (migration)
                if existing.supports_structured_output != provider.supports_structured_output {
                    debug!(
                        "Updating supports_structured_output for provider '{}' from {} to {}",
                        provider.id,
                        existing.supports_structured_output,
                        provider.supports_structured_output
                    );
                    existing.supports_structured_output = provider.supports_structured_output;
                    changed = true;
                }

                // `is_local` se recalcula siempre: el usuario pudo cambiar la
                // base_url de `custom`, y un settings.json viejo no lo trae.
                let computed = provider_is_local(existing);
                if existing.is_local != computed {
                    existing.is_local = computed;
                    changed = true;
                }
            }
            None => {
                // Provider doesn't exist, add it
                settings.post_process_providers.push(provider.clone());
                changed = true;
            }
        }

        if !settings.post_process_api_keys.contains_key(&provider.id) {
            settings
                .post_process_api_keys
                .insert(provider.id.clone(), String::new());
            changed = true;
        }

        let default_model = default_model_for_provider(&provider.id);
        match settings.post_process_models.get_mut(&provider.id) {
            Some(existing) => {
                if existing.is_empty() && !default_model.is_empty() {
                    *existing = default_model.clone();
                    changed = true;
                }
            }
            None => {
                settings
                    .post_process_models
                    .insert(provider.id.clone(), default_model);
                changed = true;
            }
        }
    }

    for preset in dilo_post_process_presets() {
        if !settings
            .post_process_prompts
            .iter()
            .any(|prompt| prompt.id == preset.id)
        {
            settings.post_process_prompts.push(preset);
            changed = true;
        }
    }

    changed
}

pub const SETTINGS_STORE_PATH: &str = "settings_store.json";

pub fn get_default_settings() -> AppSettings {
    #[cfg(target_os = "windows")]
    let default_shortcut = "ctrl+space";
    #[cfg(target_os = "macos")]
    let default_shortcut = "option+space";
    #[cfg(target_os = "linux")]
    let default_shortcut = "ctrl+space";
    #[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
    let default_shortcut = "alt+space";

    let mut bindings = HashMap::new();
    bindings.insert(
        "transcribe".to_string(),
        ShortcutBinding {
            id: "transcribe".to_string(),
            name: "Transcribe".to_string(),
            description: "Converts your speech into text.".to_string(),
            default_binding: default_shortcut.to_string(),
            current_binding: default_shortcut.to_string(),
        },
    );
    // El atajo general de post-proceso llega **sin tecla**. Aplicaba el "modo
    // activo", y ese concepto ya no existe: sin un modo que aplicar no tendría
    // nada que hacer más que pegar el dictado crudo, o sea sería una tecla
    // muerta. Quien transforma lo hace con la tecla del modo que quiere
    // (`mode:<id>`); de fábrica, Limpio en `fn+F17`.
    bindings.insert(
        "transcribe_with_post_process".to_string(),
        ShortcutBinding {
            id: "transcribe_with_post_process".to_string(),
            name: "Transcribe with Post-Processing".to_string(),
            description: "Converts your speech into text and applies AI post-processing."
                .to_string(),
            default_binding: String::new(),
            current_binding: String::new(),
        },
    );
    bindings.insert(
        "cancel".to_string(),
        ShortcutBinding {
            id: "cancel".to_string(),
            name: "Cancel".to_string(),
            description: "Cancels the current recording.".to_string(),
            default_binding: "escape".to_string(),
            current_binding: "escape".to_string(),
        },
    );
    bindings.insert(
        "quick_note".to_string(),
        ShortcutBinding {
            id: "quick_note".to_string(),
            name: "Quick Note".to_string(),
            description: "Dictates into a local note instead of pasting.".to_string(),
            default_binding: String::new(),
            current_binding: String::new(),
        },
    );
    bindings.insert(
        "voice_assistant".to_string(),
        ShortcutBinding {
            id: "voice_assistant".to_string(),
            name: "Voice Assistant".to_string(),
            description: "Sends the transcription to the configured LLM and reads the reply aloud instead of pasting.".to_string(),
            default_binding: String::new(),
            current_binding: String::new(),
        },
    );

    AppSettings {
        settings_schema_version: default_settings_schema_version(),
        bindings,
        push_to_talk: default_push_to_talk(),
        audio_feedback: false,
        audio_feedback_volume: default_audio_feedback_volume(),
        sound_theme: default_sound_theme(),
        start_hidden: default_start_hidden(),
        autostart_enabled: default_autostart_enabled(),
        update_checks_enabled: default_update_checks_enabled(),
        show_whats_new_on_update: default_show_whats_new_on_update(),
        whats_new_last_seen_version: default_whats_new_last_seen_version(),
        selected_model: "".to_string(),
        onboarding_completed: false,
        always_on_microphone: false,
        selected_microphone: None,
        clamshell_microphone: None,
        selected_output_device: None,
        translate_to_english: false,
        selected_language: "auto".to_string(),
        overlay_position: default_overlay_position(),
        debug_mode: false,
        log_level: default_log_level(),
        custom_words: Vec::new(),
        model_unload_timeout: ModelUnloadTimeout::default(),
        word_correction_threshold: default_word_correction_threshold(),
        history_limit: default_history_limit(),
        recording_retention_period: default_recording_retention_period(),
        paste_method: PasteMethod::default(),
        clipboard_handling: ClipboardHandling::default(),
        auto_submit: default_auto_submit(),
        auto_submit_key: AutoSubmitKey::default(),
        post_process_enabled: default_post_process_enabled(),
        post_process_provider_id: default_post_process_provider_id(),
        post_process_providers: default_post_process_providers(),
        post_process_api_keys: default_post_process_api_keys(),
        post_process_models: default_post_process_models(),
        post_process_prompts: default_post_process_prompts(),
        mute_while_recording: false,
        append_trailing_space: false,
        app_language: default_app_language(),
        theme: default_theme(),
        experimental_enabled: false,
        lazy_stream_close: false,
        keyboard_implementation: KeyboardImplementation::default(),
        show_tray_icon: default_show_tray_icon(),
        show_dock_icon: default_show_dock_icon(),
        paste_delay_ms: default_paste_delay_ms(),
        paste_delay_after_ms: default_paste_delay_after_ms(),
        typing_tool: default_typing_tool(),
        external_script_path: None,
        custom_filler_words: None,
        transcribe_accelerator: TranscribeAcceleratorSetting::default(),
        ort_accelerator: OrtAcceleratorSetting::default(),
        transcribe_gpu_device: default_transcribe_gpu_device(),
        extra_recording_buffer_ms: 0,
        vad_enabled: default_vad_enabled(),
        overlay_style: default_overlay_style(),
        notes_folder: None,
        notes_apple_enabled: false,
        notes_apple_folder: default_notes_apple_folder(),
        notes_notion_enabled: false,
        notes_notion_parent: String::new(),
        notes_secrets: default_notes_secrets(),
        notes_pending: Vec::new(),
        tts_engine: TtsEngineSetting::default(),
        tts_voice: default_tts_voice(),
        voice_assistant_enabled: false,
        meeting_audio_source: MeetingAudioSource::default(),
        meeting_model_id: None,
    }
}

impl Default for AppSettings {
    fn default() -> Self {
        get_default_settings()
    }
}

impl AppSettings {
    pub fn active_post_process_provider(&self) -> Option<&PostProcessProvider> {
        self.post_process_providers
            .iter()
            .find(|provider| provider.id == self.post_process_provider_id)
    }

    pub fn post_process_provider(&self, provider_id: &str) -> Option<&PostProcessProvider> {
        self.post_process_providers
            .iter()
            .find(|provider| provider.id == provider_id)
    }

    pub fn post_process_provider_mut(
        &mut self,
        provider_id: &str,
    ) -> Option<&mut PostProcessProvider> {
        self.post_process_providers
            .iter_mut()
            .find(|provider| provider.id == provider_id)
    }
}

/// Qué IA le toca a un modo, ya resuelta contra el catálogo y los modelos
/// configurados.
#[derive(Debug, Clone)]
pub struct ResolvedProvider {
    pub provider: PostProcessProvider,
    pub model: String,
    pub is_local: bool,
    /// `true` si salió del proveedor global en vez del propio del modo.
    /// Lo verifican los tests de esta función; el llamador de producción
    /// (la caída a la Task 3) distingue por id de proveedor en vez de por
    /// esta bandera, así que queda sin lector fuera de tests.
    #[allow(dead_code)]
    pub inherited: bool,
}

/// Resuelve el proveedor de un modo. `None` significa "no hay nada a qué
/// llamar" (sin proveedor global válido, o sin modelo configurado), que el
/// llamador trata como proveedor no disponible.
///
/// Un modo que apunta a un proveedor inexistente —el usuario lo borró— cae al
/// global **en silencio**: eso no es una falla, es configuración vieja.
pub fn resolve_mode_provider(
    settings: &AppSettings,
    prompt: &LLMPrompt,
) -> Option<ResolvedProvider> {
    let own = prompt
        .provider_id
        .as_deref()
        .and_then(|id| settings.post_process_provider(id));

    let (provider, inherited) = match own {
        Some(provider) => (provider, false),
        None => (settings.active_post_process_provider()?, true),
    };

    let model = if inherited {
        settings.post_process_models.get(&provider.id).cloned()
    } else {
        prompt
            .model
            .clone()
            .or_else(|| settings.post_process_models.get(&provider.id).cloned())
    }?;

    if model.trim().is_empty() {
        return None;
    }

    Some(ResolvedProvider {
        is_local: provider_is_local(provider),
        provider: provider.clone(),
        model,
        inherited,
    })
}

/// Startup entry point. Same load-or-create/salvage/migrate behavior as
/// `get_settings`; kept as a named alias for call-site clarity, plus a
/// one-time debug dump of the loaded settings.
pub fn load_or_create_app_settings(app: &AppHandle) -> AppSettings {
    let settings = get_settings(app);
    debug!("Loaded settings: {:?}", settings);
    settings
}

pub fn get_settings(app: &AppHandle) -> AppSettings {
    let store = app
        .store(crate::portable::store_path(SETTINGS_STORE_PATH))
        .expect("Failed to initialize store");

    // Settings reads also persist one-time migrations. Migration helpers are
    // idempotent, so this converges after the first read of an older store.
    let mut settings = if let Some(settings_value) = store.get("settings") {
        let (mut settings, mut updated) =
            match serde_json::from_value::<AppSettings>(settings_value.clone()) {
                Ok(settings) => (settings, false),
                Err(e) => {
                    warn!("Failed to parse stored settings ({e}); salvaging valid fields");
                    (salvage_settings(&settings_value), true)
                }
            };

        if apply_settings_migrations(&mut settings, &settings_value) {
            updated = true;
        }

        // Merge in any bindings added since this store was written.
        for (key, value) in get_default_settings().bindings {
            if let std::collections::hash_map::Entry::Vacant(entry) = settings.bindings.entry(key) {
                debug!("Adding missing binding: {}", entry.key());
                entry.insert(value);
                updated = true;
            }
        }

        if updated {
            store.set("settings", serde_json::to_value(&settings).unwrap());
        }

        settings
    } else {
        let default_settings = get_default_settings();
        store.set("settings", serde_json::to_value(&default_settings).unwrap());
        default_settings
    };

    if ensure_post_process_defaults(&mut settings) {
        store.set("settings", serde_json::to_value(&settings).unwrap());
    }

    settings
}

/// Rebuilds settings from a store value that failed to deserialize as a whole.
/// Every stored field that is individually valid is kept; only broken values
/// (e.g. an enum variant written by a newer or older version) fall back to
/// their default. This means one bad field can never reset the rest of the
/// user's configuration (#1619).
fn salvage_settings(stored: &serde_json::Value) -> AppSettings {
    let Some(stored_map) = stored.as_object() else {
        warn!("Stored settings are not a JSON object; falling back to defaults");
        return get_default_settings();
    };

    let mut merged = serde_json::to_value(get_default_settings())
        .expect("default settings serialize to a JSON object");

    for (key, value) in stored_map {
        let previous = merged
            .as_object_mut()
            .expect("merged settings stay an object")
            .insert(key.clone(), value.clone());
        if serde_json::from_value::<AppSettings>(merged.clone()).is_err() {
            // Log only the key: values may hold secrets (e.g. API keys).
            warn!("Dropping invalid settings field '{key}', keeping its default");
            let map = merged
                .as_object_mut()
                .expect("merged settings stay an object");
            match previous {
                Some(previous) => map.insert(key.clone(), previous),
                None => map.remove(key),
            };
        }
    }

    serde_json::from_value(merged).unwrap_or_else(|e| {
        warn!("Failed to reassemble salvaged settings ({e}); falling back to defaults");
        get_default_settings()
    })
}

fn apply_settings_migrations(
    settings: &mut AppSettings,
    settings_value: &serde_json::Value,
) -> bool {
    let mut updated = false;

    // One-time onboarding migration: users with an explicit selected model have
    // already made it through model selection. Users who merely have compatible
    // files on disk should still see onboarding.
    if settings_value.get("onboarding_completed").is_none() {
        settings.onboarding_completed = !settings.selected_model.is_empty();
        updated = true;
    }

    // One-time What's New migration: migrations only run on an existing store
    // (fresh installs stamp the current version via get_default_settings). A
    // missing key here means a user upgrading from before it existed — blank it
    // so they see the current release's What's New, mirroring the onboarding
    // migration's explicit first-run-vs-upgrade decision.
    if settings_value.get("whats_new_last_seen_version").is_none() {
        settings.whats_new_last_seen_version = String::new();
        updated = true;
    }

    let stored_schema_version = settings_value
        .get("settings_schema_version")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);
    if stored_schema_version < 1 {
        // `transcribe_gpu_device` used to be a UI ordinal; it is now a
        // transcribe.cpp registry index. A positive legacy value can point at a
        // different GPU after CPU/accelerator/backend devices are included in
        // the registry, so reset ambiguous explicit selections to Auto once.
        if settings.transcribe_gpu_device > 0 {
            settings.transcribe_accelerator = TranscribeAcceleratorSetting::Auto;
            settings.transcribe_gpu_device = default_transcribe_gpu_device();
        }
        settings.settings_schema_version = CURRENT_SETTINGS_SCHEMA_VERSION;
        updated = true;
    }

    // One-time overlay migration (only while the new key is absent): the retired
    // overlay_position `none` meant "hide the overlay" → OverlayStyle::None; any
    // other position had it visible → Live. The position enum no longer has a
    // `none` variant (legacy "none" deserializes to Bottom via a serde alias), so
    // read the raw stored string to recover the old intent.
    if settings_value.get("overlay_style").is_none() {
        let was_hidden = settings_value
            .get("overlay_position")
            .and_then(|v| v.as_str())
            == Some("none");
        settings.overlay_style = if was_hidden {
            OverlayStyle::None
        } else {
            OverlayStyle::Live
        };
        updated = true;
    }

    if migrate_active_mode_to_mode_shortcuts(settings, settings_value) {
        updated = true;
    }

    updated
}

/// La clave del "modo activo" de la 0.2.2. Ya no es un campo: que siga escrita
/// en el JSON guardado es justamente lo que marca un store anterior a los
/// atajos por modo.
const LEGACY_SELECTED_PROMPT_KEY: &str = "post_process_selected_prompt_id";

/// El atajo general de post-proceso, el que aplicaba el modo activo.
const POST_PROCESS_BINDING_ID: &str = "transcribe_with_post_process";

/// El proveedor cuyo endpoint pone la persona (Ollama, LM Studio, un servidor
/// de la LAN). Funciona sin clave aunque su `base_url` no sea loopback.
const CUSTOM_PROVIDER_ID: &str = "custom";

/// `true` si el atajo lleva al menos un modificador (`fn+f17`,
/// `option+shift+space`) en vez de ser una tecla pelada (`f17`).
fn has_modifiers(shortcut: &str) -> bool {
    shortcut.contains('+')
}

/// El atajo del modo, ya sin espacios, o `""` si no tiene.
fn mode_shortcut(prompt: &LLMPrompt) -> &str {
    prompt.shortcut.as_deref().unwrap_or("").trim()
}

/// El atajo listo para comparar: minúsculas, sin la variante izquierda/derecha
/// del modificador (`"left option"` → `"option"`) y con las partes ordenadas,
/// para que `shift+fn` y `fn+shift` no cuenten como teclas distintas.
///
/// Espejo de `normalizeCombo` en `src/lib/utils/shortcutConflicts.ts`, que es
/// la que decide si la interfaz avisa de un choque. Acá sirve para lo mismo
/// del otro lado: que la migración no le regale a un modo una combinación que
/// otro ya tiene.
fn normalized_combo(shortcut: &str) -> String {
    fn normalized_key(part: &str) -> String {
        let part = part.trim().to_lowercase();
        match part.split_once(' ') {
            Some((side, key)) if side == "left" || side == "right" => key.to_string(),
            _ => part.to_string(),
        }
    }

    let mut parts: Vec<String> = shortcut
        .split('+')
        .map(normalized_key)
        .filter(|part| !part.is_empty())
        .collect();
    parts.sort();
    parts.join("+")
}

/// Migración del "modo activo" (0.2.2) a un atajo por modo.
///
/// Corre una sola vez: sólo mira stores donde la clave retirada sigue escrita,
/// y `get_settings` reescribe el archivo —ya sin ella— cuando algo cambió.
/// Es idempotente igual: si no hay nada que mover devuelve `false` y el store
/// se queda como está.
///
/// Tres reglas (numeradas como en el diseño), aplicadas en este orden:
///
/// - **Regla 2 primero: se borran los atajos de modo que no pueden
///   dispararse.** Va antes que la 1 para que el modo activo pueda heredar la
///   tecla del atajo general una vez que quedó libre — al revés, el modo
///   activo del dueño (con `f17` guardado) se habría quedado sin nada.
/// - **Regla 1: el modo activo hereda la tecla del atajo general** —sólo si el
///   post-proceso estaba encendido y si ningún otro modo tiene ya esa
///   combinación—, para no perder la elección de la persona.
///   La tecla se **muda**: si el atajo general se quedara con ella, las dos se
///   registrarían sobre la misma combinación (y las dos implementaciones de
///   teclado rechazan duplicados, así que el que se quedaba sin registrar era
///   el modo). El atajo general suelta su tecla haya heredero o no.
/// - **Regla 3: un proveedor de modo que necesita clave y no la tiene vuelve a
///   `None`** (usa el general).
fn migrate_active_mode_to_mode_shortcuts(
    settings: &mut AppSettings,
    settings_value: &serde_json::Value,
) -> bool {
    let Some(selected) = settings_value.get(LEGACY_SELECTED_PROMPT_KEY) else {
        return false;
    };
    let mut updated = false;

    // --- Regla 2: los atajos que no pueden dispararse se borran ------------
    //
    // Un `f17` pelado en un teclado que emite `fn+f17` no dispara nunca, y la
    // app no sabe qué teclado hay: inventarle el `fn` sería otro atajo
    // fantasma. Los atajos generales son la única referencia confiable de lo
    // que emite este teclado, porque siempre se capturaron con el grabador
    // nativo (los de modo venían de eventos del navegador, que en macOS no ven
    // `fn` — ésa es la causa raíz). `cancel` queda fuera de la referencia: es
    // Escape a propósito, una tecla pelada de fábrica.
    let keyboard_uses_modifiers = {
        let reference: Vec<&str> = settings
            .bindings
            .iter()
            .filter(|(id, _)| id.as_str() != "cancel")
            .map(|(_, binding)| binding.current_binding.trim())
            .filter(|shortcut| !shortcut.is_empty())
            .collect();
        !reference.is_empty() && reference.iter().all(|shortcut| has_modifiers(shortcut))
    };
    if keyboard_uses_modifiers {
        for prompt in settings.post_process_prompts.iter_mut() {
            let shortcut = mode_shortcut(prompt);
            if !shortcut.is_empty() && !has_modifiers(shortcut) {
                warn!(
                    "El atajo '{}' del modo '{}' no puede dispararse con este teclado; el modo queda sin tecla",
                    shortcut, prompt.name
                );
                prompt.shortcut = None;
                updated = true;
            }
        }
    }

    // --- Regla 1: el modo activo hereda la tecla del atajo general ---------
    let general = settings
        .bindings
        .get(POST_PROCESS_BINDING_ID)
        .map(|binding| binding.current_binding.trim().to_string())
        .unwrap_or_default();
    if !general.is_empty() {
        // Heredar pide dos cosas: que hubiera un modo elegido y que el
        // post-proceso estuviera **encendido**. El desplegable de 0.2.2
        // persistía la selección con sólo abrir un prompt para editarlo, sin
        // encender nada; y los bindings `mode:<id>` no consultan
        // `post_process_enabled` (sólo lo hace el atajo general, por su id
        // literal). Sin esta condición, alguien con el post-proceso apagado se
        // despertaría con una tecla viva mandando sus dictados al LLM sin
        // haberlo pedido.
        if settings.post_process_enabled {
            if let Some(active_id) = selected.as_str().filter(|id| !id.is_empty()) {
                // Y una tercera: que esa combinación esté libre. Heredar una
                // tecla que **otro** modo ya tiene deja dos bindings sobre la
                // misma combinación, y las dos implementaciones de teclado
                // rechazan duplicados (`HotkeyAlreadyRegistered`): al arrancar,
                // `register_mode_shortcuts` sólo loguea un `warn!` y el segundo
                // del `Vec` queda mudo. Sería reintroducir por la migración el
                // mismo atajo fantasma que esta versión vino a matar.
                let combo = normalized_combo(&general);
                let ocupada_por_otro = settings.post_process_prompts.iter().any(|prompt| {
                    prompt.id != active_id && normalized_combo(mode_shortcut(prompt)) == combo
                });
                if let Some(prompt) = settings
                    .post_process_prompts
                    .iter_mut()
                    .find(|prompt| prompt.id == active_id)
                {
                    // Un modo que ya tenía su propia tecla se la queda: era una
                    // elección más explícita que la del desplegable.
                    if ocupada_por_otro {
                        warn!(
                            "El modo activo '{}' no hereda '{}': otro modo ya tiene esa tecla",
                            prompt.name, general
                        );
                    } else if mode_shortcut(prompt).is_empty() {
                        debug!(
                            "El modo activo '{}' hereda el atajo general '{}'",
                            prompt.name, general
                        );
                        prompt.shortcut = Some(general);
                    }
                }
            }
        }

        // La tecla se suelta **siempre**, haya heredero o no. Tras esta
        // migración el atajo general no puede hacer nada útil en ningún caso:
        // dispara el post-proceso sin ningún modo que aplicar, así que pega el
        // dictado crudo — una tecla que promete transformar y sólo duplica el
        // dictado. Por eso las instalaciones nuevas también lo traen vacío.
        if let Some(binding) = settings.bindings.get_mut(POST_PROCESS_BINDING_ID) {
            binding.current_binding = String::new();
            binding.default_binding = String::new();
        }
        updated = true;
    }

    // --- Regla 3: un proveedor de modo sin clave vuelve al general ---------
    //
    // Residuo del bug corregido en 0.2.2, donde elegir "Online" preseleccionaba
    // el primer proveedor del catálogo en vez del que la persona ya usaba.
    //
    // "Sin clave" no es lo mismo que "no es loopback": los proveedores locales
    // quedan fuera porque no llevan clave por diseño, y `custom` también —es el
    // endpoint que pone la persona, y un Ollama en la LAN
    // (`http://192.168.1.20:11434`) funciona sin clave aunque no sea loopback.
    // Confundirlos le borraría el proveedor al modo y mandaría sus dictados al
    // general, típicamente a la nube. Mismo criterio que
    // `fetch_post_process_models` en `shortcut/mod.rs`.
    let unusable: Vec<String> = settings
        .post_process_providers
        .iter()
        .filter(|provider| !provider_is_local(provider) && provider.id != CUSTOM_PROVIDER_ID)
        .filter(|provider| {
            settings
                .post_process_api_keys
                .get(&provider.id)
                .is_none_or(|key| key.trim().is_empty())
        })
        .map(|provider| provider.id.clone())
        .collect();
    for prompt in settings.post_process_prompts.iter_mut() {
        let orphan = prompt
            .provider_id
            .as_deref()
            .is_some_and(|id| unusable.iter().any(|unusable_id| unusable_id == id));
        if orphan {
            debug!(
                "El modo '{}' apuntaba a un proveedor sin clave; vuelve al general",
                prompt.name
            );
            prompt.provider_id = None;
            // Un modelo sin proveedor no significa nada (misma regla que
            // `apply_post_process_prompt_provider`).
            prompt.model = None;
            updated = true;
        }
    }

    updated
}

pub fn write_settings(app: &AppHandle, settings: AppSettings) {
    let store = app
        .store(crate::portable::store_path(SETTINGS_STORE_PATH))
        .expect("Failed to initialize store");

    store.set("settings", serde_json::to_value(&settings).unwrap());
}

pub fn get_bindings(app: &AppHandle) -> HashMap<String, ShortcutBinding> {
    let settings = get_settings(app);

    settings.bindings
}

pub fn get_stored_binding(app: &AppHandle, id: &str) -> ShortcutBinding {
    let bindings = get_bindings(app);

    let binding = bindings.get(id).unwrap().clone();

    binding
}

pub fn get_history_limit(app: &AppHandle) -> usize {
    let settings = get_settings(app);
    settings.history_limit
}

pub fn get_recording_retention_period(app: &AppHandle) -> RecordingRetentionPeriod {
    let settings = get_settings(app);
    settings.recording_retention_period
}

#[cfg(test)]
mod tests {
    use super::*;

    fn default_settings_json() -> serde_json::Value {
        serde_json::to_value(get_default_settings()).unwrap()
    }

    #[test]
    fn post_process_defaults_add_dilo_presets_without_removing_custom_prompts() {
        let mut settings = get_default_settings();
        settings.post_process_prompts = vec![LLMPrompt {
            id: "my-custom-prompt".to_string(),
            name: "My custom prompt".to_string(),
            prompt: "Keep this prompt".to_string(),
            shortcut: None,
            provider_id: None,
            model: None,
        }];

        assert!(ensure_post_process_defaults(&mut settings));

        let ids: std::collections::HashSet<&str> = settings
            .post_process_prompts
            .iter()
            .map(|prompt| prompt.id.as_str())
            .collect();
        assert!(ids.contains("my-custom-prompt"));
        for preset_id in [
            "dilo-clean",
            "dilo-prompt",
            "dilo-message",
            "dilo-email",
            "dilo-code",
        ] {
            assert!(ids.contains(preset_id), "missing preset {preset_id}");
        }
    }

    #[test]
    fn apple_intelligence_is_local_and_the_cloud_providers_are_not() {
        let providers = default_post_process_providers();
        let find = |id: &str| providers.iter().find(|p| p.id == id).cloned();

        #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
        {
            let apple =
                find(APPLE_INTELLIGENCE_PROVIDER_ID).expect("Apple Intelligence en el catálogo");
            assert!(
                provider_is_local(&apple),
                "corre en el chip, no sale del equipo"
            );
        }

        let openai = find("openai").expect("openai en el catálogo");
        assert!(!provider_is_local(&openai));
        let gemini = find("google").expect("google en el catálogo");
        assert!(!provider_is_local(&gemini));
    }

    #[test]
    fn custom_provider_is_local_only_while_it_points_at_this_machine() {
        let mut custom = default_post_process_providers()
            .into_iter()
            .find(|p| p.id == "custom")
            .expect("custom en el catálogo");

        // Viene apuntando a Ollama en la propia máquina.
        assert!(provider_is_local(&custom), "el default apunta a localhost");

        for url in [
            "http://127.0.0.1:1234/v1",
            "http://[::1]:11434/v1",
            "http://LOCALHOST:11434/v1",
        ] {
            custom.base_url = url.to_string();
            assert!(provider_is_local(&custom), "{url} es esta máquina");
        }

        // Si el usuario lo apunta afuera, deja de ser local solo.
        custom.base_url = "https://api.midominio.com/v1".to_string();
        assert!(
            !provider_is_local(&custom),
            "un servidor remoto no puede seguir diciendo LOCAL"
        );
    }

    // Regresión minor del review final: el literal de `custom` en
    // `default_post_process_providers()` traía `is_local: false` hardcodeado
    // aunque su `base_url` por defecto es `localhost`. `ensure_post_process_defaults`
    // lo recalcula al cargar settings existentes, pero una instalación nueva
    // usa el literal tal cual (ver `get_default_settings`), así que el campo
    // en sí tiene que nacer correcto, no sólo lo que calcula `provider_is_local`.
    #[test]
    fn fresh_install_custom_provider_field_is_already_local() {
        let custom = default_post_process_providers()
            .into_iter()
            .find(|p| p.id == "custom")
            .expect("custom en el catálogo");
        assert!(
            custom.is_local,
            "el campo is_local del literal debe nacer en true: el default apunta a localhost"
        );
    }

    #[test]
    fn loading_recomputes_is_local_for_a_settings_file_without_the_field() {
        let mut settings = get_default_settings();
        // Simula un settings.json de v0.1.13: el campo no existía.
        for provider in settings.post_process_providers.iter_mut() {
            provider.is_local = false;
        }
        settings
            .post_process_providers
            .iter_mut()
            .find(|p| p.id == "custom")
            .expect("custom")
            .base_url = "http://localhost:11434/v1".to_string();

        assert!(ensure_post_process_defaults(&mut settings));

        let custom = settings
            .post_process_providers
            .iter()
            .find(|p| p.id == "custom")
            .unwrap();
        assert!(custom.is_local, "apunta a esta máquina: es local");
    }

    /// Every field must survive a partial store: a missing key must never fail
    /// the whole-settings parse (#1619). `json!({})` is the extreme case.
    #[test]
    fn empty_store_parses_with_defaults() {
        let settings: AppSettings = serde_json::from_value(serde_json::json!({}))
            .expect("all AppSettings fields need serde defaults");
        assert!(settings.push_to_talk);
        assert!(!settings.audio_feedback);
        // Bindings default to empty; the load path merges the real defaults in.
        assert!(settings.bindings.is_empty());
    }

    /// Frozen snapshot of a real v0.9.0-era settings store, as written to
    /// disk. This pins backwards compatibility: it must always parse strictly
    /// (no salvage), and the only thing a migration may change in it is the
    /// retired post-processing shortcut.
    ///
    /// If a schema change breaks this test, do NOT just update the fixture —
    /// it stands in for the stores on users' machines. Add a
    /// `#[serde(alias)]`/`#[serde(other)]` or a one-time migration in
    /// `apply_settings_migrations` so old values keep loading, and only extend
    /// the fixture alongside that.
    ///
    /// `post_process_selected_prompt_id` stays in the fixture on purpose even
    /// though the field is gone: real stores still have it, and this pins that
    /// a store carrying it is neither rejected nor rewritten beyond that one
    /// shortcut (this one has no active mode, no mode shortcuts and no
    /// per-mode provider, and its `f13` binding says the keyboard emits bare
    /// function keys, so nothing else has anything to migrate).
    #[test]
    fn frozen_v0_9_store_parses_strictly_and_only_the_retired_shortcut_migrates() {
        // Note "log_level": 2 — the legacy numeric format, kept deliberately.
        let stored: serde_json::Value = serde_json::from_str(
            r##"{
            "settings_schema_version": 1,
            "bindings": {
                "transcribe": {
                    "id": "transcribe",
                    "name": "Transcribe",
                    "description": "Converts your speech into text.",
                    "default_binding": "option+space",
                    "current_binding": "f13"
                },
                "transcribe_with_post_process": {
                    "id": "transcribe_with_post_process",
                    "name": "Transcribe with Post-Processing",
                    "description": "Converts your speech into text and applies AI post-processing.",
                    "default_binding": "option+shift+space",
                    "current_binding": "option+shift+space"
                },
                "cancel": {
                    "id": "cancel",
                    "name": "Cancel",
                    "description": "Cancels the current recording.",
                    "default_binding": "escape",
                    "current_binding": "escape"
                }
            },
            "push_to_talk": false,
            "audio_feedback": true,
            "audio_feedback_volume": 0.8,
            "sound_theme": "pop",
            "start_hidden": false,
            "autostart_enabled": true,
            "update_checks_enabled": true,
            "show_whats_new_on_update": true,
            "whats_new_last_seen_version": "0.9.0",
            "selected_model": "whisper-large-v3-turbo",
            "onboarding_completed": true,
            "always_on_microphone": false,
            "selected_microphone": "MacBook Pro Microphone",
            "clamshell_microphone": null,
            "selected_output_device": null,
            "translate_to_english": false,
            "selected_language": "en",
            "overlay_position": "bottom",
            "debug_mode": false,
            "log_level": 2,
            "custom_words": ["Dilo", "cjpais"],
            "model_unload_timeout": "min5",
            "word_correction_threshold": 0.18,
            "history_limit": 5,
            "recording_retention_period": "preserve_limit",
            "paste_method": "ctrl_v",
            "clipboard_handling": "dont_modify",
            "auto_submit": false,
            "auto_submit_key": "enter",
            "post_process_enabled": false,
            "post_process_provider_id": "openai",
            "post_process_providers": [
                {
                    "id": "openai",
                    "label": "OpenAI",
                    "base_url": "https://api.openai.com/v1",
                    "allow_base_url_edit": false,
                    "models_endpoint": null,
                    "supports_structured_output": true
                }
            ],
            "post_process_api_keys": { "openai": "" },
            "post_process_models": { "openai": "gpt-4o-mini" },
            "post_process_prompts": [
                { "id": "default", "name": "Default", "prompt": "Clean up the transcript." }
            ],
            "post_process_selected_prompt_id": null,
            "mute_while_recording": false,
            "append_trailing_space": false,
            "app_language": "en",
            "experimental_enabled": false,
            "lazy_stream_close": false,
            "keyboard_implementation": "handy_keys",
            "show_tray_icon": true,
            "paste_delay_ms": 60,
            "typing_tool": "auto",
            "external_script_path": null,
            "custom_filler_words": null,
            "transcribe_accelerator": "gpu",
            "ort_accelerator": "auto",
            "transcribe_gpu_device": 0,
            "extra_recording_buffer_ms": 0,
            "vad_enabled": true,
            "overlay_style": "live"
        }"##,
        )
        .expect("fixture is valid JSON");

        let mut settings: AppSettings = serde_json::from_value(stored.clone())
            .expect("a stored v0.9.0 settings object must keep parsing strictly");

        assert_eq!(settings.selected_model, "whisper-large-v3-turbo");
        assert_eq!(settings.bindings["transcribe"].current_binding, "f13");
        assert_eq!(settings.log_level, LogLevel::Debug);
        assert_eq!(settings.sound_theme, SoundTheme::Pop);

        // Lo único que cambia: el atajo general de post-proceso suelta su
        // tecla, porque sin modo activo ya no puede aplicar ningún prompt.
        let mut expected = serde_json::to_value(&settings).unwrap();
        expected["bindings"][POST_PROCESS_BINDING_ID]["current_binding"] = serde_json::json!("");
        expected["bindings"][POST_PROCESS_BINDING_ID]["default_binding"] = serde_json::json!("");

        assert!(apply_settings_migrations(&mut settings, &stored));
        assert_eq!(
            serde_json::to_value(&settings).unwrap(),
            expected,
            "nada más de un store v0.9 se toca al migrar"
        );

        // Y esa reescritura pasa una sola vez: releído (ya sin la clave
        // retirada) el store no se vuelve a tocar.
        let rewritten = serde_json::to_value(&settings).unwrap();
        assert!(!apply_settings_migrations(&mut settings, &rewritten));
    }

    #[test]
    fn salvage_preserves_valid_fields_when_one_value_is_invalid() {
        let mut stored = default_settings_json();
        let map = stored.as_object_mut().unwrap();
        map.insert(
            "selected_model".into(),
            serde_json::json!("parakeet-tdt-0.6b-v3"),
        );
        map.insert("onboarding_completed".into(), serde_json::json!(true));
        // An enum variant this build doesn't know, e.g. written by a newer
        // version before a downgrade.
        map.insert("sound_theme".into(), serde_json::json!("theremin"));
        stored["bindings"]["transcribe"]["current_binding"] = serde_json::json!("f13");

        // Precondition: this is exactly the whole-store parse failure from
        // #1619 that used to reset everything to defaults.
        assert!(serde_json::from_value::<AppSettings>(stored.clone()).is_err());

        let salvaged = salvage_settings(&stored);
        assert_eq!(salvaged.selected_model, "parakeet-tdt-0.6b-v3");
        assert!(salvaged.onboarding_completed);
        assert_eq!(salvaged.bindings["transcribe"].current_binding, "f13");
        assert_eq!(salvaged.sound_theme, default_sound_theme());
    }

    #[test]
    fn salvage_drops_only_wrong_typed_fields() {
        let mut stored = default_settings_json();
        let map = stored.as_object_mut().unwrap();
        map.insert("paste_delay_ms".into(), serde_json::json!("sixty"));
        map.insert("sound_theme".into(), serde_json::json!(42));
        map.insert("custom_words".into(), serde_json::json!(["handy"]));

        assert!(serde_json::from_value::<AppSettings>(stored.clone()).is_err());

        let salvaged = salvage_settings(&stored);
        assert_eq!(salvaged.paste_delay_ms, default_paste_delay_ms());
        assert_eq!(salvaged.sound_theme, default_sound_theme());
        assert_eq!(salvaged.custom_words, vec!["handy".to_string()]);
    }

    #[test]
    fn salvage_of_poisoned_bindings_keeps_other_fields() {
        let mut stored = default_settings_json();
        let map = stored.as_object_mut().unwrap();
        // One malformed entry poisons the whole bindings map, but must not
        // take the rest of the settings down with it.
        map.insert(
            "bindings".into(),
            serde_json::json!({ "transcribe": { "id": 42 } }),
        );
        map.insert("selected_model".into(), serde_json::json!("whisper-small"));

        assert!(serde_json::from_value::<AppSettings>(stored.clone()).is_err());

        let salvaged = salvage_settings(&stored);
        assert_eq!(salvaged.selected_model, "whisper-small");
        let defaults = get_default_settings();
        assert_eq!(
            salvaged.bindings["transcribe"].current_binding,
            defaults.bindings["transcribe"].current_binding
        );
    }

    #[test]
    fn salvage_tolerates_unknown_keys() {
        let mut stored = default_settings_json();
        let map = stored.as_object_mut().unwrap();
        map.insert(
            "field_from_the_future".into(),
            serde_json::json!({ "nested": true }),
        );
        map.insert("selected_model".into(), serde_json::json!("kept"));
        map.insert("sound_theme".into(), serde_json::json!("theremin"));

        let salvaged = salvage_settings(&stored);
        assert_eq!(salvaged.selected_model, "kept");
        assert_eq!(salvaged.sound_theme, default_sound_theme());
    }

    #[test]
    fn salvage_of_non_object_store_falls_back_to_defaults() {
        for stored in [
            serde_json::json!("corrupt"),
            serde_json::json!(null),
            serde_json::json!([1, 2, 3]),
        ] {
            let salvaged = salvage_settings(&stored);
            assert_eq!(
                serde_json::to_value(&salvaged).unwrap(),
                default_settings_json()
            );
        }
    }

    #[test]
    fn default_settings_disable_auto_submit() {
        let settings = get_default_settings();
        assert!(!settings.auto_submit);
        assert_eq!(settings.auto_submit_key, AutoSubmitKey::Enter);
        assert_eq!(
            settings.settings_schema_version,
            CURRENT_SETTINGS_SCHEMA_VERSION
        );
    }

    #[cfg(not(target_os = "linux"))]
    #[test]
    fn default_overlay_style_is_minimal_when_overlay_defaults_on() {
        let settings = get_default_settings();
        assert_eq!(settings.overlay_style, OverlayStyle::Minimal);
    }

    #[test]
    fn overlay_migration_keeps_disabled_overlay_off() {
        let mut settings = get_default_settings();

        // Legacy store: overlay was hidden via the retired position "none".
        let raw = serde_json::json!({
            "selected_model": "",
            "overlay_position": "none"
        });

        assert!(apply_settings_migrations(&mut settings, &raw));
        assert_eq!(settings.overlay_style, OverlayStyle::None);
    }

    #[test]
    fn legacy_none_overlay_position_deserializes_to_bottom() {
        // A persisted "none" must not fail the whole settings load; the serde
        // alias folds it onto Bottom (visibility is owned by overlay_style).
        let raw = serde_json::json!({ "overlay_position": "none" });
        let position: OverlayPosition =
            serde_json::from_value(raw.get("overlay_position").unwrap().clone())
                .expect("legacy \"none\" should deserialize, not error");
        assert_eq!(position, OverlayPosition::Bottom);
    }

    #[test]
    fn overlay_migration_promotes_enabled_overlay_to_live() {
        let mut settings = get_default_settings();
        settings.overlay_position = OverlayPosition::Top;
        settings.overlay_style = OverlayStyle::Minimal;

        let raw = serde_json::json!({
            "selected_model": "",
            "overlay_position": "top"
        });

        assert!(apply_settings_migrations(&mut settings, &raw));
        assert_eq!(settings.overlay_style, OverlayStyle::Live);
        assert_eq!(settings.overlay_position, OverlayPosition::Top);
    }

    #[test]
    fn gpu_device_migration_resets_legacy_positive_selection_to_auto() {
        let mut settings = get_default_settings();
        settings.transcribe_accelerator = TranscribeAcceleratorSetting::Gpu;
        settings.transcribe_gpu_device = 2;

        let raw = serde_json::json!({
            "transcribe_accelerator": "gpu",
            "transcribe_gpu_device": 2
        });

        assert!(apply_settings_migrations(&mut settings, &raw));
        assert_eq!(
            settings.transcribe_accelerator,
            TranscribeAcceleratorSetting::Auto
        );
        assert_eq!(
            settings.transcribe_gpu_device,
            default_transcribe_gpu_device()
        );
        assert_eq!(
            settings.settings_schema_version,
            CURRENT_SETTINGS_SCHEMA_VERSION
        );
    }

    #[test]
    fn gpu_device_migration_keeps_current_schema_positive_selection() {
        let mut settings = get_default_settings();
        settings.transcribe_accelerator = TranscribeAcceleratorSetting::Gpu;
        settings.transcribe_gpu_device = 2;

        let raw = serde_json::json!({
            "settings_schema_version": CURRENT_SETTINGS_SCHEMA_VERSION,
            "onboarding_completed": false,
            "whats_new_last_seen_version": default_whats_new_last_seen_version(),
            "overlay_style": "live",
            "transcribe_accelerator": "gpu",
            "transcribe_gpu_device": 2
        });

        assert!(!apply_settings_migrations(&mut settings, &raw));
        assert_eq!(
            settings.transcribe_accelerator,
            TranscribeAcceleratorSetting::Gpu
        );
        assert_eq!(settings.transcribe_gpu_device, 2);
    }

    #[test]
    fn debug_output_redacts_api_keys() {
        let mut settings = get_default_settings();
        settings
            .post_process_api_keys
            .insert("openai".to_string(), "sk-proj-secret-key-12345".to_string());
        settings.post_process_api_keys.insert(
            "anthropic".to_string(),
            "sk-ant-secret-key-67890".to_string(),
        );
        settings
            .post_process_api_keys
            .insert("empty_provider".to_string(), "".to_string());

        let debug_output = format!("{:?}", settings);

        assert!(!debug_output.contains("sk-proj-secret-key-12345"));
        assert!(!debug_output.contains("sk-ant-secret-key-67890"));
        assert!(debug_output.contains("[REDACTED]"));
    }

    #[test]
    fn llm_prompt_shortcut_defaults_to_none_and_roundtrips() {
        let p: LLMPrompt = serde_json::from_value(serde_json::json!({
            "id": "x", "name": "X", "prompt": "haz X"
        }))
        .expect("prompt viejo sin shortcut debe deserializar");
        assert!(p.shortcut.is_none());

        let p2 = LLMPrompt {
            id: "y".into(),
            name: "Y".into(),
            prompt: "haz Y".into(),
            shortcut: Some("ctrl+alt+y".into()),
            provider_id: None,
            model: None,
        };
        let back: LLMPrompt = serde_json::from_value(serde_json::to_value(&p2).unwrap()).unwrap();
        assert_eq!(back.shortcut.as_deref(), Some("ctrl+alt+y"));
    }

    #[test]
    fn notes_settings_default_and_roundtrip() {
        let s = get_default_settings();
        assert!(s.notes_folder.is_none());
        assert!(!s.notes_apple_enabled);
        assert_eq!(s.notes_apple_folder, "Dilo");
        assert!(!s.notes_notion_enabled);
        assert!(s.notes_pending.is_empty());
        assert_eq!(s.bindings["quick_note"].current_binding, "");

        let json = serde_json::to_value(&s).unwrap();
        let back: AppSettings = serde_json::from_value(json).unwrap();
        assert_eq!(back.notes_apple_folder, "Dilo");
    }

    #[test]
    fn tts_settings_default_and_roundtrip() {
        let s = get_default_settings();
        assert_eq!(s.tts_engine, TtsEngineSetting::Supertonic);
        assert_eq!(s.tts_voice, "F5");

        let json = serde_json::to_value(&s).unwrap();
        let back: AppSettings = serde_json::from_value(json).unwrap();
        assert_eq!(back.tts_voice, "F5");
        assert_eq!(back.tts_engine, TtsEngineSetting::Supertonic);
    }

    #[test]
    fn tts_settings_missing_from_a_stored_object_fall_back_to_defaults() {
        // A store saved before this feature existed simply lacks these keys —
        // the struct-level `#[serde(default)]` must fill them in without
        // touching `apply_settings_migrations` (no one-time migration needed,
        // unlike the schema-version / onboarding cases above).
        let mut stored = default_settings_json();
        stored
            .as_object_mut()
            .unwrap()
            .remove("tts_engine")
            .expect("fixture should have the key to remove");
        stored.as_object_mut().unwrap().remove("tts_voice");

        let settings: AppSettings = serde_json::from_value(stored)
            .expect("missing tts_* keys must not fail the whole parse");
        assert_eq!(settings.tts_engine, TtsEngineSetting::Supertonic);
        assert_eq!(settings.tts_voice, "F5");
    }

    #[test]
    fn voice_assistant_defaults_off_with_empty_shortcut() {
        let s = get_default_settings();
        assert!(!s.voice_assistant_enabled);
        assert_eq!(s.bindings["voice_assistant"].current_binding, "");

        let json = serde_json::to_value(&s).unwrap();
        let back: AppSettings = serde_json::from_value(json).unwrap();
        assert!(!back.voice_assistant_enabled);
    }

    #[test]
    fn voice_assistant_enabled_missing_from_a_stored_object_falls_back_to_default() {
        // Igual que con tts_engine/tts_voice: un store guardado antes de que
        // este campo existiera simplemente no lo trae — el `#[serde(default)]`
        // a nivel de struct debe llenarlo sin fallar el parse completo.
        let mut stored = default_settings_json();
        stored
            .as_object_mut()
            .unwrap()
            .remove("voice_assistant_enabled")
            .expect("fixture should have the key to remove");

        let settings: AppSettings = serde_json::from_value(stored)
            .expect("missing voice_assistant_enabled must not fail the whole parse");
        assert!(!settings.voice_assistant_enabled);
    }

    #[test]
    fn secret_map_debug_redacts_values() {
        let map = SecretMap(HashMap::from([("key".into(), "secret".into())]));
        let out = format!("{:?}", map);
        assert!(!out.contains("secret"));
        assert!(out.contains("[REDACTED]"));
    }

    fn settings_with_mode(provider_id: Option<&str>, model: Option<&str>) -> AppSettings {
        let mut settings = get_default_settings();
        settings.post_process_provider_id = "openai".to_string();
        settings
            .post_process_models
            .insert("openai".to_string(), "gpt-4o-mini".to_string());
        settings
            .post_process_models
            .insert("google".to_string(), "gemini-2.5-flash".to_string());
        let prompt = settings
            .post_process_prompts
            .iter_mut()
            .find(|p| p.id == "dilo-code")
            .expect("el modo Código viene de fábrica");
        prompt.provider_id = provider_id.map(str::to_string);
        prompt.model = model.map(str::to_string);
        settings
    }

    fn code_mode(settings: &AppSettings) -> LLMPrompt {
        settings
            .post_process_prompts
            .iter()
            .find(|p| p.id == "dilo-code")
            .cloned()
            .unwrap()
    }

    #[test]
    fn a_mode_without_its_own_provider_inherits_the_global_one() {
        let settings = settings_with_mode(None, None);
        let resolved = resolve_mode_provider(&settings, &code_mode(&settings)).expect("resuelve");

        assert_eq!(resolved.provider.id, "openai");
        assert_eq!(resolved.model, "gpt-4o-mini");
        assert!(
            resolved.inherited,
            "hereda: la UI lo muestra como 'General'"
        );
    }

    #[test]
    fn a_mode_with_its_own_provider_uses_it() {
        let settings = settings_with_mode(Some("google"), Some("gemini-2.5-pro"));
        let resolved = resolve_mode_provider(&settings, &code_mode(&settings)).expect("resuelve");

        assert_eq!(resolved.provider.id, "google");
        assert_eq!(resolved.model, "gemini-2.5-pro", "el modelo del modo manda");
        assert!(!resolved.inherited);
        assert!(!resolved.is_local);
    }

    #[test]
    fn a_mode_without_its_own_model_falls_back_to_the_provider_default_model() {
        let settings = settings_with_mode(Some("google"), None);
        let resolved = resolve_mode_provider(&settings, &code_mode(&settings)).expect("resuelve");

        assert_eq!(resolved.provider.id, "google");
        assert_eq!(
            resolved.model, "gemini-2.5-flash",
            "sin modelo propio usa el que ya está configurado para ese proveedor"
        );
    }

    #[test]
    fn a_mode_pointing_at_a_deleted_provider_falls_back_to_the_global_one() {
        let settings = settings_with_mode(Some("proveedor-que-el-usuario-borro"), None);
        let resolved = resolve_mode_provider(&settings, &code_mode(&settings)).expect("resuelve");

        assert_eq!(
            resolved.provider.id, "openai",
            "configuración vieja no es una falla: se usa el general en silencio"
        );
        assert!(resolved.inherited);
    }

    #[test]
    fn a_provider_without_any_model_configured_does_not_resolve() {
        let mut settings = settings_with_mode(Some("anthropic"), None);
        settings.post_process_models.remove("anthropic");
        assert!(
            resolve_mode_provider(&settings, &code_mode(&settings)).is_none(),
            "sin modelo no hay a qué llamar: cuenta como no disponible"
        );
    }

    // ---------------------------------------------------------------------
    // Migración del "modo activo" (0.2.2 → un atajo por modo)
    // ---------------------------------------------------------------------

    /// Un `settings.json` con la forma que dejó la 0.2.2: el modo activo
    /// existe como clave, el post-proceso está encendido, los atajos generales
    /// salieron del grabador nativo (por eso traen `fn`) y los modos tienen los
    /// suyos. Cada test ajusta sólo lo que le toca probar.
    fn store_with_active_mode() -> serde_json::Value {
        let mut stored = default_settings_json();
        {
            let map = stored.as_object_mut().unwrap();
            map.insert("post_process_enabled".into(), serde_json::json!(true));
            map.insert(
                "post_process_selected_prompt_id".into(),
                serde_json::Value::Null,
            );
            map.insert(
                "post_process_prompts".into(),
                serde_json::json!([
                    {
                        "id": "dilo-clean",
                        "name": "Limpio",
                        "prompt": "Limpia esta transcripción.",
                        "shortcut": null,
                        "provider_id": null,
                        "model": null
                    },
                    {
                        "id": "dilo-email",
                        "name": "Correo",
                        "prompt": "Escribe esto como correo.",
                        "shortcut": null,
                        "provider_id": null,
                        "model": null
                    }
                ]),
            );
            map.insert(
                "post_process_api_keys".into(),
                serde_json::json!({ "openai": "", "groq": "gsk-la-que-sí-puso", "custom": "" }),
            );
        }
        stored["bindings"]["transcribe"]["current_binding"] = serde_json::json!("fn+f19");
        stored["bindings"]["transcribe_with_post_process"]["current_binding"] =
            serde_json::json!("fn+f17");
        stored
    }

    fn migrated(stored: &serde_json::Value) -> (AppSettings, bool) {
        let mut settings: AppSettings = serde_json::from_value(stored.clone())
            .expect("un settings.json de 0.2.2 tiene que seguir parseando");
        let updated = apply_settings_migrations(&mut settings, stored);
        (settings, updated)
    }

    fn mode<'a>(settings: &'a AppSettings, id: &str) -> &'a LLMPrompt {
        settings
            .post_process_prompts
            .iter()
            .find(|prompt| prompt.id == id)
            .unwrap_or_else(|| panic!("el modo '{id}' sigue en la lista"))
    }

    #[test]
    fn el_modo_activo_hereda_el_atajo_general() {
        let mut stored = store_with_active_mode();
        stored["post_process_selected_prompt_id"] = serde_json::json!("dilo-email");

        let (settings, updated) = migrated(&stored);

        assert!(updated, "la migración reescribe el store una vez");
        assert_eq!(
            mode(&settings, "dilo-email").shortcut.as_deref(),
            Some("fn+f17"),
            "la elección de la persona sobrevive como la tecla del modo"
        );
        // La tecla se muda, no se copia: si el atajo general se quedara con
        // ella, las dos se registrarían sobre la misma combinación y el modo
        // volvería a ser un atajo fantasma.
        assert_eq!(
            settings.bindings["transcribe_with_post_process"].current_binding, "",
            "el atajo general suelta la tecla que entregó"
        );
        assert_eq!(
            mode(&settings, "dilo-clean").shortcut,
            None,
            "los demás modos no heredan nada"
        );
    }

    #[test]
    fn el_modo_activo_con_un_atajo_muerto_igual_hereda_el_general() {
        // El store real que motivó todo el trabajo, y la intersección que no
        // cubría ningún test: modo activo `dilo-email` **con** un `f17` pelado
        // guardado (que este teclado no dispara) y el general en `fn+f17`.
        //
        // Es lo único que fija el orden regla 2 → regla 1. Al revés, el `f17`
        // muerto contaría como "ya tenía tecla propia", bloquearía la herencia
        // y recién después se borraría: el dueño se despertaría con el modo
        // que usaba todos los días sin ninguna tecla.
        let mut stored = store_with_active_mode();
        stored["post_process_selected_prompt_id"] = serde_json::json!("dilo-email");
        stored["post_process_prompts"][1]["shortcut"] = serde_json::json!("f17");

        let (settings, updated) = migrated(&stored);

        assert!(updated);
        assert_eq!(
            mode(&settings, "dilo-email").shortcut.as_deref(),
            Some("fn+f17"),
            "primero se borra el atajo que no dispara, después se hereda el general"
        );
        assert_eq!(
            settings.bindings["transcribe_with_post_process"].current_binding, "",
            "y el general suelta la tecla que entregó"
        );
    }

    #[test]
    fn el_modo_activo_no_hereda_una_tecla_que_otro_modo_ya_tiene() {
        // Heredar acá dejaría dos modos en `fn+f17`. Las dos implementaciones
        // de teclado rechazan duplicados y `register_mode_shortcuts` sólo hace
        // `warn!`: uno de los dos arranca mudo, en silencio.
        let mut stored = store_with_active_mode();
        stored["post_process_selected_prompt_id"] = serde_json::json!("dilo-email");
        stored["post_process_prompts"][0]["shortcut"] = serde_json::json!("fn+f17");

        let (settings, _) = migrated(&stored);

        assert_eq!(
            mode(&settings, "dilo-clean").shortcut.as_deref(),
            Some("fn+f17"),
            "el modo que ya tenía la tecla se la queda"
        );
        assert_eq!(
            mode(&settings, "dilo-email").shortcut,
            None,
            "el heredero se queda sin tecla antes que dejar dos modos mudos a medias"
        );
        assert_eq!(
            settings.bindings["transcribe_with_post_process"].current_binding, "",
            "el general suelta la tecla igual: ya no puede aplicar ningún modo"
        );
    }

    #[test]
    fn la_tecla_ocupada_se_detecta_aunque_este_escrita_distinto() {
        // El choque no siempre es literal: `Fn + F17` y `fn+f17` son la misma
        // tecla, y compararlas como strings crudos diría que está libre.
        let mut stored = store_with_active_mode();
        stored["post_process_selected_prompt_id"] = serde_json::json!("dilo-email");
        stored["post_process_prompts"][0]["shortcut"] = serde_json::json!("F17 + Fn");

        let (settings, _) = migrated(&stored);

        assert_eq!(
            mode(&settings, "dilo-email").shortcut,
            None,
            "el orden y las mayúsculas no hacen que la tecla esté libre"
        );
    }

    #[test]
    fn el_modo_activo_no_hereda_si_el_post_proceso_estaba_apagado() {
        let mut stored = store_with_active_mode();
        stored["post_process_selected_prompt_id"] = serde_json::json!("dilo-email");
        // El desplegable de 0.2.2 persistía la selección con sólo abrir un
        // prompt para editarlo, sin encender nada.
        stored["post_process_enabled"] = serde_json::json!(false);

        let (settings, _) = migrated(&stored);

        assert_eq!(
            mode(&settings, "dilo-email").shortcut,
            None,
            "heredar acá dejaría una tecla viva mandando dictados al LLM sin haberlo pedido"
        );
        assert_eq!(
            settings.bindings["transcribe_with_post_process"].current_binding, "",
            "y la tecla igual se suelta: ya no puede aplicar ningún prompt"
        );
    }

    #[test]
    fn el_atajo_general_suelta_la_tecla_aunque_nadie_la_herede() {
        // Modo activo que apunta a un prompt que la persona borró. Lo mismo da
        // `null` o un modo que ya tenía tecla propia: en los tres casos el
        // atajo general se quedaría disparando post-proceso sin ningún prompt
        // que aplicar, o sea pegando el dictado crudo.
        let mut stored = store_with_active_mode();
        stored["post_process_selected_prompt_id"] = serde_json::json!("un-modo-que-ya-no-existe");

        let (settings, updated) = migrated(&stored);

        assert!(updated);
        assert_eq!(
            settings.bindings["transcribe_with_post_process"].current_binding, "",
            "una tecla que no puede hacer nada útil no se deja puesta"
        );
        assert!(
            settings
                .post_process_prompts
                .iter()
                .all(|prompt| prompt.shortcut.is_none()),
            "y no se le regala a nadie"
        );
    }

    #[test]
    fn un_atajo_sin_modificadores_se_borra_si_el_resto_los_tiene() {
        let mut stored = store_with_active_mode();
        // El caso del dueño: el teclado emite `fn+f17`, así que un `f17`
        // pelado guardado por la captura vieja no dispara nunca.
        stored["post_process_prompts"][1]["shortcut"] = serde_json::json!("f17");
        stored["post_process_prompts"][0]["shortcut"] = serde_json::json!("fn+f15");

        let (settings, updated) = migrated(&stored);

        assert!(updated);
        assert_eq!(
            mode(&settings, "dilo-email").shortcut,
            None,
            "el atajo que no puede dispararse se borra, no se adivina"
        );
        assert_eq!(
            mode(&settings, "dilo-clean").shortcut.as_deref(),
            Some("fn+f15"),
            "un atajo que sí puede dispararse no se toca"
        );
    }

    #[test]
    fn un_atajo_sin_modificadores_se_queda_si_los_generales_tampoco_los_tienen() {
        let mut stored = store_with_active_mode();
        // Teclado que emite las teclas de función peladas: acá `f17` sí
        // dispara, y borrarlo sería quitarle una tecla que le funciona.
        stored["bindings"]["transcribe"]["current_binding"] = serde_json::json!("f13");
        stored["bindings"]["transcribe_with_post_process"]["current_binding"] =
            serde_json::json!("f14");
        stored["post_process_prompts"][1]["shortcut"] = serde_json::json!("f17");

        let (settings, _) = migrated(&stored);

        assert_eq!(
            mode(&settings, "dilo-email").shortcut.as_deref(),
            Some("f17")
        );
    }

    #[test]
    fn un_teclado_mixto_no_borra_ningun_atajo_de_modo() {
        // El caso que separa "todos los generales llevan modificador" de
        // "alguno lo lleva": `transcribe` pelado y el de post-proceso con
        // modificadores. Acá la referencia no dice nada sobre qué emite el
        // teclado —hay evidencia de las dos cosas—, así que se elige lo
        // conservador: no borrar. Borrar con esta evidencia le sacaría al
        // usuario una tecla que puede estarle funcionando.
        let mut stored = store_with_active_mode();
        stored["bindings"]["transcribe"]["current_binding"] = serde_json::json!("f13");
        stored["bindings"]["transcribe_with_post_process"]["current_binding"] =
            serde_json::json!("option+shift+space");
        stored["post_process_prompts"][1]["shortcut"] = serde_json::json!("f17");

        let (settings, _) = migrated(&stored);

        assert_eq!(
            mode(&settings, "dilo-email").shortcut.as_deref(),
            Some("f17"),
            "con evidencia mixta no se borra: hace falta que TODOS los generales lleven modificador"
        );
    }

    #[test]
    fn un_proveedor_de_modo_sin_clave_vuelve_al_general() {
        let mut stored = store_with_active_mode();
        stored["post_process_prompts"][1]["provider_id"] = serde_json::json!("openai");
        stored["post_process_prompts"][1]["model"] = serde_json::json!("gpt-4o-mini");
        stored["post_process_prompts"][0]["provider_id"] = serde_json::json!("groq");
        stored["post_process_prompts"][0]["model"] = serde_json::json!("llama-3.3-70b");

        let (settings, updated) = migrated(&stored);

        assert!(updated);
        let email = mode(&settings, "dilo-email");
        assert_eq!(
            email.provider_id, None,
            "residuo del bug de la 0.2.2: sin clave no puede llamar a nadie"
        );
        assert_eq!(
            email.model, None,
            "un modelo sin proveedor no significa nada"
        );
        let clean = mode(&settings, "dilo-clean");
        assert_eq!(
            clean.provider_id.as_deref(),
            Some("groq"),
            "el proveedor que sí tiene clave se queda"
        );
        assert_eq!(clean.model.as_deref(), Some("llama-3.3-70b"));
    }

    #[test]
    fn un_proveedor_local_de_modo_se_queda_aunque_no_tenga_clave() {
        let mut stored = store_with_active_mode();
        // `custom` apunta a Ollama en localhost: no lleva clave por diseño.
        stored["post_process_prompts"][1]["provider_id"] = serde_json::json!("custom");

        let (settings, _) = migrated(&stored);

        assert_eq!(
            mode(&settings, "dilo-email").provider_id.as_deref(),
            Some("custom")
        );
    }

    #[test]
    fn un_custom_en_la_red_local_se_queda_aunque_no_sea_loopback() {
        let mut stored = store_with_active_mode();
        // Ollama en otra máquina de la casa: no es loopback, no lleva clave, y
        // borrarle el proveedor al modo mandaría sus dictados al general —
        // típicamente a la nube, sin avisar.
        for provider in stored["post_process_providers"].as_array_mut().unwrap() {
            if provider["id"] == serde_json::json!("custom") {
                provider["base_url"] = serde_json::json!("http://192.168.1.20:11434/v1");
                provider["is_local"] = serde_json::json!(false);
            }
        }
        stored["post_process_prompts"][1]["provider_id"] = serde_json::json!("custom");
        stored["post_process_prompts"][1]["model"] = serde_json::json!("qwen3:8b");

        let (settings, _) = migrated(&stored);

        let email = mode(&settings, "dilo-email");
        assert_eq!(
            email.provider_id.as_deref(),
            Some("custom"),
            "'no es loopback' no significa 'necesita clave'"
        );
        assert_eq!(email.model.as_deref(), Some("qwen3:8b"));
    }

    #[test]
    fn instalacion_nueva_trae_limpio_en_fn_f17() {
        let settings = AppSettings::default();

        let clean = mode(&settings, "dilo-clean");
        assert_eq!(
            clean.shortcut.as_deref(),
            Some("fn+F17"),
            "una instalación nueva tiene algo funcionando de inmediato"
        );
        assert!(
            settings
                .post_process_prompts
                .iter()
                .filter(|prompt| prompt.id != "dilo-clean")
                .all(|prompt| prompt.shortcut.is_none()),
            "los demás modos llegan sin tecla; cada persona asigna las que quiera"
        );
        assert_eq!(
            settings.bindings["transcribe_with_post_process"].current_binding, "",
            "sin modo activo el atajo general no tiene qué prompt aplicar"
        );
    }
}
