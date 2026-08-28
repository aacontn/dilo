//! Cliente del motor de dictado en línea **Gemini 3.5 Transcribe**.
//!
//! Es el espejo de [`crate::llm_client`] para el otro lado del producto: aquel
//! manda texto a un LLM, este manda audio a un motor de transcripción. Mismo
//! reparto de trabajo: casi todo son funciones puras —armar el cuerpo, leer la
//! respuesta, clasificar la falla— y una sola función asíncrona que sale a la
//! red. Así el protocolo se fija con tests que corren en milisegundos y sin
//! clave.
//!
//! ## Las trampas del protocolo
//!
//! Están pagadas por Jot (la demo oficiosa de Google) y verificadas contra la
//! API viva; el diseño las documenta en
//! `docs/superpowers/specs/2026-08-27-motor-gemini-transcribe-design.md` §3.
//! Cada una tiene su test acá abajo, porque ninguna se manifiesta como un
//! error visible:
//!
//! - **`language_codes` nunca viaja.** Junto a `mode: "smart"` el servidor
//!   contesta HTTP 200, sin queja, y apaga smart en silencio. Por eso este
//!   motor no ofrece selección manual de idioma: solo Auto.
//! - **El transporte es `interactions`**, no `:generateContent`: ahí `mode` se
//!   parsea y devuelve texto vacío.
//! - **Una clave mala es un 400**, no un 401, y hay que reconocerla por el
//!   texto (`API_KEY_INVALID`). Un 403/404 en cambio habla del endpoint, no de
//!   la clave ni del modelo.
//! - **El envelope de error viene a veces envuelto en un array**, según el
//!   endpoint. Por eso el parser es propio y no un `Deserialize` rígido.
//! - **En un 429 hay que mirar el `quotaId`**: `PerDay` es terminal (se acabó
//!   el día), el resto es pasajero y se reintenta una vez.
//!
//! ## La clave
//!
//! Viaja **siempre** en el header `x-goog-api-key`, nunca en la query string:
//! una URL termina en logs, en trazas y en mensajes de error de `reqwest`; un
//! header no. Ningún error de este módulo incluye la clave.

use crate::managers::model::GEMINI_STT_MODEL_ID;
use log::{debug, info, warn};
use serde_json::{json, Value};
use std::time::Duration;

/// El único transporte que la fase 1 implementa. El modelo va en el cuerpo, no
/// en la ruta, y la clave **no** va acá: va en [`API_KEY_HEADER`].
const INTERACTIONS_URL: &str = "https://generativelanguage.googleapis.com/v1beta/interactions";

/// Autenticación por header. Ver la nota del módulo: nunca query string.
const API_KEY_HEADER: &str = "x-goog-api-key";

/// Techo **total** del dictado, reintento incluido.
///
/// Es total y no por petición a propósito: quien dicta espera su texto, y un
/// 429 con reintento no puede convertir la espera en el doble. El reloj se
/// arranca una vez y cubre las dos idas, la siesta del `retryDelay` incluida.
const TRANSCRIBE_DEADLINE: Duration = Duration::from_secs(45);

/// Hasta cuánto vale la pena esperar un `retryDelay` de un 429 pasajero. Más
/// que esto ya no es un reintento, es un plantón: mejor caer al modelo local.
const MAX_RETRY_DELAY: Duration = Duration::from_secs(8);

/// El audio que Dilo graba y el que Gemini espera son el mismo: 16 kHz mono.
const SAMPLE_RATE: u32 = 16_000;
const CHANNELS: u16 = 1;
const BITS_PER_SAMPLE: u16 = 16;

/// Por qué falló un dictado con Gemini.
///
/// Las variantes no son una taxonomía HTTP: son las decisiones que puede tomar
/// quien llama. `MissingKey`/`InvalidKey` mandan a la pestaña de claves,
/// `DailyQuota` dice que hoy no hay más, y `Offline`/`Timeout`/`Transient`
/// justifican caer al modelo local y avisar después.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GeminiSttError {
    /// No hay clave configurada. Ni se sale a la red.
    MissingKey,
    /// El servidor dijo que la clave no sirve (400 con `API_KEY_INVALID`).
    InvalidKey(String),
    /// No se pudo ni establecer la conexión.
    Offline,
    /// Se acabó el tiempo: el techo total del dictado.
    Timeout,
    /// Cuota diaria agotada (`quotaId` con `PerDay`). Reintentar no sirve hoy.
    DailyQuota,
    /// Falla pasajera: 5xx, 429 sin cuota diaria, o red rara.
    Transient(String),
    /// El servidor rechazó la petición por algo que no es la clave.
    BadRequest(String),
}

impl std::fmt::Display for GeminiSttError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GeminiSttError::MissingKey => write!(
                f,
                "Falta la API key de Google AI Studio para dictar con Gemini"
            ),
            GeminiSttError::InvalidKey(detail) => {
                write!(f, "Google no aceptó la API key: {}", detail)
            }
            GeminiSttError::Offline => write!(f, "No se pudo conectar con Gemini: no hay red"),
            GeminiSttError::Timeout => write!(f, "Gemini no respondió a tiempo"),
            GeminiSttError::DailyQuota => write!(
                f,
                "Se acabó la cuota diaria de Gemini: vuelve mañana o usa un modelo local"
            ),
            GeminiSttError::Transient(detail) => {
                write!(f, "Gemini falló por algo pasajero: {}", detail)
            }
            GeminiSttError::BadRequest(detail) => {
                write!(f, "Gemini rechazó la petición: {}", detail)
            }
        }
    }
}

impl std::error::Error for GeminiSttError {}

// --- Audio ------------------------------------------------------------------

/// Empaqueta las muestras del grabador en un WAV PCM 16 bits, 16 kHz, mono.
///
/// El header canónico son 44 bytes escritos a mano en vez de pasar por `hound`:
/// `hound` escribe a un `Write` y habría que pasarle un `Cursor` para volver a
/// bytes, y su header no está garantizado byte a byte por su API pública. Acá
/// el formato **es** el contrato con Google, así que se escribe explícito y el
/// test lo verifica campo por campo.
pub fn encode_wav_16k_mono(samples: &[f32]) -> Vec<u8> {
    // 45 s de audio a 16 kHz son medio mega: el `try_from` nunca se cae en la
    // práctica, pero un `as u32` que envuelva escribiría un header que miente.
    let data_len = u32::try_from(samples.len().saturating_mul(2)).unwrap_or(u32::MAX);
    let byte_rate = SAMPLE_RATE * CHANNELS as u32 * (BITS_PER_SAMPLE as u32 / 8);
    let block_align = CHANNELS * BITS_PER_SAMPLE / 8;

    let mut wav = Vec::with_capacity(44 + data_len as usize);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_len).to_le_bytes());
    wav.extend_from_slice(b"WAVE");
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16u32.to_le_bytes()); // tamaño del bloque fmt
    wav.extend_from_slice(&1u16.to_le_bytes()); // 1 = PCM sin comprimir
    wav.extend_from_slice(&CHANNELS.to_le_bytes());
    wav.extend_from_slice(&SAMPLE_RATE.to_le_bytes());
    wav.extend_from_slice(&byte_rate.to_le_bytes());
    wav.extend_from_slice(&block_align.to_le_bytes());
    wav.extend_from_slice(&BITS_PER_SAMPLE.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());

    for &sample in samples {
        // El clamp antes de escalar: sin él una muestra fuera de rango envuelve
        // el i16 y un pico se convierte en un chasquido invertido.
        let clamped = sample.clamp(-1.0, 1.0);
        wav.extend_from_slice(&((clamped * i16::MAX as f32) as i16).to_le_bytes());
    }

    wav
}

/// Alfabeto estándar de base64 (RFC 4648 §4), el que espera la API.
const BASE64_ALPHABET: &[u8; 64] =
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Base64 con relleno, escrito a mano.
///
/// No es por gusto: el crate `base64` no es una dependencia directa de Dilo y
/// esta fase no suma dependencias. Son treinta líneas y un test, contra una
/// caja negra más en el árbol.
fn to_base64(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let triple = ((chunk[0] as u32) << 16)
            | ((*chunk.get(1).unwrap_or(&0) as u32) << 8)
            | (*chunk.get(2).unwrap_or(&0) as u32);
        out.push(BASE64_ALPHABET[((triple >> 18) & 0b11_1111) as usize] as char);
        out.push(BASE64_ALPHABET[((triple >> 12) & 0b11_1111) as usize] as char);
        out.push(if chunk.len() > 1 {
            BASE64_ALPHABET[((triple >> 6) & 0b11_1111) as usize] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            BASE64_ALPHABET[(triple & 0b11_1111) as usize] as char
        } else {
            '='
        });
    }
    out
}

// --- Cuerpo de la petición ---------------------------------------------------

/// Arma el cuerpo de `POST /v1beta/interactions`.
///
/// Reglas que el test fija y que no se pueden relajar:
///
/// - **verbatim sin vocabulario no manda `generation_config`**: verbatim es el
///   default del servidor, y mandar un bloque vacío es pedirle al servidor que
///   interprete.
/// - **`language_codes` no existe acá.** Ver la nota del módulo.
pub fn build_interactions_body(smart: bool, custom_vocabulary: &[String], wav_b64: &str) -> Value {
    let mut body = json!({
        "model": GEMINI_STT_MODEL_ID,
        "input": [{
            "type": "audio",
            "mime_type": "audio/wav",
            "data": wav_b64,
        }],
    });

    // Una palabra en blanco en el diccionario de Dilo no es vocabulario: es un
    // renglón que alguien dejó a medias.
    let vocabulary: Vec<&str> = custom_vocabulary
        .iter()
        .map(|word| word.trim())
        .filter(|word| !word.is_empty())
        .collect();

    let mut transcription_config = serde_json::Map::new();
    if smart {
        transcription_config.insert("mode".to_string(), json!("smart"));
    }
    if !vocabulary.is_empty() {
        transcription_config.insert("custom_vocabulary".to_string(), json!(vocabulary));
    }
    if !transcription_config.is_empty() {
        body["generation_config"] = json!({ "transcription_config": transcription_config });
    }

    body
}

// --- Lectura de la respuesta -------------------------------------------------

/// Saca el texto del envelope de `interactions`.
///
/// La respuesta es una lista de pasos y el texto vive en los de tipo
/// `model_output`; los demás (herramientas, metadatos) se ignoran. Un dictado
/// sin habla devuelve la lista vacía: eso es `Ok("")`, no un error — el
/// silencio no es una falla, y tratarlo como tal haría saltar la caída al
/// modelo local por nada.
pub fn parse_interactions_response(body: &str) -> Result<String, GeminiSttError> {
    let parsed: Value = serde_json::from_str(body).map_err(|e| {
        // Un cuerpo que no es JSON después de un 200 es casi siempre una
        // respuesta cortada, no un contrato roto: vale reintentar/caer a local.
        GeminiSttError::Transient(format!("respuesta ilegible de Gemini: {}", e))
    })?;

    let mut text = String::new();
    if let Some(steps) = parsed.get("steps").and_then(|s| s.as_array()) {
        for step in steps {
            if step.get("type").and_then(|t| t.as_str()) != Some("model_output") {
                continue;
            }
            let contents = match step.get("content").and_then(|c| c.as_array()) {
                Some(contents) => contents,
                None => continue,
            };
            for part in contents {
                if part.get("type").and_then(|t| t.as_str()) != Some("text") {
                    continue;
                }
                if let Some(chunk) = part.get("text").and_then(|t| t.as_str()) {
                    text.push_str(chunk);
                }
            }
        }
    }

    Ok(text.trim().to_string())
}

// --- Clasificación de la falla ----------------------------------------------

/// El objeto de error, venga suelto o envuelto en un array.
///
/// Los endpoints de esta API no se ponen de acuerdo: unos contestan
/// `{"error":{…}}` y otros `[{"error":{…}}]`. Un `Deserialize` rígido se
/// rompería con la mitad.
fn error_envelope(body: &str) -> Value {
    match serde_json::from_str::<Value>(body) {
        Ok(Value::Array(mut items)) if !items.is_empty() => items.remove(0),
        Ok(other) => other,
        Err(_) => Value::Null,
    }
}

/// El mensaje que se le puede mostrar a alguien, sin la clave y sin un muro de
/// JSON.
fn error_message(body: &str) -> String {
    let envelope = error_envelope(body);
    if let Some(message) = envelope
        .get("error")
        .and_then(|error| error.get("message"))
        .and_then(|message| message.as_str())
    {
        return message.to_string();
    }
    let raw = body.trim();
    if raw.is_empty() {
        return "sin detalle".to_string();
    }
    raw.chars().take(200).collect()
}

/// ¿El servidor está diciendo que la clave no sirve?
///
/// Se reconoce por el texto porque el status miente: Google contesta **400**,
/// no 401, cuando la clave es inválida.
fn looks_like_invalid_key(body: &str) -> bool {
    let body = body.to_ascii_lowercase();
    body.contains("api_key_invalid") || body.contains("key not valid")
}

/// ¿El 429 es la cuota **diaria**?
///
/// El `quotaId` vive a distinta profundidad según el endpoint (a veces
/// `details[].quotaId`, a veces `details[].violations[].quotaId`), así que se
/// busca el patrón en el texto en vez de adivinar la forma. Ningún otro campo
/// de esta API contiene "perday".
fn mentions_daily_quota(body: &str) -> bool {
    body.to_ascii_lowercase().contains("perday")
}

/// Traduce un status + cuerpo a la decisión que puede tomar quien llama.
pub fn classify_failure(status: u16, body: &str) -> GeminiSttError {
    match status {
        // Clave mala. Google la manda como 400; se acepta igual en 401/403 por
        // si algún día se alinean con el resto del mundo.
        400..=403 if looks_like_invalid_key(body) => {
            GeminiSttError::InvalidKey(error_message(body))
        }
        401 => GeminiSttError::InvalidKey(error_message(body)),
        // 403/404 en `interactions` habla del endpoint, no del modelo ni de la
        // clave: decirlo mal manda a la persona a revisar lo que está bien.
        403 | 404 => GeminiSttError::BadRequest(format!(
            "el endpoint interactions no atiende esta petición (HTTP {}); no es el modelo: {}",
            status,
            error_message(body)
        )),
        429 if mentions_daily_quota(body) => GeminiSttError::DailyQuota,
        429 => GeminiSttError::Transient(format!(
            "límite de peticiones por minuto: {}",
            error_message(body)
        )),
        500..=599 => GeminiSttError::Transient(format!(
            "Google devolvió {}: {}",
            status,
            error_message(body)
        )),
        _ => GeminiSttError::BadRequest(error_message(body)),
    }
}

/// El `retryDelay` que el servidor pide esperar, si viene y si es razonable.
///
/// Viaja como `"5s"` dentro de `error.details[]` (el `RetryInfo` de gRPC), en
/// camelCase o snake_case según el endpoint. Se devuelve `None` cuando no está,
/// cuando no se entiende o cuando pide más de [`MAX_RETRY_DELAY`].
fn retry_delay_from_body(body: &str) -> Option<Duration> {
    let envelope = error_envelope(body);
    let details = envelope.get("error")?.get("details")?.as_array()?;
    for detail in details {
        let raw = detail
            .get("retryDelay")
            .or_else(|| detail.get("retry_delay"))
            .and_then(|value| value.as_str());
        let Some(raw) = raw else { continue };
        let seconds: f64 = raw.trim_end_matches('s').parse().ok()?;
        // El techo se comprueba en segundos, antes de construir la `Duration`:
        // `from_secs_f64` entra en pánico con un valor negativo o absurdo, y el
        // cuerpo lo escribe el servidor, no nosotros.
        if !(0.0..=MAX_RETRY_DELAY.as_secs_f64()).contains(&seconds) {
            return None;
        }
        return Some(Duration::from_secs_f64(seconds));
    }
    None
}

// --- La llamada --------------------------------------------------------------

/// Una falla de un intento, con la señal de si el servidor pidió reintentar.
struct AttemptFailure {
    error: GeminiSttError,
    /// Sólo lo llena un 429 pasajero con un `retryDelay` que cabe en el techo.
    retry_after: Option<Duration>,
}

impl AttemptFailure {
    fn terminal(error: GeminiSttError) -> Self {
        AttemptFailure {
            error,
            retry_after: None,
        }
    }
}

/// Traduce una falla de transporte. Un `reqwest::Error` trae la URL, que no
/// tiene la clave (ver la nota del módulo), así que se puede mostrar.
fn classify_network_error(error: &reqwest::Error) -> GeminiSttError {
    if error.is_timeout() {
        GeminiSttError::Timeout
    } else if error.is_connect() {
        GeminiSttError::Offline
    } else {
        GeminiSttError::Transient(format!("falló la petición: {}", error))
    }
}

/// Dicta con Gemini 3.5 Transcribe: audio adentro, texto afuera.
///
/// `smart` limpia muletillas y autocorrecciones en el propio motor;
/// `custom_vocabulary` son las palabras personalizadas de Dilo. Devuelve `""`
/// cuando no hubo habla.
pub async fn transcribe(
    samples: &[f32],
    api_key: &str,
    smart: bool,
    custom_vocabulary: &[String],
) -> Result<String, GeminiSttError> {
    transcribe_at(
        INTERACTIONS_URL,
        TRANSCRIBE_DEADLINE,
        samples,
        api_key,
        smart,
        custom_vocabulary,
    )
    .await
}

/// El cuerpo de [`transcribe`], con endpoint y techo explícitos para poder
/// probar el reintento contra un servidor local sin esperar 45 s.
async fn transcribe_at(
    endpoint: &str,
    deadline: Duration,
    samples: &[f32],
    api_key: &str,
    smart: bool,
    custom_vocabulary: &[String],
) -> Result<String, GeminiSttError> {
    if api_key.trim().is_empty() {
        return Err(GeminiSttError::MissingKey);
    }

    let wav = encode_wav_16k_mono(samples);
    debug!(
        "Gemini STT: {} muestras → {} bytes de WAV (smart={}, {} palabras)",
        samples.len(),
        wav.len(),
        smart,
        custom_vocabulary.len()
    );
    let body = build_interactions_body(smart, custom_vocabulary, &to_base64(&wav));

    let client = reqwest::Client::builder()
        .timeout(deadline)
        .build()
        .map_err(|e| GeminiSttError::Transient(format!("no se pudo crear el cliente: {}", e)))?;

    // El techo es total: envuelve el intento, la siesta del `retryDelay` y el
    // reintento. Un 429 no puede duplicar la espera de quien dicta.
    match tokio::time::timeout(
        deadline,
        attempt_with_single_retry(&client, endpoint, api_key, &body),
    )
    .await
    {
        Ok(result) => result,
        Err(_) => Err(GeminiSttError::Timeout),
    }
}

/// Un intento y, si el servidor lo pidió con un `retryDelay` corto, exactamente
/// uno más. La bandera es interna: nadie de afuera puede pedir un tercer viaje.
async fn attempt_with_single_retry(
    client: &reqwest::Client,
    endpoint: &str,
    api_key: &str,
    body: &Value,
) -> Result<String, GeminiSttError> {
    let mut already_retried = false;
    loop {
        match single_attempt(client, endpoint, api_key, body).await {
            Ok(text) => return Ok(text),
            Err(failure) => match failure.retry_after {
                Some(delay) if !already_retried => {
                    info!(
                        "Gemini STT: 429 pasajero, reintentando una vez en {:?}",
                        delay
                    );
                    already_retried = true;
                    tokio::time::sleep(delay).await;
                }
                _ => {
                    warn!("Gemini STT falló: {}", failure.error);
                    return Err(failure.error);
                }
            },
        }
    }
}

async fn single_attempt(
    client: &reqwest::Client,
    endpoint: &str,
    api_key: &str,
    body: &Value,
) -> Result<String, AttemptFailure> {
    let response = client
        .post(endpoint)
        .header(API_KEY_HEADER, api_key)
        .json(body)
        .send()
        .await
        .map_err(|e| AttemptFailure::terminal(classify_network_error(&e)))?;

    let status = response.status().as_u16();
    let text = response.text().await.unwrap_or_default();

    if !(200..300).contains(&status) {
        let error = classify_failure(status, &text);
        let retry_after = match &error {
            GeminiSttError::Transient(_) if status == 429 => retry_delay_from_body(&text),
            _ => None,
        };
        return Err(AttemptFailure { error, retry_after });
    }

    parse_interactions_response(&text).map_err(AttemptFailure::terminal)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    // --- Audio ---------------------------------------------------------------

    #[test]
    fn wav_header_is_16k_mono_pcm16() {
        let wav = encode_wav_16k_mono(&[0.0f32; 1600]); // 100 ms
        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
        assert_eq!(u32::from_le_bytes(wav[24..28].try_into().unwrap()), 16_000);
        assert_eq!(u16::from_le_bytes(wav[22..24].try_into().unwrap()), 1);
        assert_eq!(wav.len(), 44 + 1600 * 2);
    }

    #[test]
    fn wav_header_declares_every_field_the_decoder_needs() {
        let wav = encode_wav_16k_mono(&[0.0f32; 8]);
        let data_len = 8 * 2u32;
        assert_eq!(
            u32::from_le_bytes(wav[4..8].try_into().unwrap()),
            36 + data_len
        );
        assert_eq!(&wav[12..16], b"fmt ");
        assert_eq!(u32::from_le_bytes(wav[16..20].try_into().unwrap()), 16);
        assert_eq!(u16::from_le_bytes(wav[20..22].try_into().unwrap()), 1); // PCM
        assert_eq!(u32::from_le_bytes(wav[28..32].try_into().unwrap()), 32_000); // byte rate
        assert_eq!(u16::from_le_bytes(wav[32..34].try_into().unwrap()), 2); // block align
        assert_eq!(u16::from_le_bytes(wav[34..36].try_into().unwrap()), 16); // bits
        assert_eq!(&wav[36..40], b"data");
        assert_eq!(
            u32::from_le_bytes(wav[40..44].try_into().unwrap()),
            data_len
        );
    }

    #[test]
    fn samples_out_of_range_clamp_instead_of_wrapping() {
        // Sin clamp, un pico se envuelve y sale un chasquido con el signo dado
        // vuelta — un artefacto audible que el motor transcribe como ruido.
        let wav = encode_wav_16k_mono(&[2.0, -2.0, 1.0, -1.0, 0.0]);
        let pcm: Vec<i16> = wav[44..]
            .chunks_exact(2)
            .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
            .collect();
        assert_eq!(pcm, vec![i16::MAX, -i16::MAX, i16::MAX, -i16::MAX, 0]);
    }

    #[test]
    fn base64_matches_rfc4648_with_padding() {
        assert_eq!(to_base64(b"ABC"), "QUJD");
        assert_eq!(to_base64(b"A"), "QQ==");
        assert_eq!(to_base64(b"AB"), "QUI=");
        assert_eq!(to_base64(b""), "");
        // Los dos caracteres del final del alfabeto estándar (+ y /), los que
        // distinguen esta variante de la url-safe que Google no espera acá.
        assert_eq!(to_base64(&[0xfb, 0xff, 0xfe]), "+//+");
        assert_eq!(to_base64(b"cualquier cosa"), "Y3VhbHF1aWVyIGNvc2E=");
    }

    // --- Cuerpo de la petición ----------------------------------------------

    #[test]
    fn smart_body_never_carries_language_codes() {
        let body = build_interactions_body(true, &["Dilo".into()], "QUJD");
        let config = &body["generation_config"]["transcription_config"];
        assert_eq!(config["mode"], "smart");
        assert_eq!(config["custom_vocabulary"][0], "Dilo");
        assert!(
            config.get("language_codes").is_none(),
            "language_codes desactiva smart en silencio"
        );
        assert_eq!(body["model"], GEMINI_STT_MODEL_ID);
        assert_eq!(body["input"][0]["mime_type"], "audio/wav");
    }

    #[test]
    fn verbatim_without_vocabulary_omits_generation_config() {
        let body = build_interactions_body(false, &[], "QUJD");
        assert!(
            body.get("generation_config").is_none(),
            "verbatim es el default del servidor"
        );
    }

    #[test]
    fn verbatim_with_vocabulary_sends_only_the_vocabulary() {
        // Verbatim con diccionario: viaja el vocabulario, nunca un `mode` que
        // encendería smart sin que nadie lo pidiera.
        let body = build_interactions_body(false, &["Dilo".into(), "cjpais".into()], "QUJD");
        let config = &body["generation_config"]["transcription_config"];
        assert!(config.get("mode").is_none());
        assert_eq!(config["custom_vocabulary"][0], "Dilo");
        assert_eq!(config["custom_vocabulary"][1], "cjpais");
    }

    #[test]
    fn blank_custom_words_are_not_vocabulary() {
        // Un renglón a medias en el diccionario de Dilo no puede convertirse en
        // un `generation_config` que apague el default del servidor.
        let body = build_interactions_body(false, &["".into(), "   ".into()], "QUJD");
        assert!(body.get("generation_config").is_none());

        let body = build_interactions_body(false, &["  Dilo  ".into(), "".into()], "QUJD");
        let vocabulary = &body["generation_config"]["transcription_config"]["custom_vocabulary"];
        assert_eq!(vocabulary.as_array().expect("array").len(), 1);
        assert_eq!(vocabulary[0], "Dilo");
    }

    #[test]
    fn the_audio_travels_where_the_endpoint_expects_it() {
        let wav_b64 = to_base64(&encode_wav_16k_mono(&[0.0f32; 4]));
        let body = build_interactions_body(true, &[], &wav_b64);
        assert_eq!(body["input"][0]["type"], "audio");
        assert_eq!(body["input"][0]["data"], wav_b64);
    }

    // --- Lectura de la respuesta --------------------------------------------

    #[test]
    fn parses_interactions_envelope_and_empty_text_is_ok() {
        let ok = r#"{"status":"completed","steps":[{"type":"model_output","content":[{"type":"text","text":"hola"}]}]}"#;
        assert_eq!(parse_interactions_response(ok).unwrap(), "hola");
        let silencio = r#"{"status":"completed","steps":[]}"#;
        assert_eq!(parse_interactions_response(silencio).unwrap(), ""); // el silencio no es error
    }

    #[test]
    fn concatenates_text_parts_and_ignores_the_other_steps() {
        let body = r#"{
            "status":"completed",
            "steps":[
                {"type":"tool_call","content":[{"type":"text","text":"NO"}]},
                {"type":"model_output","content":[
                    {"type":"text","text":"hola "},
                    {"type":"thought","text":"NO"},
                    {"type":"text","text":"mundo"}
                ]}
            ]
        }"#;
        assert_eq!(parse_interactions_response(body).unwrap(), "hola mundo");
    }

    #[test]
    fn an_unreadable_body_is_transient_not_a_broken_contract() {
        let error = parse_interactions_response("<html>502</html>")
            .expect_err("un cuerpo que no es JSON tiene que fallar");
        assert!(matches!(error, GeminiSttError::Transient(_)));
    }

    // --- Clasificación de la falla ------------------------------------------

    #[test]
    fn classifies_the_failures_the_spec_names() {
        assert!(matches!(
            classify_failure(
                400,
                r#"{"error":{"message":"API key not valid. API_KEY_INVALID"}}"#
            ),
            GeminiSttError::InvalidKey(_)
        ));
        assert!(matches!(
            classify_failure(
                429,
                r#"{"error":{"details":[{"quotaId":"GenerateRequestsPerDayPerProjectPerModel"}]}}"#
            ),
            GeminiSttError::DailyQuota
        ));
        assert!(matches!(
            classify_failure(429, "{}"),
            GeminiSttError::Transient(_)
        ));
        assert!(matches!(
            classify_failure(503, ""),
            GeminiSttError::Transient(_)
        ));
        // el envelope de error de interactions puede venir envuelto en array — spec §3
        assert!(matches!(
            classify_failure(400, r#"[{"error":{"message":"API key not valid"}}]"#),
            GeminiSttError::InvalidKey(_)
        ));
    }

    #[test]
    fn the_daily_quota_is_terminal_even_nested_where_google_puts_it() {
        // La forma real: el quotaId vive bajo details[].violations[].
        let body = r#"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","details":[
            {"@type":"type.googleapis.com/google.rpc.QuotaFailure",
             "violations":[{"quotaId":"GenerateRequestsPerDayPerProjectPerModel"}]}
        ]}}"#;
        assert_eq!(classify_failure(429, body), GeminiSttError::DailyQuota);

        // Y el límite por minuto NO es terminal: se puede reintentar.
        let per_minute = r#"{"error":{"details":[
            {"violations":[{"quotaId":"GenerateRequestsPerMinutePerProjectPerModel"}]}
        ]}}"#;
        assert!(matches!(
            classify_failure(429, per_minute),
            GeminiSttError::Transient(_)
        ));
    }

    #[test]
    fn a_403_talks_about_the_endpoint_not_about_the_model() {
        // Trampa del spec §3: 403/404 en interactions es el endpoint. Decir
        // "modelo inválido" manda a revisar lo que está bien.
        let error = classify_failure(403, r#"{"error":{"message":"PERMISSION_DENIED"}}"#);
        let GeminiSttError::BadRequest(detail) = &error else {
            panic!("un 403 no es una clave mala: {:?}", error);
        };
        assert!(detail.contains("endpoint"), "{}", detail);
        assert!(detail.contains("no es el modelo"), "{}", detail);
    }

    #[test]
    fn other_400s_are_bad_requests_not_key_problems() {
        let error = classify_failure(400, r#"{"error":{"message":"Invalid JSON payload"}}"#);
        assert_eq!(
            error,
            GeminiSttError::BadRequest("Invalid JSON payload".to_string())
        );
        // Un 500 que espeje el texto de la clave mala sigue siendo pasajero:
        // el status manda cuando el servidor está roto.
        assert!(matches!(
            classify_failure(500, r#"{"error":{"message":"API key not valid"}}"#),
            GeminiSttError::Transient(_)
        ));
    }

    #[test]
    fn the_message_survives_a_body_that_is_not_json() {
        let error = classify_failure(400, "<html>Bad Request</html>");
        assert_eq!(
            error,
            GeminiSttError::BadRequest("<html>Bad Request</html>".to_string())
        );
        assert_eq!(
            classify_failure(400, "   "),
            GeminiSttError::BadRequest("sin detalle".to_string())
        );
    }

    // --- El reintento del 429 -----------------------------------------------

    #[test]
    fn the_retry_delay_is_honoured_only_when_it_is_short() {
        let with_delay = |raw: &str| {
            format!(
                r#"{{"error":{{"details":[{{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"{}"}}]}}}}"#,
                raw
            )
        };
        assert_eq!(
            retry_delay_from_body(&with_delay("5s")),
            Some(Duration::from_secs(5))
        );
        assert_eq!(
            retry_delay_from_body(&with_delay("1.5s")),
            Some(Duration::from_millis(1500))
        );
        // Más de 8 s no es un reintento, es un plantón: mejor caer a local.
        assert_eq!(retry_delay_from_body(&with_delay("30s")), None);
        // Sin RetryInfo no se inventa una espera.
        assert_eq!(retry_delay_from_body(r#"{"error":{"details":[]}}"#), None);
        assert_eq!(retry_delay_from_body("{}"), None);
        assert_eq!(retry_delay_from_body("no soy json"), None);
        assert_eq!(retry_delay_from_body(&with_delay("ya mismo")), None);
        // snake_case, que aparece según el endpoint.
        assert_eq!(
            retry_delay_from_body(r#"{"error":{"details":[{"retry_delay":"2s"}]}}"#),
            Some(Duration::from_secs(2))
        );
    }

    // --- Contratos que no se pueden aflojar ---------------------------------

    #[test]
    fn the_key_never_travels_in_the_url() {
        assert!(!INTERACTIONS_URL.contains('?'), "{}", INTERACTIONS_URL);
        assert!(!INTERACTIONS_URL.contains("key="), "{}", INTERACTIONS_URL);
        assert!(INTERACTIONS_URL.ends_with("/v1beta/interactions"));
        assert_eq!(API_KEY_HEADER, "x-goog-api-key");
    }

    #[test]
    fn the_deadline_is_total_finite_and_human() {
        // Cubre el reintento entero: la siesta más larga que se acepta tiene
        // que caber holgada adentro del techo.
        assert!(TRANSCRIBE_DEADLINE >= Duration::from_secs(20));
        assert!(TRANSCRIBE_DEADLINE <= Duration::from_secs(60));
        assert!(MAX_RETRY_DELAY * 2 < TRANSCRIBE_DEADLINE);
    }

    #[test]
    fn no_error_ever_shows_the_key() {
        // Ninguna variante lleva la clave: el único lugar donde vive es el
        // header, y `classify_failure` ni siquiera la recibe.
        for error in [
            GeminiSttError::MissingKey,
            GeminiSttError::InvalidKey("API key not valid".to_string()),
            GeminiSttError::Offline,
            GeminiSttError::Timeout,
            GeminiSttError::DailyQuota,
            GeminiSttError::Transient("503".to_string()),
            GeminiSttError::BadRequest("payload".to_string()),
        ] {
            assert!(!error.to_string().contains("AIza"), "{}", error);
        }
    }

    // --- El viaje completo, contra un servidor de mentira --------------------

    /// Servidor HTTP mínimo sobre `TcpListener` (sin dependencias nuevas, mismo
    /// patrón que los tests de `llm_client`): registra los headers y el cuerpo
    /// de cada llamada y contesta según el número de llamada.
    struct FakeServer {
        port: u16,
        calls: Arc<Mutex<Vec<(String, String, String)>>>,
    }

    impl FakeServer {
        fn url(&self) -> String {
            format!("http://127.0.0.1:{}/v1beta/interactions", self.port)
        }

        fn calls(&self) -> Vec<(String, String, String)> {
            self.calls.lock().expect("lock").clone()
        }
    }

    fn spawn_fake_server(
        responder: impl Fn(usize) -> (u16, String) + Send + 'static,
    ) -> Arc<FakeServer> {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().expect("addr").port();
        let calls: Arc<Mutex<Vec<(String, String, String)>>> = Arc::new(Mutex::new(Vec::new()));
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

                let mut headers = String::new();
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
                    headers.push_str(&lowered);
                }

                let mut body = vec![0u8; content_length];
                let _ = reader.read_exact(&mut body);

                let call_index = {
                    let mut calls = calls_thread.lock().expect("lock");
                    calls.push((path, headers, String::from_utf8_lossy(&body).to_string()));
                    calls.len() - 1
                };

                let (status, payload) = responder(call_index);
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

    const COMPLETED: &str = r#"{"status":"completed","steps":[{"type":"model_output","content":[{"type":"text","text":"hola mundo"}]}]}"#;

    #[tokio::test]
    async fn a_dictation_sends_the_key_in_the_header_and_returns_the_text() {
        let server = spawn_fake_server(|_| (200, COMPLETED.to_string()));

        let text = transcribe_at(
            &server.url(),
            Duration::from_secs(5),
            &[0.0f32; 160],
            "clave-secreta",
            true,
            &["Dilo".to_string()],
        )
        .await
        .expect("el servidor contesta");
        assert_eq!(text, "hola mundo");

        let calls = server.calls();
        assert_eq!(calls.len(), 1);
        let (path, headers, body) = &calls[0];
        // La clave va en el header y **no** en la URL.
        assert_eq!(path, "/v1beta/interactions");
        assert!(!path.contains("clave-secreta"), "{}", path);
        assert!(
            headers.contains("x-goog-api-key: clave-secreta"),
            "{}",
            headers
        );
        // Y el cuerpo es el del spec.
        let sent: Value = serde_json::from_str(body).expect("cuerpo JSON");
        assert_eq!(sent["model"], GEMINI_STT_MODEL_ID);
        assert_eq!(sent["input"][0]["mime_type"], "audio/wav");
        assert_eq!(
            sent["generation_config"]["transcription_config"]["mode"],
            "smart"
        );
    }

    #[tokio::test]
    async fn a_transient_429_is_retried_exactly_once() {
        let server = spawn_fake_server(|call| {
            if call == 0 {
                (
                    429,
                    r#"{"error":{"message":"quota","details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"0.05s"}]}}"#
                        .to_string(),
                )
            } else {
                (200, COMPLETED.to_string())
            }
        });

        let text = transcribe_at(
            &server.url(),
            Duration::from_secs(5),
            &[0.0f32; 160],
            "clave",
            true,
            &[],
        )
        .await
        .expect("el segundo intento contesta");
        assert_eq!(text, "hola mundo");
        assert_eq!(server.calls().len(), 2, "un intento y un solo reintento");
    }

    #[tokio::test]
    async fn a_429_that_keeps_failing_does_not_loop_forever() {
        let server = spawn_fake_server(|_| {
            (
                429,
                r#"{"error":{"message":"quota","details":[{"retryDelay":"0.05s"}]}}"#.to_string(),
            )
        });

        let error = transcribe_at(
            &server.url(),
            Duration::from_secs(5),
            &[0.0f32; 160],
            "clave",
            true,
            &[],
        )
        .await
        .expect_err("dos 429 seguidos son una falla");
        assert!(matches!(error, GeminiSttError::Transient(_)));
        assert_eq!(server.calls().len(), 2, "el reintento es uno, no infinitos");
    }

    #[tokio::test]
    async fn the_daily_quota_is_not_retried() {
        let server = spawn_fake_server(|_| {
            (
                429,
                r#"{"error":{"details":[{"quotaId":"GenerateRequestsPerDayPerProjectPerModel","retryDelay":"1s"}]}}"#
                    .to_string(),
            )
        });

        let error = transcribe_at(
            &server.url(),
            Duration::from_secs(5),
            &[0.0f32; 160],
            "clave",
            true,
            &[],
        )
        .await
        .expect_err("la cuota diaria es terminal");
        assert_eq!(error, GeminiSttError::DailyQuota);
        assert_eq!(
            server.calls().len(),
            1,
            "reintentar la cuota diaria sólo agrega espera"
        );
    }

    #[tokio::test]
    async fn a_bad_key_never_reaches_the_network() {
        let server = spawn_fake_server(|_| (200, COMPLETED.to_string()));

        for key in ["", "   "] {
            let error = transcribe_at(
                &server.url(),
                Duration::from_secs(5),
                &[0.0f32; 160],
                key,
                true,
                &[],
            )
            .await
            .expect_err("sin clave no hay dictado");
            assert_eq!(error, GeminiSttError::MissingKey);
        }
        assert!(server.calls().is_empty(), "no tenía que salir a la red");
    }

    #[tokio::test]
    async fn the_total_deadline_cuts_a_server_that_never_answers() {
        // El techo es total y corta, aunque el servidor acepte la conexión y se
        // quede callado: quien dicta no puede esperar para siempre.
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().expect("addr").port();
        std::thread::spawn(move || {
            let mut held = Vec::new();
            for stream in listener.incoming() {
                match stream {
                    Ok(stream) => held.push(stream), // aceptar y callar
                    Err(_) => break,
                }
            }
        });

        let started = std::time::Instant::now();
        let error = transcribe_at(
            &format!("http://127.0.0.1:{}/v1beta/interactions", port),
            Duration::from_millis(300),
            &[0.0f32; 160],
            "clave",
            true,
            &[],
        )
        .await
        .expect_err("un servidor mudo tiene que cortar por tiempo");
        assert_eq!(error, GeminiSttError::Timeout);
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "cortó por tiempo en vez de esperar"
        );
    }
}
