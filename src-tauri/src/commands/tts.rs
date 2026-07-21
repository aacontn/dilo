//! Comandos Tauri de la voz de salida — capa fina sobre `crate::tts`.
//!
//! Nuevo, propio de Dilo (no existe en Handy/upstream). Ver
//! `docs/plans/dilo-v2-voz.md` (Command Center) para el diseño completo.

use crate::settings::{get_settings, write_settings};
use crate::tts::supertonic::{self, SupertonicEngine};
use crate::tts::{self, VoiceGender, VoiceId};
use cpal::traits::{DeviceTrait, HostTrait};
use serde::Serialize;
use specta::Type;
use std::path::PathBuf;
use std::sync::Arc;
use tauri::{AppHandle, Manager};

#[derive(Serialize, Clone, Copy, Debug, PartialEq, Eq, Type)]
#[serde(rename_all = "snake_case")]
pub enum TtsVoiceGender {
    Female,
    Male,
}

impl From<VoiceGender> for TtsVoiceGender {
    fn from(g: VoiceGender) -> Self {
        match g {
            VoiceGender::Female => TtsVoiceGender::Female,
            VoiceGender::Male => TtsVoiceGender::Male,
        }
    }
}

#[derive(Serialize, Clone, Debug, Type)]
pub struct TtsVoiceInfo {
    pub id: String,
    pub name: String,
    pub gender: TtsVoiceGender,
}

/// Las 10 voces disponibles, sin necesitar el motor cargado — la UI puede
/// mostrar el selector antes de sintetizar nada.
#[tauri::command]
#[specta::specta]
pub fn tts_list_voices() -> Vec<TtsVoiceInfo> {
    supertonic::voice_catalog()
        .into_iter()
        .map(|v| TtsVoiceInfo {
            id: v.id.0,
            name: v.name,
            gender: v.gender.into(),
        })
        .collect()
}

#[derive(Serialize, Clone, Debug, Type)]
pub struct TtsWeightsStatus {
    /// Si los pesos están listos para sintetizar (en disco, o el desarrollo
    /// apunta a una copia local vía `DILO_SUPERTONIC_MODELS_DIR`).
    pub downloaded: bool,
    /// `true` cuando `DILO_SUPERTONIC_MODELS_DIR` está fijada — solo pensada
    /// para desarrollo local, nunca se persiste en settings.
    pub dev_override: bool,
    pub license_url: String,
}

/// Directorio raíz de modelos de la app (`<app_data>/models`), mismo patrón
/// que `ModelManager` (ver `managers/model.rs`).
fn models_root_dir(app: &AppHandle) -> Result<PathBuf, String> {
    crate::portable::app_data_dir(app)
        .map(|dir| dir.join("models"))
        .map_err(|e| format!("no se pudo resolver el directorio de datos: {e}"))
}

/// Resuelve dónde están (o deberían estar) los pesos de Supertonic:
/// `DILO_SUPERTONIC_MODELS_DIR` para desarrollo (apunta directo a un
/// directorio con `onnx/` y `voice_styles/`, sin pasar por la caché
/// gestionada) o `<app_data>/models/tts/supertonic-3` para el resto.
fn resolve_weights_paths(app: &AppHandle) -> Result<(PathBuf, PathBuf), String> {
    if let Ok(dir) = std::env::var("DILO_SUPERTONIC_MODELS_DIR") {
        let base = PathBuf::from(dir);
        return Ok((base.join("onnx"), base.join("voice_styles")));
    }

    let models_root = models_root_dir(app)?;
    if !supertonic::is_downloaded(&models_root) {
        return Err(
            "Los pesos de voz todavía no están descargados. Ve a Ajustes > Voz y descárgalos."
                .to_string(),
        );
    }
    let weights = supertonic::weights_dir(&models_root);
    Ok((weights.join("onnx"), weights.join("voice_styles")))
}

#[tauri::command]
#[specta::specta]
pub fn tts_weights_status(app: AppHandle) -> Result<TtsWeightsStatus, String> {
    if std::env::var("DILO_SUPERTONIC_MODELS_DIR").is_ok() {
        return Ok(TtsWeightsStatus {
            downloaded: true,
            dev_override: true,
            license_url: supertonic::LICENSE_NOTICE_SOURCE_URL.to_string(),
        });
    }

    let models_root = models_root_dir(&app)?;
    Ok(TtsWeightsStatus {
        downloaded: supertonic::is_downloaded(&models_root),
        dev_override: false,
        license_url: supertonic::LICENSE_NOTICE_SOURCE_URL.to_string(),
    })
}

/// Texto del LICENSE OpenRAIL-M en la revisión pineada, para que el diálogo
/// de la UI muestre la copia real (restricciones incluidas) antes de que el
/// usuario acepte descargar.
#[tauri::command]
#[specta::specta]
pub async fn tts_license_text() -> Result<String, String> {
    supertonic::license_text().await.map_err(|e| e.to_string())
}

/// Descarga los pesos desde Hugging Face. `license_accepted` viene del
/// diálogo que muestra la licencia (`tts_license_text`): el frontend solo
/// puede mandar `true` después de que el usuario apretó "Aceptar" con el
/// texto a la vista. El gate real vive en
/// `tts::supertonic::ensure_weights_downloaded`, que rechaza sin él — acá
/// ya no se hardcodea `true` por nadie.
#[tauri::command]
#[specta::specta]
pub async fn tts_download_weights(app: AppHandle, license_accepted: bool) -> Result<(), String> {
    if std::env::var("DILO_SUPERTONIC_MODELS_DIR").is_ok() {
        // El desarrollo ya apunta a una copia local; no hay nada que bajar.
        return Ok(());
    }
    let models_root = models_root_dir(&app)?;
    supertonic::ensure_weights_downloaded(&models_root, license_accepted)
        .await
        .map_err(|e| e.to_string())
}

/// Motor activo cacheado en `TtsState` o recién cargado desde disco. Cargar
/// el motor es CPU-bound (~0,6 s, 4 sesiones ONNX) — se hace en
/// `spawn_blocking`, nunca en el hilo async.
async fn get_or_load_engine(app: &AppHandle) -> Result<Arc<SupertonicEngine>, String> {
    let state = app.state::<tts::TtsState>();
    if let Some(engine) = state.engine.lock().unwrap().clone() {
        return Ok(engine);
    }

    let (onnx_dir, voice_styles_dir) = resolve_weights_paths(app)?;
    let engine =
        tokio::task::spawn_blocking(move || SupertonicEngine::load(&onnx_dir, &voice_styles_dir))
            .await
            .map_err(|e| format!("la carga del motor de voz se interrumpió: {e}"))?
            .map_err(|e| format!("no se pudo cargar el motor de voz: {e}"))?;
    let engine = Arc::new(engine);

    *state.engine.lock().unwrap() = Some(engine.clone());
    Ok(engine)
}

/// Abre el stream de salida de audio según `selected_output_device` (mismo
/// dispositivo elegido en Ajustes > Sonido) — puerto minimalista de la
/// resolución de dispositivo que ya usa `audio_feedback::play_audio_file`,
/// sin tocar ese archivo (aditivo, propio de este comando).
fn open_output_stream(selected_device: Option<String>) -> Result<rodio::OutputStream, String> {
    let builder = match selected_device {
        None => rodio::OutputStreamBuilder::from_default_device(),
        Some(device_name) if device_name == "Default" || device_name == "default" => {
            rodio::OutputStreamBuilder::from_default_device()
        }
        Some(device_name) => {
            let host = crate::audio_toolkit::get_cpal_host();
            let devices = host
                .output_devices()
                .map_err(|e| format!("no se pudo listar dispositivos de salida: {e}"))?;
            let found = devices
                .into_iter()
                .find(|d| d.name().map(|n| n == device_name).unwrap_or(false));
            match found {
                Some(device) => rodio::OutputStreamBuilder::from_device(device),
                None => rodio::OutputStreamBuilder::from_default_device(),
            }
        }
    }
    .map_err(|e| format!("no se pudo abrir el dispositivo de audio: {e}"))?;

    builder
        .open_stream()
        .map_err(|e| format!("no se pudo abrir el flujo de audio: {e}"))
}

/// Sintetiza `text` y lo reproduce por los parlantes hasta terminar.
/// Bloqueante (ONNX + `Sink::sleep_until_end`) — se ejecuta en
/// `spawn_blocking`.
fn speak_blocking(
    engine: Arc<SupertonicEngine>,
    text: String,
    voice: VoiceId,
    output_device: Option<String>,
) -> Result<(), String> {
    let stream = open_output_stream(output_device)?;
    let sink = rodio::Sink::connect_new(stream.mixer());
    tts::streaming::speak_into_sink(engine.as_ref(), &text, &voice, &sink)
        .map_err(|e| e.to_string())?;
    sink.sleep_until_end();
    Ok(())
}

/// Persiste la voz elegida por el dueño (settings.tts_voice). No valida
/// contra el catálogo: una voz desconocida simplemente fallará en
/// `tts_speak` con `TtsError::UnknownVoice`, igual que cualquier otro id
/// mal escrito — la UI solo ofrece las 10 de [`tts_list_voices`].
#[tauri::command]
#[specta::specta]
pub fn tts_set_voice(app: AppHandle, voice: String) -> Result<(), String> {
    let mut settings = get_settings(&app);
    settings.tts_voice = voice;
    write_settings(&app, settings);
    Ok(())
}

/// Enciende o apaga el modo asistente hablado (settings.voice_assistant_enabled),
/// el toggle de Ajustes > Voz que habilita el atajo `voice_assistant`.
///
/// Existe porque el guard de `actions.rs` lee este valor desde los settings
/// persistidos: sin un comando que lo escriba, el toggle solo cambiaba el
/// estado del frontend y el backend seguía viendo `false` para siempre.
#[tauri::command]
#[specta::specta]
pub fn tts_set_voice_assistant_enabled(app: AppHandle, enabled: bool) -> Result<(), String> {
    let mut settings = get_settings(&app);
    settings.voice_assistant_enabled = enabled;
    write_settings(&app, settings);
    Ok(())
}

/// Sintetiza `text` con `voice` (o la voz elegida en settings si se omite) y
/// lo reproduce por los parlantes. Devuelve una vez terminó de sonar.
#[tauri::command]
#[specta::specta]
pub async fn tts_speak(app: AppHandle, text: String, voice: Option<String>) -> Result<(), String> {
    if text.trim().is_empty() {
        return Ok(());
    }

    let settings = get_settings(&app);
    let voice_id = VoiceId::new(voice.unwrap_or(settings.tts_voice));
    let output_device = settings.selected_output_device;

    let engine = get_or_load_engine(&app).await?;

    tokio::task::spawn_blocking(move || speak_blocking(engine, text, voice_id, output_device))
        .await
        .map_err(|e| format!("la síntesis de voz se interrumpió: {e}"))?
}
