//! Motor local de síntesis de voz: Supertonic 3 (`Supertone/supertonic-3`,
//! ONNX vía `ort`), por defecto en Dilo.
//!
//! Port directo de `spikes/voz/supertonic/src/lib.rs` (Command Center),
//! adaptación 1:1 de `rust/src/helper.rs` del repo oficial
//! `supertone-inc/supertonic` — medido en ese spike: carga ≈0,59-0,66 s,
//! síntesis ≈1,9-2,7 s por frase completa (RTF ≈0,31-0,41), RAM pico
//! ≈500 MB, streaming por frases con TTFA 543-653 ms (ver
//! `spikes/voz/RESULTADOS.md`).
//!
//! **Las 10 voces se preloadean al construir el motor** (`SupertonicEngine::load`)
//! porque son datos livianos (~285 KB cada una) comparados con las 4 sesiones
//! ONNX (~408 MB compartidos entre las 10). Esto es lo que garantiza que
//! cambiar de voz nunca recarga el modelo: no hay ningún "swap" de sesión, solo
//! se elige qué tensor de estilo ya cargado usar para la próxima síntesis.

use super::{AudioChunk, TtsEngine, TtsError, TtsResult, VoiceGender, VoiceId, VoiceInfo};
use anyhow::{bail, Context, Result};
use ndarray::{Array, Array3};
use ort::session::Session;
use ort::value::Value;
use rand_distr::{Distribution, Normal};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs::File;
use std::io::BufReader;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use unicode_normalization::UnicodeNormalization;

/// Las 10 voces publicadas por Supertone para Supertonic 3 (`F1`-`F5`
/// femeninas, `M1`-`M5` masculinas). Comparten el mismo checkpoint de 408 MB
/// — cada voz es solo un tensor de estilo de ~285 KB.
pub const VOICE_IDS: &[&str] = &["F1", "F2", "F3", "F4", "F5", "M1", "M2", "M3", "M4", "M5"];

/// Voz de fábrica. Elegida de oído por el dueño en la audición del spike
/// (ver `spikes/voz/RESULTADOS.md`, sección "Supertonic — streaming por
/// frases").
pub const DEFAULT_VOICE: &str = "F5";

/// Idioma fijo de síntesis: Dilo es español-primero (ver `AGENTS.md`). El
/// modelo es multilingüe (31 idiomas) y selecciona el idioma con un tag de
/// texto en tiempo de inferencia (`preprocess_text`), no con pesos
/// separados — dejar esto como constante (no parámetro) hasta que haya un
/// caso de uso real para sintetizar en otro idioma.
const LANG: &str = "es";

/// Pasos de denoising del flow-matching (duration predictor -> text encoder
/// -> vector estimator -> vocoder). Valor por defecto del ejemplo oficial;
/// no se "optimizó" para forzar mejores números en el spike, así que se
/// mantiene igual acá. Más alto = mejor calidad, más lento.
const TOTAL_STEP: usize = 8;

/// Factor de velocidad de síntesis (>1.0 = más rápido). Mismo valor medido
/// en el spike.
const SPEED: f32 = 1.05;

// ============================================================================
// Descarga de pesos — reusa el patrón de `managers/model.rs` (hf-hub,
// caché compartida), pero como funciones libres desacopladas de Tauri: este
// módulo no depende de `AppHandle` para poder testearse sin construir una
// app completa. El llamador (fuera de alcance de este cambio — la UI viene
// después) resuelve `models_dir` con `crate::portable::app_data_dir` y se
// lo pasa a estas funciones, igual que hace `ModelManager::new`.
// ============================================================================

/// Repo de Hugging Face de donde se descargan los pesos. Confirmado en el
/// spike: es `Supertone/supertonic-3` (v3, no `Supertone/supertonic` v1 —
/// el WER 1.13 en español citado en el plan es de la v3, ver
/// `spikes/voz/RESULTADOS.md`).
pub const HF_REPO_ID: &str = "Supertone/supertonic-3";
pub const HF_REVISION: &str = "main";

/// Los 6 archivos del checkpoint compartido (config + 4 modelos ONNX +
/// indexador Unicode), relativos a `onnx/` dentro del repo de HF.
pub const ONNX_FILES: &[&str] = &[
    "tts.json",
    "unicode_indexer.json",
    "duration_predictor.onnx",
    "text_encoder.onnx",
    "vector_estimator.onnx",
    "vocoder.onnx",
];

/// Punto donde debe mostrarse el aviso de licencia OpenRAIL-M antes de
/// descargar los pesos — la UI que lo muestra viene después (fuera de
/// alcance de este cambio, ver `docs/plans/dilo-v2-voz.md`). El texto real
/// de las 13 restricciones de uso debe copiarse desde el archivo LICENSE
/// del repo de Hugging Face al implementar esa UI; no se reproduce aquí
/// para no fijar en el código una copia que podría quedar desactualizada.
/// El código en sí (este motor) es MIT — es solo el checkpoint el que es
/// OpenRAIL-M.
pub const LICENSE_NOTICE_SOURCE_URL: &str =
    "https://huggingface.co/Supertone/supertonic-3/blob/main/LICENSE";

/// Directorio donde viven los pesos dentro del árbol de datos de la app,
/// mismo patrón que `ModelManager` (`<app_data>/models/...`).
pub fn weights_dir(models_dir: &Path) -> PathBuf {
    models_dir.join("tts").join("supertonic-3")
}

fn onnx_dir(models_dir: &Path) -> PathBuf {
    weights_dir(models_dir).join("onnx")
}

fn voice_styles_dir(models_dir: &Path) -> PathBuf {
    weights_dir(models_dir).join("voice_styles")
}

/// Si ya están todos los archivos esperados en disco (los 6 del checkpoint
/// más las 10 voces). No verifica checksums — igual que el resto de este
/// módulo, la verificación de integridad fuerte queda para cuando se
/// enganche con `managers/model.rs`.
pub fn is_downloaded(models_dir: &Path) -> bool {
    let onnx = onnx_dir(models_dir);
    let styles = voice_styles_dir(models_dir);
    ONNX_FILES.iter().all(|f| onnx.join(f).is_file())
        && VOICE_IDS
            .iter()
            .all(|v| styles.join(format!("{v}.json")).is_file())
}

/// Descarga los pesos desde Hugging Face si faltan. Requiere que el
/// llamador haya mostrado y confirmado el aviso de licencia OpenRAIL-M
/// (`license_acknowledged` — ver [`LICENSE_NOTICE_SOURCE_URL`]); rechaza
/// descargar si no.
///
/// No ejercitada por los tests automáticos de este módulo (depende de red
/// y descarga ~411 MB) — pensada para probarse manualmente o en un test de
/// integración aparte una vez conectada a la UI.
pub async fn ensure_weights_downloaded(
    models_dir: &Path,
    license_acknowledged: bool,
) -> Result<()> {
    if !license_acknowledged {
        bail!(
            "los pesos de Supertonic son OpenRAIL-M: hace falta confirmar el aviso de licencia \
             antes de descargarlos (ver {LICENSE_NOTICE_SOURCE_URL})"
        );
    }
    if is_downloaded(models_dir) {
        return Ok(());
    }

    let onnx = onnx_dir(models_dir);
    let styles = voice_styles_dir(models_dir);
    std::fs::create_dir_all(&onnx)?;
    std::fs::create_dir_all(&styles)?;

    let api = hf_hub::api::tokio::ApiBuilder::from_env()
        .with_progress(false)
        .build()
        .map_err(|e| anyhow::anyhow!("no se pudo inicializar la API de Hugging Face: {e}"))?;
    let repo = api.repo(hf_hub::Repo::with_revision(
        HF_REPO_ID.to_string(),
        hf_hub::RepoType::Model,
        HF_REVISION.to_string(),
    ));

    for filename in ONNX_FILES {
        let cached = repo
            .get(&format!("onnx/{filename}"))
            .await
            .map_err(|e| anyhow::anyhow!("descargando onnx/{filename}: {e}"))?;
        std::fs::copy(&cached, onnx.join(filename))?;
    }
    for voice in VOICE_IDS {
        let repo_filename = format!("voice_styles/{voice}.json");
        let cached = repo
            .get(&repo_filename)
            .await
            .map_err(|e| anyhow::anyhow!("descargando {repo_filename}: {e}"))?;
        std::fs::copy(&cached, styles.join(format!("{voice}.json")))?;
    }
    Ok(())
}

// ============================================================================
// Config / preprocesamiento de texto — puerto directo de
// spikes/voz/supertonic/src/lib.rs, sin cambios de lógica.
// ============================================================================

const AVAILABLE_LANGS: &[&str] = &[
    "en", "ko", "ja", "ar", "bg", "cs", "da", "de", "el", "es", "et", "fi", "fr", "hi", "hr", "hu",
    "id", "it", "lt", "lv", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "tr", "uk", "vi", "na",
];

fn is_valid_lang(lang: &str) -> bool {
    AVAILABLE_LANGS.contains(&lang)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Config {
    ae: AEConfig,
    ttl: TTLConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct AEConfig {
    sample_rate: i32,
    base_chunk_size: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct TTLConfig {
    chunk_compress_factor: i32,
    latent_dim: i32,
}

fn load_cfgs(onnx_dir: &Path) -> Result<Config> {
    let cfg_path = onnx_dir.join("tts.json");
    let file = File::open(&cfg_path)
        .with_context(|| format!("abriendo config de Supertonic: {}", cfg_path.display()))?;
    let reader = BufReader::new(file);
    let cfgs: Config = serde_json::from_reader(reader)?;
    Ok(cfgs)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct VoiceStyleData {
    style_ttl: StyleComponent,
    style_dp: StyleComponent,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StyleComponent {
    data: Vec<Vec<Vec<f32>>>,
    dims: Vec<usize>,
    #[serde(rename = "type")]
    #[allow(dead_code)]
    dtype: String,
}

/// Tensores de estilo de una voz — timbre, independiente del idioma
/// sintetizado (el idioma se elige con un tag de texto, ver
/// `preprocess_text`).
struct Style {
    ttl: Array3<f32>,
    dp: Array3<f32>,
}

fn load_voice_style_single(voice_style_path: &Path) -> Result<Style> {
    let file = File::open(voice_style_path)
        .with_context(|| format!("abriendo estilo de voz: {}", voice_style_path.display()))?;
    let reader = BufReader::new(file);
    let data: VoiceStyleData = serde_json::from_reader(reader)?;

    let ttl_dims = &data.style_ttl.dims;
    let dp_dims = &data.style_dp.dims;

    let ttl_dim1 = ttl_dims[1];
    let ttl_dim2 = ttl_dims[2];
    let dp_dim1 = dp_dims[1];
    let dp_dim2 = dp_dims[2];

    let mut ttl_flat = Vec::with_capacity(ttl_dim1 * ttl_dim2);
    for batch in &data.style_ttl.data {
        for row in batch {
            ttl_flat.extend_from_slice(row);
        }
    }

    let mut dp_flat = Vec::with_capacity(dp_dim1 * dp_dim2);
    for batch in &data.style_dp.data {
        for row in batch {
            dp_flat.extend_from_slice(row);
        }
    }

    let ttl_style = Array3::from_shape_vec((1, ttl_dim1, ttl_dim2), ttl_flat)?;
    let dp_style = Array3::from_shape_vec((1, dp_dim1, dp_dim2), dp_flat)?;

    Ok(Style {
        ttl: ttl_style,
        dp: dp_style,
    })
}

/// Carga las 10 voces publicadas desde `dir` (`<voice>.json` por archivo) en
/// un mapa ya listo para servir cualquiera de ellas sin volver a tocar
/// disco. Separada de `SupertonicEngine::load` para poder testearla sin
/// cargar las sesiones ONNX (que requieren los ~408 MB del checkpoint).
fn load_all_voice_styles(dir: &Path) -> Result<HashMap<VoiceId, Style>> {
    let mut styles = HashMap::with_capacity(VOICE_IDS.len());
    for voice in VOICE_IDS {
        let path = dir.join(format!("{voice}.json"));
        let style =
            load_voice_style_single(&path).with_context(|| format!("cargando voz {voice}"))?;
        styles.insert(VoiceId::new(*voice), style);
    }
    Ok(styles)
}

struct UnicodeProcessor {
    indexer: Vec<i64>,
}

impl UnicodeProcessor {
    fn new(unicode_indexer_json_path: &Path) -> Result<Self> {
        let file = File::open(unicode_indexer_json_path)?;
        let reader = BufReader::new(file);
        let indexer: Vec<i64> = serde_json::from_reader(reader)?;
        Ok(UnicodeProcessor { indexer })
    }

    fn call(
        &self,
        text_list: &[String],
        lang_list: &[String],
    ) -> Result<(Vec<Vec<i64>>, Array3<f32>)> {
        let mut processed_texts: Vec<String> = Vec::new();
        for (text, lang) in text_list.iter().zip(lang_list.iter()) {
            processed_texts.push(preprocess_text(text, lang)?);
        }

        let text_ids_lengths: Vec<usize> =
            processed_texts.iter().map(|t| t.chars().count()).collect();
        let max_len = *text_ids_lengths.iter().max().unwrap_or(&0);

        let mut text_ids = Vec::new();
        for text in &processed_texts {
            let mut row = vec![0i64; max_len];
            let unicode_vals = text_to_unicode_values(text);
            for (j, &val) in unicode_vals.iter().enumerate() {
                if val < self.indexer.len() {
                    row[j] = self.indexer[val];
                } else {
                    row[j] = -1;
                }
            }
            text_ids.push(row);
        }

        let text_mask = get_text_mask(&text_ids_lengths);
        Ok((text_ids, text_mask))
    }
}

/// Normaliza y prepara `text` para el modelo: limpia emojis/símbolos raros,
/// arregla espaciado de puntuación, asegura puntuación final y envuelve el
/// resultado con el tag de idioma (`<es>...</es>`) que el modelo usa para
/// elegir el idioma en tiempo de inferencia. Puerto sin cambios del spike.
fn preprocess_text(text: &str, lang: &str) -> Result<String> {
    let mut text: String = text.nfkd().collect();

    let emoji_pattern = Regex::new(r"[\x{1F600}-\x{1F64F}\x{1F300}-\x{1F5FF}\x{1F680}-\x{1F6FF}\x{1F700}-\x{1F77F}\x{1F780}-\x{1F7FF}\x{1F800}-\x{1F8FF}\x{1F900}-\x{1F9FF}\x{1FA00}-\x{1FA6F}\x{1FA70}-\x{1FAFF}\x{2600}-\x{26FF}\x{2700}-\x{27BF}\x{1F1E6}-\x{1F1FF}]+").unwrap();
    text = emoji_pattern.replace_all(&text, "").to_string();

    let replacements = [
        ("–", "-"),
        ("‑", "-"),
        ("—", "-"),
        ("_", " "),
        ("\u{201C}", "\""),
        ("\u{201D}", "\""),
        ("\u{2018}", "'"),
        ("\u{2019}", "'"),
        ("´", "'"),
        ("`", "'"),
        ("[", " "),
        ("]", " "),
        ("|", " "),
        ("/", " "),
        ("#", " "),
        ("→", " "),
        ("←", " "),
    ];
    for (from, to) in &replacements {
        text = text.replace(from, to);
    }

    let special_symbols = ["♥", "☆", "♡", "©", "\\"];
    for symbol in &special_symbols {
        text = text.replace(symbol, "");
    }

    let expr_replacements = [
        ("@", " at "),
        ("e.g.,", "for example, "),
        ("i.e.,", "that is, "),
    ];
    for (from, to) in &expr_replacements {
        text = text.replace(from, to);
    }

    text = Regex::new(r" ,")
        .unwrap()
        .replace_all(&text, ",")
        .to_string();
    text = Regex::new(r" \.")
        .unwrap()
        .replace_all(&text, ".")
        .to_string();
    text = Regex::new(r" !")
        .unwrap()
        .replace_all(&text, "!")
        .to_string();
    text = Regex::new(r" \?")
        .unwrap()
        .replace_all(&text, "?")
        .to_string();
    text = Regex::new(r" ;")
        .unwrap()
        .replace_all(&text, ";")
        .to_string();
    text = Regex::new(r" :")
        .unwrap()
        .replace_all(&text, ":")
        .to_string();
    text = Regex::new(r" '")
        .unwrap()
        .replace_all(&text, "'")
        .to_string();

    while text.contains("\"\"") {
        text = text.replace("\"\"", "\"");
    }
    while text.contains("''") {
        text = text.replace("''", "'");
    }
    while text.contains("``") {
        text = text.replace("``", "`");
    }

    text = Regex::new(r"\s+")
        .unwrap()
        .replace_all(&text, " ")
        .to_string();
    text = text.trim().to_string();

    if !text.is_empty() {
        let ends_with_punct =
            Regex::new(r#"[.!?;:,'"\u{201C}\u{201D}\u{2018}\u{2019})\]}…。」』】〉》›»]$"#)
                .unwrap();
        if !ends_with_punct.is_match(&text) {
            text.push('.');
        }
    }

    if !is_valid_lang(lang) {
        bail!("idioma inválido: {lang}. Disponibles: {AVAILABLE_LANGS:?}");
    }

    text = format!("<{lang}>{text}</{lang}>");
    Ok(text)
}

fn text_to_unicode_values(text: &str) -> Vec<usize> {
    text.chars().map(|c| c as usize).collect()
}

fn length_to_mask(lengths: &[usize], max_len: Option<usize>) -> Array3<f32> {
    let bsz = lengths.len();
    let max_len = max_len.unwrap_or_else(|| *lengths.iter().max().unwrap_or(&0));

    let mut mask = Array3::<f32>::zeros((bsz, 1, max_len));
    for (i, &len) in lengths.iter().enumerate() {
        for j in 0..len.min(max_len) {
            mask[[i, 0, j]] = 1.0;
        }
    }
    mask
}

fn get_text_mask(text_ids_lengths: &[usize]) -> Array3<f32> {
    let max_len = *text_ids_lengths.iter().max().unwrap_or(&0);
    length_to_mask(text_ids_lengths, Some(max_len))
}

fn sample_noisy_latent(
    duration: &[f32],
    sample_rate: i32,
    base_chunk_size: i32,
    chunk_compress: i32,
    latent_dim: i32,
) -> (Array3<f32>, Array3<f32>) {
    let bsz = duration.len();
    let max_dur = duration.iter().fold(0.0f32, |a, &b| a.max(b));

    let wav_len_max = (max_dur * sample_rate as f32) as usize;
    let wav_lengths: Vec<usize> = duration
        .iter()
        .map(|&d| (d * sample_rate as f32) as usize)
        .collect();

    let chunk_size = (base_chunk_size * chunk_compress) as usize;
    let latent_len = wav_len_max.div_ceil(chunk_size);
    let latent_dim_val = (latent_dim * chunk_compress) as usize;

    let mut noisy_latent = Array3::<f32>::zeros((bsz, latent_dim_val, latent_len));

    let normal = Normal::new(0.0, 1.0).unwrap();
    let mut rng = rand::thread_rng();

    for b in 0..bsz {
        for d in 0..latent_dim_val {
            for t in 0..latent_len {
                noisy_latent[[b, d, t]] = normal.sample(&mut rng);
            }
        }
    }

    let latent_lengths: Vec<usize> = wav_lengths
        .iter()
        .map(|&len| len.div_ceil(chunk_size))
        .collect();
    let latent_mask = length_to_mask(&latent_lengths, Some(latent_len));

    for b in 0..bsz {
        for d in 0..latent_dim_val {
            for t in 0..latent_len {
                noisy_latent[[b, d, t]] *= latent_mask[[b, 0, t]];
            }
        }
    }

    (noisy_latent, latent_mask)
}

// ============================================================================
// El motor
// ============================================================================

/// Motor local Supertonic 3. Las 4 sesiones ONNX se cargan una sola vez en
/// [`SupertonicEngine::load`] y quedan detrás de un `Mutex` (el API de
/// `ort::Session::run` requiere `&mut self`, pero `TtsEngine::speak_streaming`
/// recibe `&self` — Dilo necesita poder compartir el motor activo en el
/// estado de la app). Las 10 voces se preloadean ahí mismo, así que
/// [`TtsEngine::speak_streaming`] nunca vuelve a tocar disco al cambiar de
/// voz.
pub struct SupertonicEngine {
    cfgs: Config,
    text_processor: UnicodeProcessor,
    dp_ort: Mutex<Session>,
    text_enc_ort: Mutex<Session>,
    vector_est_ort: Mutex<Session>,
    vocoder_ort: Mutex<Session>,
    sample_rate: i32,
    styles: HashMap<VoiceId, Style>,
}

impl SupertonicEngine {
    /// Carga el checkpoint compartido desde `onnx_dir` (los 6 archivos de
    /// [`ONNX_FILES`]) y las 10 voces desde `voice_styles_dir`
    /// (`<voz>.json`). Ambos directorios deben existir en disco de
    /// antemano — usar [`ensure_weights_downloaded`] antes si hace falta.
    pub fn load(onnx_dir: &Path, voice_styles_dir: &Path) -> Result<Self> {
        let cfgs = load_cfgs(onnx_dir)?;

        let dp_ort =
            Session::builder()?.commit_from_file(onnx_dir.join("duration_predictor.onnx"))?;
        let text_enc_ort =
            Session::builder()?.commit_from_file(onnx_dir.join("text_encoder.onnx"))?;
        let vector_est_ort =
            Session::builder()?.commit_from_file(onnx_dir.join("vector_estimator.onnx"))?;
        let vocoder_ort = Session::builder()?.commit_from_file(onnx_dir.join("vocoder.onnx"))?;

        let text_processor = UnicodeProcessor::new(&onnx_dir.join("unicode_indexer.json"))?;
        let styles = load_all_voice_styles(voice_styles_dir)?;

        let sample_rate = cfgs.ae.sample_rate;
        Ok(Self {
            cfgs,
            text_processor,
            dp_ort: Mutex::new(dp_ort),
            text_enc_ort: Mutex::new(text_enc_ort),
            vector_est_ort: Mutex::new(vector_est_ort),
            vocoder_ort: Mutex::new(vocoder_ort),
            sample_rate,
            styles,
        })
    }

    /// Sintetiza `text` (ya un fragmento corto, no un párrafo — la
    /// segmentación vive en `streaming.rs`) con el `style` dado. Devuelve
    /// las muestras PCM f32 mono y la duración en segundos. Puerto directo
    /// de `TextToSpeech::_infer` + `TextToSpeech::call` del spike.
    fn synthesize(&self, text: &str, style: &Style) -> Result<(Vec<f32>, f32)> {
        let text_list = [text.to_string()];
        let lang_list = [LANG.to_string()];
        let bsz = 1usize;

        let (text_ids, text_mask) = self.text_processor.call(&text_list, &lang_list)?;

        let text_ids_array = {
            let shape = (bsz, text_ids[0].len());
            let mut flat = Vec::new();
            for row in &text_ids {
                flat.extend_from_slice(row);
            }
            Array::from_shape_vec(shape, flat)?
        };

        let text_ids_value = Value::from_array(text_ids_array)?;
        let text_mask_value = Value::from_array(text_mask.clone())?;
        let style_dp_value = Value::from_array(style.dp.clone())?;

        let mut dp_ort = self.dp_ort.lock().unwrap();
        let dp_outputs = dp_ort.run(ort::inputs! {
            "text_ids" => &text_ids_value,
            "style_dp" => &style_dp_value,
            "text_mask" => &text_mask_value
        })?;

        let (_, duration_data) = dp_outputs["duration"].try_extract_tensor::<f32>()?;
        let mut duration: Vec<f32> = duration_data.to_vec();
        for dur in duration.iter_mut() {
            *dur /= SPEED;
        }

        let style_ttl_value = Value::from_array(style.ttl.clone())?;
        let mut text_enc_ort = self.text_enc_ort.lock().unwrap();
        let text_enc_outputs = text_enc_ort.run(ort::inputs! {
            "text_ids" => &text_ids_value,
            "style_ttl" => &style_ttl_value,
            "text_mask" => &text_mask_value
        })?;

        let (text_emb_shape, text_emb_data) =
            text_enc_outputs["text_emb"].try_extract_tensor::<f32>()?;
        let text_emb = Array3::from_shape_vec(
            (
                text_emb_shape[0] as usize,
                text_emb_shape[1] as usize,
                text_emb_shape[2] as usize,
            ),
            text_emb_data.to_vec(),
        )?;

        let (mut xt, latent_mask) = sample_noisy_latent(
            &duration,
            self.sample_rate,
            self.cfgs.ae.base_chunk_size,
            self.cfgs.ttl.chunk_compress_factor,
            self.cfgs.ttl.latent_dim,
        );

        let total_step_array = Array::from_elem(bsz, TOTAL_STEP as f32);

        for step in 0..TOTAL_STEP {
            let current_step_array = Array::from_elem(bsz, step as f32);

            let xt_value = Value::from_array(xt.clone())?;
            let text_emb_value = Value::from_array(text_emb.clone())?;
            let latent_mask_value = Value::from_array(latent_mask.clone())?;
            let text_mask_value2 = Value::from_array(text_mask.clone())?;
            let current_step_value = Value::from_array(current_step_array)?;
            let total_step_value = Value::from_array(total_step_array.clone())?;

            let mut vector_est_ort = self.vector_est_ort.lock().unwrap();
            let vector_est_outputs = vector_est_ort.run(ort::inputs! {
                "noisy_latent" => &xt_value,
                "text_emb" => &text_emb_value,
                "style_ttl" => &style_ttl_value,
                "latent_mask" => &latent_mask_value,
                "text_mask" => &text_mask_value2,
                "current_step" => &current_step_value,
                "total_step" => &total_step_value
            })?;

            let (denoised_shape, denoised_data) =
                vector_est_outputs["denoised_latent"].try_extract_tensor::<f32>()?;
            xt = Array3::from_shape_vec(
                (
                    denoised_shape[0] as usize,
                    denoised_shape[1] as usize,
                    denoised_shape[2] as usize,
                ),
                denoised_data.to_vec(),
            )?;
        }

        let final_latent_value = Value::from_array(xt)?;
        let mut vocoder_ort = self.vocoder_ort.lock().unwrap();
        let vocoder_outputs = vocoder_ort.run(ort::inputs! { "latent" => &final_latent_value })?;

        let (_, wav_data) = vocoder_outputs["wav_tts"].try_extract_tensor::<f32>()?;
        let wav: Vec<f32> = wav_data.to_vec();

        let dur = duration[0];
        let wav_len = (self.sample_rate as f32 * dur) as usize;
        Ok((wav[..wav_len.min(wav.len())].to_vec(), dur))
    }
}

fn voice_gender(id: &str) -> VoiceGender {
    if id.starts_with('F') {
        VoiceGender::Female
    } else {
        VoiceGender::Male
    }
}

/// El mismo catálogo que [`TtsEngine::voices`] devuelve, pero sin necesitar
/// una instancia cargada del motor (las 4 sesiones ONNX, ~408 MB). Los
/// metadatos de voz son estáticos — no dependen de los pesos en disco — así
/// que la UI puede mostrar el selector de voces antes de sintetizar nada.
pub fn voice_catalog() -> Vec<VoiceInfo> {
    VOICE_IDS
        .iter()
        .map(|id| VoiceInfo {
            id: VoiceId::new(*id),
            name: format!("Voz {id}"),
            gender: voice_gender(id),
        })
        .collect()
}

impl TtsEngine for SupertonicEngine {
    fn speak_streaming(
        &self,
        text: &str,
        voice: &VoiceId,
        on_chunk: &mut dyn FnMut(AudioChunk) -> TtsResult<()>,
    ) -> TtsResult<()> {
        let style = self
            .styles
            .get(voice)
            .ok_or_else(|| TtsError::UnknownVoice(voice.clone()))?;

        let (samples, _duration_s) = self
            .synthesize(text, style)
            .map_err(|e| TtsError::Synthesis(e.to_string()))?;

        on_chunk(AudioChunk {
            samples,
            sample_rate: self.sample_rate as u32,
            channels: 1,
        })
    }

    fn voices(&self) -> Vec<VoiceInfo> {
        voice_catalog()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn ten_voices_five_female_five_male_default_is_f5() {
        assert_eq!(VOICE_IDS.len(), 10);
        assert_eq!(VOICE_IDS.iter().filter(|v| v.starts_with('F')).count(), 5);
        assert_eq!(VOICE_IDS.iter().filter(|v| v.starts_with('M')).count(), 5);
        assert!(VOICE_IDS.contains(&DEFAULT_VOICE));
        assert_eq!(DEFAULT_VOICE, "F5");
    }

    #[test]
    fn voice_gender_matches_id_prefix() {
        assert_eq!(voice_gender("F3"), VoiceGender::Female);
        assert_eq!(voice_gender("M1"), VoiceGender::Male);
    }

    #[test]
    fn voice_catalog_lists_all_ten_without_loading_the_engine() {
        // No SupertonicEngine se construye en este test — justo el punto:
        // la UI puede pedir la lista de voces sin pagar la carga de las 4
        // sesiones ONNX.
        let catalog = voice_catalog();
        assert_eq!(catalog.len(), 10);
        assert!(catalog.iter().any(|v| v.id == VoiceId::new("F5")));
        assert_eq!(
            catalog
                .iter()
                .find(|v| v.id == VoiceId::new("M2"))
                .unwrap()
                .gender,
            VoiceGender::Male
        );
    }

    #[test]
    fn preprocess_text_adds_missing_final_punctuation_and_language_tag() {
        let out = preprocess_text("Hola Alfonso", "es").unwrap();
        assert_eq!(out, "<es>Hola Alfonso.</es>");
    }

    #[test]
    fn preprocess_text_keeps_existing_final_punctuation() {
        let out = preprocess_text("¿Todo listo?", "es").unwrap();
        assert_eq!(out, "<es>¿Todo listo?</es>");
    }

    #[test]
    fn preprocess_text_normalizes_smart_quotes_and_dashes() {
        let out = preprocess_text("dijo \u{201C}hola\u{201D} \u{2014} ya", "es").unwrap();
        assert!(out.contains("\"hola\""));
        assert!(out.contains('-'));
    }

    #[test]
    fn preprocess_text_rejects_unknown_language() {
        let err = preprocess_text("hola", "xx").unwrap_err();
        assert!(err.to_string().contains("idioma inválido"));
    }

    /// Un JSON de estilo mínimo pero válido (dims/datos consistentes) para
    /// no depender de los pesos reales (~285 KB cada uno, descargados de
    /// Hugging Face) en un test unitario.
    fn write_fake_voice_style(path: &Path) {
        let json = serde_json::json!({
            "style_ttl": {
                "data": [[[0.1_f32, 0.2, 0.3]]],
                "dims": [1, 1, 3],
                "type": "float32"
            },
            "style_dp": {
                "data": [[[0.4_f32, 0.5]]],
                "dims": [1, 1, 2],
                "type": "float32"
            }
        });
        let mut file = File::create(path).unwrap();
        write!(file, "{}", serde_json::to_string(&json).unwrap()).unwrap();
    }

    #[test]
    fn load_all_voice_styles_preloads_all_ten_without_touching_disk_again() {
        let dir = tempfile::tempdir().unwrap();
        for voice in VOICE_IDS {
            write_fake_voice_style(&dir.path().join(format!("{voice}.json")));
        }

        let styles = load_all_voice_styles(dir.path()).expect("las 10 voces deben cargar");

        // Esto es justamente lo que garantiza "cambiar de voz no recarga el
        // modelo": las 10 ya están en memoria en un HashMap tras `load`, no
        // hay ningún camino de código que vuelva a `File::open` al elegir
        // una voz distinta.
        assert_eq!(styles.len(), 10);
        for voice in VOICE_IDS {
            assert!(
                styles.contains_key(&VoiceId::new(*voice)),
                "falta la voz {voice} en el mapa preloadeado"
            );
        }
    }

    #[test]
    fn is_downloaded_false_on_empty_dir_true_once_all_files_present() {
        let dir = tempfile::tempdir().unwrap();
        assert!(!is_downloaded(dir.path()));

        let onnx = onnx_dir(dir.path());
        let styles = voice_styles_dir(dir.path());
        std::fs::create_dir_all(&onnx).unwrap();
        std::fs::create_dir_all(&styles).unwrap();
        for f in ONNX_FILES {
            File::create(onnx.join(f)).unwrap();
        }
        // Falta a propósito la última voz para probar el caso parcial.
        for voice in &VOICE_IDS[..9] {
            File::create(styles.join(format!("{voice}.json"))).unwrap();
        }
        assert!(
            !is_downloaded(dir.path()),
            "no debería contar como descargado si falta una voz"
        );

        File::create(styles.join(format!("{}.json", VOICE_IDS[9]))).unwrap();
        assert!(is_downloaded(dir.path()));
    }

    #[test]
    fn weights_dir_follows_the_model_manager_layout() {
        let models_dir = Path::new("/tmp/dilo-app-data/models");
        assert_eq!(
            weights_dir(models_dir),
            models_dir.join("tts").join("supertonic-3")
        );
    }

    #[test]
    fn license_notice_points_at_the_real_openrail_m_license() {
        assert!(LICENSE_NOTICE_SOURCE_URL.contains("supertonic-3"));
        assert!(LICENSE_NOTICE_SOURCE_URL.contains("LICENSE"));
    }
}
