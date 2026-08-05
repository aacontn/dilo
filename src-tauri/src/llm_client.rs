//! Cliente HTTP del post-proceso y del asistente.
//!
//! Un modelo vive en una **superficie**: una ruta base más un protocolo.
//!
//! Los dos protocolos son dos formas del mismo contrato de texto:
//!
//! - `/chat/completions`, la clásica, la que usan Google, Groq, Anthropic,
//!   OpenRouter, Ollama y compañía. Es siempre el primer intento.
//! - `/responses`, la nueva de OpenAI, que algunos modelos (la familia GPT-5.6
//!   en adelante) hablan en exclusiva.
//!
//! Y la ruta base no siempre es la del proveedor: hay pasarelas que hospedan
//! cada familia de modelos bajo su propio prefijo (`…/v1` para unas,
//! `…/{familia}/v1` para otras).
//!
//! Qué superficie le toca a cada modelo no se decide por una lista de nombres:
//! se descubre del servidor. Si un intento responde con el error que dice que
//! ese modelo no soporta ese endpoint —o que ahí no hay nada—, se prueba la
//! siguiente superficie del plan y se recuerda la que funcionó, para no pagar
//! el viaje perdido en cada dictado.

use crate::settings::PostProcessProvider;
use log::{debug, info, warn};
use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION, CONTENT_TYPE, REFERER, USER_AGENT};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

/// Nombre del esquema de structured outputs. Lo comparten las dos rutas: en la
/// clásica va en `response_format.json_schema.name`, en la nueva en
/// `text.format.name`.
const STRUCTURED_OUTPUT_NAME: &str = "transcription_output";

/// Techo para el listado de modelos. Es una llamada de UI (Ajustes): si el
/// servidor no contesta, mejor un error visible que un spinner eterno.
const MODELS_REQUEST_TIMEOUT: Duration = Duration::from_secs(20);

/// Techo para cada petición de texto (chat/responses). Sin esto, un endpoint
/// que acepta la conexión y nunca contesta deja el post-proceso colgado para
/// siempre y el dictado nunca aparece.
///
/// Es por petición, no por dictado — pero el descubrimiento de superficie
/// (ver la nota del módulo) sólo reintenta cuando el servidor CONTESTA que
/// ese modelo no vive ahí; un timeout es `LlmError::Other` y corta la cadena
/// en el acto, así que el techo real que paga el usuario es este número, no
/// su múltiplo. Un minuto deja pasar modelos lentos con razonamiento sin
/// convertir "no contesta" en "esperá para siempre".
const CHAT_REQUEST_TIMEOUT: Duration = Duration::from_secs(60);

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
/// servidor diciendo que el modelo no vive en la superficie que se probó, que
/// es el único que justifica seguir buscando en la siguiente.
#[derive(Debug)]
enum LlmError {
    /// La credencial sirve y la petición está bien formada; el modelo no
    /// atiende en esta superficie. Vale la pena probar la que sigue.
    WrongSurface(String),
    /// Cualquier otra cosa: red, credencial, cuota, esquema inválido...
    /// El texto ya viene con el formato que espera el llamador.
    Other(String),
}

impl From<LlmError> for String {
    fn from(err: LlmError) -> String {
        match err {
            LlmError::WrongSurface(detail) | LlmError::Other(detail) => detail,
        }
    }
}

/// Cuál de las dos formas del contrato de texto habla una superficie.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Protocol {
    /// `POST {base}/chat/completions`
    ChatCompletions,
    /// `POST {base}/responses`
    Responses,
}

/// Dónde atiende un modelo: ruta base más protocolo. Es lo que se descubre y
/// lo que se recuerda.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Surface {
    base_url: String,
    protocol: Protocol,
}

impl Surface {
    fn new(base_url: &str, protocol: Protocol) -> Self {
        Surface {
            base_url: base_url.to_string(),
            protocol,
        }
    }

    /// La URL exacta que se va a golpear. Existe para poder afirmarla en los
    /// tests sin salir a la red.
    fn url(&self) -> String {
        match self.protocol {
            Protocol::ChatCompletions => format!("{}/chat/completions", self.base_url),
            Protocol::Responses => format!("{}/responses", self.base_url),
        }
    }
}

/// Superficies ya descubiertas, por `base_url` configurada + modelo. Vive lo
/// que vive el proceso: alcanza para que el segundo dictado en adelante vaya
/// derecho a la superficie buena, y no persiste nada en disco (una config que
/// cambia de servidor se re-descubre sola al próximo arranque).
static KNOWN_SURFACES: OnceLock<Mutex<HashMap<String, Surface>>> = OnceLock::new();

fn surface_memory() -> &'static Mutex<HashMap<String, Surface>> {
    KNOWN_SURFACES.get_or_init(|| Mutex::new(HashMap::new()))
}

/// `base_url` y modelo juntos: el mismo nombre de modelo puede existir en dos
/// proveedores distintos y atender en superficies distintas. El separador es
/// un carácter de control que no aparece ni en una URL ni en un id de modelo.
fn surface_key(base_url: &str, model: &str) -> String {
    format!("{}\u{1f}{}", base_url, model)
}

/// ¿Ya sabemos dónde atiende este modelo?
fn remembered_surface(base_url: &str, model: &str) -> Option<Surface> {
    surface_memory()
        .lock()
        .ok()
        .and_then(|map| map.get(&surface_key(base_url, model)).cloned())
}

fn remember_surface(base_url: &str, model: &str, surface: &Surface) {
    if let Ok(mut map) = surface_memory().lock() {
        map.insert(surface_key(base_url, model), surface.clone());
    }
}

/// El prefijo de familia de un id de modelo, si lo tiene: `openai` en
/// `openai.gpt-5.6-luna`, `mistral` en `mistral.voxtral-small-24b-2507`.
///
/// Se exige que lo que viene después del punto empiece con una letra, para no
/// confundir un número de versión con una familia: `gpt-3.5-turbo` y
/// `llama-3.1-8b` no tienen prefijo, tienen decimales.
fn model_family(model: &str) -> Option<&str> {
    let (family, rest) = model.split_once('.')?;
    if !rest.starts_with(|c: char| c.is_ascii_alphabetic()) {
        return None;
    }
    let plausible_segment = !family.is_empty()
        && family.starts_with(|c: char| c.is_ascii_alphabetic())
        && family
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    plausible_segment.then_some(family)
}

/// ¿Este último tramo de la ruta es una versión de API (`v1`, `v2`, `v1beta`)?
fn is_version_segment(segment: &str) -> bool {
    let mut chars = segment.chars();
    chars.next() == Some('v') && chars.next().is_some_and(|c| c.is_ascii_digit())
}

/// La ruta base alternativa donde una pasarela podría hospedar a la familia de
/// este modelo: `https://host/v1` + `openai.…` → `https://host/openai/v1`.
///
/// Se deriva del id del modelo, no de una lista de proveedores: sirve igual
/// para familias que todavía no existen. Devuelve `None` cuando no hay nada
/// razonable que derivar (modelo sin familia, base sin versión, o la familia
/// ya está en la ruta).
fn family_scoped_base_url(base_url: &str, model: &str) -> Option<String> {
    let family = model_family(model)?;
    let (root, version) = base_url.rsplit_once('/')?;
    if root.is_empty() || !is_version_segment(version) {
        return None;
    }
    if root.ends_with(&format!("/{}", family)) {
        return None;
    }
    Some(format!("{}/{}/{}", root, family, version))
}

/// Las superficies a probar, en orden. Primero lo que funciona hoy —la ruta
/// configurada, protocolo clásico— para no penalizar a los proveedores que
/// andan bien; las derivadas van al final y sólo se llega a ellas si el
/// servidor dijo explícitamente que el modelo no atiende antes.
fn attempt_plan(base_url: &str, model: &str) -> Vec<Surface> {
    let mut bases = vec![base_url.to_string()];
    if let Some(scoped) = family_scoped_base_url(base_url, model) {
        bases.push(scoped);
    }

    let mut plan = Vec::with_capacity(bases.len() * 2);
    for base in bases {
        plan.push(Surface::new(&base, Protocol::ChatCompletions));
        plan.push(Surface::new(&base, Protocol::Responses));
    }
    plan
}

/// ¿Este error dice que el modelo no atiende en la superficie que se probó?
///
/// Se reconoce por el mensaje, no por el status: un 400 puede ser cualquier
/// cosa (credencial, cuota, esquema inválido) y seguir buscando en esos casos
/// sólo agregaría errores al log. Se aceptan las redacciones vistas en la
/// práctica:
///
/// - Bedrock Mantle: `The model 'X' does not support the '/v1/chat/completions' API`
/// - OpenAI: `This model is only supported in v1/responses and not in v1/chat/completions`
///
/// Aparte, un 404/405 sobre la URL misma se toma como superficie inexistente:
/// ahí no hay endpoint que valga, así que probar el siguiente candidato no le
/// quita nada a nadie.
fn is_wrong_surface(status: reqwest::StatusCode, body: &str) -> bool {
    if status == reqwest::StatusCode::NOT_FOUND || status == reqwest::StatusCode::METHOD_NOT_ALLOWED
    {
        return true;
    }
    if !status.is_client_error() {
        return false;
    }

    let body = body.to_ascii_lowercase();
    let mentions_endpoint = body.contains("chat/completions")
        || body.contains("chat completions")
        || body.contains("/responses")
        || body.contains("responses api");
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
    create_client_with_timeout(provider, api_key, CHAT_REQUEST_TIMEOUT)
}

/// Igual que [`create_client`], con el techo de espera explícito para que los
/// tests puedan comprobar el camino del timeout sin esperar un minuto.
fn create_client_with_timeout(
    provider: &PostProcessProvider,
    api_key: &str,
    timeout: Duration,
) -> Result<reqwest::Client, String> {
    let headers = build_headers(provider, api_key)?;
    reqwest::Client::builder()
        .default_headers(headers)
        .timeout(timeout)
        .build()
        .map_err(|e| format!("Failed to build HTTP client: {}", e))
}

/// Traduce una falla de envío a algo que el usuario pueda leer. Un servidor
/// que no contesta es el caso frecuente y tiene su propio texto: "falló la
/// petición HTTP" no dice nada accionable, "se agotó el tiempo" sí.
fn describe_send_error(url: &str, error: &reqwest::Error) -> String {
    if error.is_timeout() {
        format!("Se agotó el tiempo de espera: {} no respondió", url)
    } else {
        format!("HTTP request failed: {}", error)
    }
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

    // El plan por defecto, con la superficie ya descubierta (si la hay) al
    // frente. Ponerla al frente en vez de reemplazar el plan deja que una
    // memoria vieja —el servidor cambió— caiga sola al resto de los intentos.
    let default_plan = attempt_plan(base_url, model);
    let mut plan = default_plan.clone();
    if let Some(known) = remembered_surface(base_url, model) {
        debug!("Model '{}' is known to live at {}", model, known.url());
        plan.retain(|surface| *surface != known);
        plan.insert(0, known);
    }

    // El error del primer intento es el que describe la configuración del
    // usuario; los siguientes son de superficies que Dilo se inventó, así que
    // no son lo que hay que mostrarle si al final ninguna anduvo.
    let mut first_error: Option<String> = None;

    for surface in &plan {
        let attempt = match surface.protocol {
            Protocol::ChatCompletions => {
                send_via_chat_completions(
                    &client,
                    &surface.base_url,
                    model,
                    user_content.clone(),
                    system_prompt.clone(),
                    json_schema.clone(),
                    reasoning_effort.clone(),
                    reasoning.clone(),
                )
                .await
            }
            Protocol::Responses => {
                send_via_responses(
                    &client,
                    &surface.base_url,
                    model,
                    user_content.clone(),
                    system_prompt.clone(),
                    json_schema.clone(),
                )
                .await
            }
        };

        match attempt {
            Ok(content) => {
                // Sólo se recuerda lo que no es el camino por defecto: los
                // proveedores que andan bien ni tocan la memoria.
                if default_plan.first() != Some(surface) {
                    info!(
                        "Model '{}' answered at {}; remembering it",
                        model,
                        surface.url()
                    );
                    remember_surface(base_url, model, surface);
                }
                return Ok(content);
            }
            Err(LlmError::WrongSurface(detail)) => {
                info!(
                    "Model '{}' does not answer at {} ({}); trying the next surface",
                    model,
                    surface.url(),
                    detail
                );
                if first_error.is_none() {
                    first_error = Some(detail);
                }
            }
            Err(LlmError::Other(detail)) => return Err(detail),
        }
    }

    Err(first_error.unwrap_or_else(|| format!("No surface answered for model '{}'", model)))
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
    let url = Surface::new(base_url, Protocol::ChatCompletions).url();

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
        .map_err(|e| LlmError::Other(describe_send_error(&url, &e)))?;

    let status = response.status();
    if !status.is_success() {
        let error_text = response
            .text()
            .await
            .unwrap_or_else(|_| "Failed to read error response".to_string());
        let detail = format!("API request failed with status {}: {}", status, error_text);
        return Err(if is_wrong_surface(status, &error_text) {
            LlmError::WrongSurface(detail)
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
    let url = Surface::new(base_url, Protocol::Responses).url();

    debug!("Sending responses request to: {}", url);

    let request_body =
        build_responses_body(model, &user_content, system_prompt.as_deref(), json_schema);

    let response = client
        .post(&url)
        .json(&request_body)
        .send()
        .await
        .map_err(|e| LlmError::Other(describe_send_error(&url, &e)))?;

    let status = response.status();
    if !status.is_success() {
        let error_text = response
            .text()
            .await
            .unwrap_or_else(|_| "Failed to read error response".to_string());
        let detail = format!(
            "Responses API request failed with status {}: {}",
            status, error_text
        );
        return Err(if is_wrong_surface(status, &error_text) {
            LlmError::WrongSurface(detail)
        } else {
            LlmError::Other(detail)
        });
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
            describe_send_error(&url, &e)
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
        assert!(is_wrong_surface(StatusCode::BAD_REQUEST, mantle));

        // El mismo servidor, para el otro endpoint de la misma ruta base: si
        // esto no se reconociera, la búsqueda se cortaría antes de llegar a la
        // ruta de la familia.
        let mantle_responses = r#"{"error":{"code":"validation_error","message":"The model 'openai.gpt-5.6-luna' does not support the '/v1/responses' API","param":null,"type":"invalid_request_error"}}"#;
        assert!(is_wrong_surface(StatusCode::BAD_REQUEST, mantle_responses));

        // Redacción de OpenAI para el mismo caso.
        let openai = r#"{"error":{"message":"This model is only supported in v1/responses and not in v1/chat/completions.","type":"invalid_request_error"}}"#;
        assert!(is_wrong_surface(StatusCode::BAD_REQUEST, openai));

        // Un 404/405 sobre la URL misma: ahí no hay endpoint que valga.
        assert!(is_wrong_surface(StatusCode::NOT_FOUND, "Not Found"));
        assert!(is_wrong_surface(
            StatusCode::METHOD_NOT_ALLOWED,
            "Method Not Allowed"
        ));
    }

    #[test]
    fn other_400s_do_not_trigger_the_retry() {
        // Un 400 puede ser cualquier cosa: si se siguiera buscando, sólo se
        // agregarían más errores al log.
        for body in [
            r#"{"error":{"message":"Invalid API key provided","type":"invalid_request_error"}}"#,
            r#"{"error":{"message":"This model's maximum context length is 8192 tokens","type":"invalid_request_error"}}"#,
            r#"{"error":{"message":"Invalid schema for response_format 'transcription_output'","type":"invalid_request_error"}}"#,
            r#"{"error":{"message":"The model 'foo' does not exist","type":"invalid_request_error"}}"#,
            "",
        ] {
            assert!(
                !is_wrong_surface(StatusCode::BAD_REQUEST, body),
                "no debería disparar el reintento: {}",
                body
            );
        }

        // Ni un 401/429 con el mismo texto de cortesía, ni un 500 que devuelva
        // el cuerpo del error espejado.
        assert!(!is_wrong_surface(
            StatusCode::UNAUTHORIZED,
            r#"{"error":{"message":"Invalid API key"}}"#
        ));
        assert!(!is_wrong_surface(
            StatusCode::INTERNAL_SERVER_ERROR,
            r#"{"error":{"message":"The model 'x' does not support the '/v1/chat/completions' API"}}"#
        ));
    }

    // --- El plan de intentos ------------------------------------------------

    fn urls(plan: &[Surface]) -> Vec<String> {
        plan.iter().map(|surface| surface.url()).collect()
    }

    #[test]
    fn the_classic_surface_is_always_first() {
        // Lo que anda hoy no paga nada por lo que se agregó: primer intento,
        // ruta configurada, protocolo clásico.
        for model in ["gemini-2.5-flash", "openai.gpt-5.6-luna", "gpt-oss-120b"] {
            assert_eq!(
                attempt_plan("https://x.example/v1", model)[0].url(),
                "https://x.example/v1/chat/completions",
                "modelo {}",
                model
            );
        }
    }

    #[test]
    fn a_model_without_family_only_has_the_configured_base() {
        // Gemini, Groq, Anthropic, OpenRouter, Ollama: el plan es exactamente
        // el de siempre, dos intentos sobre la ruta configurada.
        assert_eq!(
            urls(&attempt_plan(
                "https://generativelanguage.googleapis.com/v1beta/openai",
                "gemini-2.5-flash"
            )),
            vec![
                "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
                "https://generativelanguage.googleapis.com/v1beta/openai/responses",
            ]
        );
    }

    #[test]
    fn a_family_prefixed_model_adds_the_scoped_base_at_the_end() {
        // El caso de Mantle: los modelos de OpenAI viven en /openai/v1 y los
        // demás en /v1. La ruta derivada va última, nunca primera.
        assert_eq!(
            urls(&attempt_plan(
                "https://bedrock-mantle.us-east-1.api.aws/v1",
                "openai.gpt-5.6-luna"
            )),
            vec![
                "https://bedrock-mantle.us-east-1.api.aws/v1/chat/completions",
                "https://bedrock-mantle.us-east-1.api.aws/v1/responses",
                "https://bedrock-mantle.us-east-1.api.aws/openai/v1/chat/completions",
                "https://bedrock-mantle.us-east-1.api.aws/openai/v1/responses",
            ]
        );
    }

    #[test]
    fn the_scoped_base_is_derived_not_hardcoded() {
        // Nada dice "openai" en el código: la familia sale del id del modelo,
        // así que una familia que todavía no existe funciona igual.
        assert_eq!(
            family_scoped_base_url("https://host.example/v1", "familianueva.modelo-x").as_deref(),
            Some("https://host.example/familianueva/v1")
        );
        assert_eq!(
            family_scoped_base_url("https://host.example/v1", "mistral.voxtral-small-24b-2507")
                .as_deref(),
            Some("https://host.example/mistral/v1")
        );
    }

    #[test]
    fn no_scoped_base_when_there_is_nothing_sane_to_derive() {
        // Un decimal no es una familia: gpt-3.5 y llama-3.1 no inventan rutas.
        assert_eq!(model_family("gpt-3.5-turbo"), None);
        assert_eq!(model_family("llama-3.1-8b-instant"), None);
        assert_eq!(model_family("gemini-2.5-flash"), None);
        assert_eq!(model_family(".sin-familia"), None);
        assert_eq!(model_family("openai.gpt-5.6-luna"), Some("openai"));

        // Base sin versión al final: no hay dónde insertar el tramo.
        assert_eq!(
            family_scoped_base_url("https://host.example/api", "openai.gpt-5.6-luna"),
            None
        );
        assert_eq!(
            family_scoped_base_url("https://host.example", "openai.x"),
            None
        );
        // Y si la familia ya está en la ruta, no se duplica.
        assert_eq!(
            family_scoped_base_url("https://host.example/openai/v1", "openai.gpt-5.6-luna"),
            None
        );
        assert_eq!(
            urls(&attempt_plan(
                "https://host.example/api",
                "openai.gpt-5.6-luna"
            )),
            vec![
                "https://host.example/api/chat/completions",
                "https://host.example/api/responses",
            ]
        );
    }

    // --- Memoria de la superficie -------------------------------------------

    #[test]
    fn remembering_is_per_model_and_per_base_url() {
        // Claves propias de este test: la memoria es global al proceso y los
        // tests corren en paralelo.
        let base = "https://memoria-test.example/v1";
        let other_base = "https://otra-memoria-test.example/v1";
        let model = "familiax.modelo-lejano";
        let other_model = "modelo-clasico";
        let found = Surface::new(
            "https://memoria-test.example/familiax/v1",
            Protocol::Responses,
        );

        assert_eq!(remembered_surface(base, model), None);

        remember_surface(base, model, &found);

        // El segundo dictado con el mismo modelo va derecho a la superficie
        // buena: ruta base y protocolo, no sólo protocolo.
        let known = remembered_surface(base, model).expect("recordada");
        assert_eq!(known, found);
        assert_eq!(
            known.url(),
            "https://memoria-test.example/familiax/v1/responses"
        );
        // Y no arrastra a los vecinos: ni otro modelo del mismo proveedor
        // (Mantle hospeda los dos tipos), ni el mismo nombre en otro servidor.
        assert_eq!(remembered_surface(base, other_model), None);
        assert_eq!(remembered_surface(other_base, model), None);
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
        spawn_fake_server_after(Duration::ZERO, responder)
    }

    /// Igual, pero se toma `delay` antes de contestar: así se puede probar un
    /// endpoint que acepta la conexión y se queda callado, que es el caso que
    /// dejaba el post-proceso colgado para siempre.
    fn spawn_fake_server_after(
        delay: Duration,
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

                if !delay.is_zero() {
                    std::thread::sleep(delay);
                }
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
    async fn un_endpoint_mudo_corta_por_tiempo_y_el_error_lo_dice() {
        // El endpoint acepta la conexión y contesta recién a los 3 s. Sin
        // techo de espera, el post-proceso se quedaba ahí para siempre y el
        // dictado nunca aparecía (reporte del dueño, 0.2.1).
        let server = spawn_fake_server_after(Duration::from_secs(3), |_| {
            (200, json!({ "choices": [] }).to_string())
        });
        let provider = provider_at(&server.base_url());
        let client = create_client_with_timeout(&provider, "clave", Duration::from_millis(200))
            .expect("cliente");

        let started = std::time::Instant::now();
        let error = send_via_chat_completions(
            &client,
            &provider.base_url,
            "modelo-lento",
            "hola".to_string(),
            None,
            None,
            None,
            None,
        )
        .await
        .expect_err("una petición sin respuesta tiene que fallar, no esperar para siempre");

        let detail: String = error.into();
        assert!(
            detail.contains("Se agotó el tiempo"),
            "el error tiene que hablar de tiempo agotado, no de una falla genérica: {}",
            detail
        );
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "cortó por tiempo, no esperó la respuesta tardía"
        );
    }

    #[test]
    fn el_techo_de_espera_del_post_proceso_es_finito_y_humano() {
        // Techo por petición: suficiente para un modelo lento con
        // razonamiento, lejos de "para siempre".
        assert!(CHAT_REQUEST_TIMEOUT >= Duration::from_secs(30));
        assert!(CHAT_REQUEST_TIMEOUT <= Duration::from_secs(120));
    }

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

    /// El servidor de Mantle tal como lo vio el dueño: en `/v1` no existe
    /// ningún modelo `openai.*` (los dos endpoints contestan el mismo 400), y
    /// la familia atiende en `/openai/v1`, ahí sí con la API clásica.
    const UNSUPPORTED_RESPONSES_BODY: &str = r#"{"error":{"code":"validation_error","message":"The model 'openai.gpt-5.6-luna' does not support the '/v1/responses' API","param":null,"type":"invalid_request_error"}}"#;

    #[tokio::test]
    async fn walks_to_the_family_scoped_base_and_remembers_it() {
        let server = spawn_fake_server(|path| {
            if path.starts_with("/openai/v1") {
                (
                    200,
                    json!({ "choices": [ { "message": { "content": "{\"transcription\":\"listo\"}" } } ] })
                        .to_string(),
                )
            } else if path.ends_with("/chat/completions") {
                (400, UNSUPPORTED_BODY.to_string())
            } else {
                (400, UNSUPPORTED_RESPONSES_BODY.to_string())
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
        .expect("la ruta de la familia responde");
        assert_eq!(first.as_deref(), Some("{\"transcription\":\"listo\"}"));

        // Primer dictado: la ruta configurada primero (las dos formas), y
        // recién después la derivada del id del modelo.
        assert_eq!(
            server.paths(),
            vec![
                "/v1/chat/completions",
                "/v1/responses",
                "/openai/v1/chat/completions",
            ]
        );

        // Y lo que llegó allá es el cuerpo clásico de siempre.
        let sent = server.body_for("/openai/v1/chat/completions");
        assert_eq!(sent["model"], "openai.gpt-5.6-luna");
        assert_eq!(sent["messages"][0]["role"], "system");
        assert_eq!(sent["response_format"]["json_schema"]["strict"], true);
        assert!(sent.get("input").is_none());

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
        .expect("la ruta de la familia responde");
        assert_eq!(second.as_deref(), Some("{\"transcription\":\"listo\"}"));

        // Segundo dictado: un solo viaje, derecho a la superficie descubierta.
        assert_eq!(
            server.paths(),
            vec![
                "/v1/chat/completions",
                "/v1/responses",
                "/openai/v1/chat/completions",
                "/openai/v1/chat/completions",
            ]
        );

        // Y el vecino sin prefijo de familia ni siquiera conoce esa ruta: su
        // plan es el de siempre, dos intentos sobre la ruta configurada.
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
            server.paths()[4..],
            ["/v1/chat/completions", "/v1/responses"]
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
            surface_key("https://x.example/v1", "bmodelo"),
            surface_key("https://x.example/v1b", "modelo")
        );
        remember_surface(
            "https://x.example/v1",
            "bmodelo",
            &Surface::new("https://x.example/v1", Protocol::Responses),
        );
        assert_eq!(remembered_surface("https://x.example/v1b", "modelo"), None);
    }
}
