//! Modo asistente hablado.
//!
//! Nuevo, propio de Dilo (no existe en Handy/upstream) — igual que
//! `notes.rs` y `commands/tts.rs`. El atajo dedicado `voice_assistant`
//! (ver `actions.rs`, `OutputDestination::Speak`) manda la transcripción al
//! LLM de post-proceso ya configurado (mismo cliente que
//! `llm_client.rs`, con su propio system prompt conversacional) y dice la
//! respuesta en voz alta con `tts::streaming::speak_into_sink` (vía
//! `commands::tts::tts_speak`, que ya hace exactamente eso) en vez de
//! pegarla en la app activa.
//!
//! Se activa explícitamente: `settings.voice_assistant_enabled` (apagado
//! por defecto) más un atajo asignado por el dueño — ver el guard al
//! principio de `TranscribeAction::start` en `actions.rs`.

use crate::managers::history::HistoryManager;
use crate::managers::transcription::{StreamWorkKind, TranscriptionManager};
use crate::settings::{
    get_settings, AppSettings, PostProcessProvider, APPLE_INTELLIGENCE_PROVIDER_ID,
};
use crate::tray::{change_tray_icon, TrayIconState};
use crate::utils;
use log::{debug, error};
use tauri::{AppHandle, Emitter};

/// System prompt del asistente — conversacional, es-CL, tuteo, breve porque
/// la respuesta se ESCUCHA, no se lee. Fijo y propio de este modo: no toca
/// `settings.post_process_prompts` (esos son plantillas de limpieza de
/// dictado, un caso de uso distinto).
pub const ASSISTANT_SYSTEM_PROMPT: &str = "Eres el asistente de voz de Dilo. Respondes en español de Chile, con tuteo, directo y sin relleno. Tu respuesta se va a escuchar en voz alta, no a leer: 1 a 3 frases breves, sin listas, sin markdown, sin emojis, sin párrafos largos. Si no tienes la información, dilo simple y corto en vez de inventar.";

/// Mismo filtro que `strip_invisible_chars` en `actions.rs`, copiado acá
/// para no tener que exponerlo (`pub(crate)`) desde ese archivo compartido
/// con upstream por una función de una línea.
fn strip_invisible_chars(s: &str) -> String {
    s.replace(['\u{200B}', '\u{200C}', '\u{200D}', '\u{FEFF}'], "")
}

/// Por qué el modo asistente no pudo responder. `error_type()` es el mismo
/// string que viaja en el evento `assistant-error` al frontend (ver
/// `emit_assistant_error`), que lo traduce a un toast.
#[derive(Debug, PartialEq)]
pub enum AssistantError {
    /// Transcripción vacía (no se dijo nada útil) — no es una falla real,
    /// se maneja en silencio, igual que el post-proceso normal.
    Blank,
    /// No hay proveedor/modelo de post-proceso configurado (o Apple
    /// Intelligence no está disponible en este equipo).
    NotConfigured,
    /// El LLM falló o devolvió una respuesta vacía.
    Llm(String),
    /// La síntesis de voz falló (motor, dispositivo de audio, pesos no
    /// descargados, etc.).
    Tts(String),
}

impl AssistantError {
    fn error_type(&self) -> &'static str {
        match self {
            AssistantError::Blank => "blank",
            AssistantError::NotConfigured => "not_configured",
            AssistantError::Llm(_) => "llm_failed",
            AssistantError::Tts(_) => "tts_failed",
        }
    }

    fn detail(&self) -> Option<String> {
        match self {
            AssistantError::Blank | AssistantError::NotConfigured => None,
            AssistantError::Llm(msg) | AssistantError::Tts(msg) => Some(msg.clone()),
        }
    }
}

impl std::fmt::Display for AssistantError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AssistantError::Blank => write!(f, "transcripción vacía"),
            AssistantError::NotConfigured => {
                write!(f, "sin proveedor/modelo de LLM configurado")
            }
            AssistantError::Llm(msg) => write!(f, "fallo del LLM: {msg}"),
            AssistantError::Tts(msg) => write!(f, "fallo de la síntesis de voz: {msg}"),
        }
    }
}

/// A qué llamar para obtener la respuesta: un proveedor HTTP OpenAI-compatible
/// (vía `llm_client.rs`) o Apple Intelligence (APIs nativas de Swift, sin
/// pasar por HTTP — mismo caso especial que `actions::post_process_transcription`).
// `Http` carga un `PostProcessProvider` clonado (varios `String`); no vale la
// pena un `Box` solo para achicar una enum que se instancia una vez por turno
// del asistente, no en un loop caliente.
#[derive(Debug)]
#[allow(clippy::large_enum_variant)]
enum ResolvedProvider {
    Http {
        provider: PostProcessProvider,
        model: String,
        api_key: String,
        reasoning_effort: Option<String>,
        reasoning: Option<crate::llm_client::ReasoningConfig>,
    },
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    AppleIntelligence { token_limit: i32 },
}

/// Resuelve el proveedor activo de post-proceso a algo con lo que se pueda
/// llamar. Pura (sin red) — testeable sin mockear HTTP.
fn resolve_provider(settings: &AppSettings) -> Result<ResolvedProvider, AssistantError> {
    let provider = settings
        .active_post_process_provider()
        .cloned()
        .ok_or(AssistantError::NotConfigured)?;

    let model = settings
        .post_process_models
        .get(&provider.id)
        .cloned()
        .unwrap_or_default();

    if model.trim().is_empty() {
        return Err(AssistantError::NotConfigured);
    }

    if provider.id == APPLE_INTELLIGENCE_PROVIDER_ID {
        #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
        {
            if !crate::apple_intelligence::check_apple_intelligence_availability() {
                return Err(AssistantError::NotConfigured);
            }
            let token_limit = model.trim().parse::<i32>().unwrap_or(0);
            return Ok(ResolvedProvider::AppleIntelligence { token_limit });
        }
        #[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
        {
            return Err(AssistantError::NotConfigured);
        }
    }

    let api_key = settings
        .post_process_api_keys
        .get(&provider.id)
        .cloned()
        .unwrap_or_default();

    // Misma tabla que `actions::post_process_transcription`: sin razonamiento
    // para los proveedores donde no aporta y solo agrega latencia — acá
    // importa más todavía, la respuesta se dice en voz alta y el TTFA del
    // asistente completo depende de que el LLM conteste rápido.
    let (reasoning_effort, reasoning) = match provider.id.as_str() {
        "custom" => (Some("none".to_string()), None),
        "openrouter" => (
            None,
            Some(crate::llm_client::ReasoningConfig {
                effort: Some("none".to_string()),
                exclude: Some(true),
            }),
        ),
        _ => (None, None),
    };

    Ok(ResolvedProvider::Http {
        provider,
        model,
        api_key,
        reasoning_effort,
        reasoning,
    })
}

/// Le pregunta al LLM configurado (system prompt del asistente + la
/// transcripción como mensaje del usuario) y devuelve la respuesta lista
/// para hablar. Reusa `llm_client.rs` — el mismo cliente HTTP que el
/// post-proceso de dictado, sin escribir ningún cliente nuevo.
pub async fn ask_llm(
    settings: &AppSettings,
    transcription: &str,
) -> Result<String, AssistantError> {
    if transcription.trim().is_empty() {
        return Err(AssistantError::Blank);
    }

    match resolve_provider(settings)? {
        ResolvedProvider::Http {
            provider,
            model,
            api_key,
            reasoning_effort,
            reasoning,
        } => {
            match crate::llm_client::send_chat_completion_with_schema(
                &provider,
                api_key,
                &model,
                transcription.to_string(),
                Some(ASSISTANT_SYSTEM_PROMPT.to_string()),
                None,
                reasoning_effort,
                reasoning,
            )
            .await
            {
                Ok(Some(content)) if !content.trim().is_empty() => {
                    Ok(strip_invisible_chars(&content))
                }
                Ok(_) => Err(AssistantError::Llm(
                    "el modelo devolvió una respuesta vacía".to_string(),
                )),
                Err(e) => Err(AssistantError::Llm(e)),
            }
        }
        #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
        ResolvedProvider::AppleIntelligence { token_limit } => {
            match crate::apple_intelligence::process_text_with_system_prompt(
                ASSISTANT_SYSTEM_PROMPT,
                transcription,
                token_limit,
            ) {
                Ok(result) if !result.trim().is_empty() => Ok(strip_invisible_chars(&result)),
                Ok(_) => Err(AssistantError::Llm(
                    "Apple Intelligence devolvió una respuesta vacía".to_string(),
                )),
                Err(e) => Err(AssistantError::Llm(e)),
            }
        }
    }
}

#[derive(Clone, serde::Serialize)]
struct AssistantErrorEvent {
    error_type: String,
    detail: Option<String>,
}

/// Notifica el error al frontend (toast) — salvo `Blank`, que no es una
/// falla real y se maneja en silencio (mismo criterio que
/// `is_blank_transcription` en el post-proceso normal).
fn emit_assistant_error(app: &AppHandle, err: &AssistantError) {
    if matches!(err, AssistantError::Blank) {
        debug!("Modo asistente: transcripción vacía, no se llama al LLM");
        return;
    }
    let _ = app.emit(
        "assistant-error",
        AssistantErrorEvent {
            error_type: err.error_type().to_string(),
            detail: err.detail(),
        },
    );
}

/// Orquesta el modo asistente hablado completo tras una transcripción:
/// "pensando" (LLM) -> "hablando" (TTS) -> ocioso. Reusa los overlays que ya
/// existen (`show_processing_overlay`/`show_speaking_overlay`, o el work-kind
/// de la Live overlay) — no inventa UI nueva. Llamado desde
/// `TranscribeAction::stop` en `actions.rs`; consume `file_name` porque solo
/// se usa acá si hay que guardar la entrada de historial.
pub async fn respond_and_speak(
    app: &AppHandle,
    tm: &TranscriptionManager,
    hm: &HistoryManager,
    transcription: &str,
    use_streaming_overlay: bool,
    wav_saved: bool,
    file_name: String,
) {
    let settings = get_settings(app);

    // "Pensando": mismo estado visual que el post-proceso de dictado — es
    // exactamente lo mismo (una llamada al LLM en curso).
    if use_streaming_overlay {
        tm.emit_stream_working(StreamWorkKind::Polishing);
    } else {
        utils::show_processing_overlay(app);
    }

    let reply = match ask_llm(&settings, transcription).await {
        Ok(reply) => reply,
        Err(err) => {
            if !matches!(err, AssistantError::Blank) {
                error!("Modo asistente: {err}");
                if wav_saved {
                    if let Err(e) = hm.save_entry(
                        file_name,
                        transcription.to_string(),
                        true,
                        None,
                        Some(ASSISTANT_SYSTEM_PROMPT.to_string()),
                    ) {
                        error!("Modo asistente: no se pudo guardar el historial: {e}");
                    }
                }
            }
            emit_assistant_error(app, &err);
            utils::hide_recording_overlay(app);
            change_tray_icon(app, TrayIconState::Idle);
            return;
        }
    };

    if wav_saved {
        if let Err(e) = hm.save_entry(
            file_name,
            transcription.to_string(),
            true,
            Some(reply.clone()),
            Some(ASSISTANT_SYSTEM_PROMPT.to_string()),
        ) {
            error!("Modo asistente: no se pudo guardar el historial: {e}");
        }
    }

    // "Hablando": la overlay Live (panel de transcripción en vivo) no tiene
    // un tercer work-kind para "hablando" — agregarlo tocaría
    // managers/transcription.rs y el branch streaming de RecordingOverlay.tsx
    // solo para el caso Live + modelo con streaming, un costo no justificado
    // hoy. Se reusa "polishing" ahí; la píldora compacta (el caso común, ver
    // default de `overlay_style`) sí tiene su propio estado "speaking".
    if use_streaming_overlay {
        tm.emit_stream_working(StreamWorkKind::Polishing);
    } else {
        utils::show_speaking_overlay(app);
    }

    if let Err(e) = crate::commands::tts::tts_speak(app.clone(), reply, None).await {
        error!("Modo asistente: fallo la síntesis de voz: {e}");
        emit_assistant_error(app, &AssistantError::Tts(e));
    }

    utils::hide_recording_overlay(app);
    change_tray_icon(app, TrayIconState::Idle);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::get_default_settings;

    fn settings_with_openai(model: &str) -> AppSettings {
        let mut settings = get_default_settings();
        settings.post_process_provider_id = "openai".to_string();
        settings
            .post_process_models
            .insert("openai".to_string(), model.to_string());
        settings
    }

    #[test]
    fn blank_transcription_is_reported_as_blank_without_calling_the_provider() {
        // Mismo patrón que los tests async de `actions.rs`: `block_on` sobre
        // el runtime de Tauri en vez de `#[tokio::test]`, que necesitaría
        // habilitar la feature `macros` de tokio solo para esto.
        let settings = settings_with_openai("gpt-4o-mini");
        let err = tauri::async_runtime::block_on(ask_llm(&settings, "   "))
            .expect_err("una transcripción vacía no debe llamar al LLM");
        assert_eq!(err, AssistantError::Blank);
    }

    #[test]
    fn missing_provider_is_not_configured() {
        let mut settings = get_default_settings();
        settings.post_process_provider_id = "no-existe".to_string();
        assert_eq!(
            resolve_provider(&settings).unwrap_err(),
            AssistantError::NotConfigured
        );
    }

    #[test]
    fn provider_without_a_model_is_not_configured() {
        let settings = settings_with_openai("");
        assert_eq!(
            resolve_provider(&settings).unwrap_err(),
            AssistantError::NotConfigured
        );
    }

    #[test]
    fn configured_http_provider_resolves_with_its_model_and_key() {
        let settings = settings_with_openai("gpt-4o-mini");
        match resolve_provider(&settings).expect("openai con modelo debe resolver") {
            ResolvedProvider::Http {
                provider, model, ..
            } => {
                assert_eq!(provider.id, "openai");
                assert_eq!(model, "gpt-4o-mini");
            }
            #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
            ResolvedProvider::AppleIntelligence { .. } => {
                panic!("openai no debe resolver a Apple Intelligence")
            }
        }
    }

    #[test]
    fn custom_provider_disables_reasoning_effort() {
        let mut settings = get_default_settings();
        settings.post_process_provider_id = "custom".to_string();
        settings
            .post_process_models
            .insert("custom".to_string(), "local-model".to_string());
        match resolve_provider(&settings).expect("custom con modelo debe resolver") {
            ResolvedProvider::Http {
                reasoning_effort, ..
            } => assert_eq!(reasoning_effort.as_deref(), Some("none")),
            #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
            ResolvedProvider::AppleIntelligence { .. } => panic!("custom no es Apple Intelligence"),
        }
    }

    #[test]
    fn error_types_match_the_frontend_event_contract() {
        assert_eq!(AssistantError::Blank.error_type(), "blank");
        assert_eq!(AssistantError::NotConfigured.error_type(), "not_configured");
        assert_eq!(
            AssistantError::Llm("x".to_string()).error_type(),
            "llm_failed"
        );
        assert_eq!(
            AssistantError::Tts("x".to_string()).error_type(),
            "tts_failed"
        );
        assert!(AssistantError::Blank.detail().is_none());
        assert!(AssistantError::NotConfigured.detail().is_none());
        assert_eq!(
            AssistantError::Llm("boom".to_string()).detail(),
            Some("boom".to_string())
        );
    }
}
