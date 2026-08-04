//! Sonda temporal (Task 1 del plan "reuniones en streaming"): compara la
//! diarización con Sortformer streaming (NVIDIA NeMo, exportado a ONNX)
//! contra la diarización actual de Dilo (`DiarizationEngine::diarize`,
//! pyannote-segmentation-3.0 + CAM++) sobre el mismo audio real en español,
//! para decidir si Sortformer sirve como reemplazo.
//!
//! Este archivo es descartable, no producción: si el veredicto en
//! `.superpowers/sdd/2026-08-04-reuniones-en-streaming/task-1-report.md` no
//! es favorable, el plan se detiene acá y este archivo se borra (o se borra
//! de todos modos al empezar la Task 2 si el plan sigue). No lo referencia
//! ningún otro módulo — sólo el test `#[ignore]` de más abajo, que corre a
//! mano.
//!
//! ## Por qué esto no es "cargar el .onnx y correr un forward"
//!
//! El brief (Step 2) imaginaba correr Sortformer con un solo forward pass
//! sobre el WAV, como el resto de los modelos ONNX que ya usa Dilo. La
//! metadata real del modelo (`Scrybl/diar_streaming_sortformer_4spk-v2.1`,
//! confirmado inspeccionando el grafo con `onnx.load`) dice otra cosa: seis
//! inputs (`chunk, chunk_lengths, spkcache, spkcache_lengths, fifo,
//! fifo_lengths`) y metadata custom `chunk_len=124, fifo_len=124,
//! spkcache_len=188, right_context=1` — es un modelo *streaming* que no
//! toma audio crudo (toma log-mel de 128 bandas) y que mantiene estado
//! (`spkcache`/`fifo`, un caché de embeddings de hablante) entre llamadas.
//! Correrlo "offline" sobre un WAV completo significa igual alimentar el
//! estado en pasos, como si fuera streaming en tiempo real pero sin esperar
//! el reloj real.
//!
//! Siguiendo la instrucción del brief para este caso exacto ("si la
//! inferencia resulta más enredada... la referencia es el fork de
//! sherpa-onnx del issue #3497"), todo lo de acá abajo —extracción de
//! features, máquina de estados de streaming, post-proceso— es un port
//! directo de
//! <https://github.com/scottyeager/sherpa-onnx/blob/sortformer-diarization/sherpa-onnx/csrc/offline-sortformer-diarization.cc>
//! (rama real `sortformer-diarization`; el brief decía `sortformer-di`, que
//! no existe — confirmado con `git ls-remote --heads`), que sherpa-onnx
//! documenta con ~99.5% de paridad frente al NeMo original. Cada función de
//! acá abajo referencia en su doc comment la función C++ de la que es port
//! directo; las constantes (STFT/mel, streaming, umbrales de post-proceso)
//! son los defaults de esa misma referencia, no inventados ni ajustados a
//! mano.
//!
//! La única pieza reutilizada del propio Rfft de `kaldi-native-fbank`
//! (dependencia ya presente en el árbol, usada por [`super::EmbeddingModel`]
//! para Fbank) es la FFT real empaquetada — su formato de salida
//! (`[Re(0), Re(N/2), Re(1), Im(1), ...]`) coincide exactamente con lo que
//! la referencia C++ espera de `knf::Rfft`, así que no hace falta escribir
//! ni depender de otra FFT.

use anyhow::{bail, Context, Result};
use ndarray::{Array1, Array3};
use ort::session::Session;
use ort::value::Value;
use std::path::Path;
use std::time::Instant;

use crate::audio_toolkit::read_wav_samples;

// ============================================================================
// Constantes -- todas tomadas de offline-sortformer-diarization.cc (ver doc
// comment del módulo), no inventadas.
// ============================================================================

const SAMPLE_RATE: usize = 16_000;
const N_FFT: usize = 512;
const WIN_LENGTH: usize = 400; // 25 ms
const HOP_LENGTH: usize = 160; // 10 ms
const N_MELS: usize = 128;
const NUM_SPEAKERS: usize = 4;
const EMB_DIM: usize = 512;
const SUBSAMPLING: usize = 8; // frames mel -> frames de modelo
const PREEMPH: f32 = 0.97;
const LOG_GUARD: f32 = 5.960_464_5e-8; // 2^-24
/// Duración de un frame de audio a la tasa de 10 ms (`HOP_LENGTH / SAMPLE_RATE`),
/// usada en el post-proceso tipo VAD tras el `repeat_interleave` por
/// subsampling. Literal en vez de calculada en `const` para no depender de
/// que la división de enteros-a-flotante sea const-evaluable en toda
/// versión de Rust.
const AUDIO_FRAME_DURATION_S: f32 = 0.01;

// `_compress_spkcache` (NeMo) -- hiperparámetros de entrenamiento omitidos,
// sólo los que la inferencia necesita.
const SIL_FRAMES_PER_SPK: usize = 3;
const STRONG_BOOST_RATE: f32 = 0.75;
const WEAK_BOOST_RATE: f32 = 1.5;
const MIN_POS_SCORES_RATE: f32 = 0.5;
const SCORES_BOOST_LATEST: f32 = 0.05;
const PRED_SCORE_THRESHOLD: f32 = 0.25;
const SIL_THRESHOLD: f32 = 0.2;
const MAX_INDEX: i32 = 99_999;

/// `OfflineSortformerDiarizationConfig` -- streaming (leído/sobre-escrito
/// desde la metadata custom del .onnx) + post-proceso (defaults documentados
/// de la referencia; el checkpoint no trae overrides para éstos).
struct SortformerCfg {
    chunk_len: i64,
    fifo_len: i64,
    spkcache_len: i64,
    right_context: i64,
    spkcache_update_period: i64,
    onset: f32,
    offset: f32,
    pad_onset: f32,
    pad_offset: f32,
    min_duration_on: f32,
    min_duration_off: f32,
    median_window: i32,
}

impl Default for SortformerCfg {
    fn default() -> Self {
        Self {
            chunk_len: 124,
            fifo_len: 124,
            spkcache_len: 188,
            right_context: 1,
            spkcache_update_period: 188,
            onset: 0.641,
            offset: 0.561,
            pad_onset: 0.229,
            pad_offset: 0.079,
            min_duration_on: 0.511,
            min_duration_off: 0.296,
            median_window: 11,
        }
    }
}

/// `ReadIntMetaData`: lee un entero de la metadata custom del ONNX si está,
/// si no devuelve `fallback` en silencio -- a propósito más permisivo que
/// [`super::read_i32_metadata`] (que este módulo también podría reusar, pero
/// que falla si la clave no existe: acá `spkcache_update_period` de hecho no
/// está presente en la metadata real del checkpoint, sólo
/// `chunk_len`/`fifo_len`/`spkcache_len`/`right_context`).
fn read_i32_metadata_or(session: &Session, key: &str, fallback: i32) -> i32 {
    super::read_string_metadata(session, key)
        .and_then(|s| s.trim().parse::<i32>().ok())
        .unwrap_or(fallback)
}

fn load_sortformer_session(path: &Path) -> Result<(Session, SortformerCfg)> {
    let session = Session::builder()?
        .commit_from_file(path)
        .with_context(|| format!("cargando modelo Sortformer: {}", path.display()))?;

    let mut cfg = SortformerCfg::default();
    cfg.chunk_len = read_i32_metadata_or(&session, "chunk_len", cfg.chunk_len as i32) as i64;
    cfg.fifo_len = read_i32_metadata_or(&session, "fifo_len", cfg.fifo_len as i32) as i64;
    cfg.spkcache_len =
        read_i32_metadata_or(&session, "spkcache_len", cfg.spkcache_len as i32) as i64;
    cfg.right_context =
        read_i32_metadata_or(&session, "right_context", cfg.right_context as i32) as i64;
    cfg.spkcache_update_period = read_i32_metadata_or(
        &session,
        "spkcache_update_period",
        cfg.spkcache_update_period as i32,
    ) as i64;

    Ok((session, cfg))
}

// ============================================================================
// Extracción de features -- `ExtractMelFeatures` + `BuildHannWindow` +
// `BuildMelFilterbank` (mel-spectrograma log, estilo NeMo
// AudioToMelSpectrogramPreprocessor: Slaney, NO Kaldi/HTK -- distinto del
// banco de mel que usa `EmbeddingModel::compute` en el módulo padre).
// ============================================================================

/// `BuildHannWindow`: Hann periódica (fftbins=True, se divide por N no por
/// N-1), centrada con padding de ceros hasta `N_FFT`.
fn build_hann_window() -> Vec<f32> {
    let mut window = vec![0.0f32; N_FFT];
    let offset = (N_FFT - WIN_LENGTH) / 2;
    for i in 0..WIN_LENGTH {
        let w = 0.5 - 0.5 * (2.0 * std::f32::consts::PI * i as f32 / WIN_LENGTH as f32).cos();
        window[offset + i] = w;
    }
    window
}

/// `HzToMelSlaney` / `MelToHzSlaney`: escala mel de Slaney (la que usa
/// librosa con `htk=False`), no la fórmula Kaldi/HTK
/// (`1127*ln(1+f/700)`) que usa el resto de este módulo para Fbank.
fn hz_to_mel_slaney(hz: f64) -> f64 {
    const F_SP: f64 = 200.0 / 3.0;
    const MIN_LOG_HZ: f64 = 1000.0;
    const MIN_LOG_MEL: f64 = MIN_LOG_HZ / F_SP;
    const LOG_STEP: f64 = 0.068_751_777_420_949_12; // ln(6.4) / 27.0
    if hz < MIN_LOG_HZ {
        hz / F_SP
    } else {
        MIN_LOG_MEL + (hz / MIN_LOG_HZ).ln() / LOG_STEP
    }
}

fn mel_to_hz_slaney(mel: f64) -> f64 {
    const F_SP: f64 = 200.0 / 3.0;
    const MIN_LOG_HZ: f64 = 1000.0;
    const MIN_LOG_MEL: f64 = MIN_LOG_HZ / F_SP;
    const LOG_STEP: f64 = 0.068_751_777_420_949_12;
    if mel < MIN_LOG_MEL {
        mel * F_SP
    } else {
        MIN_LOG_HZ * ((mel - MIN_LOG_MEL) * LOG_STEP).exp()
    }
}

/// `BuildMelFilterbank`: banco triangular estilo Slaney con normalización
/// Slaney (`enorm = 2 / (mel[i+2] - mel[i])`), igual que librosa `htk=False`.
/// Devuelve `(N_MELS, freq_bins)` row-major, `freq_bins = N_FFT/2 + 1`.
fn build_mel_filterbank() -> Vec<f32> {
    let freq_bins = N_FFT / 2 + 1;
    let mut mel_basis = vec![0.0f32; N_MELS * freq_bins];

    let fmax = SAMPLE_RATE as f64 / 2.0;
    let mel_min = hz_to_mel_slaney(0.0);
    let mel_max = hz_to_mel_slaney(fmax);

    let mel_points: Vec<f64> = (0..N_MELS + 2)
        .map(|i| {
            let mel = mel_min + (mel_max - mel_min) * i as f64 / (N_MELS + 1) as f64;
            mel_to_hz_slaney(mel)
        })
        .collect();

    let fft_freqs: Vec<f64> = (0..freq_bins)
        .map(|k| k as f64 * SAMPLE_RATE as f64 / N_FFT as f64)
        .collect();

    let fdiff: Vec<f64> = (0..N_MELS + 1)
        .map(|i| mel_points[i + 1] - mel_points[i])
        .collect();

    for i in 0..N_MELS {
        let enorm = 2.0 / (mel_points[i + 2] - mel_points[i]);
        for k in 0..freq_bins {
            let lower = (fft_freqs[k] - mel_points[i]) / fdiff[i];
            let upper = (mel_points[i + 2] - fft_freqs[k]) / fdiff[i + 1];
            let v = lower.min(upper).max(0.0) * enorm;
            mel_basis[i * freq_bins + k] = v as f32;
        }
    }

    mel_basis
}

fn apply_preemphasis(audio: &[f32]) -> Vec<f32> {
    let mut out = vec![0.0f32; audio.len()];
    if audio.is_empty() {
        return out;
    }
    out[0] = audio[0];
    for i in 1..audio.len() {
        out[i] = audio[i] - PREEMPH * audio[i - 1];
    }
    out
}

/// `ExtractMelFeatures`: log-mel-spectrograma completo del audio, en un solo
/// paso (a diferencia del resto de la sonda, que sí es streaming). Devuelve
/// `(num_mel_frames, N_MELS)` row-major.
fn extract_mel_features(audio: &[f32], window: &[f32], mel_basis: &[f32]) -> Vec<f32> {
    let preemph = apply_preemphasis(audio);

    // Padding con CEROS de N_FFT/2 a cada lado -- así lo hace la referencia
    // (no es el padding "reflect" que usa librosa por defecto).
    let pad = N_FFT / 2;
    let mut padded = vec![0.0f32; preemph.len() + 2 * pad];
    padded[pad..pad + preemph.len()].copy_from_slice(&preemph);

    let total = padded.len();
    let num_frames = if total >= N_FFT {
        (total - N_FFT) / HOP_LENGTH + 1
    } else {
        0
    };
    if num_frames == 0 {
        return vec![];
    }

    let freq_bins = N_FFT / 2 + 1;
    let mut out = vec![0.0f32; num_frames * N_MELS];

    let mut rfft = kaldi_native_fbank::rfft::Rfft::new(N_FFT, false);
    let mut fft_buf = vec![0.0f32; N_FFT];
    let mut power = vec![0.0f32; freq_bins];

    for t in 0..num_frames {
        let start = t * HOP_LENGTH;
        for i in 0..N_FFT {
            fft_buf[i] = padded[start + i] * window[i];
        }
        rfft.compute(&mut fft_buf);

        power[0] = fft_buf[0] * fft_buf[0];
        power[freq_bins - 1] = fft_buf[1] * fft_buf[1];
        for k in 1..freq_bins - 1 {
            let r = fft_buf[2 * k];
            let im = fft_buf[2 * k + 1];
            power[k] = r * r + im * im;
        }

        let out_row = &mut out[t * N_MELS..(t + 1) * N_MELS];
        for (m, out_m) in out_row.iter_mut().enumerate() {
            let mel_row = &mel_basis[m * freq_bins..(m + 1) * freq_bins];
            let acc: f32 = mel_row.iter().zip(power.iter()).map(|(w, p)| w * p).sum();
            *out_m = (acc + LOG_GUARD).ln();
        }
    }

    out
}

// ============================================================================
// Estado de streaming -- campos de `Impl` en la referencia (spkcache/fifo +
// sus predicciones asociadas + perfil de silencio).
// ============================================================================

struct StreamState {
    /// `(spkcache_frames, EMB_DIM)` row-major.
    spkcache: Vec<f32>,
    spkcache_frames: usize,
    /// `(spkcache_frames, NUM_SPEAKERS)` row-major.
    spkcache_preds: Vec<f32>,
    spkcache_preds_initialized: bool,
    /// `(fifo_frames, EMB_DIM)` row-major.
    fifo: Vec<f32>,
    fifo_frames: usize,
    /// `(fifo_frames, NUM_SPEAKERS)` row-major.
    fifo_preds: Vec<f32>,
    /// Media móvil de embeddings "de silencio", `(EMB_DIM,)`.
    mean_sil_emb: Vec<f32>,
    n_sil_frames: i64,
}

impl StreamState {
    fn new() -> Self {
        Self {
            spkcache: Vec::new(),
            spkcache_frames: 0,
            spkcache_preds: Vec::new(),
            spkcache_preds_initialized: false,
            fifo: Vec::new(),
            fifo_frames: 0,
            fifo_preds: Vec::new(),
            mean_sil_emb: vec![0.0; EMB_DIM],
            n_sil_frames: 0,
        }
    }
}

/// `_get_log_pred_scores`: score alto para frames de un solo hablante
/// confiado, usado por [`compress_spkcache`] para decidir qué frames
/// conservar en el caché al comprimirlo.
fn get_log_pred_scores(preds: &[f32], n: usize, n_spk: usize) -> Vec<f32> {
    let thresh = PRED_SCORE_THRESHOLD;
    let log2 = std::f32::consts::LN_2;
    let mut scores = vec![0.0f32; n * n_spk];
    let mut b = vec![0.0f32; n_spk];
    for t in 0..n {
        let mut sum_b = 0.0f32;
        for s in 0..n_spk {
            let p = preds[t * n_spk + s];
            let b_s = (1.0 - p).max(thresh).ln();
            b[s] = b_s;
            sum_b += b_s;
        }
        for s in 0..n_spk {
            let p = preds[t * n_spk + s];
            let a = p.max(thresh).ln();
            scores[t * n_spk + s] = a - b[s] + sum_b + log2;
        }
    }
    scores
}

/// `_disable_low_scores`.
fn disable_low_scores(
    preds: &[f32],
    n: usize,
    n_spk: usize,
    min_pos_scores_per_spk: i32,
    scores: &mut [f32],
) {
    let neg_inf = f32::NEG_INFINITY;
    for t in 0..n {
        for s in 0..n_spk {
            if preds[t * n_spk + s] <= 0.5 {
                scores[t * n_spk + s] = neg_inf;
            }
        }
    }
    let mut pos_count = vec![0i32; n_spk];
    for t in 0..n {
        for s in 0..n_spk {
            if scores[t * n_spk + s] > 0.0 {
                pos_count[s] += 1;
            }
        }
    }
    for s in 0..n_spk {
        if pos_count[s] < min_pos_scores_per_spk {
            continue;
        }
        for t in 0..n {
            let v = scores[t * n_spk + s];
            if v <= 0.0 && preds[t * n_spk + s] > 0.5 {
                scores[t * n_spk + s] = neg_inf;
            }
        }
    }
}

/// `_boost_topk_scores`: por hablante, encuentra los `n_boost` frames de
/// mayor score y les suma `scale_factor * ln(2)`.
fn boost_topk_scores(scores: &mut [f32], n: usize, n_spk: usize, n_boost: i32, scale_factor: f32) {
    if n_boost <= 0 || n == 0 {
        return;
    }
    let delta = scale_factor * std::f32::consts::LN_2;
    let k = (n_boost as usize).min(n);
    for s in 0..n_spk {
        let mut pairs: Vec<(f32, usize)> = (0..n).map(|t| (scores[t * n_spk + s], t)).collect();
        pairs.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
        for &(_, t) in pairs.iter().take(k) {
            // -inf + delta se mantiene -inf, igual que el original en C++.
            scores[t * n_spk + s] += delta;
        }
    }
}

/// `_get_topk_indices`: elige, sobre `n_frames_data` frames reales más
/// [`SIL_FRAMES_PER_SPK`] slots "de silencio" por hablante, los
/// `spkcache_len` de mayor score; devuelve el índice temporal de cada slot
/// elegido y si quedó deshabilitado (se llena con el embedding medio de
/// silencio).
fn get_topk_indices(
    scores: &[f32],
    n_frames_data: usize,
    n_spk: usize,
    spkcache_len: usize,
) -> (Vec<i32>, Vec<bool>) {
    let n_sil = SIL_FRAMES_PER_SPK;
    let n_frames_total = n_frames_data + n_sil;
    let pos_inf = f32::INFINITY;
    let neg_inf = f32::NEG_INFINITY;

    let mut pairs: Vec<(f32, i32)> = Vec::with_capacity(n_frames_total * n_spk);
    for s in 0..n_spk {
        let base = (s * n_frames_total) as i32;
        for t in 0..n_frames_data {
            pairs.push((scores[t * n_spk + s], base + t as i32));
        }
        for k in 0..n_sil {
            pairs.push((pos_inf, base + n_frames_data as i32 + k as i32));
        }
    }

    let total = pairs.len();
    let take = spkcache_len.min(total);
    if take < total {
        pairs.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
    }
    pairs.truncate(take);

    for p in pairs.iter_mut() {
        if p.0 == neg_inf {
            p.1 = MAX_INDEX;
        }
    }
    pairs.sort_by_key(|p| p.1);

    let mut time_indices = vec![0i32; spkcache_len];
    let mut is_disabled = vec![false; spkcache_len];
    for k in 0..spkcache_len {
        if k >= take {
            is_disabled[k] = true;
            continue;
        }
        let fi = pairs[k].1;
        let mut disabled = fi == MAX_INDEX;
        let mut time_idx = 0i32;
        if !disabled {
            time_idx = fi % n_frames_total as i32;
            if time_idx as usize >= n_frames_data {
                disabled = true;
            }
        }
        time_indices[k] = if disabled { 0 } else { time_idx };
        is_disabled[k] = disabled;
    }
    (time_indices, is_disabled)
}

/// `_gather_spkcache_and_preds`: slots deshabilitados resuelven al embedding
/// medio de silencio + predicciones cero.
fn gather_spkcache_and_preds(
    state: &StreamState,
    time_indices: &[i32],
    is_disabled: &[bool],
    spkcache_len: usize,
) -> (Vec<f32>, Vec<f32>) {
    let n_spk = NUM_SPEAKERS;
    let mut new_cache = vec![0.0f32; spkcache_len * EMB_DIM];
    let mut new_preds = vec![0.0f32; spkcache_len * n_spk];
    for k in 0..spkcache_len {
        if is_disabled[k] {
            new_cache[k * EMB_DIM..(k + 1) * EMB_DIM].copy_from_slice(&state.mean_sil_emb);
        } else {
            let t = time_indices[k] as usize;
            new_cache[k * EMB_DIM..(k + 1) * EMB_DIM]
                .copy_from_slice(&state.spkcache[t * EMB_DIM..(t + 1) * EMB_DIM]);
            new_preds[k * n_spk..(k + 1) * n_spk]
                .copy_from_slice(&state.spkcache_preds[t * n_spk..(t + 1) * n_spk]);
        }
    }
    (new_cache, new_preds)
}

/// `_compress_spkcache`: cuando el caché de hablante supera `spkcache_len`,
/// lo recomprime a ese tamaño conservando los frames de mayor "calidad"
/// (más confiados, con boost extra para los más recientes).
fn compress_spkcache(state: &mut StreamState, cfg: &SortformerCfg) {
    let n_spk = NUM_SPEAKERS;
    let n_frames = state.spkcache_frames;
    let spkcache_len = cfg.spkcache_len as usize;
    let spkcache_len_per_spk = spkcache_len / n_spk - SIL_FRAMES_PER_SPK;
    let strong_boost_per_spk = (spkcache_len_per_spk as f32 * STRONG_BOOST_RATE).floor() as i32;
    let weak_boost_per_spk = (spkcache_len_per_spk as f32 * WEAK_BOOST_RATE).floor() as i32;
    let min_pos_scores_per_spk = (spkcache_len_per_spk as f32 * MIN_POS_SCORES_RATE).floor() as i32;

    let mut scores = get_log_pred_scores(&state.spkcache_preds, n_frames, n_spk);
    disable_low_scores(
        &state.spkcache_preds,
        n_frames,
        n_spk,
        min_pos_scores_per_spk,
        &mut scores,
    );

    if SCORES_BOOST_LATEST > 0.0 && n_frames > spkcache_len {
        for t in spkcache_len..n_frames {
            for s in 0..n_spk {
                scores[t * n_spk + s] += SCORES_BOOST_LATEST;
            }
        }
    }

    boost_topk_scores(&mut scores, n_frames, n_spk, strong_boost_per_spk, 2.0);
    boost_topk_scores(&mut scores, n_frames, n_spk, weak_boost_per_spk, 1.0);

    let (time_indices, is_disabled) = get_topk_indices(&scores, n_frames, n_spk, spkcache_len);
    let (new_cache, new_preds) =
        gather_spkcache_and_preds(state, &time_indices, &is_disabled, spkcache_len);

    state.spkcache = new_cache;
    state.spkcache_preds = new_preds;
    state.spkcache_frames = spkcache_len;
}

/// Actualiza la media móvil de embeddings "de silencio" (frames cuya suma de
/// predicciones por hablante cae debajo de [`SIL_THRESHOLD`]) -- usada para
/// rellenar los slots deshabilitados de [`gather_spkcache_and_preds`].
fn update_silence_profile(state: &mut StreamState, embs: &[f32], preds: &[f32], n: usize) {
    if n == 0 {
        return;
    }
    let mut new_sil = 0i64;
    let mut sum = vec![0.0f32; EMB_DIM];
    for t in 0..n {
        let total: f32 = preds[t * NUM_SPEAKERS..(t + 1) * NUM_SPEAKERS].iter().sum();
        if total < SIL_THRESHOLD {
            new_sil += 1;
            let row = &embs[t * EMB_DIM..(t + 1) * EMB_DIM];
            for (i, &v) in row.iter().enumerate() {
                sum[i] += v;
            }
        }
    }
    if new_sil == 0 {
        return;
    }
    let total_frames = state.n_sil_frames + new_sil;
    let scale = 1.0 / total_frames as f32;
    for i in 0..EMB_DIM {
        let old_sum = state.mean_sil_emb[i] * state.n_sil_frames as f32;
        state.mean_sil_emb[i] = (old_sum + sum[i]) * scale;
    }
    state.n_sil_frames = total_frames;
}

/// `StreamingUpdate`: un paso del streaming -- arma los seis tensores de
/// entrada a partir del estado actual, corre el modelo, extrae las
/// predicciones del tramo `chunk` (descartando el lookahead de
/// `right_context`) y actualiza `spkcache`/`fifo` para el siguiente paso.
#[allow(clippy::too_many_lines)]
fn streaming_update(
    session: &mut Session,
    cfg: &SortformerCfg,
    state: &mut StreamState,
    chunk_feat: &[f32],
    current_len: i64,
) -> Result<Vec<f32>> {
    let feed_size = ((cfg.chunk_len + cfg.right_context) * SUBSAMPLING as i64) as usize;
    let total_prefix = state.spkcache_frames + state.fifo_frames;

    let chunk_array = Array3::from_shape_vec((1, feed_size, N_MELS), chunk_feat.to_vec())
        .context("armando el tensor 'chunk' de Sortformer")?;
    let chunk_value = Value::from_array(chunk_array)?;
    let chunk_lengths_value = Value::from_array(Array1::from_vec(vec![current_len]))?;

    let spkcache_array =
        Array3::from_shape_vec((1, state.spkcache_frames, EMB_DIM), state.spkcache.clone())
            .context("armando el tensor 'spkcache' de Sortformer")?;
    let spkcache_value = Value::from_array(spkcache_array)?;
    let spkcache_lengths_value =
        Value::from_array(Array1::from_vec(vec![state.spkcache_frames as i64]))?;

    let fifo_array = Array3::from_shape_vec((1, state.fifo_frames, EMB_DIM), state.fifo.clone())
        .context("armando el tensor 'fifo' de Sortformer")?;
    let fifo_value = Value::from_array(fifo_array)?;
    let fifo_lengths_value = Value::from_array(Array1::from_vec(vec![state.fifo_frames as i64]))?;

    let outputs = session.run(ort::inputs![
        "chunk" => &chunk_value,
        "chunk_lengths" => &chunk_lengths_value,
        "spkcache" => &spkcache_value,
        "spkcache_lengths" => &spkcache_lengths_value,
        "fifo" => &fifo_value,
        "fifo_lengths" => &fifo_lengths_value,
    ])?;

    let (preds_shape, preds_data) =
        outputs["spkcache_fifo_chunk_preds"].try_extract_tensor::<f32>()?;
    let (embs_shape, embs_data) = outputs["chunk_pre_encode_embs"].try_extract_tensor::<f32>()?;

    let preds_rows = preds_shape[1] as usize;
    let preds_cols = preds_shape[2] as usize;
    if preds_cols != NUM_SPEAKERS {
        bail!("Sortformer: se esperaban {NUM_SPEAKERS} hablantes por frame, salió {preds_cols}");
    }
    let embs_rows = embs_shape[1] as usize;
    let embs_cols = embs_shape[2] as usize;
    if embs_cols != EMB_DIM {
        bail!("Sortformer: se esperaban embeddings de {EMB_DIM} dims, salieron {embs_cols}");
    }

    let chunk_model_frames = preds_rows as i64 - total_prefix as i64;
    let valid_model_frames = (current_len + SUBSAMPLING as i64 - 1) / SUBSAMPLING as i64;
    let keep = [
        cfg.chunk_len,
        chunk_model_frames,
        valid_model_frames,
        embs_rows as i64,
    ]
    .into_iter()
    .min()
    .unwrap_or(0)
    .max(0) as usize;

    let mut chunk_preds = vec![0.0f32; keep * NUM_SPEAKERS];
    for t in 0..keep {
        let src_row = total_prefix + t;
        for s in 0..NUM_SPEAKERS {
            chunk_preds[t * NUM_SPEAKERS + s] = preds_data[src_row * preds_cols + s];
        }
    }

    // --- Actualización de estado: FIFO recibe los embeddings del chunk,
    // y si se desborda derrama las filas más viejas al speaker cache
    // (comprimiéndolo si hace falta). Port de la segunda mitad de
    // `StreamingUpdate` en la referencia. ---
    let old_spkcache_frames = state.spkcache_frames;
    let old_fifo_frames = state.fifo_frames;
    let chunk_frames = keep;

    let new_fifo_frames = old_fifo_frames + chunk_frames;
    let mut new_fifo = vec![0.0f32; new_fifo_frames * EMB_DIM];
    new_fifo[..old_fifo_frames * EMB_DIM].copy_from_slice(&state.fifo);
    for t in 0..chunk_frames {
        let src = &embs_data[t * embs_cols..(t + 1) * embs_cols];
        let dst = (old_fifo_frames + t) * EMB_DIM;
        new_fifo[dst..dst + EMB_DIM].copy_from_slice(src);
    }
    state.fifo = new_fifo;

    let mut new_fifo_preds = vec![0.0f32; new_fifo_frames * NUM_SPEAKERS];
    for (t, row) in new_fifo_preds.chunks_mut(NUM_SPEAKERS).enumerate() {
        let src_row = old_spkcache_frames + t;
        row.copy_from_slice(&preds_data[src_row * preds_cols..src_row * preds_cols + NUM_SPEAKERS]);
    }
    state.fifo_preds = new_fifo_preds;
    state.fifo_frames = new_fifo_frames;

    if old_fifo_frames + chunk_frames > cfg.fifo_len as usize {
        let mut pop_out_len = cfg.spkcache_update_period as usize;
        pop_out_len = pop_out_len
            .max((chunk_frames as i64 - cfg.fifo_len + old_fifo_frames as i64).max(0) as usize);
        pop_out_len = pop_out_len.min(old_fifo_frames + chunk_frames);
        pop_out_len = pop_out_len.min(state.fifo_frames);

        if pop_out_len > 0 {
            let pop_embs = state.fifo[..pop_out_len * EMB_DIM].to_vec();
            let pop_preds = state.fifo_preds[..pop_out_len * NUM_SPEAKERS].to_vec();

            update_silence_profile(state, &pop_embs, &pop_preds, pop_out_len);

            let rem = state.fifo_frames - pop_out_len;
            state.fifo = state.fifo[pop_out_len * EMB_DIM..].to_vec();
            state.fifo_preds = state.fifo_preds[pop_out_len * NUM_SPEAKERS..].to_vec();
            state.fifo_frames = rem;

            let new_cache_frames = old_spkcache_frames + pop_out_len;
            let mut new_cache = vec![0.0f32; new_cache_frames * EMB_DIM];
            new_cache[..old_spkcache_frames * EMB_DIM].copy_from_slice(&state.spkcache);
            new_cache[old_spkcache_frames * EMB_DIM..].copy_from_slice(&pop_embs);
            state.spkcache = new_cache;

            if state.spkcache_preds_initialized {
                let mut new_cache_preds = vec![0.0f32; new_cache_frames * NUM_SPEAKERS];
                new_cache_preds[..old_spkcache_frames * NUM_SPEAKERS]
                    .copy_from_slice(&state.spkcache_preds);
                new_cache_preds[old_spkcache_frames * NUM_SPEAKERS..].copy_from_slice(&pop_preds);
                state.spkcache_preds = new_cache_preds;
            }
            state.spkcache_frames = new_cache_frames;

            if state.spkcache_frames > cfg.spkcache_len as usize {
                if !state.spkcache_preds_initialized {
                    // Primera compresión: las primeras `old_spkcache_frames`
                    // filas salen de la predicción de esta misma iteración
                    // (el caché todavía no tenía preds propias), seguidas de
                    // las filas recién derramadas.
                    let mut seeded = vec![0.0f32; new_cache_frames * NUM_SPEAKERS];
                    for t in 0..old_spkcache_frames {
                        for s in 0..NUM_SPEAKERS {
                            seeded[t * NUM_SPEAKERS + s] = preds_data[t * preds_cols + s];
                        }
                    }
                    seeded[old_spkcache_frames * NUM_SPEAKERS..].copy_from_slice(&pop_preds);
                    state.spkcache_preds = seeded;
                    state.spkcache_preds_initialized = true;
                }
                compress_spkcache(state, cfg);
            }
        }
    }

    Ok(chunk_preds)
}

// ============================================================================
// Post-proceso -- `Binarize` + su cadena de median filter / hysteresis /
// merge / filter.
// ============================================================================

/// `median_filter` (scipy.signal.medfilt1d, mode="nearest") por hablante,
/// sobre las predicciones sigmoid crudas antes de binarizar.
fn median_filter_per_speaker(preds: &mut [f32], n_frames: usize, n_spk: usize, window: usize) {
    if window <= 1 || n_frames == 0 {
        return;
    }
    let half = window / 2;
    for s in 0..n_spk {
        let buf: Vec<f32> = (0..n_frames).map(|t| preds[t * n_spk + s]).collect();
        for t in 0..n_frames {
            let lo = t.saturating_sub(half);
            let hi = (t + half + 1).min(n_frames);
            let mut tmp: Vec<f32> = buf[lo..hi].to_vec();
            let m = tmp.len();
            tmp.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
            let mut median = tmp[m / 2];
            if m % 2 == 0 {
                median = 0.5 * (median + tmp[m / 2 - 1]);
            }
            preds[t * n_spk + s] = median;
        }
    }
}

/// `merge_overlap_segment`: ordena por inicio y fusiona vecinos que se
/// tocan o se superponen.
fn merge_overlapping(segs: &mut Vec<(f32, f32)>) {
    if segs.len() < 2 {
        return;
    }
    segs.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    let mut out: Vec<(f32, f32)> = Vec::with_capacity(segs.len());
    out.push(segs[0]);
    for &(s, e) in &segs[1..] {
        let last = out
            .last_mut()
            .expect("out siempre tiene al menos un elemento");
        if last.1 >= s {
            if e > last.1 {
                last.1 = e;
            }
        } else {
            out.push((s, e));
        }
    }
    *segs = out;
}

/// `filter_short_segments`.
fn filter_short(segs: &mut Vec<(f32, f32)>, threshold: f32) {
    if threshold <= 0.0 {
        return;
    }
    segs.retain(|&(s, e)| (e - s) >= threshold);
}

/// `get_gap_segments` (asume `segs` ya ordenado por inicio).
fn gap_segments(segs: &[(f32, f32)]) -> Vec<(f32, f32)> {
    if segs.len() < 2 {
        return vec![];
    }
    (1..segs.len())
        .map(|i| (segs[i - 1].1, segs[i].0))
        .collect()
}

/// `filtering(..., filter_speech_first=1.0)`: descarta segmentos cortos y
/// funde huecos cortos entre segmentos del mismo hablante (reinsertando el
/// hueco como si fuera habla y fusionando).
fn filter_per_speaker(segs: &mut Vec<(f32, f32)>, min_on: f32, min_off: f32) {
    if segs.is_empty() {
        return;
    }
    if min_on > 0.0 {
        filter_short(segs, min_on);
    }
    if min_off > 0.0 && segs.len() >= 2 {
        segs.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
        let gaps = gap_segments(segs);
        let mut short_gaps: Vec<(f32, f32)> = gaps
            .into_iter()
            .filter(|&(s, e)| (e - s) < min_off)
            .collect();
        segs.append(&mut short_gaps);
        merge_overlapping(segs);
    }
}

/// `binarization()`: umbralado con histéresis (onset/offset) más
/// padding y fusión de solapes -- un hablante a la vez.
fn binarize_per_speaker(
    frames: &[f32],
    onset: f32,
    offset: f32,
    pad_onset: f32,
    pad_offset: f32,
    frame_length_in_sec: f32,
) -> Vec<(f32, f32)> {
    let mut out = Vec::new();
    let mut speech = false;
    let mut start = 0.0f32;
    let mut last_i = 0usize;
    for (i, &p) in frames.iter().enumerate() {
        last_i = i;
        if speech {
            if p < offset {
                let end_s = i as f32 * frame_length_in_sec + pad_offset;
                let start_s = (start - pad_onset).max(0.0);
                if end_s > start_s {
                    out.push((start_s, end_s));
                }
                start = i as f32 * frame_length_in_sec;
                speech = false;
            }
        } else if p > onset {
            start = i as f32 * frame_length_in_sec;
            speech = true;
        }
    }
    if speech {
        let end_s = last_i as f32 * frame_length_in_sec + pad_offset;
        let start_s = (start - pad_onset).max(0.0);
        if end_s > start_s {
            out.push((start_s, end_s));
        }
    }
    merge_overlapping(&mut out);
    out
}

/// `ts_vad_post_processing`: `repeat_interleave` de cada frame de modelo
/// (80 ms) a frames de audio (10 ms) por subsampling, luego binariza y
/// filtra cada hablante independientemente. Devuelve `(inicio_s, fin_s,
/// hablante)`.
fn binarize(
    preds: &[f32],
    num_frames: usize,
    num_audio_samples: usize,
    cfg: &SortformerCfg,
) -> Vec<(f32, f32, usize)> {
    let onset = cfg.onset;
    let offset = if cfg.offset > onset {
        onset
    } else {
        cfg.offset
    };
    let audio_duration = num_audio_samples as f32 / SAMPLE_RATE as f32;

    let mut filtered = preds.to_vec();
    if cfg.median_window > 1 && num_frames > 0 {
        median_filter_per_speaker(
            &mut filtered,
            num_frames,
            NUM_SPEAKERS,
            cfg.median_window as usize,
        );
    }

    let n_audio_frames = num_frames * SUBSAMPLING;
    let mut result = Vec::new();

    for spk in 0..NUM_SPEAKERS {
        let mut channel = vec![0.0f32; n_audio_frames];
        for t in 0..num_frames {
            let p = filtered[t * NUM_SPEAKERS + spk];
            channel[t * SUBSAMPLING..(t + 1) * SUBSAMPLING].fill(p);
        }

        let mut segs = binarize_per_speaker(
            &channel,
            onset,
            offset,
            cfg.pad_onset,
            cfg.pad_offset,
            AUDIO_FRAME_DURATION_S,
        );
        filter_per_speaker(&mut segs, cfg.min_duration_on, cfg.min_duration_off);

        for (mut s, mut e) in segs {
            if e > audio_duration {
                e = audio_duration;
            }
            if s < 0.0 {
                s = 0.0;
            }
            if e > s {
                result.push((s, e, spk));
            }
        }
    }

    result
}

// ============================================================================
// Orquestación -- `Process`: mel completo -> ventaneo streaming -> binarize.
// ============================================================================

/// `Process`: corre Sortformer streaming sobre TODO el audio, alimentándolo
/// en chunks (sin esperar el reloj real -- "streaming" en el sentido de la
/// máquina de estados del modelo, no de tiempo real). Devuelve tramos
/// `(inicio_s, fin_s, hablante_local_0..3)`.
fn process_sortformer(
    session: &mut Session,
    cfg: &SortformerCfg,
    audio: &[f32],
) -> Result<Vec<(f32, f32, usize)>> {
    if audio.is_empty() {
        return Ok(vec![]);
    }

    let window = build_hann_window();
    let mel_basis = build_mel_filterbank();
    let mel = extract_mel_features(audio, &window, &mel_basis);
    let num_mel_frames = mel.len() / N_MELS;
    if num_mel_frames == 0 {
        return Ok(vec![]);
    }

    let mut state = StreamState::new();

    let feed_size = ((cfg.chunk_len + cfg.right_context) * SUBSAMPLING as i64) as usize;
    let stride = (cfg.chunk_len * SUBSAMPLING as i64) as usize;
    let num_chunks = ((num_mel_frames + stride - 1) / stride).max(1);

    let mut all_chunk_preds: Vec<f32> = Vec::new();
    let mut chunk_feat = vec![0.0f32; feed_size * N_MELS];

    for ci in 0..num_chunks {
        let start = ci * stride;
        let end = (start + feed_size).min(num_mel_frames);
        let current_len = end.saturating_sub(start);

        chunk_feat.iter_mut().for_each(|v| *v = 0.0);
        if current_len > 0 {
            chunk_feat[..current_len * N_MELS].copy_from_slice(&mel[start * N_MELS..end * N_MELS]);
        }

        let chunk_preds =
            streaming_update(session, cfg, &mut state, &chunk_feat, current_len as i64)?;
        all_chunk_preds.extend_from_slice(&chunk_preds);
    }

    let mut total_model_frames = all_chunk_preds.len() / NUM_SPEAKERS;
    let max_model_frames = num_mel_frames / SUBSAMPLING;
    if max_model_frames < total_model_frames {
        total_model_frames = max_model_frames;
        all_chunk_preds.truncate(total_model_frames * NUM_SPEAKERS);
    }
    if total_model_frames == 0 {
        return Ok(vec![]);
    }

    Ok(binarize(
        &all_chunk_preds,
        total_model_frames,
        audio.len(),
        cfg,
    ))
}

// ============================================================================
// Sonda -- corre a mano, ver task-1-report.md para el veredicto.
// ============================================================================

#[test]
#[ignore = "requiere DILO_SORTFORMER_WAV (WAV real de 16 kHz mono) y el .onnx de Sortformer en disco -- ver task-1-report.md"]
fn compara_sortformer_contra_diarizacion_actual_en_espanol() -> Result<()> {
    let wav_path = std::env::var("DILO_SORTFORMER_WAV")
        .context("seteá DILO_SORTFORMER_WAV con la ruta a un WAV de 16 kHz mono")?;

    // `read_wav_samples` no expone sample_rate/canales -- se valida el
    // formato acá directo con `hound` antes de confiar en los samples.
    {
        let reader =
            hound::WavReader::open(&wav_path).with_context(|| format!("abriendo {wav_path}"))?;
        let spec = reader.spec();
        if spec.sample_rate != SAMPLE_RATE as u32 || spec.channels != 1 {
            bail!(
                "{wav_path}: se esperaba 16 kHz mono, es {} Hz / {} canal(es)",
                spec.sample_rate,
                spec.channels
            );
        }
    }

    let audio = read_wav_samples(&wav_path)?;
    let audio_duration_s = audio.len() as f32 / SAMPLE_RATE as f32;
    println!(
        "\n=== Audio: {wav_path} ({audio_duration_s:.2}s, {} samples) ===",
        audio.len()
    );

    // --- Sortformer streaming ---
    let sortformer_path = std::env::var("DILO_SORTFORMER_MODEL_PATH")
        .unwrap_or_else(|_| "/tmp/sortformer/sortformer.onnx".to_string());
    let (mut session, cfg) = load_sortformer_session(Path::new(&sortformer_path))?;

    let t0 = Instant::now();
    let sortformer_segments = process_sortformer(&mut session, &cfg, &audio)?;
    let sortformer_elapsed = t0.elapsed();

    println!("\n--- Sortformer streaming ({sortformer_path}) ---");
    for (start, end, speaker) in &sortformer_segments {
        println!("{start:.2}s → {end:.2}s | hablante {speaker}");
    }
    let sortformer_speakers: std::collections::BTreeSet<usize> =
        sortformer_segments.iter().map(|s| s.2).collect();
    println!(
        "hablantes distintos: {} | tiempo: {:.2}s para {audio_duration_s:.2}s de audio ({:.3}x tiempo real)",
        sortformer_speakers.len(),
        sortformer_elapsed.as_secs_f32(),
        sortformer_elapsed.as_secs_f32() / audio_duration_s.max(0.001)
    );

    // --- Diarización actual (pyannote-segmentation-3.0 + CAM++) ---
    let seg_model_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("resources/models/pyannote_segmentation_3_0.onnx");
    let emb_model_path = dirs::data_dir()
        .map(|d| {
            d.join("cl.espaciodigital.dilo")
                .join("models")
                .join(crate::managers::diarization_models::EMBEDDING_MODEL_FILENAME)
        })
        .unwrap_or_default();

    if seg_model_path.is_file() && emb_model_path.is_file() {
        let engine = super::DiarizationEngine::load(&seg_model_path, &emb_model_path)?;
        let t1 = Instant::now();
        let current_segments = engine.diarize(&audio, SAMPLE_RATE as u32)?;
        let current_elapsed = t1.elapsed();

        println!("\n--- Diarización actual (pyannote-segmentation-3.0 + CAM++) ---");
        for seg in &current_segments {
            println!(
                "{:.2}s → {:.2}s | hablante {}{}",
                seg.start_ms as f32 / 1000.0,
                seg.end_ms as f32 / 1000.0,
                seg.speaker,
                if seg.overlapped { " (solapado)" } else { "" }
            );
        }
        let current_speakers: std::collections::BTreeSet<usize> =
            current_segments.iter().map(|s| s.speaker).collect();
        println!(
            "hablantes distintos: {} | tiempo: {:.2}s para {audio_duration_s:.2}s de audio ({:.3}x tiempo real)",
            current_speakers.len(),
            current_elapsed.as_secs_f32(),
            current_elapsed.as_secs_f32() / audio_duration_s.max(0.001)
        );
    } else {
        println!(
            "\n--- Diarización actual: SIN COMPARAR -- faltan modelos en disco \
             (segmentación presente: {}, embeddings presente: {}) ---",
            seg_model_path.is_file(),
            emb_model_path.is_file()
        );
    }

    Ok(())
}
