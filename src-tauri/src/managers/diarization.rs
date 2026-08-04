//! Speaker diarization engine: identifies "who spoke when" within a meeting
//! recording, including marking audio where two people spoke at once
//! (FR-004) instead of guessing a single speaker.
//!
//! ## Provenance (T009)
//!
//! This is a direct algorithmic port of sherpa-onnx's (`k2-fsa/sherpa-onnx`)
//! offline pyannote-based speaker diarization pipeline, run on the two ONNX
//! models T008 already acquired (`diarization_models.rs`) via the `ort`
//! crate Dilo already depends on for `tts/supertonic.rs` — **not** a
//! reimplementation from general ML knowledge of how diarization "usually"
//! works. Per the T009 brief (`.superpowers/sdd/task-T009-brief.md`) and the
//! project's Principio VI (Sin Atajos de Alcance), this doc comment records
//! exactly which sherpa-onnx C++ sources were read (cloned locally from
//! `k2-fsa/sherpa-onnx`, branch `master`, during this task) and what each one
//! established, so a reviewer can verify the port against the same sources:
//!
//! - `sherpa-onnx/csrc/offline-speaker-segmentation-pyannote-model.{h,cc}`
//!   and `-meta-data.h`: the segmentation model is a plain `Ort::Session`
//!   (`ort::session::Session` here) that takes a raw waveform tensor of shape
//!   `(1, 1, window_size)` — no feature extraction — and returns
//!   `(1, num_frames, num_classes)` powerset-encoded logits. All of
//!   `sample_rate`/`window_size`/`receptive_field_size`/
//!   `receptive_field_shift`/`num_speakers`/`powerset_max_classes`/
//!   `num_classes` are read from the ONNX file's **custom metadata** at load
//!   time (`read_i32_metadata` below), exactly like sherpa-onnx's
//!   `SHERPA_ONNX_READ_META_DATA` macro — not hardcoded, even though this
//!   session also independently downloaded and inspected
//!   `pyannote_segmentation_3_0.onnx`'s real metadata with `onnx.load()` to
//!   confirm the expected values (`window_size=160000`, `num_speakers=3`,
//!   `powerset_max_classes=2`, `num_classes=7`, `receptive_field_size=991`,
//!   `receptive_field_shift=270`, `sample_rate=16000`) before writing this
//!   code, so the dynamic-reading path could be validated against the real
//!   committed file, not just against the C++ struct definitions.
//! - `sherpa-onnx/csrc/offline-speaker-diarization-pyannote-impl.h`: the full
//!   pipeline — `RunSpeakerSegmentationModel` (overlapping-window chunking,
//!   `window_shift = clamp(window_shift_ratio * window_size, 1, window_size)`
//!   with `window_shift_ratio = 0.1`, from
//!   `offline-speaker-segmentation-pyannote-model-config.h`),
//!   `InitPowersetMapping`/`ToMultiLabel` (powerset decoding),
//!   `ComputeSpeakersPerFrame` (weighted aggregation of overlapping-chunk
//!   frame counts into a single global timeline), `ExcludeOverlap` +
//!   `GetChunkSpeakerSampleIndexes` (drop frames with 2+ simultaneous local
//!   speakers before extracting per-speaker sample ranges — the >=10-frame
//!   minimum-run filter is theirs, ported verbatim), `ComputeEmbeddings`,
//!   `ConvertChunkSpeakerToCluster`/`ReLabel`/`ComputeSpeakerCount`/
//!   `FinalizeLabels` (mapping local per-window speaker slots to global
//!   cluster IDs and picking the top-k active clusters per frame, where k
//!   comes from `ComputeSpeakersPerFrame`), `ComputeResult`/`MergeSegments`
//!   (frame runs -> time segments, gap-merging by `min_duration_off`,
//!   dropping segments shorter than `min_duration_on`), and
//!   `HandleOneChunkSpecialCase` (audio no longer than one window skips
//!   embeddings/clustering entirely — local speaker slots ARE the global
//!   speaker IDs when there is only one window).
//! - `sherpa-onnx/csrc/speaker-embedding-extractor-model.{h,cc}` and
//!   `speaker-embedding-extractor-general-impl.h`: the embedding model takes
//!   `(N, T, feature_dim)` Fbank features (not raw audio), with
//!   `output_dim`/`sample_rate`/`normalize_samples`/`feature_normalize_type`/
//!   `framework` read from ONNX custom metadata the same way. This session
//!   downloaded the real (T008-verified) embedding checkpoint
//!   (`3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx`,
//!   confirmed byte-for-byte via its already-recorded SHA-256 in
//!   `diarization_models.rs`) and inspected its metadata directly:
//!   `output_dim=192`, `sample_rate=16000`, `normalize_samples=1`,
//!   `feature_normalize_type="global-mean"`, `framework="3d-speaker"`, input
//!   shape `(N, T, 80)`. `SubtractGlobalMean` (per-utterance, per-mel-bin
//!   mean subtraction across time) is ported verbatim for the
//!   `"global-mean"` case.
//! - `sherpa-onnx/csrc/features.h` / `features.cc`
//!   (`FeatureExtractorConfig::InitFbank`): the exact Fbank options the
//!   embedding model's feature stream uses when nothing overrides them —
//!   `feature_dim=80`, `low_freq=20.0`, `high_freq=-400.0` (Nyquist minus
//!   400 Hz), `dither=0.0`, `snip_edges=false`, `frame_shift_ms=10.0`,
//!   `frame_length_ms=25.0`, `remove_dc_offset=true`, `preemph_coeff=0.97`,
//!   `window_type="povey"`, `round_to_power_of_two=true`, and critically
//!   `use_energy=false` for the fbank path (only used for MFCC in
//!   sherpa-onnx) — reproduced explicitly in
//!   [`EmbeddingModel::compute`] below rather than relying on any crate's
//!   own defaults (see the `kaldi-native-fbank` note further down, which
//!   defaults `use_energy` to `true` and would silently misalign the feature
//!   dimension if used unmodified).
//! - `sherpa-onnx/csrc/fast-clustering.{h,cc}` and
//!   `fast-clustering-config.{h,cc}`: the clustering step. Per-row L2
//!   normalization, then a **condensed cosine-dissimilarity matrix**
//!   (`max(0, 1 - cosine_similarity)`, upper triangle, `i < j` order) fed to
//!   `fastclustercpp::hclust_fast(..., HCLUST_METHOD_COMPLETE, ...)`
//!   (complete-linkage agglomerative clustering, i.e. **not** spectral
//!   clustering — the correction `research.md` §1 and T002 already flagged),
//!   then `cutree_cdist(..., threshold, ...)` to cut the dendrogram at a
//!   fixed dissimilarity threshold (default `0.5`) when the speaker count is
//!   unknown, which is what makes FR-003 possible without ever choosing a
//!   fixed `k`. `sherpa-onnx-offline-speaker-diarization.cc` (the reference
//!   CLI) documents this default and the `--clustering.cluster-threshold`
//!   flag's meaning (larger threshold -> fewer speakers).
//! - `sherpa-onnx/csrc/offline-speaker-diarization-result.{h,cc}`: segment
//!   merge semantics (`Merge`: only join two same-speaker segments if the
//!   gap between them is `<= min_duration_off`) and the `min_duration_on`
//!   filter (drop segments shorter than `0.3` s), both ported verbatim from
//!   `OfflineSpeakerDiarizationConfig`'s documented defaults
//!   (`min_duration_on = 0.3`, `min_duration_off = 0.5`).
//! - `sherpa-onnx-offline-speaker-diarization.cc` (reference CLI): confirms
//!   the caller is expected to supply audio **already at the segmentation
//!   model's sample rate** — the CLI itself rejects a mismatched sample rate
//!   outright rather than resampling internally for this pipeline. This
//!   module does the same in [`DiarizationEngine::diarize`] (returns an
//!   error instead of silently resampling); resampling audio before calling
//!   this engine is the future caller's job (T012+), same division of
//!   responsibility as upstream.
//!
//! ## Deliberate, disclosed simplifications and deviations
//!
//! Per the brief's escalation ladder (full fidelity > documented
//! simplification > escalate — never a silent shortcut), here is every place
//! this port differs from sherpa-onnx's C++ on purpose, and why:
//!
//! 1. **FR-004 "overlapped" marking is a Dilo-specific addition, not present
//!    in sherpa-onnx's own result type at all.** sherpa-onnx's
//!    `OfflineSpeakerDiarizationResult`/`OfflineSpeakerDiarizationSegment`
//!    has no concept of "uncertain" segments — its native output is simply
//!    one independent segment list per speaker, which can (and does)
//!    overlap in time across speakers when two people spoke at once; nothing
//!    downstream is told this happened. Dilo's FR-004 explicitly requires
//!    marking such audio as uncertain instead of silently attributing it.
//!    This implementation reuses data the pipeline already computes for
//!    another purpose (`speakers_per_frame`, sherpa-onnx's own
//!    `ComputeSpeakersPerFrame` output, which counts simultaneous local
//!    speakers **before** the overlap-exclusion step that feeds embeddings)
//!    and additionally flags a segment as `overlapped = true` if `>= 2`
//!    speakers were estimated active at any frame within that segment's
//!    time range. This is a **segment-level** flag (computed once per
//!    finished segment), not a **frame-level** one that would split segments
//!    exactly at overlap-boundary transitions — the latter would need to
//!    thread the overlap flag through `MergeSegments`' gap-merging criterion
//!    too, and given segments here are already only a few seconds long by
//!    construction (`min_duration_on`/`min_duration_off` keep them short),
//!    the practical loss of precision from not sub-splitting is small. This
//!    is disclosed as a real simplification, not hidden.
//! 2. **No `--clustering.num-clusters` (fixed-k) mode.** sherpa-onnx's
//!    `FastClusteringConfig` supports both a distance-threshold cut (unknown
//!    speaker count) and a fixed-`k` cut. FR-003 requires "sin conocer de
//!    antemano cuántos hablantes hay," so only the threshold path is
//!    implemented here. This narrows sherpa-onnx's *config surface*, not the
//!    clustering *algorithm* itself (same complete-linkage dendrogram either
//!    way).
//! 3. **Graceful degradation instead of `SHERPA_ONNX_EXIT(-1)`.** The C++
//!    source hard-exits the whole process in a few "should not happen"
//!    branches (e.g. a filtered speech segment somehow too short to produce
//!    one Fbank frame, an embedding that comes back NaN). Dilo is a desktop
//!    GUI app, not a CLI tool — aborting the process on a defensive
//!    assertion in one meeting's diarization would be strictly worse than
//!    Rust's own reference behavior. This port logs a warning and skips that
//!    one (chunk, speaker) pair instead, letting the rest of the meeting's
//!    diarization proceed. This is a safety improvement on an edge case, not
//!    a shortcut on the core algorithm.
//! 4. **Metadata parsing is stricter than sherpa-onnx's.** The C++ macro
//!    uses `atoi`, which silently returns `0` for a non-numeric string
//!    instead of failing. [`read_i32_metadata`] uses Rust's `str::parse`,
//!    which returns an error instead — this can only make a corrupt/renamed
//!    model file fail loudly at load time rather than silently run with a
//!    wrong value.
//! 5. **Fbank feature extraction uses the `kaldi-native-fbank` crate**
//!    (RustedBytes, MIT, pure Rust) instead of a hand-rolled FFT + mel
//!    filterbank. This is not "skipping" the real preprocessing — it is a
//!    Rust port of the *same* `kaldi-native-fbank` C++ library that
//!    sherpa-onnx itself vendors (confirmed by finding the literal
//!    `#include "kaldi-native-fbank/csrc/online-feature.h"` in
//!    `sherpa-onnx/csrc/features.cc`). Its window functions (`povey`
//!    formula), mel-scale formula (`1127 * ln(1 + f/700)`, the classic
//!    Kaldi/HTK formula, unaffected by its unused `use_slaney_mel_scale`
//!    field — verified by reading `src/mel.rs`) and per-frame log-energy
//!    formula were spot-checked against the standard Kaldi conventions
//!    before use. Its own `FbankOptions::default()`/`FrameOptions::default()`
//!    differ from what sherpa-onnx actually configures in a couple of
//!    fields (notably `use_energy: true` and `snip_edges: true` by default,
//!    vs. sherpa-onnx's `false`/`false`) — [`EmbeddingModel::compute`] does
//!    **not** rely on the crate's defaults; every field is set explicitly to
//!    match `sherpa-onnx/csrc/features.cc`'s `InitFbank()` values.
//! 6. **`num_speakers`/`powerset_max_classes` other than what pyannote-3.0
//!    ships is not supported**, matching sherpa-onnx's own limitation, not a
//!    new one: `InitPowersetMapping` in the C++ source hard-exits for
//!    `powerset_max_classes >= 3` with "currently not supported" — this port
//!    returns an error instead (per simplification 3 above) but does not
//!    attempt to support more than sherpa-onnx itself does.
//!
//! See `.superpowers/sdd/task-T009-report.md` for the full research log,
//! including the exact `gh`/`git clone` commands used and links to every
//! source file.
//!
//! `DiarizationEngine::load`/`diarize` (and everything they call) have no
//! caller outside this module's own tests yet -- wiring them into
//! `MeetingManager`/`commands/meeting.rs` and deciding when model loading
//! happens (lazy, on first `start_meeting`) is explicitly T012+'s job per
//! the T009 brief, not this task's. `#[allow(dead_code)]` stays until then,
//! same pattern (and same reasoning) as `managers/diarization_models.rs`.
#![allow(dead_code)]

use anyhow::{anyhow, bail, Context, Result};
use kaldi_native_fbank::mel::MelOptions;
use kaldi_native_fbank::online::FeatureComputer;
use kaldi_native_fbank::{FbankComputer, FbankOptions, FrameOptions, OnlineFeature};
use kodama::{linkage, Method};
use ndarray::Array3;
use ort::session::Session;
use ort::value::Value;
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Mutex, RwLock};

// ============================================================================
// Constantes del algoritmo — valores por defecto de sherpa-onnx, no
// inventados acá. Ver el doc comment del módulo para la fuente exacta de
// cada uno.
// ============================================================================

/// `OfflineSpeakerSegmentationPyannoteModelConfig::window_shift_ratio`
/// default. El shift real (en samples) se calcula como
/// `window_shift_ratio * window_size`, leído dinámicamente de la metadata
/// del modelo — ver [`SegmentationModel::load`].
const WINDOW_SHIFT_RATIO: f32 = 0.1;

/// `OfflineSpeakerDiarizationConfig::min_duration_on` default (segundos):
/// segmentos más cortos que esto se descartan.
const MIN_DURATION_ON_S: f32 = 0.3;

/// `OfflineSpeakerDiarizationConfig::min_duration_off` default (segundos):
/// dos segmentos del mismo hablante separados por menos que esto se
/// fusionan.
const MIN_DURATION_OFF_S: f32 = 0.5;

/// `FastClusteringConfig::threshold` default: distancia coseno máxima para
/// fusionar dos clusters en el corte del dendrograma. Más alto = menos
/// hablantes; más bajo = más hablantes. Este es el mecanismo que cumple
/// FR-003 (no hace falta conocer `k` de antemano).
///
/// `pub(crate)` porque T013 (`managers/meeting.rs`) deriva de este mismo
/// número los umbrales de su registro de hablantes en vivo: la atribución
/// turno-a-turno de una reunión es el mismo juicio "¿estos dos embeddings son
/// la misma persona?" que hace este corte, sólo que incremental — tenerlos
/// desacoplados haría que un mismo audio se agrupe distinto según por dónde
/// entró.
pub(crate) const CLUSTER_THRESHOLD: f32 = 0.5;

/// `GetChunkSpeakerSampleIndexes`: un tramo de actividad local más corto que
/// esto (en frames de segmentación, no en samples de audio) se descarta
/// antes de intentar calcular un embedding para él.
const MIN_ACTIVE_SEGMENTATION_FRAMES: u32 = 10;

// ============================================================================
// Lectura de metadata custom de ONNX — equivalente a
// `SHERPA_ONNX_READ_META_DATA` (macros.h), con parsing más estricto (ver
// simplificación 4 en el doc comment del módulo).
// ============================================================================

fn read_i32_metadata(session: &Session, key: &str) -> Result<i32> {
    let metadata = session
        .metadata()
        .context("leyendo metadata del modelo ONNX")?;
    let raw = metadata
        .custom(key)
        .ok_or_else(|| anyhow!("falta la metadata custom '{key}' en el modelo ONNX"))?;
    raw.trim()
        .parse::<i32>()
        .with_context(|| format!("metadata '{key}' = '{raw}' no es un entero válido"))
}

fn read_string_metadata(session: &Session, key: &str) -> Option<String> {
    session.metadata().ok()?.custom(key)
}

// ============================================================================
// Modelo de segmentación (pyannote-style)
// ============================================================================

/// Metadata leída de la metadata custom del `.onnx` de segmentación —
/// equivalente a `OfflineSpeakerSegmentationPyannoteModelMetaData`.
#[derive(Debug, Clone, Copy)]
struct SegmentationMetaData {
    sample_rate: i32,
    window_size: i32,
    window_shift: i32,
    receptive_field_size: i32,
    receptive_field_shift: i32,
    /// Cantidad de "slots" de hablante local por ventana (p.ej. 3 en
    /// pyannote-segmentation-3.0). No es la cantidad final de hablantes de
    /// la reunión — eso lo determina el clustering.
    num_speakers: i32,
    powerset_max_classes: i32,
    num_classes: i32,
}

struct SegmentationModel {
    session: Mutex<Session>,
    input_name: String,
    output_name: String,
    meta: SegmentationMetaData,
    /// `powerset_mapping[class][speaker] = 0|1` — equivalente a
    /// `powerset_mapping_` (`InitPowersetMapping`).
    powerset_mapping: Vec<Vec<u8>>,
}

impl SegmentationModel {
    fn load(model_path: &Path) -> Result<Self> {
        let session = Session::builder()?
            .commit_from_file(model_path)
            .with_context(|| {
                format!(
                    "cargando modelo de segmentación de hablantes: {}",
                    model_path.display()
                )
            })?;

        let input_name = session
            .inputs()
            .first()
            .ok_or_else(|| anyhow!("modelo de segmentación sin ningún input"))?
            .name()
            .to_string();
        let output_name = session
            .outputs()
            .first()
            .ok_or_else(|| anyhow!("modelo de segmentación sin ningún output"))?
            .name()
            .to_string();

        let sample_rate = read_i32_metadata(&session, "sample_rate")?;
        let window_size = read_i32_metadata(&session, "window_size")?;
        let receptive_field_size = read_i32_metadata(&session, "receptive_field_size")?;
        let receptive_field_shift = read_i32_metadata(&session, "receptive_field_shift")?;
        let num_speakers = read_i32_metadata(&session, "num_speakers")?;
        let powerset_max_classes = read_i32_metadata(&session, "powerset_max_classes")?;
        let num_classes = read_i32_metadata(&session, "num_classes")?;

        if powerset_max_classes != 2 {
            // Mismo límite que sherpa-onnx: `InitPowersetMapping` hard-exits
            // para powerset_max_classes >= 3 ("currently not supported").
            // No es una limitación nueva de este port.
            bail!(
                "powerset_max_classes = {powerset_max_classes} no soportado (sherpa-onnx \
                 tampoco lo soporta; solo el caso 2, el de pyannote-segmentation-3.0, está \
                 implementado)"
            );
        }

        let window_shift_f = WINDOW_SHIFT_RATIO * window_size as f32;
        let window_shift = if !window_shift_f.is_finite() || window_shift_f < 1.0 {
            1
        } else if window_shift_f > window_size as f32 {
            window_size
        } else {
            window_shift_f as i32
        };

        let meta = SegmentationMetaData {
            sample_rate,
            window_size,
            window_shift,
            receptive_field_size,
            receptive_field_shift,
            num_speakers,
            powerset_max_classes,
            num_classes,
        };

        let powerset_mapping = build_powerset_mapping(
            num_classes as usize,
            num_speakers as usize,
            powerset_max_classes as usize,
        );

        Ok(Self {
            session: Mutex::new(session),
            input_name,
            output_name,
            meta,
            powerset_mapping,
        })
    }

    /// `ProcessChunk`: corre el modelo sobre una ventana de exactamente
    /// `window_size` samples y devuelve `(num_frames, num_classes, data)`
    /// con `data` en row-major `(num_frames, num_classes)`.
    fn forward(&self, window: &[f32]) -> Result<(usize, usize, Vec<f32>)> {
        debug_assert_eq!(window.len(), self.meta.window_size as usize);

        let array = Array3::from_shape_vec((1, 1, window.len()), window.to_vec())
            .context("armando el tensor de entrada del modelo de segmentación")?;
        let value = Value::from_array(array)?;

        let mut session = self.session.lock().unwrap();
        let outputs = session.run(ort::inputs![self.input_name.as_str() => &value])?;
        let (shape, data) = outputs[self.output_name.as_str()].try_extract_tensor::<f32>()?;

        let num_frames = shape[1] as usize;
        let num_classes = shape[2] as usize;
        Ok((num_frames, num_classes, data.to_vec()))
    }
}

/// `InitPowersetMapping`, port directo (ver
/// https://github.com/pyannote/pyannote-audio/blob/develop/pyannote/audio/utils/powerset.py#L68
/// citado también en el comentario original). Solo soporta
/// `powerset_max_classes == 2` — mismo límite de sherpa-onnx, no uno nuevo.
// `needless_range_loop`: se mantiene deliberadamente como los loops
// anidados con índices explícitos del original en vez de reescribirlo con
// iteradores -- acá la fidelidad estructural con `InitPowersetMapping`
// importa más que el idiom de Rust (`k` avanza independiente de `j`/`m`,
// así que un iterador sobre `mapping` no simplifica nada).
#[allow(clippy::needless_range_loop)]
fn build_powerset_mapping(
    num_classes: usize,
    num_speakers: usize,
    powerset_max_classes: usize,
) -> Vec<Vec<u8>> {
    let mut mapping = vec![vec![0u8; num_speakers]; num_classes];
    let mut k = 1usize;
    for i in 1..=powerset_max_classes.min(2) {
        if i == 1 {
            for j in 0..num_speakers {
                if k < num_classes {
                    mapping[k][j] = 1;
                }
                k += 1;
            }
        } else if i == 2 {
            for j in 0..num_speakers {
                for m in (j + 1)..num_speakers {
                    if k < num_classes {
                        mapping[k][j] = 1;
                        mapping[k][m] = 1;
                    }
                    k += 1;
                }
            }
        }
    }
    mapping
}

/// `ToMultiLabel`: argmax por frame sobre las clases powerset, mapeado a un
/// vector multi-hot de hablantes locales vía `powerset_mapping`.
fn to_multi_label(
    num_frames: usize,
    num_classes: usize,
    data: &[f32],
    mapping: &[Vec<u8>],
) -> Vec<Vec<u8>> {
    let mut ans = Vec::with_capacity(num_frames);
    for f in 0..num_frames {
        let row = &data[f * num_classes..(f + 1) * num_classes];
        let mut best_idx = 0usize;
        let mut best_val = f32::NEG_INFINITY;
        for (i, &v) in row.iter().enumerate() {
            if v > best_val {
                best_val = v;
                best_idx = i;
            }
        }
        ans.push(mapping[best_idx].clone());
    }
    ans
}

// ============================================================================
// Modelo de embeddings de hablante
// ============================================================================

#[derive(Debug, Clone)]
struct EmbeddingMetaData {
    output_dim: i32,
    sample_rate: i32,
    normalize_samples: bool,
    feature_normalize_type: String,
}

struct EmbeddingModel {
    session: Mutex<Session>,
    input_name: String,
    output_name: String,
    meta: EmbeddingMetaData,
}

impl EmbeddingModel {
    fn load(model_path: &Path) -> Result<Self> {
        let session = Session::builder()?
            .commit_from_file(model_path)
            .with_context(|| {
                format!(
                    "cargando modelo de embeddings de hablante: {}",
                    model_path.display()
                )
            })?;

        let input_name = session
            .inputs()
            .first()
            .ok_or_else(|| anyhow!("modelo de embeddings sin ningún input"))?
            .name()
            .to_string();
        let output_name = session
            .outputs()
            .first()
            .ok_or_else(|| anyhow!("modelo de embeddings sin ningún output"))?
            .name()
            .to_string();

        let output_dim = read_i32_metadata(&session, "output_dim")?;
        let sample_rate = read_i32_metadata(&session, "sample_rate")?;
        let normalize_samples = read_i32_metadata(&session, "normalize_samples")? != 0;
        let feature_normalize_type =
            read_string_metadata(&session, "feature_normalize_type").unwrap_or_default();

        let framework = read_string_metadata(&session, "framework").unwrap_or_default();
        if framework != "wespeaker" && framework != "3d-speaker" {
            bail!(
                "modelo de embeddings de hablante inesperado: framework metadata = '{framework}' \
                 (se esperaba 'wespeaker' o '3d-speaker', igual que sherpa-onnx valida en \
                 speaker-embedding-extractor-model.cc)"
            );
        }

        Ok(Self {
            session: Mutex::new(session),
            input_name,
            output_name,
            meta: EmbeddingMetaData {
                output_dim,
                sample_rate,
                normalize_samples,
                feature_normalize_type,
            },
        })
    }

    /// `SpeakerEmbeddingExtractorGeneralImpl::Compute`: computa el embedding
    /// de hablante para un tramo de audio (posiblemente concatenado a partir
    /// de varios rangos disjuntos del mismo hablante local, ver
    /// `ComputeEmbeddings` en el C++ original / [`compute_embeddings`] acá).
    fn compute(&self, samples: &[f32], sample_rate: u32) -> Result<Vec<f32>> {
        if sample_rate != self.meta.sample_rate as u32 {
            bail!(
                "EmbeddingModel::compute: se esperaba audio a {} Hz, se recibió {} Hz",
                self.meta.sample_rate,
                sample_rate
            );
        }

        let scaled;
        let feed: &[f32] = if self.meta.normalize_samples {
            samples
        } else {
            scaled = samples.iter().map(|&s| s * 32768.0).collect::<Vec<_>>();
            &scaled
        };

        // Valores EXACTOS de `FeatureExtractorConfig::InitFbank()` en
        // sherpa-onnx/csrc/features.cc — no los defaults del crate
        // `kaldi-native-fbank` (que difieren en use_energy/snip_edges). Ver
        // simplificación 5 del doc comment del módulo.
        let frame_opts = FrameOptions {
            samp_freq: self.meta.sample_rate as f32,
            frame_shift_ms: 10.0,
            frame_length_ms: 25.0,
            dither: 0.0,
            preemph_coeff: 0.97,
            remove_dc_offset: true,
            window_type: "povey".to_string(),
            round_to_power_of_two: true,
            blackman_coeff: 0.42,
            snip_edges: false,
        };
        let mel_opts = MelOptions {
            num_bins: 80,
            low_freq: 20.0,
            high_freq: -400.0,
            ..Default::default()
        };
        let fbank_opts = FbankOptions {
            frame_opts,
            mel_opts,
            use_energy: false,
            raw_energy: true,
            htk_compat: false,
            energy_floor: 0.0,
            use_log_fbank: true,
            use_power: true,
        };

        let computer = FbankComputer::new(fbank_opts)
            .map_err(|e| anyhow!("inicializando el extractor de features Fbank: {e}"))?;
        let mut online = OnlineFeature::new(FeatureComputer::Fbank(computer));
        online.accept_waveform(self.meta.sample_rate as f32, feed);
        online.input_finished();

        let num_frames = online.num_frames_ready();
        if num_frames == 0 {
            bail!("el segmento de audio es demasiado corto para generar al menos un frame Fbank");
        }

        let feat_dim = 80usize;
        let mut features: Vec<Vec<f32>> = Vec::with_capacity(num_frames);
        for i in 0..num_frames {
            let frame = online
                .get_frame(i)
                .ok_or_else(|| anyhow!("frame Fbank {i} fuera de rango"))?;
            features.push(frame.to_vec());
        }

        if self.meta.feature_normalize_type == "global-mean" {
            subtract_global_mean(&mut features, feat_dim);
        }

        let mut flat = Vec::with_capacity(num_frames * feat_dim);
        for row in &features {
            flat.extend_from_slice(row);
        }
        let array = Array3::from_shape_vec((1, num_frames, feat_dim), flat)
            .context("armando el tensor de features del modelo de embeddings")?;
        let value = Value::from_array(array)?;

        let mut session = self.session.lock().unwrap();
        let outputs = session.run(ort::inputs![self.input_name.as_str() => &value])?;
        let (_, data) = outputs[self.output_name.as_str()].try_extract_tensor::<f32>()?;

        Ok(data.to_vec())
    }
}

/// `SubtractGlobalMean` (speaker-embedding-extractor-general-impl.h): resta,
/// por cada dimensión mel, la media a lo largo del tiempo del propio
/// segmento (media "global" al segmento, no al dataset).
fn subtract_global_mean(features: &mut [Vec<f32>], feat_dim: usize) {
    let t = features.len();
    if t == 0 {
        return;
    }
    let mut mean = vec![0.0f32; feat_dim];
    for row in features.iter() {
        for (i, &v) in row.iter().enumerate() {
            mean[i] += v;
        }
    }
    for m in mean.iter_mut() {
        *m /= t as f32;
    }
    for row in features.iter_mut() {
        for (i, v) in row.iter_mut().enumerate() {
            *v -= mean[i];
        }
    }
}

// ============================================================================
// Clustering jerárquico/aglomerativo (fast-clustering.cc)
// ============================================================================

/// `FastClustering::Cluster`: normaliza L2 cada embedding, arma la matriz
/// condensada de disimilitud coseno, corre clustering jerárquico
/// complete-linkage (`kodama::Method::Complete`, equivalente a
/// `HCLUST_METHOD_COMPLETE`) y corta el dendrograma por umbral de distancia
/// (equivalente a `cutree_cdist`) — nunca por `k` fijo, ver simplificación 2
/// del doc comment del módulo.
///
/// `kodama::linkage` garantiza (verificado leyendo `src/union.rs`: `relabel`
/// ordena los steps por disimilitud ascendente antes de asignarles label,
/// para cualquier método que no sea Centroid/Median) que `dendrogram.steps()`
/// viene en orden de altura no decreciente — la misma propiedad de
/// "sin inversiones" que linkage completo garantiza y que scipy/fastcluster
/// asumen. Esto es lo que hace válido cortar con un simple union-find en un
/// solo pase: para cuando se procesa un step con altura <= threshold, todos
/// los steps que lo preceden topológicamente (y por lo tanto tienen altura
/// <= la suya) ya fueron procesados.
/// Similitud coseno entre dos embeddings de hablante, en `[-1, 1]`. Es la
/// misma métrica que usa [`cluster_embeddings`] (que trabaja con su
/// disimilitud, `max(0, 1 - cos)`), expuesta como función suelta para el
/// registro incremental de hablantes de T013, que compara de a un embedding
/// contra centroides ya acumulados en vez de armar una matriz condensada
/// completa. Devuelve `0.0` si alguno de los dos vectores es nulo o si las
/// dimensiones no coinciden — un "no se parecen" neutro, nunca un pánico.
pub(crate) fn cosine_similarity(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() {
        return 0.0;
    }
    let dot: f32 = a.iter().zip(b).map(|(x, y)| x * y).sum();
    let norm_a = a.iter().map(|x| x * x).sum::<f32>().sqrt();
    let norm_b = b.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm_a == 0.0 || norm_b == 0.0 {
        return 0.0;
    }
    dot / (norm_a * norm_b)
}

fn cluster_embeddings(embeddings: &[Vec<f32>], threshold: f32) -> Vec<usize> {
    let n = embeddings.len();
    if n == 0 {
        return vec![];
    }
    if n == 1 {
        return vec![0];
    }

    let normalized: Vec<Vec<f32>> = embeddings
        .iter()
        .map(|v| {
            let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
            if norm > 0.0 {
                v.iter().map(|x| x / norm).collect()
            } else {
                v.clone()
            }
        })
        .collect();

    let mut condensed: Vec<f32> = Vec::with_capacity(n * (n - 1) / 2);
    for i in 0..n {
        for j in (i + 1)..n {
            let dot: f32 = normalized[i]
                .iter()
                .zip(&normalized[j])
                .map(|(a, b)| a * b)
                .sum();
            condensed.push((1.0 - dot).max(0.0));
        }
    }

    let dendrogram = linkage(&mut condensed, n, Method::Complete);

    let total_labels = n + dendrogram.len();
    let mut parent: Vec<usize> = (0..total_labels).collect();

    fn find(parent: &mut [usize], x: usize) -> usize {
        if parent[x] != x {
            let root = find(parent, parent[x]);
            parent[x] = root;
        }
        parent[x]
    }
    fn union(parent: &mut [usize], a: usize, b: usize) {
        let ra = find(parent, a);
        let rb = find(parent, b);
        if ra != rb {
            parent[ra] = rb;
        }
    }

    for (step_index, step) in dendrogram.steps().iter().enumerate() {
        if step.dissimilarity <= threshold {
            union(&mut parent, step.cluster1, step.cluster2);
            union(&mut parent, n + step_index, step.cluster1);
        }
    }

    let mut label_map: HashMap<usize, usize> = HashMap::new();
    let mut labels = Vec::with_capacity(n);
    for i in 0..n {
        let root = find(&mut parent, i);
        let next_id = label_map.len();
        let id = *label_map.entry(root).or_insert(next_id);
        labels.push(id);
    }
    labels
}

// ============================================================================
// Ventaneo + segmentación local (offline-speaker-diarization-pyannote-impl.h)
// ============================================================================

struct SegChunk {
    /// `labels[frame][speaker] = 0|1`, ya decodificado de powerset.
    labels: Vec<Vec<u8>>,
}

/// `RunSpeakerSegmentationModel` + `ToMultiLabel`: parte `audio` en ventanas
/// (con la última rellenada con ceros si hace falta), corre el modelo de
/// segmentación en cada una y decodifica powerset -> multi-hot.
fn run_segmentation(seg: &SegmentationModel, audio: &[f32]) -> Result<Vec<SegChunk>> {
    let window_size = seg.meta.window_size as usize;
    let window_shift = seg.meta.window_shift as usize;
    let n = audio.len();

    if n == 0 {
        return Ok(vec![]);
    }

    let mut raw_chunks: Vec<(usize, usize, Vec<f32>)> = Vec::new();

    if n <= window_size {
        let mut buf = vec![0.0f32; window_size];
        buf[..n].copy_from_slice(audio);
        raw_chunks.push(seg.forward(&buf)?);
    } else {
        let num_chunks = (n - window_size) / window_shift + 1;
        let has_last_chunk = !(n - window_size).is_multiple_of(window_shift);

        for i in 0..num_chunks {
            let start = i * window_shift;
            raw_chunks.push(seg.forward(&audio[start..start + window_size])?);
        }

        if has_last_chunk {
            let start = num_chunks * window_shift;
            if start < n {
                let mut buf = vec![0.0f32; window_size];
                let remaining = &audio[start..];
                let take = remaining.len().min(window_size);
                buf[..take].copy_from_slice(&remaining[..take]);
                raw_chunks.push(seg.forward(&buf)?);
            }
        }
    }

    Ok(raw_chunks
        .into_iter()
        .map(|(num_frames, num_classes, data)| SegChunk {
            labels: to_multi_label(num_frames, num_classes, &data, &seg.powerset_mapping),
        })
        .collect())
}

/// `ComputeSpeakersPerFrame`: agrega, con peso por solapamiento de ventanas,
/// cuántos hablantes locales están activos en cada frame de la línea de
/// tiempo global. Se reutiliza también para la marca `overlapped` de FR-004
/// (ver doc comment del módulo, simplificación 1).
fn compute_speakers_per_frame(
    chunks: &[SegChunk],
    window_size: usize,
    window_shift: usize,
    receptive_field_shift: usize,
) -> Vec<i32> {
    let num_chunks = chunks.len();
    let num_frames = (window_size + (num_chunks - 1) * window_shift) / receptive_field_shift + 1;

    let mut count = vec![0.0f32; num_frames];
    let mut weight = vec![0.0f32; num_frames];

    for (i, chunk) in chunks.iter().enumerate() {
        let start =
            ((i as f32) * window_shift as f32 / receptive_field_shift as f32 + 0.5) as usize;
        for (f, frame) in chunk.labels.iter().enumerate() {
            let idx = start + f;
            if idx < num_frames {
                count[idx] += frame.iter().map(|&x| x as f32).sum::<f32>();
                weight[idx] += 1.0;
            }
        }
    }

    count
        .iter()
        .zip(weight.iter())
        .map(|(&c, &w)| ((c / (w + 1e-12)) + 0.5) as i32)
        .collect()
}

/// `ExcludeOverlap`: frames con 2+ hablantes locales simultáneos se excluyen
/// antes de extraer tramos de audio "limpios" para calcular embeddings (el
/// embedding de un tramo con dos voces mezcladas no representa a ninguna).
fn exclude_overlap(chunk: &SegChunk) -> Vec<Vec<u8>> {
    chunk
        .labels
        .iter()
        .map(|frame| {
            let sum: u32 = frame.iter().map(|&x| x as u32).sum();
            if sum < 2 {
                frame.clone()
            } else {
                vec![0u8; frame.len()]
            }
        })
        .collect()
}

struct ChunkSpeakerSegments {
    /// `pairs[i] = (chunk_index, local_speaker_index)`.
    pairs: Vec<(usize, usize)>,
    /// `sample_ranges[i]` = rangos `(start, end)` en samples de audio para
    /// `pairs[i]` (pueden ser varios tramos disjuntos dentro de la misma
    /// ventana).
    sample_ranges: Vec<Vec<(usize, usize)>>,
}

/// `GetChunkSpeakerSampleIndexes`: para cada ventana y cada slot de hablante
/// local con al menos [`MIN_ACTIVE_SEGMENTATION_FRAMES`] frames activos (tras
/// excluir solapamiento), encuentra los tramos contiguos de actividad y los
/// convierte a rangos de samples de audio.
fn get_chunk_speaker_sample_indexes(
    chunks: &[SegChunk],
    window_size: usize,
    window_shift: usize,
    num_speakers: usize,
) -> ChunkSpeakerSegments {
    let mut pairs = Vec::new();
    let mut sample_ranges = Vec::new();

    for (chunk_index, chunk) in chunks.iter().enumerate() {
        let cleaned = exclude_overlap(chunk);
        let num_frames = cleaned.len();
        if num_frames == 0 {
            continue;
        }
        let sample_offset = chunk_index * window_shift;

        for speaker_index in 0..num_speakers {
            let active: Vec<u8> = cleaned.iter().map(|f| f[speaker_index]).collect();
            let sum: u32 = active.iter().map(|&x| x as u32).sum();
            if sum < MIN_ACTIVE_SEGMENTATION_FRAMES {
                continue;
            }

            let mut this_speaker_samples = Vec::new();
            let mut is_active = false;
            let mut start_index = 0usize;

            for (k, &v) in active.iter().enumerate() {
                if v != 0 {
                    if !is_active {
                        is_active = true;
                        start_index = k;
                    }
                } else if is_active {
                    is_active = false;
                    let start_samples = (start_index as f32 / num_frames as f32
                        * window_size as f32) as usize
                        + sample_offset;
                    let end_samples = (k as f32 / num_frames as f32 * window_size as f32) as usize
                        + sample_offset;
                    this_speaker_samples.push((start_samples, end_samples));
                }
            }
            if is_active {
                let start_samples = (start_index as f32 / num_frames as f32 * window_size as f32)
                    as usize
                    + sample_offset;
                let end_samples = ((num_frames - 1) as f32 / num_frames as f32 * window_size as f32)
                    as usize
                    + sample_offset;
                this_speaker_samples.push((start_samples, end_samples));
            }

            pairs.push((chunk_index, speaker_index));
            sample_ranges.push(this_speaker_samples);
        }
    }

    ChunkSpeakerSegments {
        pairs,
        sample_ranges,
    }
}

/// `ComputeEmbeddings`: calcula un embedding por cada (ventana, hablante
/// local) con suficiente actividad. Ver simplificación 3 del doc comment del
/// módulo: en vez de abortar el proceso, un tramo problemático se descarta
/// con un log y el resto de la reunión sigue procesándose.
fn compute_embeddings(
    embedding: &EmbeddingModel,
    audio: &[f32],
    sample_rate: u32,
    segs: &ChunkSpeakerSegments,
) -> (Vec<Vec<f32>>, Vec<usize>) {
    let n = audio.len();
    let mut embeddings = Vec::new();
    let mut valid_indexes = Vec::new();

    for (k, ranges) in segs.sample_ranges.iter().enumerate() {
        let mut samples: Vec<f32> = Vec::new();
        for &(start, end) in ranges {
            let end = end.min(n);
            if end > start {
                samples.extend_from_slice(&audio[start..end]);
            }
        }
        if samples.is_empty() {
            continue;
        }

        match embedding.compute(&samples, sample_rate) {
            Ok(vec) if vec.iter().all(|v| v.is_finite()) => {
                embeddings.push(vec);
                valid_indexes.push(k);
            }
            Ok(_) => {
                log::warn!(
                    "diarización: embedding con NaN/Inf para el tramo {k}, se descarta (igual \
                     que sherpa-onnx filtra embeddings NaN antes de clustering)"
                );
            }
            Err(e) => {
                log::warn!("diarización: no se pudo calcular el embedding del tramo {k}: {e:#}");
            }
        }
    }

    (embeddings, valid_indexes)
}

/// `ReLabel`: reemplaza los slots de hablante local de cada ventana por el
/// cluster global correspondiente (según el resultado del clustering).
fn relabel(
    chunks: &[SegChunk],
    num_speakers: usize,
    num_clusters: usize,
    chunk_speaker_to_cluster: &HashMap<(usize, usize), usize>,
) -> Vec<Vec<Vec<u8>>> {
    chunks
        .iter()
        .enumerate()
        .map(|(chunk_index, chunk)| {
            let num_frames = chunk.labels.len();
            let mut new_label = vec![vec![0u8; num_clusters]; num_frames];
            for speaker_index in 0..num_speakers {
                if let Some(&new_speaker_index) =
                    chunk_speaker_to_cluster.get(&(chunk_index, speaker_index))
                {
                    for (k, frame) in chunk.labels.iter().enumerate() {
                        if frame[speaker_index] == 1 {
                            new_label[k][new_speaker_index] = 1;
                        }
                    }
                }
            }
            new_label
        })
        .collect()
}

/// `ComputeSpeakerCount`: agrega, sobre la línea de tiempo global, cuántas
/// ventanas marcaron a cada cluster como activo en cada frame; recorta la
/// cola de padding-con-ceros de la última ventana cuando corresponde.
fn compute_speaker_count(
    new_labels: &[Vec<Vec<u8>>],
    window_size: usize,
    window_shift: usize,
    receptive_field_shift: usize,
    num_clusters: usize,
    num_samples: usize,
) -> Vec<Vec<i32>> {
    let num_chunks = new_labels.len();
    let num_frames = (window_size + (num_chunks - 1) * window_shift) / receptive_field_shift + 1;

    let mut count = vec![vec![0i32; num_clusters]; num_frames];

    for (i, chunk_labels) in new_labels.iter().enumerate() {
        let start =
            ((i as f32) * window_shift as f32 / receptive_field_shift as f32 + 0.5) as usize;
        for (f, frame) in chunk_labels.iter().enumerate() {
            let idx = start + f;
            if idx < num_frames {
                for c in 0..num_clusters {
                    count[idx][c] += frame[c] as i32;
                }
            }
        }
    }

    // Misma semántica de resto con signo que C++ (truncado hacia cero,
    // igual que Rust `%` para enteros con signo) -- `ComputeSpeakerCount`
    // solo se llama desde el camino multi-chunk, donde `num_samples >
    // window_size` siempre, así que `diff` es positivo acá en la práctica;
    // se mantiene i64 con signo para calzar exactamente con el original en
    // vez de asumirlo.
    let has_last_chunk = {
        let diff = num_samples as i64 - window_size as i64;
        let ws = window_shift as i64;
        (diff % ws) > 0
    };

    if !has_last_chunk {
        return count;
    }

    let mut last_frame = num_samples / receptive_field_shift;
    if last_frame >= count.len() {
        last_frame = count.len().saturating_sub(1);
    }
    count.truncate(last_frame + 1);
    count
}

/// `FinalizeLabels`: para cada frame, activa los `k` clusters con mayor
/// cuenta, donde `k = speakers_per_frame[frame]` (la estimación de cuántos
/// hablantes locales estaban activos ahí).
fn finalize_labels(count: &[Vec<i32>], speakers_per_frame: &[i32]) -> Vec<Vec<u8>> {
    count
        .iter()
        .enumerate()
        .map(|(i, row)| {
            let mut ans = vec![0u8; row.len()];
            let k = speakers_per_frame.get(i).copied().unwrap_or(0).max(0) as usize;
            if k == 0 {
                return ans;
            }
            for idx in topk_indices(row, k) {
                ans[idx] = 1;
            }
            ans
        })
        .collect()
}

/// `TopkIndex` (math.h): índices de los `k` valores más grandes. Empates se
/// resuelven por orden de índice original (sort estable) — funcionalmente
/// equivalente a `std::partial_sort`, aunque no bit-idéntico en el
/// desempate, que tampoco está especificado por el C++ original.
fn topk_indices(values: &[i32], k: usize) -> Vec<usize> {
    let k = k.min(values.len());
    let mut idx: Vec<usize> = (0..values.len()).collect();
    idx.sort_by(|&a, &b| values[b].cmp(&values[a]));
    idx.truncate(k);
    idx
}

/// Segmento crudo (en segundos) de un hablante, antes de convertir a
/// `DiarizedSegment`.
struct RawSegment {
    start_s: f32,
    end_s: f32,
}

/// `ComputeResult` + `MergeSegments`: convierte la matriz de labels final en
/// segmentos por hablante (tiempo en segundos), fusiona huecos cortos y
/// descarta segmentos demasiado breves. También calcula la marca FR-004
/// `overlapped` (ver simplificación 1 del doc comment del módulo).
// `needless_range_loop`: el escaneo de frame_index arranca en 1 (no 0) y
// mantiene un pequeño estado (is_active/start_index) entre iteraciones --
// port estructural directo de `ComputeResult`, no se simplifica con
// iteradores sin oscurecer la máquina de estados.
#[allow(clippy::too_many_arguments, clippy::needless_range_loop)]
fn compute_result(
    final_labels: &[Vec<u8>],
    num_clusters: usize,
    receptive_field_shift: i32,
    receptive_field_size: i32,
    sample_rate: i32,
    min_duration_on: f32,
    min_duration_off: f32,
    speakers_per_frame: &[i32],
) -> Vec<DiarizedSegment> {
    let num_frames = final_labels.len();
    if num_frames == 0 {
        return vec![];
    }

    let scale = receptive_field_shift as f32 / sample_rate as f32;
    let scale_offset = 0.5 * receptive_field_size as f32 / sample_rate as f32;

    let mut result = Vec::new();

    for speaker_index in 0..num_clusters {
        let mut this_speaker: Vec<RawSegment> = Vec::new();

        let mut is_active = final_labels[0][speaker_index] > 0;
        let mut start_index = 0usize;

        for frame_index in 1..num_frames {
            if is_active {
                if final_labels[frame_index][speaker_index] == 0 {
                    this_speaker.push(RawSegment {
                        start_s: start_index as f32 * scale + scale_offset,
                        end_s: frame_index as f32 * scale + scale_offset,
                    });
                    is_active = false;
                }
            } else if final_labels[frame_index][speaker_index] == 1 {
                is_active = true;
                start_index = frame_index;
            }
        }
        if is_active {
            this_speaker.push(RawSegment {
                start_s: start_index as f32 * scale + scale_offset,
                end_s: (num_frames - 1) as f32 * scale + scale_offset,
            });
        }

        let merged = merge_segments(this_speaker, min_duration_off);

        for seg in merged {
            if seg.end_s - seg.start_s > min_duration_on {
                let overlapped = frame_range_has_overlap(
                    seg.start_s,
                    seg.end_s,
                    scale,
                    scale_offset,
                    speakers_per_frame,
                );
                result.push(DiarizedSegment {
                    start_ms: (seg.start_s.max(0.0) * 1000.0).round() as u64,
                    end_ms: (seg.end_s.max(0.0) * 1000.0).round() as u64,
                    speaker: speaker_index,
                    overlapped,
                });
            }
        }
    }

    result
}

/// `OfflineSpeakerDiarizationSegment::Merge`, aplicado en una sola pasada de
/// izquierda a derecha: como los segmentos de UN hablante ya salen
/// ordenados y sin superposición de `compute_result` (se generan escaneando
/// frames en orden), esto es equivalente al loop de reintentos del original
/// (que existe porque ahí se opera sobre una lista mutable general) sin
/// necesidad de reiniciar el escaneo en cada fusión.
fn merge_segments(mut segments: Vec<RawSegment>, gap: f32) -> Vec<RawSegment> {
    if segments.is_empty() {
        return segments;
    }
    let mut merged = Vec::with_capacity(segments.len());
    let mut current = segments.remove(0);
    for seg in segments {
        if seg.start_s - current.end_s <= gap {
            current.end_s = seg.end_s;
        } else {
            merged.push(current);
            current = seg;
        }
    }
    merged.push(current);
    merged
}

/// FR-004: un segmento se marca incierto si en algún frame dentro de su
/// rango de tiempo se estimaron 2+ hablantes locales activos
/// simultáneamente (ver doc comment del módulo, simplificación 1).
fn frame_range_has_overlap(
    start_s: f32,
    end_s: f32,
    scale: f32,
    scale_offset: f32,
    speakers_per_frame: &[i32],
) -> bool {
    if scale <= 0.0 || speakers_per_frame.is_empty() {
        return false;
    }
    let start_frame = (((start_s - scale_offset) / scale).round().max(0.0)) as usize;
    let end_frame_raw = (((end_s - scale_offset) / scale).round().max(0.0)) as usize;
    let end_frame = end_frame_raw.min(speakers_per_frame.len());
    let start_frame = start_frame.min(end_frame);
    speakers_per_frame[start_frame..end_frame]
        .iter()
        .any(|&c| c >= 2)
}

// ============================================================================
// API pública
// ============================================================================

/// Un tramo de audio atribuido a un hablante (o marcado incierto, FR-004).
///
/// `speaker` es un índice **local a esta llamada** de `diarize` (0-based) —
/// no es una identidad de voz persistente entre reuniones, consistente con
/// `meeting_speakers` en `data-model.md` (un hablante es local a una
/// reunión). Mapear a `MeetingSpeaker`/`MeetingSegment` (asignar labels
/// "Hablante 1", "Hablante 2"... y persistir) es responsabilidad del
/// llamador (T012+), fuera de alcance de este motor en aislamiento.
#[derive(Debug, Clone, PartialEq)]
pub struct DiarizedSegment {
    /// Offset de inicio en milisegundos desde el comienzo del audio pasado a
    /// `diarize`.
    pub start_ms: u64,
    /// Offset de fin en milisegundos.
    pub end_ms: u64,
    /// Índice de hablante local a esta llamada (0-based).
    pub speaker: usize,
    /// FR-004: `true` si se detectó habla superpuesta (2+ hablantes activos
    /// simultáneamente) en algún punto de este segmento — la atribución a
    /// `speaker` debe tratarse como incierta, no como un hecho.
    pub overlapped: bool,
}

struct LoadedModels {
    segmentation: SegmentationModel,
    embedding: EmbeddingModel,
}

/// Motor de diarización local/offline: identifica hablantes distintos en
/// audio de un solo micrófono sin conocer de antemano cuántos hay (FR-003) y
/// marca como incierta la habla superpuesta en vez de adivinar (FR-004). Ver
/// el doc comment de este módulo para el detalle completo del algoritmo y
/// sus fuentes.
///
/// [`DiarizationEngine::new`] sigue siendo barata e infalible a propósito:
/// `lib.rs` la construye incondicionalmente al arrancar la app (mismo
/// registro de T007), y cargar ~34 MB de sesiones ONNX en cada arranque —
/// incluso para quien nunca usa el notetaker de reuniones — sería un
/// regresión de performance fuera de alcance de esta tarea. La carga real de
/// modelos vive en [`DiarizationEngine::load`], que T012+ decidirá cuándo y
/// cómo invocar (carga perezosa en el primer `start_meeting`, mismo patrón
/// que `tts::TtsState` ya usa para Supertonic).
pub struct DiarizationEngine {
    /// `RwLock` (y no un simple `Option`) porque la instancia real vive
    /// detrás de un `Arc` compartido creado en `lib.rs` al arrancar la app,
    /// antes de que exista ninguna reunión: sin interior mutability, cargar
    /// los modelos más tarde obligaría a reemplazar ese `Arc` —
    /// imposible una vez repartido a `MeetingManager` y al estado de Tauri.
    /// Ver [`Self::ensure_loaded`].
    models: RwLock<Option<LoadedModels>>,
}

impl DiarizationEngine {
    /// Constructor barato: no carga ningún modelo. Ver el doc comment de la
    /// struct.
    pub fn new() -> Self {
        Self {
            models: RwLock::new(None),
        }
    }

    /// Carga ambos modelos ONNX (segmentación + embeddings) desde disco.
    /// Este es el constructor "real" que habilita [`Self::diarize`] —
    /// [`Self::new`] por sí sola no alcanza.
    pub fn load(segmentation_model_path: &Path, embedding_model_path: &Path) -> Result<Self> {
        let engine = Self::new();
        engine.ensure_loaded(segmentation_model_path, embedding_model_path)?;
        Ok(engine)
    }

    /// Carga perezosa e idempotente sobre una instancia ya compartida: si los
    /// modelos ya están cargados no hace nada, si no los carga y los deja
    /// disponibles para todos los `Arc` que apunten acá. Pensada para
    /// llamarse fuera del hilo de captura (cargar ~34 MB de sesiones ONNX
    /// tarda), en paralelo con el arranque de la grabación.
    ///
    /// La carga ocurre FUERA del lock de escritura a propósito: así un
    /// `diarize()`/`embed()` en curso (que sólo toma el lock de lectura) no
    /// queda bloqueado durante todo el tiempo de carga. La consecuencia
    /// aceptada es que dos llamadas concurrentes con los modelos aún sin
    /// cargar pueden cargar ambas y una descartar su copia; en la práctica
    /// sólo la llamada de `start_capture` lo invoca.
    pub fn ensure_loaded(
        &self,
        segmentation_model_path: &Path,
        embedding_model_path: &Path,
    ) -> Result<()> {
        if self.is_loaded() {
            return Ok(());
        }

        let segmentation = SegmentationModel::load(segmentation_model_path)?;
        let embedding = EmbeddingModel::load(embedding_model_path)?;

        let mut guard = self.models.write().unwrap();
        if guard.is_none() {
            *guard = Some(LoadedModels {
                segmentation,
                embedding,
            });
        }
        Ok(())
    }

    /// Si [`Self::ensure_loaded`]/[`Self::load`] ya dejaron los modelos
    /// disponibles. El llamador en vivo (T013) lo consulta por turno para
    /// decidir si puede atribuir hablante o si todavía tiene que dejar el
    /// segmento sin atribuir.
    pub fn is_loaded(&self) -> bool {
        self.models.read().unwrap().is_some()
    }

    /// Embedding de hablante (192 dims, CAM++) de un tramo de audio de UN
    /// solo hablante — el mismo vector que [`Self::diarize`] usa
    /// internamente para clusterizar, expuesto para la atribución
    /// incremental de T013: en una reunión en vivo cada turno se diariza por
    /// separado, así que los índices de hablante locales a cada llamada no
    /// alcanzan para saber si "el hablante 0 de este turno" es el mismo que
    /// "el hablante 0 del turno anterior". Comparar embeddings contra un
    /// registro acumulado sí lo resuelve.
    ///
    /// `samples` debe ser audio de un solo hablante ya recortado (concatenar
    /// varios rangos disjuntos del mismo hablante es válido y es lo que hace
    /// el pipeline interno); mezclar dos voces acá produce un embedding a
    /// medio camino entre ambas, que es exactamente la clase de atribución
    /// falsa que FR-004 pide evitar.
    pub fn embed(&self, samples: &[f32], sample_rate: u32) -> Result<Vec<f32>> {
        let guard = self.models.read().unwrap();
        let models = guard.as_ref().ok_or_else(|| {
            anyhow!(
                "DiarizationEngine: modelos no cargados -- llamá a DiarizationEngine::load(...) \
                 o ensure_loaded(...) antes de embed()"
            )
        })?;
        models.embedding.compute(samples, sample_rate)
    }

    /// Diariza `audio` (mono, f32, normalizado a `[-1, 1]`) a `sample_rate`
    /// Hz. Requiere haber sido construido con [`Self::load`] (no
    /// [`Self::new`]). `sample_rate` debe coincidir exactamente con el
    /// sample rate esperado por el modelo de segmentación (16 kHz para
    /// pyannote-segmentation-3.0) — igual que el CLI de referencia de
    /// sherpa-onnx, este método no resamplea internamente; resamplear antes
    /// de llamar es responsabilidad del llamador.
    pub fn diarize(&self, audio: &[f32], sample_rate: u32) -> Result<Vec<DiarizedSegment>> {
        let guard = self.models.read().unwrap();
        let models = guard.as_ref().ok_or_else(|| {
            anyhow!(
                "DiarizationEngine: modelos no cargados -- llamá a DiarizationEngine::load(...) \
                 antes de diarize()"
            )
        })?;

        if sample_rate != models.segmentation.meta.sample_rate as u32 {
            bail!(
                "diarize(): se esperaba audio a {} Hz (sample rate del modelo de segmentación), \
                 se recibió {} Hz -- resamplear antes de llamar",
                models.segmentation.meta.sample_rate,
                sample_rate
            );
        }

        run_pipeline(models, audio)
    }
}

impl Default for DiarizationEngine {
    fn default() -> Self {
        Self::new()
    }
}

/// `OfflineSpeakerDiarizationPyannoteImpl::Process`: orquesta el pipeline
/// completo. Ver el doc comment del módulo para el mapeo a cada función de
/// sherpa-onnx.
fn run_pipeline(models: &LoadedModels, audio: &[f32]) -> Result<Vec<DiarizedSegment>> {
    let seg = &models.segmentation;
    let emb = &models.embedding;

    let chunks = run_segmentation(seg, audio)?;
    if chunks.is_empty() {
        return Ok(vec![]);
    }

    let window_size = seg.meta.window_size as usize;
    let window_shift = seg.meta.window_shift as usize;
    let receptive_field_shift = seg.meta.receptive_field_shift;
    let receptive_field_size = seg.meta.receptive_field_size;
    let sample_rate = seg.meta.sample_rate;
    let num_speakers = seg.meta.num_speakers as usize;

    // `HandleOneChunkSpecialCase`: con una sola ventana, los slots de
    // hablante local SON los hablantes globales -- no hace falta
    // embeddings/clustering.
    if chunks.len() == 1 {
        let chunk = &chunks[0];
        let speakers_per_frame: Vec<i32> = chunk
            .labels
            .iter()
            .map(|f| f.iter().map(|&x| x as i32).sum())
            .collect();
        return Ok(compute_result(
            &chunk.labels,
            num_speakers,
            receptive_field_shift,
            receptive_field_size,
            sample_rate,
            MIN_DURATION_ON_S,
            MIN_DURATION_OFF_S,
            &speakers_per_frame,
        ));
    }

    let speakers_per_frame = compute_speakers_per_frame(
        &chunks,
        window_size,
        window_shift,
        receptive_field_shift as usize,
    );

    if speakers_per_frame.iter().all(|&x| x == 0) {
        log::info!("diarización: no se detectó actividad de hablante en el audio");
        return Ok(vec![]);
    }

    let segs = get_chunk_speaker_sample_indexes(&chunks, window_size, window_shift, num_speakers);

    let (embeddings, valid_indexes) = compute_embeddings(emb, audio, sample_rate as u32, &segs);

    if embeddings.is_empty() {
        log::warn!("diarización: no se pudo calcular ningún embedding de hablante válido");
        return Ok(vec![]);
    }

    let cluster_labels = cluster_embeddings(&embeddings, CLUSTER_THRESHOLD);
    if cluster_labels.is_empty() {
        return Ok(vec![]);
    }

    let max_cluster_index = *cluster_labels.iter().max().unwrap_or(&0);
    let num_clusters = max_cluster_index + 1;

    let mut chunk_speaker_to_cluster: HashMap<(usize, usize), usize> = HashMap::new();
    for (&list_index, &cluster) in valid_indexes.iter().zip(cluster_labels.iter()) {
        if let Some(&pair) = segs.pairs.get(list_index) {
            chunk_speaker_to_cluster.insert(pair, cluster);
        }
    }

    let new_labels = relabel(
        &chunks,
        num_speakers,
        num_clusters,
        &chunk_speaker_to_cluster,
    );

    let count = compute_speaker_count(
        &new_labels,
        window_size,
        window_shift,
        receptive_field_shift as usize,
        num_clusters,
        audio.len(),
    );

    let final_labels = finalize_labels(&count, &speakers_per_frame);

    Ok(compute_result(
        &final_labels,
        num_clusters,
        receptive_field_shift,
        receptive_field_size,
        sample_rate,
        MIN_DURATION_ON_S,
        MIN_DURATION_OFF_S,
        &speakers_per_frame,
    ))
}

/// Motor de diarización en streaming con Sortformer (Task 2 del plan
/// "reuniones en streaming"): ventana deslizante + caché de hablantes entre
/// trozos + salida incremental. Reemplaza la sonda descartable de la Task 1
/// (`sortformer_probe.rs`, borrada en el commit que agregó este módulo).
/// Ver su doc comment para el diseño completo.
pub mod sortformer;

/// Alineador de tokens con hablantes (Task 4 del plan "reuniones en
/// streaming"): pega cada `TimedToken` de la Task 3 al `SpeakerSpan` de la
/// Task 2 con mayor solape temporal y agrupa tokens consecutivos del mismo
/// hablante en intervenciones. Lógica pura, sin ONNX ni estado. Ver su doc
/// comment para el diseño completo.
pub mod align;

#[cfg(test)]
mod tests {
    use super::*;

    // ------------------------------------------------------------------
    // Unit tests puros (sin ONNX) -- powerset mapping, top-k, merge,
    // clustering.
    // ------------------------------------------------------------------

    #[test]
    fn powerset_mapping_matches_pyannote_3_0_combinatorics() {
        // num_speakers=3, powerset_max_classes=2, num_classes=7 -- los
        // valores REALES leídos de la metadata de
        // resources/models/pyannote_segmentation_3_0.onnx durante la
        // investigación de esta tarea (ver doc comment del módulo).
        let mapping = build_powerset_mapping(7, 3, 2);
        assert_eq!(
            mapping,
            vec![
                vec![0, 0, 0], // silencio
                vec![1, 0, 0], // solo hablante 0
                vec![0, 1, 0], // solo hablante 1
                vec![0, 0, 1], // solo hablante 2
                vec![1, 1, 0], // hablantes 0+1 solapados
                vec![1, 0, 1], // hablantes 0+2 solapados
                vec![0, 1, 1], // hablantes 1+2 solapados
            ]
        );
    }

    #[test]
    fn to_multi_label_picks_argmax_class_per_frame() {
        let mapping = build_powerset_mapping(7, 3, 2);
        // 2 frames: frame 0 favorece la clase 1 (hablante 0 solo), frame 1
        // favorece la clase 4 (hablantes 0+1 solapados).
        #[rustfmt::skip]
        let data = [
            0.1, 0.9, 0.05, 0.05, 0.0, 0.0, 0.0,
            0.0, 0.0, 0.0, 0.0, 0.8, 0.1, 0.1,
        ];
        let labels = to_multi_label(2, 7, &data, &mapping);
        assert_eq!(labels[0], vec![1, 0, 0]);
        assert_eq!(labels[1], vec![1, 1, 0]);
    }

    #[test]
    fn topk_indices_picks_highest_counts() {
        let values = [3, 1, 4, 1, 5, 9, 2];
        assert_eq!(topk_indices(&values, 3), vec![5, 4, 2]);
        assert_eq!(topk_indices(&values, 0), Vec::<usize>::new());
        assert_eq!(topk_indices(&values, 100), vec![5, 4, 2, 0, 6, 1, 3]);
    }

    #[test]
    fn merge_segments_joins_close_gaps_and_keeps_far_ones() {
        let segments = vec![
            RawSegment {
                start_s: 0.0,
                end_s: 1.0,
            },
            RawSegment {
                start_s: 1.3,
                end_s: 2.0,
            }, // hueco 0.3s < min_duration_off(0.5) -> se fusiona
            RawSegment {
                start_s: 5.0,
                end_s: 6.0,
            }, // hueco 3s -> no se fusiona
        ];
        let merged = merge_segments(segments, MIN_DURATION_OFF_S);
        assert_eq!(merged.len(), 2);
        assert!((merged[0].start_s - 0.0).abs() < 1e-6);
        assert!((merged[0].end_s - 2.0).abs() < 1e-6);
        assert!((merged[1].start_s - 5.0).abs() < 1e-6);
        assert!((merged[1].end_s - 6.0).abs() < 1e-6);
    }

    #[test]
    fn cluster_embeddings_separates_distinct_speakers() {
        // 2 embeddings casi idénticos ("hablante A", dos tramos) + 2
        // embeddings casi idénticos entre sí pero MUY distintos de A
        // ("hablante B") -- deben terminar en 2 clusters, con A y B cada uno
        // agrupado consigo mismo.
        let speaker_a_1 = vec![1.0, 0.0, 0.0, 0.0];
        let speaker_a_2 = vec![0.98, 0.02, 0.0, 0.0];
        let speaker_b_1 = vec![0.0, 0.0, 1.0, 0.0];
        let speaker_b_2 = vec![0.0, 0.0, 0.98, 0.02];

        let embeddings = vec![speaker_a_1, speaker_b_1, speaker_a_2, speaker_b_2];
        let labels = cluster_embeddings(&embeddings, CLUSTER_THRESHOLD);

        assert_eq!(labels.len(), 4);
        assert_eq!(labels[0], labels[2], "los dos tramos de A deben agruparse");
        assert_eq!(labels[1], labels[3], "los dos tramos de B deben agruparse");
        assert_ne!(
            labels[0], labels[1],
            "A y B deben quedar en clusters distintos"
        );
    }

    #[test]
    fn cluster_embeddings_groups_everything_with_high_threshold() {
        // Con un threshold altísimo (imposible de superar en distancia
        // coseno, que está acotada en [0, 2]), todo cae en un solo cluster
        // -- confirma que el corte es puramente por umbral, sin un `k` fijo
        // implícito en otro lado (FR-003).
        let embeddings = vec![vec![1.0, 0.0], vec![0.0, 1.0], vec![-1.0, 0.0]];
        let labels = cluster_embeddings(&embeddings, 10.0);
        assert!(labels.iter().all(|&l| l == labels[0]));
    }

    #[test]
    fn cluster_embeddings_handles_zero_and_one_row() {
        assert_eq!(
            cluster_embeddings(&[], CLUSTER_THRESHOLD),
            Vec::<usize>::new()
        );
        assert_eq!(
            cluster_embeddings(&[vec![1.0, 2.0, 3.0]], CLUSTER_THRESHOLD),
            vec![0]
        );
    }

    #[test]
    fn subtract_global_mean_zeroes_out_a_constant_signal() {
        let mut features = vec![vec![5.0, 5.0], vec![5.0, 5.0], vec![5.0, 5.0]];
        subtract_global_mean(&mut features, 2);
        for row in &features {
            for &v in row {
                assert!((v - 0.0).abs() < 1e-6);
            }
        }
    }

    #[test]
    fn diarize_without_load_returns_a_clear_error() {
        let engine = DiarizationEngine::new();
        let err = engine.diarize(&[0.0; 1000], 16000).unwrap_err();
        assert!(err.to_string().contains("no cargados"));
    }

    // ------------------------------------------------------------------
    // Integration tests con el modelo de segmentación REAL (committeado en
    // resources/models/, no requiere red). El modelo de embeddings no está
    // committeado (T008) así que estos tests no lo ejercitan -- ver el test
    // `#[ignore]` más abajo para el pipeline completo.
    // ------------------------------------------------------------------

    fn segmentation_model_path() -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("resources/models/pyannote_segmentation_3_0.onnx")
    }

    #[test]
    fn segmentation_model_loads_and_reads_expected_metadata() {
        let model = SegmentationModel::load(&segmentation_model_path())
            .expect("el modelo de segmentación committeado debe cargar");

        // Valores reales verificados con onnx.load() sobre el archivo
        // committeado durante la investigación de esta tarea (ver doc
        // comment del módulo).
        assert_eq!(model.meta.sample_rate, 16000);
        assert_eq!(model.meta.window_size, 160000);
        assert_eq!(model.meta.num_speakers, 3);
        assert_eq!(model.meta.powerset_max_classes, 2);
        assert_eq!(model.meta.num_classes, 7);
        assert_eq!(model.meta.receptive_field_size, 991);
        assert_eq!(model.meta.receptive_field_shift, 270);
        // window_shift_ratio(0.1) * window_size(160000) = 16000
        assert_eq!(model.meta.window_shift, 16000);
    }

    #[test]
    fn run_segmentation_on_silence_produces_frames_without_crashing() {
        let model = SegmentationModel::load(&segmentation_model_path())
            .expect("el modelo de segmentación committeado debe cargar");

        // ~12s de silencio digital a 16kHz -- más largo que una ventana
        // (10s), así que ejercita el camino multi-chunk (varias llamadas a
        // Forward, agregación entre ventanas) sin necesitar el modelo de
        // embeddings.
        let audio = vec![0.0f32; 16000 * 12];
        let chunks = run_segmentation(&model, &audio).expect("segmentación no debe fallar");
        assert!(
            chunks.len() > 1,
            "audio de 12s debe producir más de 1 ventana"
        );
        for chunk in &chunks {
            assert!(!chunk.labels.is_empty());
            for frame in &chunk.labels {
                assert_eq!(frame.len(), 3);
            }
        }

        let speakers_per_frame = compute_speakers_per_frame(
            &chunks,
            model.meta.window_size as usize,
            model.meta.window_shift as usize,
            model.meta.receptive_field_shift as usize,
        );
        // Silencio digital puro no debería activar ningún slot de hablante
        // en un modelo entrenado con voz real.
        assert!(
            speakers_per_frame.iter().all(|&x| x == 0),
            "silencio digital no debería producir actividad de hablante"
        );
    }

    // ------------------------------------------------------------------
    // Test end-to-end con AMBOS modelos reales + un fixture de audio real
    // con 4 hablantes, publicado por el propio sherpa-onnx para probar este
    // pipeline (`0-four-speakers-zh.wav`,
    // release `speaker-segmentation-models` de k2-fsa/sherpa-onnx).
    //
    // Requiere red (descarga el modelo de embeddings, ~27MB, y el wav de
    // prueba, ~1.8MB) -- por eso #[ignore], igual que
    // tts/streaming.rs ya hace para su test que requiere pesos de Supertonic
    // en disco. No corre en CI ni en `cargo test` normal; se corrió
    // manualmente durante esta tarea para verificar el pipeline completo
    // contra audio real antes de dar la tarea por terminada (ver el reporte
    // de la tarea para el resultado de esa corrida manual).
    // ------------------------------------------------------------------
    #[tokio::test]
    #[ignore = "requiere red: descarga el modelo de embeddings y un wav de prueba reales"]
    async fn diarize_end_to_end_on_real_four_speaker_audio() {
        let tmp = tempfile::tempdir().expect("tempdir");

        let embedding_path =
            crate::managers::diarization_models::ensure_embedding_model_downloaded(tmp.path())
                .await
                .expect("el modelo de embeddings debe descargar y verificar su SHA-256");

        let wav_path = tmp.path().join("0-four-speakers-zh.wav");
        let wav_bytes = reqwest::get(
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/0-four-speakers-zh.wav",
        )
        .await
        .expect("descargando el wav de prueba")
        .bytes()
        .await
        .expect("leyendo el wav de prueba");
        std::fs::write(&wav_path, &wav_bytes).expect("escribiendo el wav de prueba");

        let mut reader = hound::WavReader::open(&wav_path).expect("abriendo el wav de prueba");
        let spec = reader.spec();
        assert_eq!(spec.sample_rate, 16000, "el fixture ya viene a 16kHz mono");
        let samples: Vec<f32> = reader
            .samples::<i16>()
            .map(|s| s.expect("sample válido") as f32 / i16::MAX as f32)
            .collect();

        let engine = DiarizationEngine::load(&segmentation_model_path(), &embedding_path)
            .expect("ambos modelos deben cargar");

        let segments = engine
            .diarize(&samples, spec.sample_rate)
            .expect("diarize() no debe fallar sobre audio real");

        assert!(!segments.is_empty(), "debe producir al menos un segmento");

        let distinct_speakers: std::collections::HashSet<usize> =
            segments.iter().map(|s| s.speaker).collect();
        assert!(
            distinct_speakers.len() >= 2,
            "un audio con 4 hablantes reales debe distinguir al menos 2 (no probamos exactitud \
             de conteo, solo que el clustering no colapsa todo a 1 -- eso sería indistinguible \
             de no diarizar nada)"
        );

        for seg in &segments {
            assert!(seg.end_ms > seg.start_ms);
        }
    }
}
