//! Motor de diarización en streaming con Sortformer (NVIDIA NeMo, exportado
//! a ONNX) — Task 2 del plan "reuniones en streaming"
//! (`.superpowers/sdd/2026-08-04-reuniones-en-streaming/`).
//!
//! Reemplaza la sonda descartable de la Task 1
//! (`diarization/sortformer_probe.rs`, borrada en este mismo commit) por un
//! motor de verdad: [`StreamingDiarizer`] mantiene una ventana deslizante
//! sobre audio que llega en trozos arbitrarios (`push`), un caché de
//! hablantes por orden de llegada entre trozos (Arrival-Order Speaker
//! Cache — `spkcache`/`fifo` en [`StreamState`], sin cambios respecto a la
//! sonda) y devuelve sólo los tramos **nuevos** desde la última llamada
//! (`SpeakerSpan`), no todo el historial.
//!
//! ## Referencia
//!
//! Las funciones de extracción de features (mel Slaney) y post-proceso
//! (histéresis onset/offset, filtro de mediana, merge/filtro de tramos
//! cortos) y la máquina de estados de streaming (`streaming_update`,
//! `compress_spkcache`) son un port directo, sin cambios de comportamiento,
//! de la sonda de la Task 1 — que a su vez es port línea por línea de
//! <https://github.com/scottyeager/sherpa-onnx/blob/sortformer-diarization/sherpa-onnx/csrc/offline-sortformer-diarization.cc>
//! (~99.5% de paridad con NeMo documentada por sherpa-onnx). Cada función
//! porteada conserva su doc comment con la función C++ de origen. Lo nuevo
//! de esta tarea es la capa incremental: [`MelStream`] (extracción de mel
//! frame a frame según llega audio, en vez de sobre el WAV completo),
//! [`StreamingDiarizer::push`] (alimenta el modelo en cuanto hay un chunk
//! completo disponible y devuelve sólo los tramos que ya se pueden dar por
//! estables — la emisión sigue los cierres de turno, no un reloj fijo, ver
//! "Cola sin cerrar" más abajo), [`StreamingDiarizer::flush`] (fuerza la
//! salida de lo que quede pendiente al terminar una reunión, sin esperar
//! un cierre de turno que puede no llegar nunca) y [`flatten_overlaps`]
//! (nuevo, sin equivalente en la referencia — ver esa sección).
//!
//! ## Modelo: v2, no v2.1
//!
//! La sonda de la Task 1 corrió contra
//! `nvidia/diar_streaming_sortformer_4spk-v2.1`, cuya ficha de HuggingFace
//! declara licencia `nvidia-open-model-license` (sin verificar para
//! distribución). `nvidia/diar_streaming_sortformer_4spk-v2` (sin el
//! `.1`) declara `cc-by-4.0` — la misma licencia que Canary, que Dilo ya
//! distribuye — así que Task 2 usa v2, no v2.1 (decisión tomada antes de
//! empezar esta tarea, ver el brief). El repo oficial de NVIDIA sólo
//! publica el checkpoint `.nemo`, no un export ONNX; el archivo que usa
//! este módulo es la exportación de
//! <https://huggingface.co/altunenes/parakeet-rs> (usada para su port a
//! Rust de modelos NeMo, `parakeet-rs`/`sherpa-onnx`-adyacente — su propio
//! README dice "All models using the same licences from NVIDIA. I only
//! exported them to ONNX"), verificada bit a bit: `sha256` del archivo
//! descargado coincide exactamente con el `x-linked-etag` que HuggingFace
//! reporta para ese mismo blob. Metadata custom del grafo (`chunk_len=124,
//! fifo_len=124, spkcache_len=188`) — mismo formato y mismos valores por
//! default que v2.1, confirmando que es la misma arquitectura de
//! exportación. Ver `task-2-report.md` para la comparación empírica v2
//! contra v2.1 sobre el mismo audio real.
//!
//! ## Tamaño de chunk: medido, no supuesto (y la primera medición estaba mal)
//!
//! El grafo ONNX declara el eje de tiempo del tensor `chunk` como dinámico
//! (`time_chunk`, no un entero fijo) — el modelo SÍ acepta, técnicamente,
//! cualquier tamaño de chunk desde 3 frames de 80&nbsp;ms (0.32&nbsp;s) hasta
//! 340 (30.4&nbsp;s), como documenta su model card. Un primer barrido de RTF
//! variando sólo `chunk_len` sobre un clip de UN SOLO hablante (ver
//! `task-2-report.md`) dio: 124 (default del checkpoint, ~9.92&nbsp;s de
//! audio nuevo por llamada) → RTF 0.106×; 12 (~1.04&nbsp;s) → 0.294×; 6
//! (~0.56&nbsp;s) → 0.554×; 3 (~0.32&nbsp;s, el mínimo del model card) →
//! 1.226× (más lento que tiempo real) — y con los mismos límites de tramo
//! en ese clip para cualquier `chunk_len`, así que la primera conclusión
//! fue "12 es un buen punto medio, sin pérdida de calidad".
//!
//! Esa conclusión estaba incompleta: un clip de un solo hablante no puede
//! mostrar el problema real, que es de **identidad** (a qué slot de
//! `spkcache` va cada voz), no de límites de tramo. Repetido sobre los
//! 180&nbsp;s de audio real multi-hablante (mismo archivo que la
//! comparación v2/v2.1, ver `task-2-report.md`): con `chunk_len=12` el
//! motor alucina un tercer hablante que no existe y fragmenta los primeros
//! ~20&nbsp;s en varios cambios de hablante espurios que el checkpoint por
//! default (124) no muestra — con embeddings de chunks muy chicos, la
//! asignación de una voz a un slot de `spkcache` es más ruidosa,
//! especialmente antes de que el caché tenga suficiente historia. `24`
//! todavía alucina ese tercer hablante (más corto, pero presente); recién
//! en `48` (~3.84&nbsp;s de audio nuevo por llamada) el resultado vuelve a
//! tener los mismos 2 hablantes y los mismos bloques largos que el
//! checkpoint por default, con una sola discrepancia menor: un tramo falso
//! de ~2.6&nbsp;s cerca del arranque (5.13s→7.76s, hablante 1), ausente en
//! la referencia offline. Atribuible a **arranque en frío**: a los pocos
//! segundos de empezar el stream, `spkcache`/`fifo`/`mean_sil_emb`
//! (`StreamState`) todavía no acumularon suficiente historia para
//! distinguir hablantes con confianza, y con `chunk_len=48` el contexto
//! disponible en esa ventana inicial es más corto que con el default
//! (124) -- no se confirmó con etiquetado manual, es la lectura más
//! plausible dado dónde cae (siempre al principio, nunca en medio de la
//! grabación) y no una causa verificada distinta.
//!
//! [`LIVE_CHUNK_LEN`] queda en 48: RTF 0.122× medido sobre los 180&nbsp;s
//! reales (~8.2× de margen bajo tiempo real -- importa porque en producción
//! esto corre en paralelo con la transcripción en vivo de la reunión, no
//! aislado como en esta medición) y calidad equivalente al default del
//! checkpoint en el único audio multi-hablante disponible. Es una mejora
//! más modesta que la promesa inicial (~3.84&nbsp;s de latencia por
//! *cómputo*, no de emisión -- ver "La emisión sigue cierres de turno" más
//! abajo) pero es la que sostiene con evidencia real, no con un clip que
//! no podía mostrar el problema. No se probaron valores entre 24 y 48, y
//! sólo hay UN audio multi-hablante disponible para esta comparación — ver
//! preocupaciones en `task-2-report.md`.
//!
//! ## Hablante activo único: `flatten_overlaps`
//!
//! Sortformer predice una probabilidad **independiente por hablante** por
//! frame (así detecta habla superpuesta de verdad) — el post-proceso de la
//! referencia (`binarize`, sin cambios acá) devuelve tramos por canal de
//! hablante que SÍ pueden solaparse entre sí en el tiempo. El contrato de
//! [`SpeakerSpan`] no tiene un flag de superposición (a diferencia de
//! `DiarizedSegment::overlapped` del motor no-streaming) y el invariante
//! que exige quien consume `push()` es una única línea de tiempo sin
//! solapes (`spans_are_monotonic`) — así que [`flatten_overlaps`] resuelve
//! el solape con una política simple y explícita: el hablante que ya
//! estaba activo se queda con el piso hasta que termina su propio tramo;
//! recién ahí puede empezar el que sigue por orden de inicio. No es una
//! resolución "inteligente" (no compara confianza frame a frame en la zona
//! de solape) — es una simplificación deliberada dado que la interfaz no
//! tiene dónde reportar la ambigüedad.
//!
//! ## La emisión sigue cierres de turno, no un reloj fijo
//!
//! El modelo se LLAMA cada `LIVE_CHUNK_LEN` frames nuevos (~3.84&nbsp;s,
//! cadencia fija) — pero eso es la cadencia de **cómputo**, no la cadencia
//! de **emisión**. `binarize()` sólo cierra un tramo cuando ve la
//! probabilidad del hablante activo cruzar el umbral de `offset` hacia
//! abajo (silencio) o cambiar de hablante; mientras alguien habla de
//! corrido, ese tramo sigue "abierto" y [`StreamingDiarizer::push`]
//! devuelve `vec![]` para él llamada tras llamada, por largo que sea el
//! turno — no es que no haya pasado nada, es que todavía no se puede saber
//! dónde termina. Un corolario directo: **la primera vez que `push()`
//! devuelve algo no es a los ~3.84&nbsp;s** de audio nuevo, sino recién
//! cuando el primer cierre de turno real ocurre (medido en Task 2: ~7.8&nbsp;s
//! sobre audio real, porque el hablante inicial no hizo una pausa antes).
//! Quien construya el transcript en vivo sobre esto (Task 6+) tiene que
//! diseñarse para "llega cuando llega, en ráfagas ligadas al habla", no
//! para un tick de reloj.
//!
//! ## Cola sin cerrar
//!
//! Consecuencia directa de lo anterior: si nadie sigue empujando audio
//! después del último `push()` de una reunión, el turno que estaba en
//! curso en ese momento **nunca se cierra ni se emite** — no son
//! "unos pocos segundos", es el turno completo que seguía abierto (podían
//! ser 20, 30&nbsp;s si el hablante no hizo pausas), más hasta
//! `LIVE_CHUNK_LEN` frames (~3.84&nbsp;s) de audio bufferizado sin
//! alcanzar a completar un chunk, más el margen de estabilidad
//! ([`SAFE_TAIL_MARGIN_S`], ~1.5&nbsp;s) sobre lo último que sí se procesó.
//! En la práctica, sin hacer nada más, eso es un piso de ~5&nbsp;s y sin
//! techo real (tan largo como el último turno sin pausas).
//!
//! [`StreamingDiarizer::flush`] existe para esto: se llama al terminar una
//! reunión, antes de `reset()`, y fuerza dos cosas que `push()` nunca hace
//! por su cuenta — (a) alimenta al modelo lo que haya bufferizado sin
//! completar un chunk, relleno con ceros hasta `LIVE_CHUNK_LEN` (mismo
//! truco que la sonda offline usaba para el último chunk de un WAV de
//! duración conocida) y (b) emite todo lo pendiente **sin** esperar el
//! margen de estabilidad ni un cierre de turno futuro que ya no va a
//! llegar. `flush()` no limpia el caché de hablantes -- para arrancar una
//! reunión nueva hay que llamar a `reset()` después. Sigue sin ser
//! perfecto: el post-proceso que decide dónde termina un tramo
//! (histéresis + filtro de mediana) nunca vio el "silencio real" que
//! vendría después del final de la reunión, así que el corte de `flush()`
//! es la mejor estimación con los datos que hay, no la verdad de
//! `binarize()` sobre una grabación completa -- ver preocupaciones en
//! `task-2-report.md`.

#![allow(dead_code)]

use anyhow::{bail, Context, Result};
use ndarray::{Array1, Array3};
use ort::session::Session;
use ort::value::Value;
use std::path::Path;

// ============================================================================
// Constantes -- las mismas que la sonda de Task 1 (ver su doc comment
// original, ahora borrado junto con el archivo, para el detalle de a qué
// función/constante de offline-sortformer-diarization.cc corresponde cada
// una). Sin cambios de valores.
// ============================================================================

const SAMPLE_RATE: usize = 16_000;
const N_FFT: usize = 512;
const WIN_LENGTH: usize = 400; // 25 ms
const HOP_LENGTH: usize = 160; // 10 ms
const N_MELS: usize = 128;
/// Tope de hablantes del modelo Sortformer 4spk -- cualquier índice de
/// hablante por encima de esto en una salida sería un bug de interpretación
/// de la salida del modelo, no un hablante real (ver el test
/// `el_tope_de_hablantes_es_el_del_modelo`).
pub const SORTFORMER_MAX_SPEAKERS: u8 = 4;
const NUM_SPEAKERS: usize = SORTFORMER_MAX_SPEAKERS as usize;
const EMB_DIM: usize = 512;
const SUBSAMPLING: usize = 8; // frames mel -> frames de modelo
const PREEMPH: f32 = 0.97;
const LOG_GUARD: f32 = 5.960_464_5e-8; // 2^-24
const AUDIO_FRAME_DURATION_S: f32 = 0.01;

const SIL_FRAMES_PER_SPK: usize = 3;
const STRONG_BOOST_RATE: f32 = 0.75;
const WEAK_BOOST_RATE: f32 = 1.5;
const MIN_POS_SCORES_RATE: f32 = 0.5;
const SCORES_BOOST_LATEST: f32 = 0.05;
const PRED_SCORE_THRESHOLD: f32 = 0.25;
const SIL_THRESHOLD: f32 = 0.2;
const MAX_INDEX: i32 = 99_999;

/// Frames de modelo (80&nbsp;ms cada uno: `SUBSAMPLING` × 10&nbsp;ms) pedidos
/// por llamada al modelo en vivo -- ver "Tamaño de chunk" en el doc comment
/// del módulo para la medición (y la corrección sobre la primera medición,
/// que sólo había probado audio de un solo hablante) que justifica este
/// valor en vez del default del checkpoint (124).
const LIVE_CHUNK_LEN: i64 = 48;

/// Margen que se le resta a la duración de audio ya procesada por el modelo
/// antes de animarse a emitir un tramo como "definitivo" en
/// [`StreamingDiarizer::push`]. Tiene que cubrir todo lo que el
/// post-proceso puede todavía mover hacia atrás con más contexto futuro:
/// medio ancho del filtro de mediana (`median_window=11` frames de
/// 80&nbsp;ms → ~0.44&nbsp;s), `pad_offset` (0.079&nbsp;s) y el hueco máximo
/// que `filter_per_speaker` todavía puede fundir con el tramo siguiente
/// (`min_duration_off=0.296s`) -- suman ~0.8&nbsp;s; 1.5&nbsp;s deja margen
/// de sobra sin alejar la latencia de emisión demasiado del ritmo real de
/// actualización del modelo (~3.84&nbsp;s con [`LIVE_CHUNK_LEN`]).
const SAFE_TAIL_MARGIN_S: f32 = 1.5;

/// `OfflineSortformerDiarizationConfig` -- streaming (leído/sobre-escrito
/// desde la metadata custom del .onnx, salvo `chunk_len`, fijado a
/// [`LIVE_CHUNK_LEN`] para uso en vivo) + post-proceso (defaults
/// documentados de la referencia).
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
// Extracción de features -- Hann / mel Slaney, sin cambios de fórmula
// respecto a la sonda. `extract_mel_features` (single-shot) se reemplaza acá
// por [`MelStream`] (incremental); el resto se reutiliza tal cual.
// ============================================================================

fn build_hann_window() -> Vec<f32> {
    let mut window = vec![0.0f32; N_FFT];
    let offset = (N_FFT - WIN_LENGTH) / 2;
    for i in 0..WIN_LENGTH {
        let w = 0.5 - 0.5 * (2.0 * std::f32::consts::PI * i as f32 / WIN_LENGTH as f32).cos();
        window[offset + i] = w;
    }
    window
}

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

/// Extractor incremental de mel-features: recibe audio crudo en trozos de
/// cualquier tamaño (`feed`) y va acumulando frames de mel nuevos a medida
/// que hay ventana completa disponible. Sólo retiene la cola de audio crudo
/// necesaria para la superposición win/hop entre frames consecutivos (nunca
/// el historial completo) -- costo de memoria O(1) en la duración de la
/// reunión, a diferencia de [`StreamingDiarizer`], cuyo historial de
/// predicciones sí crece con ella (ver su doc comment).
struct MelStream {
    window: Vec<f32>,
    mel_basis: Vec<f32>,
    rfft: kaldi_native_fbank::rfft::Rfft,
    fft_buf: Vec<f32>,
    power: Vec<f32>,
    /// Cola de samples crudos aún no completamente consumidos -- ya
    /// preenfatizados y, al principio del stream, con el padding inicial de
    /// `N_FFT/2` ceros (agregado una única vez).
    raw_tail: Vec<f32>,
    /// Índice, en la señal paddeada global, del primer sample de `raw_tail`.
    raw_tail_base: usize,
    front_padded: bool,
    /// Estado del filtro de preénfasis (`y[i] = x[i] - PREEMPH*x[i-1]`)
    /// entre llamadas a `feed` -- `0.0` al arranque reproduce exactamente
    /// `out[0] = audio[0]` de la versión batch.
    prev_raw_sample: f32,
    /// Frames de mel ya extraídos en total desde el arranque del stream.
    frames_extracted: usize,
    /// Frames de mel extraídos y todavía no consumidos por el modelo (filas
    /// de `N_MELS` valores), esperando juntar un chunk completo.
    pending: Vec<f32>,
    /// Total de samples de audio crudo (sin contar padding) recibidos hasta
    /// ahora -- para clippear la duración real en `binarize`.
    total_raw_samples: usize,
}

impl MelStream {
    fn new() -> Self {
        Self {
            window: build_hann_window(),
            mel_basis: build_mel_filterbank(),
            rfft: kaldi_native_fbank::rfft::Rfft::new(N_FFT, false),
            fft_buf: vec![0.0f32; N_FFT],
            power: vec![0.0f32; N_FFT / 2 + 1],
            raw_tail: Vec::new(),
            raw_tail_base: 0,
            front_padded: false,
            prev_raw_sample: 0.0,
            frames_extracted: 0,
            pending: Vec::new(),
            total_raw_samples: 0,
        }
    }

    fn reset(&mut self) {
        self.raw_tail.clear();
        self.raw_tail_base = 0;
        self.front_padded = false;
        self.prev_raw_sample = 0.0;
        self.frames_extracted = 0;
        self.pending.clear();
        self.total_raw_samples = 0;
    }

    fn pending_rows(&self) -> usize {
        self.pending.len() / N_MELS
    }

    /// Alimenta audio crudo nuevo: preenfatiza, lo agrega a la cola y
    /// extrae todos los frames de mel que ya tengan ventana completa
    /// disponible.
    fn feed(&mut self, samples: &[f32]) {
        if samples.is_empty() {
            return;
        }
        if !self.front_padded {
            self.raw_tail.extend(std::iter::repeat_n(0.0f32, N_FFT / 2));
            self.front_padded = true;
        }
        self.total_raw_samples += samples.len();
        self.raw_tail.reserve(samples.len());
        for &x in samples {
            let y = x - PREEMPH * self.prev_raw_sample;
            self.prev_raw_sample = x;
            self.raw_tail.push(y);
        }
        self.extract_ready_frames();
    }

    fn extract_ready_frames(&mut self) {
        let padded_len = self.raw_tail_base + self.raw_tail.len();
        let frames_possible = if padded_len >= N_FFT {
            (padded_len - N_FFT) / HOP_LENGTH + 1
        } else {
            0
        };
        if frames_possible <= self.frames_extracted {
            return;
        }

        let freq_bins = N_FFT / 2 + 1;
        for t in self.frames_extracted..frames_possible {
            let start = t * HOP_LENGTH - self.raw_tail_base;
            for i in 0..N_FFT {
                self.fft_buf[i] = self.raw_tail[start + i] * self.window[i];
            }
            self.rfft.compute(&mut self.fft_buf);

            self.power[0] = self.fft_buf[0] * self.fft_buf[0];
            self.power[freq_bins - 1] = self.fft_buf[1] * self.fft_buf[1];
            for k in 1..freq_bins - 1 {
                let r = self.fft_buf[2 * k];
                let im = self.fft_buf[2 * k + 1];
                self.power[k] = r * r + im * im;
            }

            for m in 0..N_MELS {
                let mel_row = &self.mel_basis[m * freq_bins..(m + 1) * freq_bins];
                let acc: f32 = mel_row
                    .iter()
                    .zip(self.power.iter())
                    .map(|(w, p)| w * p)
                    .sum();
                self.pending.push((acc + LOG_GUARD).ln());
            }
        }
        self.frames_extracted = frames_possible;

        // Sólo hace falta retener desde donde empieza el próximo frame sin
        // extraer -- todo lo anterior ya no lo necesita ningún frame futuro
        // (cada frame sólo mira `N_FFT` muestras hacia adelante desde su
        // propio inicio).
        let next_start = self.frames_extracted * HOP_LENGTH;
        let drop = next_start
            .saturating_sub(self.raw_tail_base)
            .min(self.raw_tail.len());
        if drop > 0 {
            self.raw_tail.drain(0..drop);
            self.raw_tail_base += drop;
        }
    }

    /// Si hay al menos `feed_size` frames pendientes, arma un chunk
    /// (`feed_size * N_MELS` valores, row-major) listo para alimentar al
    /// modelo -- pero sólo AVANZA la cola en `stride` frames (`stride <=
    /// feed_size`, típicamente `chunk_len*SUBSAMPLING`, sin contar
    /// `right_context`), no en `feed_size`. Los últimos `feed_size - stride`
    /// frames del chunk actual (el lookahead de `right_context`) se
    /// retienen y se vuelven a leer como cabecera del próximo chunk -- igual
    /// que el `stride` de la referencia offline
    /// (`process_sortformer`/`Process`), que relee esos mismos frames en el
    /// chunk siguiente en vez de saltárselos. Perderse esto (drenar
    /// `feed_size` completo en vez de `stride`) fue un bug real de esta
    /// tarea: sin el solape, cada llamada arranca la ventana un poco más
    /// lejos de donde debería, y el error se acumula -- confirmado
    /// comparando contra la sonda offline de Task 1 sobre el mismo audio
    /// (ver task-2-report.md).
    fn take_chunk(&mut self, feed_size: usize, stride: usize) -> Option<Vec<f32>> {
        if self.pending_rows() < feed_size {
            return None;
        }
        let chunk = self.pending[..feed_size * N_MELS].to_vec();
        self.pending.drain(0..stride * N_MELS);
        Some(chunk)
    }

    /// Para [`StreamingDiarizer::flush`]: si queda algo pendiente (menos de
    /// `feed_size` frames, o `take_chunk` nunca habría dejado que se
    /// acumulara tanto), arma un último chunk con eso relleno de ceros hasta
    /// `feed_size` -- igual que el último chunk de un WAV de duración
    /// conocida en la sonda offline de Task 1 -- y vacía la cola por
    /// completo (a diferencia de `take_chunk`, acá no queda lookahead que
    /// retener: es el cierre). Devuelve `(chunk, current_len)`, con
    /// `current_len` la cantidad real de frames válidos (el resto es
    /// padding) para que el modelo sepa qué parte del tensor ignorar.
    /// `None` si no había nada pendiente.
    fn take_final_chunk(&mut self, feed_size: usize) -> Option<(Vec<f32>, usize)> {
        let current_len = self.pending_rows().min(feed_size);
        if current_len == 0 {
            return None;
        }
        let mut chunk = vec![0.0f32; feed_size * N_MELS];
        let have = current_len * N_MELS;
        chunk[..have].copy_from_slice(&self.pending[..have]);
        self.pending.clear();
        Some((chunk, current_len))
    }
}

// ============================================================================
// Estado de streaming del modelo (spkcache/fifo) -- sin cambios respecto a
// la sonda de Task 1.
// ============================================================================

struct StreamState {
    spkcache: Vec<f32>,
    spkcache_frames: usize,
    spkcache_preds: Vec<f32>,
    spkcache_preds_initialized: bool,
    fifo: Vec<f32>,
    fifo_frames: usize,
    fifo_preds: Vec<f32>,
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
            scores[t * n_spk + s] += delta;
        }
    }
}

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
    for (mean, &s) in state.mean_sil_emb.iter_mut().zip(sum.iter()) {
        let old_sum = *mean * state.n_sil_frames as f32;
        *mean = (old_sum + s) * scale;
    }
    state.n_sil_frames = total_frames;
}

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
// Post-proceso -- sin cambios respecto a la sonda de Task 1.
// ============================================================================

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
            if m.is_multiple_of(2) {
                median = 0.5 * (median + tmp[m / 2 - 1]);
            }
            preds[t * n_spk + s] = median;
        }
    }
}

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

fn filter_short(segs: &mut Vec<(f32, f32)>, threshold: f32) {
    if threshold <= 0.0 {
        return;
    }
    segs.retain(|&(s, e)| (e - s) >= threshold);
}

fn gap_segments(segs: &[(f32, f32)]) -> Vec<(f32, f32)> {
    if segs.len() < 2 {
        return vec![];
    }
    (1..segs.len())
        .map(|i| (segs[i - 1].1, segs[i].0))
        .collect()
}

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

/// Resuelve solapes entre canales de distintos hablantes en una única línea
/// de tiempo -- ver "Hablante activo único" en el doc comment del módulo
/// para la política y su justificación. Asume que `segs` no viene
/// necesariamente ordenado (lo ordena acá).
fn flatten_overlaps(mut segs: Vec<(f32, f32, usize)>) -> Vec<(f32, f32, usize)> {
    segs.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    let mut out: Vec<(f32, f32, usize)> = Vec::with_capacity(segs.len());
    let mut frontier = f32::NEG_INFINITY;
    for (mut s, e, spk) in segs.drain(..) {
        if s < frontier {
            s = frontier;
        }
        if s >= e {
            continue;
        }
        out.push((s, e, spk));
        frontier = e;
    }
    out
}

// ============================================================================
// API pública
// ============================================================================

/// Un tramo de un único hablante activo, ya resuelto (sin solapes con otros
/// hablantes -- ver [`flatten_overlaps`]). `speaker` es un índice local
/// 0..[`SORTFORMER_MAX_SPEAKERS`), consistente con `DiarizedSegment::speaker`
/// del motor no-streaming: identifica a un hablante dentro de esta sesión de
/// [`StreamingDiarizer`], no una identidad de voz persistente entre
/// reuniones.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SpeakerSpan {
    /// Offset de inicio en milisegundos desde que arrancó el stream (o desde
    /// el último [`StreamingDiarizer::reset`]).
    pub start_ms: u64,
    /// Offset de fin en milisegundos.
    pub end_ms: u64,
    /// Índice de hablante local a esta sesión, `0..SORTFORMER_MAX_SPEAKERS`.
    pub speaker: u8,
}

/// Invariante del contrato de [`StreamingDiarizer::push`]: los tramos que
/// devuelve, en el orden en que los devuelve, nunca se solapan ni retroceden
/// -- quien los consume puede concatenarlos directamente. También rechaza
/// un tramo individual invertido (`start_ms > end_ms`), que técnicamente no
/// "se solapa ni retrocede" respecto al anterior pero rompe la misma
/// promesa de que la lista se puede leer como una línea de tiempo válida.
/// Función pura, sin estado, para poder testearla sin cargar ningún modelo.
pub fn spans_are_monotonic(spans: &[SpeakerSpan]) -> bool {
    spans.iter().all(|s| s.start_ms <= s.end_ms)
        && spans.windows(2).all(|w| w[1].start_ms >= w[0].end_ms)
}

/// Núcleo mutable de [`StreamingDiarizer::push`]/[`StreamingDiarizer::flush`],
/// extraído a función pura para poder testearlo sin cargar el modelo (era la
/// parte frágil sin cobertura automática: el corte por `safe_boundary_ms`,
/// el clamp con `emitted_until_ms` y el salto de lo ya emitido). `flat` es
/// la salida ya aplanada de [`flatten_overlaps`] (ordenada por inicio, sin
/// solapes); `safe_boundary_ms` es el límite hasta donde animarse a emitir
/// (`u64::MAX` = sin límite, el caso de `flush`); `emitted_until_ms` se
/// actualiza in-place con el nuevo watermark.
fn emit_new_spans(
    flat: &[(f32, f32, usize)],
    safe_boundary_ms: u64,
    emitted_until_ms: &mut u64,
) -> Vec<SpeakerSpan> {
    let mut new_spans = Vec::new();
    for &(s, e, spk) in flat {
        let end_ms = (e * 1000.0).round() as u64;
        if end_ms > safe_boundary_ms {
            // `flat` viene ordenado por inicio y, por construcción de
            // `flatten_overlaps`, también por fin -- todo lo que sigue es
            // más tarde todavía.
            break;
        }
        if end_ms <= *emitted_until_ms {
            continue;
        }
        let start_ms = (s * 1000.0).round() as u64;
        let start_ms = start_ms.max(*emitted_until_ms);
        if start_ms >= end_ms {
            continue;
        }
        new_spans.push(SpeakerSpan {
            start_ms,
            end_ms,
            speaker: spk as u8,
        });
        *emitted_until_ms = end_ms;
    }
    new_spans
}

/// Motor de diarización en streaming: ventana deslizante sobre audio que
/// llega en trozos arbitrarios de 16&nbsp;kHz mono (`push`), con caché de
/// hablantes por orden de llegada mantenido entre llamadas
/// ([`StreamState`], limpiado por [`Self::reset`]). Ver el doc comment del
/// módulo para el diseño completo (tamaño de chunk, resolución de solapes,
/// límites conocidos de la cola sin cerrar).
pub struct StreamingDiarizer {
    session: Session,
    cfg: SortformerCfg,
    state: StreamState,
    mel: MelStream,
    /// Historial completo de predicciones del modelo (`NUM_SPEAKERS` floats
    /// por frame de 80&nbsp;ms) desde el arranque del stream o el último
    /// `reset()` -- crece con la duración de la reunión (unos pocos KB por
    /// hora, ver el doc comment del módulo), a diferencia de [`MelStream`],
    /// que es O(1). Se necesita completo en cada `push()` porque el filtro
    /// de mediana y el merge de huecos cortos de `binarize` miran hacia
    /// atrás en el tiempo, no sólo el chunk más reciente.
    all_preds: Vec<f32>,
    /// Hasta dónde (en ms desde el arranque del stream) ya se devolvió un
    /// tramo en una llamada anterior a `push()` -- para no repetirlo.
    emitted_until_ms: u64,
}

impl StreamingDiarizer {
    /// Carga el modelo Sortformer desde `model_path` (un `.onnx`, ver el
    /// doc comment del módulo para cuál -- v2, no v2.1) y arranca con el
    /// caché de hablantes vacío.
    pub fn load(model_path: &Path) -> Result<Self> {
        let (session, mut cfg) = load_sortformer_session(model_path)?;
        // El default del checkpoint apunta a uso offline (~10s de latencia
        // por actualización); para vivo se fuerza el valor medido en Task 2
        // -- ver "Tamaño de chunk" en el doc comment del módulo.
        cfg.chunk_len = LIVE_CHUNK_LEN;
        Ok(Self {
            session,
            cfg,
            state: StreamState::new(),
            mel: MelStream::new(),
            all_preds: Vec::new(),
            emitted_until_ms: 0,
        })
    }

    fn feed_size(&self) -> usize {
        ((self.cfg.chunk_len + self.cfg.right_context) * SUBSAMPLING as i64) as usize
    }

    /// Cuántos frames de mel NUEVOS avanza cada llamada al modelo -- a
    /// diferencia de `feed_size` (lo que se lee), no incluye el lookahead de
    /// `right_context` (ver [`MelStream::take_chunk`]).
    fn stride(&self) -> usize {
        (self.cfg.chunk_len * SUBSAMPLING as i64) as usize
    }

    /// Alimenta `samples` (16&nbsp;kHz mono, cualquier cantidad) al motor y
    /// devuelve los tramos nuevos que ya se pueden dar por estables desde la
    /// última llamada -- casi siempre un vector vacío: la emisión sigue
    /// cierres de turno (silencio o cambio de hablante), no la cadencia de
    /// llamadas al modelo, así que mientras alguien hable de corrido
    /// `push()` no devuelve nada para ese turno por largo que sea. Ver "La
    /// emisión sigue cierres de turno, no un reloj fijo" y "Cola sin
    /// cerrar" en el doc comment del módulo -- y llamar a
    /// [`Self::flush`] al terminar una reunión, para no perder el turno que
    /// haya quedado abierto.
    pub fn push(&mut self, samples: &[f32]) -> Result<Vec<SpeakerSpan>> {
        if samples.is_empty() {
            return Ok(Vec::new());
        }
        self.mel.feed(samples);

        let feed_size = self.feed_size();
        let stride = self.stride();
        let mut advanced = false;
        while let Some(chunk_feat) = self.mel.take_chunk(feed_size, stride) {
            let chunk_preds = streaming_update(
                &mut self.session,
                &self.cfg,
                &mut self.state,
                &chunk_feat,
                feed_size as i64,
            )?;
            self.all_preds.extend_from_slice(&chunk_preds);
            advanced = true;
        }

        if !advanced {
            return Ok(Vec::new());
        }

        let total_model_frames = self.all_preds.len() / NUM_SPEAKERS;
        let flat = self.flatten_current_predictions(total_model_frames);

        let processed_s = total_model_frames as f32 * SUBSAMPLING as f32 * AUDIO_FRAME_DURATION_S;
        let safe_boundary_ms = ((processed_s - SAFE_TAIL_MARGIN_S).max(0.0) * 1000.0) as u64;

        Ok(emit_new_spans(
            &flat,
            safe_boundary_ms,
            &mut self.emitted_until_ms,
        ))
    }

    /// Fuerza la salida de lo que `push()` todavía tenía retenido -- pensado
    /// para llamarse al terminar una reunión, antes de [`Self::reset`],
    /// cuando ya no va a llegar más audio y no tiene sentido seguir
    /// esperando un cierre de turno que puede no llegar nunca. A diferencia
    /// de `push()`, si queda audio bufferizado sin completar un chunk
    /// (menos de `LIVE_CHUNK_LEN` frames de mel), lo alimenta al modelo
    /// relleno con ceros -- mismo truco que la sonda offline de Task 1 usaba
    /// para el último chunk de un WAV de duración conocida -- y emite todo
    /// lo pendiente sin aplicar el margen de estabilidad
    /// ([`SAFE_TAIL_MARGIN_S`]). No limpia el caché de hablantes: seguir
    /// llamando a `push()` después funciona (no es un `finish()` que cierra
    /// el stream), pero para arrancar una reunión nueva hay que llamar a
    /// [`Self::reset`] aparte. Ver "Cola sin cerrar" en el doc comment del
    /// módulo para las limitaciones que sigue teniendo el corte que hace
    /// `flush()`.
    pub fn flush(&mut self) -> Result<Vec<SpeakerSpan>> {
        let feed_size = self.feed_size();
        if let Some((chunk_feat, current_len)) = self.mel.take_final_chunk(feed_size) {
            let chunk_preds = streaming_update(
                &mut self.session,
                &self.cfg,
                &mut self.state,
                &chunk_feat,
                current_len as i64,
            )?;
            self.all_preds.extend_from_slice(&chunk_preds);
        }

        if self.all_preds.is_empty() {
            return Ok(Vec::new());
        }

        let total_model_frames = self.all_preds.len() / NUM_SPEAKERS;
        let flat = self.flatten_current_predictions(total_model_frames);

        Ok(emit_new_spans(&flat, u64::MAX, &mut self.emitted_until_ms))
    }

    /// `binarize()` + [`flatten_overlaps`] sobre el historial completo de
    /// predicciones -- compartido por `push()` y `flush()`, que sólo
    /// difieren en qué margen de seguridad le aplican al resultado (ver
    /// [`emit_new_spans`]).
    fn flatten_current_predictions(&self, total_model_frames: usize) -> Vec<(f32, f32, usize)> {
        let per_speaker = binarize(
            &self.all_preds,
            total_model_frames,
            self.mel.total_raw_samples,
            &self.cfg,
        );
        flatten_overlaps(per_speaker)
    }

    /// Limpia el caché de hablantes (`spkcache`/`fifo`), el historial de
    /// predicciones y el buffer de features -- para arrancar una reunión
    /// nueva sin recargar el modelo (~470&nbsp;MB, caro de recargar). El
    /// audio bufferizado sin diarizar todavía (ver "Cola sin cerrar") se
    /// descarta -- llamar a [`Self::flush`] antes si no se quiere perderlo.
    pub fn reset(&mut self) {
        self.state = StreamState::new();
        self.mel.reset();
        self.all_preds.clear();
        self.emitted_until_ms = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ------------------------------------------------------------------
    // Tests del brief (Step 1) -- puros, sin ONNX.
    // ------------------------------------------------------------------

    #[test]
    fn spans_no_se_solapan_ni_retroceden() {
        let spans = vec![
            SpeakerSpan {
                start_ms: 0,
                end_ms: 1000,
                speaker: 0,
            },
            SpeakerSpan {
                start_ms: 1000,
                end_ms: 2500,
                speaker: 1,
            },
            SpeakerSpan {
                start_ms: 2500,
                end_ms: 3000,
                speaker: 0,
            },
        ];
        assert!(spans_are_monotonic(&spans));
    }

    #[test]
    fn spans_solapados_se_detectan() {
        let spans = vec![
            SpeakerSpan {
                start_ms: 0,
                end_ms: 2000,
                speaker: 0,
            },
            SpeakerSpan {
                start_ms: 1000,
                end_ms: 3000,
                speaker: 1,
            },
        ];
        assert!(!spans_are_monotonic(&spans));
    }

    #[test]
    fn el_tope_de_hablantes_es_el_del_modelo() {
        assert_eq!(SORTFORMER_MAX_SPEAKERS, 4);
    }

    #[test]
    fn spans_monotonic_rechaza_un_tramo_invertido() {
        // start_ms > end_ms en un único tramo: no "se solapa ni retrocede"
        // respecto a nada anterior, pero tampoco es una línea de tiempo
        // válida -- M1 de la revisión de Task 2.
        let spans = vec![SpeakerSpan {
            start_ms: 100,
            end_ms: 50,
            speaker: 0,
        }];
        assert!(!spans_are_monotonic(&spans));
    }

    // ------------------------------------------------------------------
    // Tests puros adicionales -- sin ONNX.
    // ------------------------------------------------------------------

    #[test]
    fn spans_monotonic_vacio_y_de_un_elemento() {
        assert!(spans_are_monotonic(&[]));
        assert!(spans_are_monotonic(&[SpeakerSpan {
            start_ms: 5,
            end_ms: 10,
            speaker: 2,
        }]));
    }

    #[test]
    fn flatten_overlaps_el_que_llega_primero_se_queda_con_el_piso() {
        // A domina 0..10; B (que arranca a los 3s, dentro de A) sale
        // recortado a partir de donde A termina.
        let flat = flatten_overlaps(vec![(0.0, 10.0, 0), (3.0, 15.0, 1)]);
        assert_eq!(flat, vec![(0.0, 10.0, 0), (10.0, 15.0, 1)]);
    }

    #[test]
    fn flatten_overlaps_tramo_totalmente_cubierto_se_descarta() {
        // B (3..5) queda completamente dentro de A (0..10) -- no debe
        // sobrevivir ni como tramo de duración cero.
        let flat = flatten_overlaps(vec![(0.0, 10.0, 0), (3.0, 5.0, 1)]);
        assert_eq!(flat, vec![(0.0, 10.0, 0)]);
    }

    #[test]
    fn flatten_overlaps_sin_solape_no_cambia_nada() {
        let flat = flatten_overlaps(vec![(5.0, 10.0, 1), (0.0, 3.0, 0)]);
        assert_eq!(flat, vec![(0.0, 3.0, 0), (5.0, 10.0, 1)]);
    }

    #[test]
    fn flatten_overlaps_resultado_siempre_monotonico() {
        let flat = flatten_overlaps(vec![
            (0.0, 10.0, 0),
            (3.0, 15.0, 1),
            (12.0, 12.5, 2),
            (14.0, 20.0, 3),
        ]);
        let spans: Vec<SpeakerSpan> = flat
            .iter()
            .map(|&(s, e, spk)| SpeakerSpan {
                start_ms: (s * 1000.0) as u64,
                end_ms: (e * 1000.0) as u64,
                speaker: spk as u8,
            })
            .collect();
        assert!(spans_are_monotonic(&spans));
    }

    // ------------------------------------------------------------------
    // emit_new_spans -- el núcleo mutable de push()/flush() (Important 2
    // de la revisión de Task 2: antes sólo lo ejercitaba el test #[ignore]
    // que necesita el .onnx real).
    // ------------------------------------------------------------------

    #[test]
    fn emit_new_spans_emite_lo_que_entra_bajo_el_margen() {
        let flat = vec![(0.0, 3.0, 0), (4.0, 6.0, 1)];
        let mut watermark = 0u64;
        let spans = emit_new_spans(&flat, 6_000, &mut watermark);
        assert_eq!(
            spans,
            vec![
                SpeakerSpan {
                    start_ms: 0,
                    end_ms: 3000,
                    speaker: 0
                },
                SpeakerSpan {
                    start_ms: 4000,
                    end_ms: 6000,
                    speaker: 1
                },
            ]
        );
        assert_eq!(watermark, 6000);
    }

    #[test]
    fn emit_new_spans_corta_en_el_margen_de_seguridad() {
        // El segundo tramo (4..6) termina después del margen (5.5s) -- se
        // retiene, igual que hace `push()` mientras el margen de
        // estabilidad no lo confirma.
        let flat = vec![(0.0, 3.0, 0), (4.0, 6.0, 1)];
        let mut watermark = 0u64;
        let spans = emit_new_spans(&flat, 5_500, &mut watermark);
        assert_eq!(
            spans,
            vec![SpeakerSpan {
                start_ms: 0,
                end_ms: 3000,
                speaker: 0
            }]
        );
        assert_eq!(watermark, 3000, "el watermark no avanza sobre lo retenido");
    }

    #[test]
    fn emit_new_spans_no_repite_lo_ya_emitido() {
        let mut watermark = 3_000u64;
        let flat = vec![(0.0, 3.0, 0), (4.0, 6.0, 1)];
        let spans = emit_new_spans(&flat, 10_000, &mut watermark);
        // El primer tramo ya estaba cubierto por el watermark -- sólo sale
        // el segundo, nuevo.
        assert_eq!(
            spans,
            vec![SpeakerSpan {
                start_ms: 4000,
                end_ms: 6000,
                speaker: 1
            }]
        );
    }

    #[test]
    fn emit_new_spans_llamado_dos_veces_no_duplica_nada() {
        // Simula dos llamadas a push() sobre el mismo `flat` (nada cambió
        // entre medio): la segunda no debe devolver nada.
        let flat = vec![(0.0, 3.0, 0)];
        let mut watermark = 0u64;
        let first = emit_new_spans(&flat, 3_000, &mut watermark);
        let second = emit_new_spans(&flat, 3_000, &mut watermark);
        assert_eq!(first.len(), 1);
        assert!(second.is_empty());
    }

    #[test]
    fn emit_new_spans_un_turno_que_crece_entre_llamadas_sale_partido_en_dos() {
        // El caso que la revisión pidió explícitamente cubrir: un mismo
        // hablante sigue sosteniendo el mismo tramo (mismo inicio) pero
        // `binarize()` lo va extendiendo llamada a llamada porque el
        // hablante no hizo pausa. `push()` no puede "corregir" el tramo ya
        // emitido -- sólo puede emitir la continuación, contigua.
        let mut watermark = 0u64;

        // Llamada 1: el tramo (0..5) ya cruzó el margen, se emite.
        let first = emit_new_spans(&[(0.0, 5.0, 0)], 5_000, &mut watermark);
        assert_eq!(
            first,
            vec![SpeakerSpan {
                start_ms: 0,
                end_ms: 5000,
                speaker: 0
            }]
        );

        // Llamada 2: el mismo tramo, ahora más largo (0..8) porque el
        // hablante seguía hablando -- debe salir SÓLO la parte nueva
        // (5..8), contigua a lo ya emitido, no el tramo completo de vuelta.
        let second = emit_new_spans(&[(0.0, 8.0, 0)], 8_000, &mut watermark);
        assert_eq!(
            second,
            vec![SpeakerSpan {
                start_ms: 5000,
                end_ms: 8000,
                speaker: 0
            }]
        );

        // Concatenado, el historial completo sigue siendo una línea de
        // tiempo válida -- la garantía real que le importa a quien consume
        // push().
        let mut all = first;
        all.extend(second);
        assert!(spans_are_monotonic(&all));
    }

    #[test]
    fn emit_new_spans_tramo_completo_antes_del_watermark_se_ignora() {
        let mut watermark = 5_000u64;
        let spans = emit_new_spans(&[(0.0, 3.0, 1)], 10_000, &mut watermark);
        assert!(spans.is_empty());
        assert_eq!(watermark, 5_000, "no retrocede");
    }

    // ------------------------------------------------------------------
    // Sonda manual (requiere el .onnx real y un WAV 16 kHz mono en disco --
    // no corre en CI). Reemplaza el test manual de la sonda de Task 1;
    // ahora ejercita `push()`/`reset()`/`flush()`, la API pública de
    // verdad, no funciones internas. Ver task-2-report.md para los números.
    // ------------------------------------------------------------------

    #[test]
    #[ignore = "requiere DILO_SORTFORMER_WAV (WAV 16 kHz mono) y el .onnx de Sortformer v2 en disco -- ver task-2-report.md"]
    fn push_incremental_sobre_audio_real() -> Result<()> {
        use crate::audio_toolkit::read_wav_samples;
        use std::time::Instant;

        let wav_path = std::env::var("DILO_SORTFORMER_WAV")
            .context("seteá DILO_SORTFORMER_WAV con la ruta a un WAV de 16 kHz mono")?;
        {
            let reader = hound::WavReader::open(&wav_path)
                .with_context(|| format!("abriendo {wav_path}"))?;
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

        let model_path = std::env::var("DILO_SORTFORMER_MODEL_PATH").unwrap_or_else(|_| {
            "/tmp/sortformer-v2/diar_streaming_sortformer_4spk-v2.onnx".to_string()
        });
        let mut diarizer = StreamingDiarizer::load(Path::new(&model_path))?;

        // Trozos de 200ms, arbitrario -- simula al llamador (captura en
        // vivo) empujando audio en chunks chicos, desacoplado del tamaño de
        // chunk interno del modelo (LIVE_CHUNK_LEN).
        const PUSH_SAMPLES: usize = SAMPLE_RATE / 5;
        let mut all_spans: Vec<SpeakerSpan> = Vec::new();
        let mut push_calls_with_output = 0usize;
        let mut first_output_at_s: Option<f32> = None;
        let t0 = Instant::now();
        for (i, chunk) in audio.chunks(PUSH_SAMPLES).enumerate() {
            let spans = diarizer.push(chunk)?;
            if !spans.is_empty() {
                push_calls_with_output += 1;
                if first_output_at_s.is_none() {
                    first_output_at_s =
                        Some((i + 1) as f32 * PUSH_SAMPLES as f32 / SAMPLE_RATE as f32);
                }
            }
            assert!(
                spans_are_monotonic(&spans),
                "push() devolvió tramos no monotónicos en la llamada {i}"
            );
            all_spans.extend(spans);
        }
        let elapsed = t0.elapsed();

        // `flush()`: recupera el turno que haya quedado abierto + el resto
        // sin diarizar -- ver "Cola sin cerrar" en el doc comment del
        // módulo. Sin esto, todo lo posterior al último cierre de turno
        // real se pierde en silencio.
        let flushed = diarizer.flush()?;
        assert!(
            spans_are_monotonic(&flushed),
            "flush() devolvió tramos no monotónicos"
        );
        all_spans.extend(flushed.clone());
        assert!(
            spans_are_monotonic(&all_spans),
            "el historial completo (push + flush) no es monotónico"
        );

        println!("\n=== StreamingDiarizer sobre {wav_path} ({audio_duration_s:.2}s) ===");
        for s in &all_spans {
            println!(
                "{:.2}s → {:.2}s | hablante {}",
                s.start_ms as f32 / 1000.0,
                s.end_ms as f32 / 1000.0,
                s.speaker
            );
        }
        let speakers: std::collections::BTreeSet<u8> =
            all_spans.iter().map(|s| s.speaker).collect();
        let flushed_tail_s = flushed
            .last()
            .map(|s| s.end_ms as f32 / 1000.0 - flushed.first().unwrap().start_ms as f32 / 1000.0);
        println!(
            "hablantes distintos: {} | llamadas a push() con salida: {push_calls_with_output} | \
             primera salida a los {:.2}s de audio empujado | tiempo total: {:.2}s para {audio_duration_s:.2}s \
             de audio ({:.3}x tiempo real) | flush() recuperó {} tramo(s) ({:?}s cubiertos)",
            speakers.len(),
            first_output_at_s.unwrap_or(-1.0),
            elapsed.as_secs_f32(),
            elapsed.as_secs_f32() / audio_duration_s.max(0.001),
            flushed.len(),
            flushed_tail_s
        );

        Ok(())
    }
}
