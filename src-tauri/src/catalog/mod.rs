//! The bundled, offline model catalog.
//!
//! `catalog.json` is generated at build time by `scripts/gen_catalog.py` from the
//! `handy-computer` Hugging Face org (card `transcribe_cpp` capabilities +
//! benchmarks, a GGUF header probe for name/params, and local curation for the
//! recommended set). It is compiled into the binary so Dilo ships a complete
//! model list with zero network access.
//!
//! Each entry is normalised into a [`ModelDescriptor`] — the same source-agnostic
//! shape every other producer (HF discovery, on-disk scans, the legacy table)
//! yields — so the catalog is "just another producer". Its explicit `capabilities`
//! map becomes a [`CapabilityProbe`] with confident `Some(..)` values; the runtime
//! `GgufHeaderProber` is the same shape with `None` where a header omits a key,
//! which is why the two are interchangeable (the catalog is a baked probe).

use std::collections::HashMap;

use once_cell::sync::Lazy;
use serde::Deserialize;

use crate::managers::model::{
    default_quant_file, EngineType, ModelDescriptor, ModelSource, QuantFile,
};
use crate::managers::model_capabilities::{CapabilityProbe, Compatibility};

#[derive(Deserialize)]
struct CatalogRoot {
    /// Base URLs tried in order when the Hugging Face download fails. The full
    /// file URL is `{mirror}/{repo_id}/{revision}/{filename}` — the same three
    /// values that form the HF resolve URL, so a mirror is a plain static host.
    /// Ported from upstream's fallback mechanism (see [`mirror_fallbacks`]).
    ///
    /// Provisional: `blob.handy.computer` es el CDN del upstream, no nuestro. Se
    /// usa mientras Dilo no tiene tracción; cuando la tenga, los modelos se
    /// mueven a hosting propio (R2 o GitHub Releases) y esta lista cambia.
    /// Decisión de Alfonso, 2026-08-02.
    #[serde(default)]
    mirrors: Vec<String>,
    models: Vec<CatalogModel>,
}

/// One model as written in `catalog.json`. Only the fields the descriptor needs
/// are declared; serde ignores the rest (slug, family, license, …).
#[derive(Deserialize)]
struct CatalogModel {
    /// HF repo id, e.g. `handy-computer/whisper-small-gguf`.
    id: String,
    /// Commit sha the catalog's sizes/hashes were generated from. Used to
    /// build both the HF acquisition revision and the mirror URL, so
    /// downloaded bytes provably match the hashes regardless of source.
    /// `None` for entries that predate pinning (our original 7, which use
    /// `download_url` instead and never reach the mirror path — see
    /// [`mirror_fallbacks`]).
    #[serde(default)]
    revision: Option<String>,
    name: String,
    description: String,
    architecture: Option<String>,
    languages: Vec<String>,
    capabilities: CatalogCaps,
    speed_score: Option<f32>,
    accuracy_score: Option<f32>,
    files: Vec<QuantFile>,
    default_quant: Option<String>,
    recommended_rank: Option<u32>,
    /// Part of the small curated onboarding set (badged "Recommended"). Distinct
    /// from `recommended_rank`, which only orders the full list.
    #[serde(default)]
    recommended: bool,
    /// Optional direct-download URL. When present the model is fetched over plain
    /// HTTP from here instead of the HF Hub — used to mirror models whose HF repo
    /// migrated to Xet storage (unsupported by the bundled hf-hub). The `id` stays
    /// the HF-style `repo/file` so identity and stored selections are unchanged.
    #[serde(default)]
    download_url: Option<String>,
    /// Expected SHA-256 of the direct-download file (integrity check). Optional.
    #[serde(default)]
    sha256: Option<String>,
}

#[derive(Deserialize)]
struct CatalogCaps {
    streaming: bool,
    translate: bool,
    lang_detect: bool,
    // `timestamps` (a string enum) is present in the catalog but has no
    // `CapabilityProbe` field yet — wire it through when the probe gains one.
}

impl From<&CatalogModel> for ModelDescriptor {
    fn from(m: &CatalogModel) -> Self {
        // The default download file. Its name is folded into the id so a catalog
        // entry collides (dedups) with the very same file later discovered in
        // the HF cache — both compute `"{repo_id}/{filename}"`.
        let default_filename = default_quant_file(&m.files, m.default_quant.as_deref())
            .map(|f| f.filename.clone())
            .unwrap_or_default();

        ModelDescriptor {
            id: format!("{}/{}", m.id, default_filename),
            // Direct URL wins when set (Xet mirror); otherwise fetch from HF Hub.
            source: match &m.download_url {
                Some(url) => ModelSource::Url {
                    url: url.clone(),
                    sha256: m.sha256.clone(),
                },
                None => ModelSource::HuggingFace {
                    repo_id: m.id.clone(),
                    // Acquire at the pin when the catalog has one (immutable,
                    // matches the hashes used for mirror verification); `main`
                    // remains the lookup fallback for pre-pinning entries.
                    revision: m.revision.clone().unwrap_or_else(|| "main".to_string()),
                },
            },
            name: m.name.clone(),
            description: m.description.clone(),
            engine_type: EngineType::TranscribeCpp,
            caps: CapabilityProbe {
                verdict: Compatibility::Compatible, // curated org models we ship support for
                display_name: None,
                architecture: m.architecture.clone(),
                variant: None,
                languages: Some(m.languages.clone()),
                supports_streaming: Some(m.capabilities.streaming),
                supports_translation: Some(m.capabilities.translate),
                supports_language_detect: Some(m.capabilities.lang_detect),
            },
            files: m.files.clone(),
            default_quant: m.default_quant.clone(),
            // catalog scores are 0–100; ModelInfo / the UI bars use 0.0–1.0.
            speed_score: m.speed_score.unwrap_or(0.0) / 100.0,
            accuracy_score: m.accuracy_score.unwrap_or(0.0) / 100.0,
            recommended_rank: m.recommended_rank,
            recommended: m.recommended,
        }
    }
}

/// The raw parsed catalog. Kept alive (not consumed) so mirror metadata that
/// deliberately stays out of [`ModelDescriptor`] (`revision`, per-file
/// `sha256`, `mirrors`) can be looked up separately by [`mirror_fallbacks`].
static ROOT: Lazy<CatalogRoot> = Lazy::new(|| {
    serde_json::from_str(include_str!("catalog.json"))
        .expect("bundled catalog.json is valid JSON matching the catalog schema")
});

/// The bundled catalog, parsed once and normalised into descriptors.
pub static CATALOG: Lazy<Vec<ModelDescriptor>> =
    Lazy::new(|| ROOT.models.iter().map(ModelDescriptor::from).collect());

/// A mirror copy of a catalog model's default file, with the expected content
/// hash for end-to-end verification. Mirrors are untrusted bit-pipes: the
/// sha256 here (from the catalog compiled into the binary) is the trust
/// anchor, which is why it is mandatory — a file without one is never offered
/// from a mirror at all.
pub struct MirrorFile {
    pub url: String,
    pub sha256: String,
    /// Catalog size — drives progress totals and resume sanity checks.
    pub size_bytes: u64,
}

/// Ordered mirror URLs for a catalog model's file — `model_id` is the registry
/// id (`"{repo_id}/{filename}"`). Empty when the model isn't from the catalog,
/// has no pinned `revision`, its file has no `sha256`, or no mirrors are
/// configured. In particular this is empty for our original 7 `download_url`
/// entries (no `revision`, no per-file `sha256`): they keep their current
/// direct-URL behaviour untouched and never fall through to a mirror.
pub fn mirror_fallbacks(model_id: &str) -> Vec<MirrorFile> {
    let Some((m, file)) = ROOT.models.iter().find_map(|m| {
        m.files
            .iter()
            .find(|f| format!("{}/{}", m.id, f.filename) == model_id)
            .map(|f| (m, f))
    }) else {
        return Vec::new();
    };
    let Some(revision) = m.revision.as_deref() else {
        return Vec::new();
    };
    // No hash means no verification means no mirror: never fetch from an
    // untrusted host without the catalog trust anchor.
    let Some(sha256) = file.sha256.as_deref() else {
        return Vec::new();
    };
    ROOT.mirrors
        .iter()
        .map(|base| MirrorFile {
            url: format!(
                "{}/{}/{}/{}",
                base.trim_end_matches('/'),
                m.id,
                revision,
                file.filename
            ),
            sha256: sha256.to_string(),
            size_bytes: file.size_bytes,
        })
        .collect()
}

/// Editorial recommended rank keyed by descriptor id (the same id the model
/// registry uses). Built once from the catalog.
static RANK_BY_ID: Lazy<HashMap<String, u32>> = Lazy::new(|| {
    CATALOG
        .iter()
        .filter_map(|d| d.recommended_rank.map(|r| (d.id.clone(), r)))
        .collect()
});

/// Recommended rank for a model id (lower = higher priority). Returns
/// `u32::MAX` for unranked/unknown ids so they sort last in an ascending sort.
pub fn rank_of(model_id: &str) -> u32 {
    RANK_BY_ID.get(model_id).copied().unwrap_or(u32::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::managers::model_capabilities::KNOWN_ARCHES;
    use std::collections::BTreeSet;

    #[test]
    fn catalog_parses_and_is_nonempty() {
        assert!(!CATALOG.is_empty(), "bundled catalog should contain models");
    }

    #[test]
    fn ids_are_unique() {
        let mut ids: Vec<&str> = CATALOG.iter().map(|d| d.id.as_str()).collect();
        ids.sort_unstable();
        let before = ids.len();
        ids.dedup();
        assert_eq!(before, ids.len(), "catalog descriptor ids must be unique");
    }

    #[test]
    fn scores_are_normalised_0_to_1() {
        for d in CATALOG.iter() {
            assert!((0.0..=1.0).contains(&d.speed_score), "{} speed", d.id);
            assert!((0.0..=1.0).contains(&d.accuracy_score), "{} acc", d.id);
        }
    }

    #[test]
    fn original_seven_models_are_still_present() {
        // Net against a future refactor silently dropping or renaming one of
        // the 7 hand-curated, direct-URL-hosted models. Ids include the
        // default filename (see `ModelDescriptor::id`), so this also pins
        // their `default_quant`.
        const ORIGINAL_SEVEN: &[&str] = &[
            "handy-computer/parakeet-tdt-0.6b-v3-gguf/parakeet-tdt-0.6b-v3-Q8_0.gguf",
            "handy-computer/cohere-transcribe-03-2026-gguf/cohere-transcribe-03-2026-Q5_K_M.gguf",
            "handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf/nemotron-3.5-asr-streaming-0.6b-Q8_0.gguf",
            "handy-computer/whisper-large-v3-turbo-gguf/whisper-large-v3-turbo-Q8_0.gguf",
            "handy-computer/whisper-medium-gguf/whisper-medium-Q8_0.gguf",
            "handy-computer/Qwen3-ASR-0.6B-gguf/Qwen3-ASR-0.6B-Q8_0.gguf",
            "handy-computer/whisper-small-gguf/whisper-small-Q8_0.gguf",
        ];
        let ids: BTreeSet<&str> = CATALOG.iter().map(|d| d.id.as_str()).collect();
        for id in ORIGINAL_SEVEN {
            assert!(
                ids.contains(id),
                "original model missing from catalog: {}",
                id
            );
        }
        // And still on their direct download URL, not migrated to the mirror.
        for id in ORIGINAL_SEVEN {
            let d = CATALOG.iter().find(|d| d.id == *id).unwrap();
            assert!(
                matches!(d.source, ModelSource::Url { .. }),
                "{} should still be Url-sourced (download_url), not HuggingFace",
                id
            );
        }
    }

    #[test]
    fn new_catalog_models_have_mirror_fallbacks_with_hashes() {
        // The 6 models added alongside the mirror mechanism must actually be
        // able to use it: pinned revision + per-file sha256 + at least one
        // configured mirror.
        const NEW_SIX: &[&str] = &[
            "handy-computer/canary-1b-flash-gguf",
            "handy-computer/canary-1b-v2-gguf",
            "handy-computer/Qwen3-ASR-1.7B-gguf",
            "handy-computer/granite-speech-4.1-2b-nar-gguf",
            "handy-computer/Voxtral-Mini-4B-Realtime-2602-gguf",
            "handy-computer/Voxtral-Mini-3B-2507-gguf",
        ];
        for repo_id in NEW_SIX {
            let d = CATALOG
                .iter()
                .find(|d| d.id.starts_with(&format!("{repo_id}/")))
                .unwrap_or_else(|| panic!("{} missing from catalog", repo_id));
            let mirrors = mirror_fallbacks(&d.id);
            assert!(!mirrors.is_empty(), "{}: no mirror fallbacks", d.id);
            for m in &mirrors {
                assert_eq!(m.sha256.len(), 64, "{}: mirror entry lacks a sha256", d.id);
                assert!(m.size_bytes > 0, "{}: mirror entry lacks a size", d.id);
                assert!(m.url.starts_with("https://"), "{}: bad url {}", d.id, m.url);
            }
        }
    }

    #[test]
    fn catalog_architectures_are_known_to_capability_probe() {
        let missing: BTreeSet<&str> = CATALOG
            .iter()
            .filter_map(|d| d.caps.architecture.as_deref())
            .filter(|arch| !KNOWN_ARCHES.contains(arch))
            .collect();

        assert!(
            missing.is_empty(),
            "catalog architecture(s) missing from KNOWN_ARCHES: {:?}",
            missing
        );
    }
}
