//! Cliente HTTP del post-proceso y del asistente.
//!
//! Habla dos formas del mismo contrato de texto:
//!
//! - `/chat/completions`, la clásica, la que usan Google, Groq, Anthropic,
//!   OpenRouter, Ollama y compañía. Es siempre el primer intento.
//! - `/responses`, la nueva de OpenAI, que algunos modelos (la familia GPT-5.6
//!   en adelante) hablan en exclusiva.
//!
//! Cuál habla cada modelo no se decide por una lista de nombres: se descubre
//! del servidor. Si `/chat/completions` responde con el error que dice que ese
//! modelo no soporta ese endpoint, se reintenta contra `/responses` y se
//! recuerda el modelo para no pagar el viaje perdido en cada dictado.

use crate::settings::PostProcessProvider;
use log::{debug, info, warn};
use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION, CONTENT_TYPE, REFERER, USER_AGENT};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashSet;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

/// Nombre del esquema de structured outputs. Lo comparten las dos rutas: en la
/// clásica va en `response_format.json_schema.name`, en la nueva en
/// `text.format.name`.
const STRUCTURED_OUTPUT_NAME: &str = "transcription_output";

/// Techo para el listado de modelos. Es una llamada de UI (Ajustes): si el
/// servidor no contesta, mejor un error visible que un spinner eterno.
const MODELS_REQUEST_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Debug, Serialize)]
struct ChatMessage {
    role: String,
    content: String,
}

#[derive(Debug, Serialize)]
struct JsonSchema {
    name: String,
    strict: bool,
    schema: Value,
}

#[derive(Debug, Serialize)]
struct ResponseFormat {
    #[serde(rename = "type")]
    format_type: String,
    json_schema: JsonSchema,
}

#[derive(Debug, Serialize, Clone, Default)]
pub struct ReasoningConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exclude: Option<bool>,
}

#[derive(Debug, Serialize)]
struct ChatCompletionRequest {
    model: String,
    messages: Vec<ChatMessage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    response_format: Option<ResponseFormat>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reasoning_effort: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reasoning: Option<ReasoningConfig>,
}

#[derive(Debug, Deserialize)]
struct ChatCompletionResponse {
    choices: Vec<ChatChoice>,
}

#[derive(Debug, Deserialize)]
struct ChatChoice {
    message: ChatMessageResponse,
}

#[derive(Debug, Deserialize)]
struct ChatMessageResponse {
    content: Option<String>,
}

/// Error de una llamada al proveedor. Sólo se distingue un caso del resto: el
/// servidor diciendo que ese modelo no habla `/chat/completions`, que es el
/// único que justifica reintentar contra `/responses`.
#[derive(Debug)]
enum LlmError {
    /// El modelo existe y la credencial sirve; lo que no soporta es el
    /// endpoint clásico.
    ChatCompletionsUnsupported(String),
    /// Cualquier otra cosa: red, credencial, cuota, modelo inexistente...
    /// El texto ya viene con el formato que espera el llamador.
    Other(String),
}

impl From<LlmError> for String {
    fn from(err: LlmError) -> String {
        match err {
            LlmError::ChatCompletionsUnsupported(detail) | LlmError::Other(detail) => detail,
        }
    }
}

/// Modelos que ya demostraron hablar sólo la Responses API, por
/// `base_url` + modelo. Vive lo que vive el proceso: alcanza para que el
/// segundo dictado en adelante vaya derecho al endpoint bueno, y no persiste
/// nada en disco (una config que cambia de servidor se re-descubre sola al
/// próximo arranque).
static RESPONSES_API_MODELS: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();

fn responses_api_memory() -> &'static Mutex<HashSet<String>> {
    RESPONSES_API_MODELS.get_or_init(|| Mutex::new(HashSet::new()))
}

/// `base_url` y modelo juntos: el mismo nombre de modelo puede existir en dos
/// proveedores distintos y hablar APIs distintas. El separador es un carácter
/// de control que no aparece ni en una URL ni en un id de modelo.
fn responses_api_key(base_url: &str, model: &str) -> String {
    format!("{}\u{1f}{}", base_url, model)
}

/// ¿Ya sabemos que este modelo sólo habla la Responses API?
fn model_uses_responses_api(base_url: &str, model: &str) -> bool {
    responses_api_memory()
        .lock()
        .map(|set| set.contains(&responses_api_key(base_url, model)))
        .unwrap_or(false)
}

fn remember_responses_api(base_url: &str, model: &str) {
    if let Ok(mut set) = responses_api_memory().lock() {
        set.insert(responses_api_key(base_url, model));
    }
}

/// ¿Este error es el que dice "este modelo no habla `/chat/completions`"?
///
/// Se reconoce por el mensaje, no por el status: un 400 puede ser cualquier
/// cosa (credencial, cuota, esquema inválido) y reintentar contra `/responses`
/// en esos casos sólo agregaría un segundo error al log. Se aceptan las dos
/// redacciones vistas en la práctica:
///
/// - Bedrock Mantle: `The model 'X' does not support the '/v1/chat/completions' API`
/// - OpenAI: `This model is only supported in v1/responses and not in v1/chat/completions`
fn is_chat_completions_unsupported(status: reqwest::StatusCode, body: &str) -> bool {
    if !status.is_client_error() {
        return false;
    }

    let body = body.to_ascii_lowercase();
    let mentions_endpoint = body.contains("chat/completions") || body.contains("chat completions");
    let mentions_unsupported = body.contains("does not support")
        || body.contains("not supported")
        || body.contains("unsupported")
        || body.contains("only supported in");

    mentions_endpoint && mentions_unsupported
}

/// Build headers for API requests based on provider type
fn build_headers(provider: &PostProcessProvider, api_key: &str) -> Result<HeaderMap, String> {
    let mut headers = HeaderMap::new();

    // Common headers
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    headers.insert(
        REFERER,
        HeaderValue::from_static("https://github.com/aacontn/dilo"),
    );
    headers.insert(
        USER_AGENT,
        HeaderValue::from_static("Dilo/1.0 (+https://github.com/aacontn/dilo)"),
    );
    headers.insert("X-Title", HeaderValue::from_static("Dilo"));

    // Provider-specific auth headers
    if !api_key.is_empty() {
        if provider.id == "anthropic" {
            headers.insert(
                "x-api-key",
                HeaderValue::from_str(api_key)
                    .map_err(|e| format!("Invalid API key header value: {}", e))?,
            );
            headers.insert("anthropic-version", HeaderValue::from_static("2023-06-01"));
        } else {
            headers.insert(
                AUTHORIZATION,
                HeaderValue::from_str(&format!("Bearer {}", api_key))
                    .map_err(|e| format!("Invalid authorization header value: {}", e))?,
            );
        }
    }

    Ok(headers)
}

/// Create an HTTP client with provider-specific headers
fn create_client(provider: &PostProcessProvider, api_key: &str) -> Result<reqwest::Client, String> {
    let headers = build_headers(provider, api_key)?;
    reqwest::Client::builder()
        .default_headers(headers)
        .build()
        .map_err(|e| format!("Failed to build HTTP client: {}", e))
}

/// Send a chat completion request to an OpenAI-compatible API
/// Returns Ok(Some(content)) on success, Ok(None) if response has no content,
/// or Err on actual errors (HTTP, parsing, etc.)
pub async fn send_chat_completion(
    provider: &PostProcessProvider,
    api_key: String,
    model: &str,
    prompt: String,
    reasoning_effort: Option<String>,
    reasoning: Option<ReasoningConfig>,
) -> Result<Option<String>, String> {
    send_chat_completion_with_schema(
        provider,
        api_key,
        model,
        prompt,
        None,
        None,
        reasoning_effort,
        reasoning,
    )
    .await
}

/// Send a chat completion request with structured output support
/// When json_schema is provided, uses structured outputs mode
/// system_prompt is used as the system message when provided
/// reasoning_effort sets the OpenAI-style top-level field (e.g., "none", "low", "medium", "high")
/// reasoning sets the OpenRouter-style nested object (effort + exclude)
#[allow(clippy::too_many_arguments)]
pub async fn send_chat_completion_with_schema(
    provider: &PostProcessProvider,
    api_key: String,
    model: &str,
    user_content: String,
    system_prompt: Option<String>,
    json_schema: Option<Value>,
    reasoning_effort: Option<String>,
    reasoning: Option<ReasoningConfig>,
) -> Result<Option<String>, String> {
    let base_url = provider.base_url.trim_end_matches('/');
    let client = create_client(provider, &api_key)?;

    // Modelo ya conocido como "sólo Responses": derecho al endpoint bueno, sin
    // pagar el 400 de ida.
    if model_uses_responses_api(base_url, model) {
        debug!(
            "Model '{}' is known to speak the Responses API; skipping /chat/completions",
            model
        );
        return send_via_responses(
            &client,
            base_url,
            model,
            user_content,
            system_prompt,
            json_schema,
        )
        .await
        .map_err(String::from);
    }

    match send_via_chat_completions(
        &client,
        base_url,
        model,
        user_content.clone(),
        system_prompt.clone(),
        json_schema.clone(),
        reasoning_effort,
        reasoning,
    )
    .await
    {
        Ok(content) => Ok(content),
        Err(LlmError::ChatCompletionsUnsupported(detail)) => {
            info!(
                "Model '{}' rejected /chat/completions ({}); retrying via /responses",
                model, detail
            );
            remember_responses_api(base_url, model);
            send_via_responses(
                &client,
                base_url,
                model,
                user_content,
                system_prompt,
                json_schema,
            )
            .await
            .map_err(String::from)
        }
        Err(other) => Err(String::from(other)),
    }
}

/// La ruta clásica: `POST {base_url}/chat/completions`. Es la que usan todos
/// los proveedores salvo los modelos que sólo hablan la Responses API.
#[allow(clippy::too_many_arguments)]
async fn send_via_chat_completions(
    client: &reqwest::Client,
    base_url: &str,
    model: &str,
    user_content: String,
    system_prompt: Option<String>,
    json_schema: Option<Value>,
    reasoning_effort: Option<String>,
    reasoning: Option<ReasoningConfig>,
) -> Result<Option<String>, LlmError> {
    let url = format!("{}/chat/completions", base_url);

    debug!("Sending chat completion request to: {}", url);

    let request_body = build_chat_completion_body(
        model,
        user_content,
        system_prompt,
        json_schema,
        reasoning_effort,
        reasoning,
    );

    let response = client
        .post(&url)
        .json(&request_body)
        .send()
        .await
        .map_err(|e| LlmError::Other(format!("HTTP request failed: {}", e)))?;

    let status = response.status();
    if !status.is_success() {
        let error_text = response
            .text()
            .await
            .unwrap_or_else(|_| "Failed to read error response".to_string());
        let detail = format!("API request failed with status {}: {}", status, error_text);
        return Err(if is_chat_completions_unsupported(status, &error_text) {
            LlmError::ChatCompletionsUnsupported(detail)
        } else {
            LlmError::Other(detail)
        });
    }

    let completion: ChatCompletionResponse = response
        .json()
        .await
        .map_err(|e| LlmError::Other(format!("Failed to parse API response: {}", e)))?;

    Ok(completion
        .choices
        .first()
        .and_then(|choice| choice.message.content.clone()))
}

fn build_chat_completion_body(
    model: &str,
    user_content: String,
    system_prompt: Option<String>,
    json_schema: Option<Value>,
    reasoning_effort: Option<String>,
    reasoning: Option<ReasoningConfig>,
) -> ChatCompletionRequest {
    // Build messages vector
    let mut messages = Vec::new();

    // Add system prompt if provided
    if let Some(system) = system_prompt {
        messages.push(ChatMessage {
            role: "system".to_string(),
            content: system,
        });
    }

    // Add user message
    messages.push(ChatMessage {
        role: "user".to_string(),
        content: user_content,
    });

    // Build response_format if schema is provided
    let response_format = json_schema.map(|schema| ResponseFormat {
        format_type: "json_schema".to_string(),
        json_schema: JsonSchema {
            name: STRUCTURED_OUTPUT_NAME.to_string(),
            strict: true,
            schema,
        },
    });

    ChatCompletionRequest {
        model: model.to_string(),
        messages,
        response_format,
        reasoning_effort,
        reasoning,
    }
}

/// La ruta nueva: `POST {base_url}/responses`.
///
/// Diferencias con la clásica, todas obligatorias:
/// - los mensajes van en `input`, no en `messages`;
/// - el esquema va en `text.format` con `type`/`name`/`schema`/`strict` como
///   claves hermanas, no en `response_format.json_schema`;
/// - la respuesta viene en `output[]`, una lista de ítems donde el texto es
///   sólo uno de ellos (también viajan los de razonamiento).
///
/// El razonamiento no se manda: los dos llamadores que lo configuran piden
/// `effort: "none"`, un valor que no todo servidor acepta, y en esta API el
/// razonamiento sale como ítem aparte, así que no puede contaminar el parseo.
/// Lo único en juego es latencia, nunca la corrección de la respuesta.
async fn send_via_responses(
    client: &reqwest::Client,
    base_url: &str,
    model: &str,
    user_content: String,
    system_prompt: Option<String>,
    json_schema: Option<Value>,
) -> Result<Option<String>, LlmError> {
    let url = format!("{}/responses", base_url);

    debug!("Sending responses request to: {}", url);

    let request_body =
        build_responses_body(model, &user_content, system_prompt.as_deref(), json_schema);

    let response = client
        .post(&url)
        .json(&request_body)
        .send()
        .await
        .map_err(|e| LlmError::Other(format!("HTTP request failed: {}", e)))?;

    let status = response.status();
    if !status.is_success() {
        let error_text = response
            .text()
            .await
            .unwrap_or_else(|_| "Failed to read error response".to_string());
        return Err(LlmError::Other(format!(
            "Responses API request failed with status {}: {}",
            status, error_text
        )));
    }

    let payload: Value = response
        .json()
        .await
        .map_err(|e| LlmError::Other(format!("Failed to parse Responses API response: {}", e)))?;

    Ok(extract_responses_text(&payload))
}

fn build_responses_body(
    model: &str,
    user_content: &str,
    system_prompt: Option<&str>,
    json_schema: Option<Value>,
) -> Value {
    let mut input = Vec::new();
    if let Some(system) = system_prompt {
        input.push(serde_json::json!({ "role": "system", "content": system }));
    }
    input.push(serde_json::json!({ "role": "user", "content": user_content }));

    let mut body = serde_json::json!({
        "model": model,
        "input": input,
    });

    if let Some(schema) = json_schema {
        body["text"] = serde_json::json!({
            "format": {
                "type": "json_schema",
                "name": STRUCTURED_OUTPUT_NAME,
                "strict": true,
                "schema": schema,
            }
        });
    }

    body
}

/// Saca el texto de una respuesta de la Responses API.
///
/// `output` es una lista de ítems y el texto no está garantizado en
/// `output[0]`: antes pueden venir ítems de razonamiento o de herramientas. Se
/// recorren todos los ítems de mensaje y se concatena su texto, igual que hace
/// la propiedad `output_text` de los SDK oficiales — que es una comodidad del
/// SDK y **no** un campo garantizado del JSON crudo, así que sólo se usa como
/// último recurso para servidores compatibles que sí lo mandan.
fn extract_responses_text(payload: &Value) -> Option<String> {
    let mut text = String::new();
    let mut refusal: Option<String> = None;

    if let Some(items) = payload.get("output").and_then(|o| o.as_array()) {
        for item in items {
            let contents = match item.get("content").and_then(|c| c.as_array()) {
                Some(contents) => contents,
                None => continue,
            };
            for part in contents {
                match part.get("type").and_then(|t| t.as_str()) {
                    Some("output_text") => {
                        if let Some(chunk) = part.get("text").and_then(|t| t.as_str()) {
                            text.push_str(chunk);
                        }
                    }
                    Some("refusal") => {
                        if let Some(reason) = part.get("refusal").and_then(|r| r.as_str()) {
                            refusal = Some(reason.to_string());
                        }
                    }
                    _ => {}
                }
            }
        }
    }

    if text.is_empty() {
        // Servidores compatibles que agregan la comodidad del SDK al JSON.
        if let Some(aggregated) = payload.get("output_text").and_then(|t| t.as_str()) {
            text.push_str(aggregated);
        }
    }

    if text.is_empty() {
        if let Some(reason) = refusal {
            warn!("Responses API returned a refusal: {}", reason);
        }
        return None;
    }

    Some(text)
}

/// Fetch available models from an OpenAI-compatible API
/// Returns a list of model IDs
pub async fn fetch_models(
    provider: &PostProcessProvider,
    api_key: String,
) -> Result<Vec<String>, String> {
    let base_url = provider.base_url.trim_end_matches('/');
    let url = format!("{}/models", base_url);

    debug!("Fetching models from: {}", url);

    let client = create_client(provider, &api_key)?;

    let response = client
        .get(&url)
        .timeout(MODELS_REQUEST_TIMEOUT)
        .send()
        .await
        .map_err(|e| {
            warn!("Failed to fetch models from {}: {}", url, e);
            format!("Failed to fetch models: {}", e)
        })?;

    let status = response.status();
    if !status.is_success() {
        let error_text = response
            .text()
            .await
            .unwrap_or_else(|_| "Unknown error".to_string());
        warn!("Model list request to {} failed ({})", url, status);
        return Err(format!(
            "Model list request failed ({}): {}",
            status, error_text
        ));
    }

    let parsed: serde_json::Value = response
        .json()
        .await
        .map_err(|e| format!("Failed to parse response: {}", e))?;

    let mut models = Vec::new();

    // Handle OpenAI format: { data: [ { id: "..." }, ... ] }
    if let Some(data) = parsed.get("data").and_then(|d| d.as_array()) {
        for entry in data {
            if let Some(id) = entry.get("id").and_then(|i| i.as_str()) {
                models.push(id.to_string());
            } else if let Some(name) = entry.get("name").and_then(|n| n.as_str()) {
                models.push(name.to_string());
            }
        }
    }
    // Handle array format: [ "model1", "model2", ... ]
    else if let Some(array) = parsed.as_array() {
        for entry in array {
            if let Some(model) = entry.as_str() {
                models.push(model.to_string());
            }
        }
    }

    debug!("Fetched {} models from {}", models.len(), url);

    Ok(models)
}

#[cfg(test)]
mod tests {
    use super::*;
    use reqwest::StatusCode;
    use serde_json::json;
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::TcpListener;
    use std::sync::Arc;

    fn schema() -> Value {
        json!({
            "type": "object",
            "properties": { "transcription": { "type": "string" } },
            "required": ["transcription"],
            "additionalProperties": false
        })
    }

    // --- Cuerpo de la ruta clásica: no cambia para nadie ---------------------

    #[test]
    fn chat_completions_body_keeps_the_classic_shape() {
        let body = build_chat_completion_body(
            "gemini-2.5-flash",
            "hola".to_string(),
            Some("sos un editor".to_string()),
            Some(schema()),
            Some("none".to_string()),
            Some(ReasoningConfig {
                effort: Some("none".to_string()),
                exclude: Some(true),
            }),
        );
        let body = serde_json::to_value(&body).expect("serializa");

        assert_eq!(body["model"], "gemini-2.5-flash");
        assert_eq!(body["messages"][0]["role"], "system");
        assert_eq!(body["messages"][0]["content"], "sos un editor");
        assert_eq!(body["messages"][1]["role"], "user");
        assert_eq!(body["messages"][1]["content"], "hola");
        // El esquema va anidado bajo response_format.json_schema, con el
        // nombre y strict adentro. Si esto cambia, se rompe Google/OpenAI.
        assert_eq!(body["response_format"]["type"], "json_schema");
        assert_eq!(
            body["response_format"]["json_schema"]["name"],
            "transcription_output"
        );
        assert_eq!(body["response_format"]["json_schema"]["strict"], true);
        assert_eq!(body["response_format"]["json_schema"]["schema"], schema());
        assert_eq!(body["reasoning_effort"], "none");
        assert_eq!(body["reasoning"]["exclude"], true);
        // La clásica no tiene ni `input` ni `text`.
        assert!(body.get("input").is_none());
        assert!(body.get("text").is_none());
    }

    #[test]
    fn chat_completions_body_omits_optional_fields() {
        let body =
            build_chat_completion_body("gpt-oss-120b", "hola".to_string(), None, None, None, None);
        let body = serde_json::to_value(&body).expect("serializa");

        assert_eq!(body["messages"].as_array().expect("array").len(), 1);
        assert_eq!(body["messages"][0]["role"], "user");
        assert!(body.get("response_format").is_none());
        assert!(body.get("reasoning_effort").is_none());
        assert!(body.get("reasoning").is_none());
    }

    // --- Cuerpo de la ruta Responses ----------------------------------------

    #[test]
    fn responses_body_uses_input_and_text_format() {
        let body = build_responses_body(
            "openai.gpt-5.6-luna",
            "hola",
            Some("sos un editor"),
            Some(schema()),
        );

        assert_eq!(body["model"], "openai.gpt-5.6-luna");
        // Los mensajes van en `input`, nunca en `messages`.
        assert!(body.get("messages").is_none());
        assert_eq!(body["input"][0]["role"], "system");
        assert_eq!(body["input"][0]["content"], "sos un editor");
        assert_eq!(body["input"][1]["role"], "user");
        assert_eq!(body["input"][1]["content"], "hola");

        // El esquema va en text.format con type/name/strict/schema como
        // claves hermanas. `response_format` no existe en esta API.
        assert!(body.get("response_format").is_none());
        assert_eq!(body["text"]["format"]["type"], "json_schema");
        assert_eq!(body["text"]["format"]["name"], "transcription_output");
        assert_eq!(body["text"]["format"]["strict"], true);
        assert_eq!(body["text"]["format"]["schema"], schema());
        // No hay un json_schema anidado adentro de format.
        assert!(body["text"]["format"].get("json_schema").is_none());
    }

    #[test]
    fn responses_body_without_schema_has_no_text_field() {
        let body = build_responses_body("openai.gpt-5.6-luna", "hola", None, None);

        assert_eq!(body["input"].as_array().expect("array").len(), 1);
        assert_eq!(body["input"][0]["role"], "user");
        assert!(body.get("text").is_none());
    }

    #[test]
    fn responses_body_never_sends_reasoning() {
        // El razonamiento no viaja: los llamadores piden "none", que no todo
        // servidor acepta, y en esta API el razonamiento sale como ítem
        // aparte, así que no puede contaminar el parseo.
        let body = build_responses_body("openai.gpt-5.6-luna", "hola", None, Some(schema()));
        assert!(body.get("reasoning").is_none());
        assert!(body.get("reasoning_effort").is_none());
    }

    // --- Parseo de la respuesta ---------------------------------------------

    #[test]
    fn extracts_text_skipping_the_reasoning_item() {
        // El texto no está garantizado en output[0]: antes viene el ítem de
        // razonamiento.
        let payload = json!({
            "id": "resp_1",
            "output": [
                { "type": "reasoning", "id": "rs_1", "summary": [] },
                {
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        { "type": "output_text", "text": "{\"transcription\":\"hola\"}" }
                    ]
                }
            ]
        });

        assert_eq!(
            extract_responses_text(&payload).as_deref(),
            Some("{\"transcription\":\"hola\"}")
        );
    }

    #[test]
    fn concatenates_several_text_parts() {
        let payload = json!({
            "output": [
                {
                    "type": "message",
                    "content": [
                        { "type": "output_text", "text": "hola " },
                        { "type": "output_text", "text": "mundo" }
                    ]
                }
            ]
        });

        assert_eq!(
            extract_responses_text(&payload).as_deref(),
            Some("hola mundo")
        );
    }

    #[test]
    fn falls_back_to_top_level_output_text() {
        // Algunos servidores compatibles agregan la comodidad del SDK al JSON.
        let payload = json!({ "output": [], "output_text": "hola" });
        assert_eq!(extract_responses_text(&payload).as_deref(), Some("hola"));
    }

    #[test]
    fn refusal_and_empty_output_yield_no_content() {
        let refusal = json!({
            "output": [
                {
                    "type": "message",
                    "content": [ { "type": "refusal", "refusal": "no puedo" } ]
                }
            ]
        });
        assert_eq!(extract_responses_text(&refusal), None);

        assert_eq!(extract_responses_text(&json!({ "output": [] })), None);
        assert_eq!(extract_responses_text(&json!({})), None);
        // Una respuesta de la API clásica no se parsea como Responses.
        let classic = json!({ "choices": [ { "message": { "content": "hola" } } ] });
        assert_eq!(extract_responses_text(&classic), None);
    }

    // --- Reconocimiento del 400 ---------------------------------------------

    #[test]
    fn recognizes_the_unsupported_endpoint_error() {
        // Cuerpo textual del servidor de Mantle (log del 2026-08-04).
        let mantle = r#"{"error":{"code":"validation_error","message":"The model 'openai.gpt-5.6-luna' does not support the '/v1/chat/completions' API","param":null,"type":"invalid_request_error"}}"#;
        assert!(is_chat_completions_unsupported(
            StatusCode::BAD_REQUEST,
            mantle
        ));

        // Redacción de OpenAI para el mismo caso.
        let openai = r#"{"error":{"message":"This model is only supported in v1/responses and not in v1/chat/completions.","type":"invalid_request_error"}}"#;
        assert!(is_chat_completions_unsupported(
            StatusCode::BAD_REQUEST,
            openai
        ));
    }

    #[test]
    fn other_400s_do_not_trigger_the_retry() {
        // Un 400 puede ser cualquier cosa: si se reintentara contra
        // /responses, sólo se agregaría un segundo error al log.
        for body in [
            r#"{"error":{"message":"Invalid API key provided","type":"invalid_request_error"}}"#,
            r#"{"error":{"message":"This model's maximum context length is 8192 tokens","type":"invalid_request_error"}}"#,
            r#"{"error":{"message":"Invalid schema for response_format 'transcription_output'","type":"invalid_request_error"}}"#,
            r#"{"error":{"message":"The model 'foo' does not exist","type":"invalid_request_error"}}"#,
            "",
        ] {
            assert!(
                !is_chat_completions_unsupported(StatusCode::BAD_REQUEST, body),
                "no debería disparar el reintento: {}",
                body
            );
        }

        // Ni un 401/429 con el mismo texto de cortesía, ni un 500 que devuelva
        // el cuerpo del error espejado.
        assert!(!is_chat_completions_unsupported(
            StatusCode::UNAUTHORIZED,
            r#"{"error":{"message":"Invalid API key"}}"#
        ));
        assert!(!is_chat_completions_unsupported(
            StatusCode::INTERNAL_SERVER_ERROR,
            r#"{"error":{"message":"The model 'x' does not support the '/v1/chat/completions' API"}}"#
        ));
    }

    // --- Memoria del modelo -------------------------------------------------

    #[test]
    fn remembering_a_model_is_per_model_and_per_base_url() {
        // Claves propias de este test: la memoria es global al proceso y los
        // tests corren en paralelo.
        let base = "https://memoria-test.example/v1";
        let other_base = "https://otra-memoria-test.example/v1";
        let model = "modelo-solo-responses";
        let other_model = "modelo-clasico";

        assert!(!model_uses_responses_api(base, model));

        remember_responses_api(base, model);

        // El segundo dictado con el mismo modelo va derecho a /responses.
        assert!(model_uses_responses_api(base, model));
        // Y no arrastra a los vecinos: ni otro modelo del mismo proveedor
        // (Mantle hospeda los dos tipos), ni el mismo nombre en otro servidor.
        assert!(!model_uses_responses_api(base, other_model));
        assert!(!model_uses_responses_api(other_base, model));
    }

    // --- El viaje completo, contra un servidor de mentira -------------------

    /// Servidor HTTP mínimo sobre `TcpListener` (sin dependencias nuevas):
    /// registra qué ruta y qué cuerpo recibió, y contesta lo que diga
    /// `responder`. Alcanza para verificar el reintento y la memoria sin salir
    /// de la máquina.
    struct FakeServer {
        port: u16,
        calls: Arc<Mutex<Vec<(String, String)>>>,
    }

    impl FakeServer {
        fn base_url(&self) -> String {
            format!("http://127.0.0.1:{}/v1", self.port)
        }

        fn paths(&self) -> Vec<String> {
            self.calls
                .lock()
                .expect("lock")
                .iter()
                .map(|(path, _)| path.clone())
                .collect()
        }

        fn body_for(&self, path: &str) -> Value {
            let calls = self.calls.lock().expect("lock");
            let (_, body) = calls
                .iter()
                .find(|(p, _)| p == path)
                .unwrap_or_else(|| panic!("no hubo llamada a {}", path));
            serde_json::from_str(body).expect("cuerpo JSON")
        }
    }

    fn spawn_fake_server(
        responder: impl Fn(&str) -> (u16, String) + Send + 'static,
    ) -> Arc<FakeServer> {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().expect("addr").port();
        let calls: Arc<Mutex<Vec<(String, String)>>> = Arc::new(Mutex::new(Vec::new()));
        let calls_thread = Arc::clone(&calls);

        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let mut stream = match stream {
                    Ok(stream) => stream,
                    Err(_) => break,
                };
                let mut reader = BufReader::new(stream.try_clone().expect("clone"));

                let mut request_line = String::new();
                if reader.read_line(&mut request_line).is_err() {
                    continue;
                }
                let path = request_line
                    .split_whitespace()
                    .nth(1)
                    .unwrap_or_default()
                    .to_string();

                let mut content_length = 0usize;
                loop {
                    let mut line = String::new();
                    match reader.read_line(&mut line) {
                        Ok(0) => break,
                        Ok(_) => {}
                        Err(_) => break,
                    }
                    if line == "\r\n" || line == "\n" {
                        break;
                    }
                    let lowered = line.to_ascii_lowercase();
                    if let Some(value) = lowered.strip_prefix("content-length:") {
                        content_length = value.trim().parse().unwrap_or(0);
                    }
                }

                let mut body = vec![0u8; content_length];
                let _ = reader.read_exact(&mut body);
                calls_thread
                    .lock()
                    .expect("lock")
                    .push((path.clone(), String::from_utf8_lossy(&body).to_string()));

                let (status, payload) = responder(&path);
                let response = format!(
                    "HTTP/1.1 {} Status\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    status,
                    payload.len(),
                    payload
                );
                let _ = stream.write_all(response.as_bytes());
                let _ = stream.flush();
            }
        });

        Arc::new(FakeServer { port, calls })
    }

    fn provider_at(base_url: &str) -> PostProcessProvider {
        PostProcessProvider {
            id: "bedrock_mantle".to_string(),
            label: "AWS Bedrock (Mantle)".to_string(),
            base_url: base_url.to_string(),
            allow_base_url_edit: false,
            models_endpoint: Some("/models".to_string()),
            supports_structured_output: true,
            is_local: false,
        }
    }

    const UNSUPPORTED_BODY: &str = r#"{"error":{"code":"validation_error","message":"The model 'openai.gpt-5.6-luna' does not support the '/v1/chat/completions' API","param":null,"type":"invalid_request_error"}}"#;

    #[tokio::test]
    async fn retries_via_responses_and_remembers_the_model() {
        let server = spawn_fake_server(|path| {
            if path.ends_with("/chat/completions") {
                (400, UNSUPPORTED_BODY.to_string())
            } else {
                (
                    200,
                    json!({
                        "output": [
                            { "type": "reasoning", "summary": [] },
                            {
                                "type": "message",
                                "role": "assistant",
                                "content": [
                                    { "type": "output_text", "text": "{\"transcription\":\"listo\"}" }
                                ]
                            }
                        ]
                    })
                    .to_string(),
                )
            }
        });
        let provider = provider_at(&server.base_url());

        let first = send_chat_completion_with_schema(
            &provider,
            "clave".to_string(),
            "openai.gpt-5.6-luna",
            "hola".to_string(),
            Some("sos un editor".to_string()),
            Some(schema()),
            None,
            None,
        )
        .await
        .expect("la ruta Responses responde");
        assert_eq!(first.as_deref(), Some("{\"transcription\":\"listo\"}"));

        // Primer dictado: se paga el viaje de ida y se reintenta.
        assert_eq!(
            server.paths(),
            vec!["/v1/chat/completions", "/v1/responses"]
        );

        // Y el cuerpo que llegó a /responses tiene la forma nueva.
        let sent = server.body_for("/v1/responses");
        assert_eq!(sent["input"][0]["role"], "system");
        assert_eq!(sent["input"][1]["content"], "hola");
        assert_eq!(sent["text"]["format"]["type"], "json_schema");
        assert!(sent.get("messages").is_none());
        assert!(sent.get("response_format").is_none());

        let second = send_chat_completion_with_schema(
            &provider,
            "clave".to_string(),
            "openai.gpt-5.6-luna",
            "otra vez".to_string(),
            None,
            None,
            None,
            None,
        )
        .await
        .expect("la ruta Responses responde");
        assert_eq!(second.as_deref(), Some("{\"transcription\":\"listo\"}"));

        // Segundo dictado: derecho a /responses, sin repetir el 400.
        assert_eq!(
            server.paths(),
            vec!["/v1/chat/completions", "/v1/responses", "/v1/responses"]
        );

        // Y el modelo vecino del mismo proveedor sigue yendo por la clásica.
        let _ = send_chat_completion_with_schema(
            &provider,
            "clave".to_string(),
            "gpt-oss-120b",
            "hola".to_string(),
            None,
            None,
            None,
            None,
        )
        .await;
        assert_eq!(
            server.paths().last().map(String::as_str),
            Some("/v1/responses")
        );
        assert_eq!(
            server
                .paths()
                .iter()
                .filter(|p| p.ends_with("/chat/completions"))
                .count(),
            2,
            "el otro modelo tiene que volver a intentar la clásica"
        );
    }

    #[tokio::test]
    async fn a_different_400_does_not_reach_responses() {
        let server = spawn_fake_server(|_| {
            (
                400,
                r#"{"error":{"message":"Invalid API key provided","type":"invalid_request_error"}}"#
                    .to_string(),
            )
        });
        let provider = provider_at(&server.base_url());

        let err = send_chat_completion_with_schema(
            &provider,
            "clave-mala".to_string(),
            "openai.gpt-5.6-luna",
            "hola".to_string(),
            None,
            Some(schema()),
            None,
            None,
        )
        .await
        .expect_err("un 400 de credencial tiene que fallar");
        assert!(err.contains("400"), "{}", err);

        // Ni reintento ni memoria: el modelo sigue yendo por la clásica.
        assert_eq!(server.paths(), vec!["/v1/chat/completions"]);
    }

    #[tokio::test]
    async fn the_classic_route_is_untouched_when_it_works() {
        let server = spawn_fake_server(|_| {
            (
                200,
                json!({ "choices": [ { "message": { "content": "limpio" } } ] }).to_string(),
            )
        });
        let provider = provider_at(&server.base_url());

        let out = send_chat_completion_with_schema(
            &provider,
            "clave".to_string(),
            "gemini-2.5-flash",
            "hola".to_string(),
            Some("sos un editor".to_string()),
            Some(schema()),
            Some("none".to_string()),
            None,
        )
        .await
        .expect("la clásica responde");

        assert_eq!(out.as_deref(), Some("limpio"));
        assert_eq!(server.paths(), vec!["/v1/chat/completions"]);

        let sent = server.body_for("/v1/chat/completions");
        assert_eq!(sent["messages"][0]["role"], "system");
        assert_eq!(sent["response_format"]["json_schema"]["strict"], true);
        assert_eq!(sent["reasoning_effort"], "none");
        assert!(sent.get("input").is_none());
        assert!(sent.get("text").is_none());
    }

    #[test]
    fn memory_key_cannot_be_forged_by_concatenation() {
        // Si la clave fuera una concatenación cruda, "…/v1" + "bmodelo"
        // colisionaría con "…/v1b" + "modelo", y recordar uno marcaría al otro.
        assert_ne!(
            responses_api_key("https://x.example/v1", "bmodelo"),
            responses_api_key("https://x.example/v1b", "modelo")
        );
        remember_responses_api("https://x.example/v1", "bmodelo");
        assert!(!model_uses_responses_api("https://x.example/v1b", "modelo"));
    }
}
