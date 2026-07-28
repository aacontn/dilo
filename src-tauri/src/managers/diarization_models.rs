//! Adquisición de los modelos ONNX de diarización (T008).
//!
//! Diarización necesita dos modelos ONNX independientes, publicados por
//! sherpa-onnx (k2-fsa) como archivos sueltos en GitHub Releases — ver
//! `.superpowers/sdd/task-T008-report.md` para el detalle completo de la
//! verificación de licencia y la decisión de ruta (committear vs. descarga
//! en runtime) de cada uno:
//!
//! 1. **Segmentación** (estilo pyannote): ~6 MB, del mismo orden de
//!    magnitud que `silero_vad_v4.onnx` (~1.8 MB) → se committea
//!    directo en `resources/models/pyannote_segmentation_3_0.onnx`, mismo
//!    patrón que Silero VAD. No necesita ninguna función de este módulo:
//!    se referencia por ruta relativa fija, igual que
//!    `managers/audio.rs` hace con Silero.
//! 2. **Embeddings de hablante** (~27 MB): supera el umbral de "committear
//!    directo" (decenas de MB), así que sigue el patrón de descarga en
//!    runtime de `managers/model.rs` — pero como **funciones libres,
//!    desacopladas de `AppHandle`/`ModelManager`/`ModelInfo`**, siguiendo
//!    el precedente ya establecido en `tts/supertonic.rs` para modelos
//!    auxiliares que no son "motores de transcripción seleccionables por
//!    el usuario" (este módulo documenta esa misma razón en su propio
//!    comentario). Registrar este modelo en `ModelInfo`/`EngineType`
//!    haría aparecer un modelo de diarización en el selector de modelos
//!    STT de la UI, que es semánticamente incorrecto — es un asset
//!    auxiliar siempre necesario para T009, no una alternativa de
//!    transcripción que el usuario elige.
//!
//! Este módulo **solo resuelve rutas y descarga bytes** — no carga los
//! modelos con `ort`, no hace inferencia, no implementa
//! `DiarizationEngine` (eso es T009, ver `managers/diarization.rs`).
//!
//! Nada de este módulo tiene todavía un llamador: `DiarizationEngine` sigue
//! siendo el esqueleto que dejó T005, sin lógica de carga de modelos (eso
//! es T009). `#[allow(dead_code)]` a nivel de módulo se queda hasta
//! entonces — mismo patrón que `MeetingManager::get_connection` en
//! `managers/meeting.rs`. Confirmado con `cargo clippy` que sacarlo
//! reactiva el warning de `dead_code` en cada item público de este archivo.
#![allow(dead_code)]

use anyhow::{bail, Context, Result};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

/// Nombre de archivo del modelo de embeddings de hablante, tal como se
/// guarda en disco. Mismo nombre que publica sherpa-onnx (no se renombra)
/// para que el hash de origen (`EMBEDDING_MODEL_SHA256`) sea trivialmente
/// verificable contra `checksum.txt` de la release.
pub const EMBEDDING_MODEL_FILENAME: &str =
    "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx";

/// URL de origen: release `speaker-recongition-models` (sic, typo real de
/// k2-fsa/sherpa-onnx) del repo `k2-fsa/sherpa-onnx`.
/// https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models
pub const EMBEDDING_MODEL_URL: &str = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx";

/// SHA-256 esperado, verificado contra dos fuentes independientes: (a) el
/// `checksum.txt` que publica la propia release de sherpa-onnx, y (b) el
/// hash calculado localmente sobre el archivo bajado en esta tarea (T008).
/// Ambos coincidieron.
pub const EMBEDDING_MODEL_SHA256: &str =
    "aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2";

/// Tamaño esperado en bytes, para validar la descarga sin tener que hashear
/// un archivo corrupto completo antes de fallar rápido.
pub const EMBEDDING_MODEL_SIZE_BYTES: u64 = 28_281_164;

/// Licencia verificada del checkpoint (no solo del repo que lo sirve): CAM++
/// de 3D-Speaker (Alibaba DAMO Academy / ModelScope), Apache-2.0. Fuentes:
///
/// - README del repo origen, leído directo vía `gh api
///   repos/modelscope/3D-Speaker/contents/README.md`: "3D-Speaker is
///   released under the Apache License 2.0."
/// - Licencia del repo detectada por GitHub: `gh api
///   repos/modelscope/3D-Speaker/license` → `apache-2.0`.
/// - Dos mirrors independientes de este mismo checkpoint ONNX en
///   HuggingFace confirman "License: Apache-2.0 (inherited from
///   3D-Speaker / ModelScope)".
///
/// Ver el detalle completo en `.superpowers/sdd/task-T008-report.md`.
pub const EMBEDDING_MODEL_LICENSE: &str =
    "Apache-2.0 (3D-Speaker / ModelScope CAM++, ver task-T008-report.md)";

/// Ruta absoluta donde debería vivir el modelo de embeddings dentro del
/// directorio de modelos de la app (mismo `models_dir` que usa
/// `ModelManager`).
pub fn embedding_model_path(models_dir: &Path) -> PathBuf {
    models_dir.join(EMBEDDING_MODEL_FILENAME)
}

/// Si el modelo de embeddings ya está descargado en disco. No verifica el
/// hash en cada llamada (sería caro para un archivo de ~27 MB en cada
/// chequeo de arranque) — la verificación fuerte ocurre una sola vez, en
/// [`ensure_embedding_model_downloaded`], inmediatamente después de bajarlo.
pub fn is_embedding_model_downloaded(models_dir: &Path) -> bool {
    embedding_model_path(models_dir).is_file()
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

/// Descarga el modelo de embeddings de hablante si falta, verificando su
/// SHA-256 contra [`EMBEDDING_MODEL_SHA256`] antes de dejarlo en su
/// ubicación final. Descarga simple (sin resume ni eventos de progreso a la
/// UI, a diferencia de `ModelManager::download_model`) — este modelo es un
/// asset auxiliar interno para T009, no algo que el usuario elija o
/// cancele desde el selector de modelos.
///
/// No ejercitado por los tests automáticos (depende de red, baja ~27 MB) —
/// pensado para probarse manualmente o desde un test de integración de
/// T009 una vez que `DiarizationEngine` lo consuma.
pub async fn ensure_embedding_model_downloaded(models_dir: &Path) -> Result<PathBuf> {
    let dest = embedding_model_path(models_dir);
    if dest.is_file() {
        return Ok(dest);
    }

    std::fs::create_dir_all(models_dir)
        .with_context(|| format!("creando {}", models_dir.display()))?;

    let response = reqwest::get(EMBEDDING_MODEL_URL)
        .await
        .with_context(|| format!("descargando {EMBEDDING_MODEL_URL}"))?;
    if !response.status().is_success() {
        bail!(
            "descarga del modelo de embeddings falló: HTTP {}",
            response.status()
        );
    }
    let bytes = response
        .bytes()
        .await
        .context("leyendo el cuerpo de la respuesta del modelo de embeddings")?;

    if bytes.len() as u64 != EMBEDDING_MODEL_SIZE_BYTES {
        bail!(
            "tamaño del modelo de embeddings no coincide: esperado {} bytes, obtenido {} \
             (descarga incompleta o el archivo upstream cambió)",
            EMBEDDING_MODEL_SIZE_BYTES,
            bytes.len()
        );
    }

    let actual_sha256 = sha256_hex(&bytes);
    if actual_sha256 != EMBEDDING_MODEL_SHA256 {
        bail!(
            "SHA-256 del modelo de embeddings no coincide: esperado {}, obtenido {} \
             (descarga corrupta o el archivo upstream cambió — no continuar sin \
             re-verificar la licencia)",
            EMBEDDING_MODEL_SHA256,
            actual_sha256
        );
    }

    let partial = models_dir.join(format!("{EMBEDDING_MODEL_FILENAME}.partial"));
    std::fs::write(&partial, &bytes)
        .with_context(|| format!("escribiendo {}", partial.display()))?;
    std::fs::rename(&partial, &dest).with_context(|| format!("moviendo a {}", dest.display()))?;

    Ok(dest)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedding_model_path_joins_filename() {
        let dir = Path::new("/tmp/dilo-app-data/models");
        assert_eq!(
            embedding_model_path(dir),
            dir.join("3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx")
        );
    }

    #[test]
    fn is_embedding_model_downloaded_false_when_missing() {
        let dir = Path::new("/tmp/dilo-app-data-does-not-exist/models");
        assert!(!is_embedding_model_downloaded(dir));
    }

    #[test]
    fn sha256_hex_matches_known_vector() {
        // "abc" -> well-known SHA-256 test vector (NIST FIPS 180-4 example).
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
