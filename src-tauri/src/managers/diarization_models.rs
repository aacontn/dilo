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
use futures_util::StreamExt;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

// ============================================================================
// Modelo de segmentación (pyannote-style) — committeado directo en
// `resources/models/`, no se descarga en runtime. Estas constantes no las
// usa ningún código todavía (el archivo se referencia por ruta relativa
// fija, igual que `silero_vad_v4.onnx` en `managers/audio.rs`) — existen
// para que la procedencia y la licencia de un binario que se embebe sin
// condiciones en cada build queden en un lugar tracked por git, no solo en
// el mensaje de commit o en el reporte gitignored de T008. Registro
// paralelo (más narrativo) en `specs/001-meeting-notetaker/research.md`
// §1, "Licencias de los modelos ONNX committeados/usados (T008)".
// ============================================================================

/// Nombre de archivo del modelo de segmentación, tal como vive en
/// `resources/models/`.
pub const SEGMENTATION_MODEL_FILENAME: &str = "pyannote_segmentation_3_0.onnx";

/// URL de origen: archivo `model.onnx` dentro de
/// `sherpa-onnx-pyannote-segmentation-3-0.tar.bz2`, release
/// `speaker-segmentation-models` del repo `k2-fsa/sherpa-onnx`.
/// https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-segmentation-models
pub const SEGMENTATION_MODEL_SOURCE_URL: &str = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2";

/// SHA-256 del archivo committeado en
/// `resources/models/pyannote_segmentation_3_0.onnx` (calculado
/// localmente en T008 sobre el `model.onnx` extraído del `.tar.bz2`
/// de origen).
pub const SEGMENTATION_MODEL_SHA256: &str =
    "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079";

/// Licencia verificada del checkpoint (no la licencia genérica del repo
/// `k2-fsa/sherpa-onnx` que lo sirve, que es Apache-2.0): **MIT License,
/// Copyright (c) 2022 CNRS** (Centre National de la Recherche
/// Scientifique — el laboratorio francés detrás de pyannote). Verificado
/// leyendo el archivo `LICENSE` bundleado *dentro* del `.tar.bz2` de la
/// release (no solo la licencia del repo que lo hostea) — texto completo
/// en `specs/001-meeting-notetaker/research.md` §1. El `README.md`
/// bundleado en el mismo `.tar.bz2` confirma el origen:
/// <https://huggingface.co/pyannote/segmentation-3.0> (licencia `mit`
/// también en su ficha de HuggingFace). Sin restricción de uso comercial
/// ni umbral de ingresos.
pub const SEGMENTATION_MODEL_LICENSE: &str =
    "MIT (pyannote/segmentation-3.0, Copyright (c) 2022 CNRS — ver research.md §1)";

// ============================================================================
// Modelo de embeddings de hablante (CAM++, 3D-Speaker) — descarga en
// runtime, ver funciones más abajo.
// ============================================================================

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

// ============================================================================
// Modelo de diarización en streaming (Sortformer, NVIDIA NeMo) — Task 2 del
// plan "reuniones en streaming"
// (`.superpowers/sdd/2026-08-04-reuniones-en-streaming/`). Descarga en
// runtime, mismo patrón que el modelo de embeddings de arriba (~470 MB, muy
// por encima del umbral de "committear directo" que sí aplica al modelo de
// segmentación).
//
// Deliberadamente NO está en `catalog/catalog.json`: ese catálogo alimenta
// el selector de modelos de transcripción de la UI
// (`catalog::ModelDescriptor`, mapeado siempre a
// `EngineType::TranscribeCpp`, el motor GGML/GGUF) — agregar acá un modelo
// ONNX de diarización lo haría aparecer como si fuera un modelo de
// transcripción seleccionable, que es exactamente la confusión que el doc
// comment del módulo (arriba) ya explica para el modelo de embeddings. Este
// modelo sigue el mismo patrón: funciones libres, desacopladas de
// `AppHandle`/`ModelManager`/`ModelInfo`.
// ============================================================================

/// Nombre de archivo del modelo Sortformer, tal como se guarda en disco.
pub const SORTFORMER_MODEL_FILENAME: &str = "diar_streaming_sortformer_4spk-v2.onnx";

/// URL de origen, pineada a un commit específico (no `main`) para que el
/// hash de abajo sea estable. `nvidia/diar_streaming_sortformer_4spk-v2`
/// (el checkpoint real, licencia verificada más abajo) sólo publica un
/// checkpoint `.nemo` — sin export ONNX propio. El archivo de acá es la
/// exportación de <https://huggingface.co/altunenes/parakeet-rs> (usada
/// para su port a Rust de modelos NeMo; su propio README dice "All models
/// using the same licences from NVIDIA. I only exported them to ONNX").
/// Verificado en Task 2: el SHA-256 de abajo coincide exactamente con el
/// `X-Linked-ETag` que Hugging Face reporta para este mismo blob.
///
/// **Bloqueante, no resuelto** (revisión de Task 2, Important 3): esto
/// apunta a un repo personal de un tercero en Hugging Face, exactamente el
/// tipo de dependencia que ya rompió las descargas de Dilo cuando Hugging
/// Face migró a Xet (ver `dilo-models-xet.md` en la memoria del proyecto) y
/// que obligó a re-hostear los 13 modelos del catálogo a
/// `github.com/aacontn/dilo-models/releases`. Este modelo debería
/// re-hostearse ahí mismo antes de que una tarea futura lo cablee de
/// verdad — no se hizo en Task 2 porque publicar un release público es una
/// acción que requiere confirmación explícita del dueño, no algo para
/// decidir en silencio dentro de una tarea de código. La URL y el SHA-256
/// de acá ya están verificados y listos para que quien lo suba los use
/// directo, sin tener que re-descargar ni re-verificar nada.
pub const SORTFORMER_MODEL_URL: &str = "https://huggingface.co/altunenes/parakeet-rs/resolve/a61d2818df4659c956b9661a9447f46e98c15126/diar_streaming_sortformer_4spk-v2.onnx";

/// SHA-256 del archivo, calculado localmente en Task 2 sobre la descarga y
/// verificado contra el `X-Linked-ETag` que reporta Hugging Face para ese
/// mismo blob (dos fuentes independientes, coinciden).
pub const SORTFORMER_MODEL_SHA256: &str =
    "cc520901a8cc25a8d7f7c2c8561a465709b67dd4f1df0572a97530087f3fbc73";

/// Tamaño esperado en bytes.
pub const SORTFORMER_MODEL_SIZE_BYTES: u64 = 492_243_002;

/// Licencia verificada del checkpoint real (`nvidia/diar_streaming_sortformer_4spk-v2`,
/// **sin el `.1`**): `cc-by-4.0`, confirmada contra
/// `huggingface.co/api/models/nvidia/diar_streaming_sortformer_4spk-v2`
/// (tag `license:cc-by-4.0` en la respuesta de la API, no sólo en el
/// README). Es la misma licencia que Canary, que Dilo ya distribuye. La
/// versión `v2.1` (con el punto uno) es un checkpoint EMPAREJADO pero
/// DISTINTO, con mejor DER pero licencia `nvidia-open-model-license` sin
/// verificar para distribución — por eso Task 2 usa v2, no v2.1 (ver
/// `task-2-report.md` para la comparación empírica de calidad entre
/// ambos). El repo que sirve el `.onnx` (`altunenes/parakeet-rs`) no
/// declara su propio tag de licencia pero su README remite explícitamente
/// a la licencia de NVIDIA para el checkpoint de origen.
pub const SORTFORMER_MODEL_LICENSE: &str =
    "CC-BY-4.0 (nvidia/diar_streaming_sortformer_4spk-v2, ver task-2-report.md)";

/// Ruta absoluta donde debería vivir el modelo Sortformer dentro del
/// directorio de modelos de la app.
pub fn sortformer_model_path(models_dir: &Path) -> PathBuf {
    models_dir.join(SORTFORMER_MODEL_FILENAME)
}

/// Si el modelo Sortformer ya está descargado en disco.
pub fn is_sortformer_model_downloaded(models_dir: &Path) -> bool {
    sortformer_model_path(models_dir).is_file()
}

/// SHA-256 de un archivo en disco, leyendo en bloques de 64&nbsp;KB en vez
/// de cargarlo entero a memoria -- mismo patrón que
/// `ModelManager::compute_sha256` en `managers/model.rs`. A diferencia de
/// [`sha256_hex`] (que sí recibe un `&[u8]` ya en memoria, usado por el
/// modelo de embeddings de ~27&nbsp;MB de arriba), este modelo pesa
/// ~470&nbsp;MB: hashearlo desde un buffer en RAM significaría tenerlo
/// completo ahí, encima del propio archivo que ya se está escribiendo a
/// disco -- justo lo que la revisión de Task 2 (Important 3) pidió evitar.
fn sha256_hex_of_file(path: &Path) -> Result<String> {
    use std::io::Read;
    let mut file =
        std::fs::File::open(path).with_context(|| format!("abriendo {}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hasher.update(&buffer[..n]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

/// Descarga el modelo Sortformer si falta, verificando tamaño y SHA-256
/// antes de dejarlo en su ubicación final. A diferencia de
/// [`ensure_embedding_model_downloaded`] (~27&nbsp;MB, cabe cómodo en RAM),
/// este modelo pesa ~470&nbsp;MB: la descarga va directo a un archivo
/// `.partial` en streaming (nunca el archivo completo en memoria) y
/// soporta resumir con `Range` si un intento anterior quedó a medias --
/// mismo patrón de streaming+resume que ya usa
/// `ModelManager::download_model`/`download_from_mirror` en
/// `managers/model.rs`, sin la parte de eventos de progreso a la UI (este
/// módulo sigue desacoplado de `AppHandle`, ver el doc comment de más
/// arriba -- cablear progreso queda para la tarea que integre esto de
/// verdad).
///
/// **Ver el doc comment de [`SORTFORMER_MODEL_URL`]**: sigue apuntando a un
/// repo personal de terceros, sin re-hostear todavía -- bloqueante
/// documentado, no resuelto acá.
pub async fn ensure_sortformer_model_downloaded(models_dir: &Path) -> Result<PathBuf> {
    let dest = sortformer_model_path(models_dir);
    if dest.is_file() {
        return Ok(dest);
    }

    std::fs::create_dir_all(models_dir)
        .with_context(|| format!("creando {}", models_dir.display()))?;

    let partial = models_dir.join(format!("{SORTFORMER_MODEL_FILENAME}.partial"));
    let mut resume_from = match partial.metadata() {
        Ok(meta) if meta.len() < SORTFORMER_MODEL_SIZE_BYTES => meta.len(),
        Ok(_) => {
            // Ya tiene el tamaño completo (o más -- restos corruptos de un
            // intento previo): no hay nada válido que resumir, se reinicia.
            let _ = std::fs::remove_file(&partial);
            0
        }
        Err(_) => 0,
    };

    let client = reqwest::Client::new();
    let mut request = client.get(SORTFORMER_MODEL_URL);
    if resume_from > 0 {
        request = request.header("Range", format!("bytes={resume_from}-"));
    }
    let mut response = request
        .send()
        .await
        .with_context(|| format!("descargando {SORTFORMER_MODEL_URL}"))?;

    // El servidor no soporta rangos (devuelve 200 en vez de 206 Partial
    // Content pese al header Range): el cuerpo es el archivo completo de
    // nuevo, no el resto -- reiniciar en vez de arriesgar un archivo
    // corrupto por concatenar de más.
    if resume_from > 0 && response.status() == reqwest::StatusCode::OK {
        drop(response);
        let _ = std::fs::remove_file(&partial);
        resume_from = 0;
        response = client
            .get(SORTFORMER_MODEL_URL)
            .send()
            .await
            .with_context(|| format!("descargando {SORTFORMER_MODEL_URL}"))?;
    }

    if !response.status().is_success() && response.status() != reqwest::StatusCode::PARTIAL_CONTENT
    {
        bail!(
            "descarga del modelo Sortformer falló: HTTP {}",
            response.status()
        );
    }

    {
        use std::io::Write;
        let mut file = if resume_from > 0 {
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&partial)
        } else {
            std::fs::File::create(&partial)
        }
        .with_context(|| format!("abriendo {}", partial.display()))?;

        let mut stream = response.bytes_stream();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.context("leyendo un chunk del modelo Sortformer")?;
            file.write_all(&chunk)
                .with_context(|| format!("escribiendo en {}", partial.display()))?;
        }
        file.flush()
            .with_context(|| format!("cerrando {}", partial.display()))?;
        // `file` se dropea acá, antes de leerlo de vuelta para el hash.
    }

    let actual_size = partial
        .metadata()
        .with_context(|| format!("leyendo el tamaño de {}", partial.display()))?
        .len();
    if actual_size != SORTFORMER_MODEL_SIZE_BYTES {
        // Se mantiene el `.partial` a propósito -- es justo lo que permite
        // resumir en el próximo intento en vez de volver a bajar ~470 MB
        // desde cero por un corte de red.
        bail!(
            "descarga del modelo Sortformer incompleta: esperado {} bytes, hay {} \
             (se guardó el .partial para resumir en el próximo intento)",
            SORTFORMER_MODEL_SIZE_BYTES,
            actual_size
        );
    }

    let actual_sha256 = sha256_hex_of_file(&partial)?;
    if actual_sha256 != SORTFORMER_MODEL_SHA256 {
        // Acá sí se borra: un hash que no matchea con el tamaño correcto es
        // corrupción real, no un corte de red -- no hay nada seguro que
        // resumir sobre datos corruptos.
        let _ = std::fs::remove_file(&partial);
        bail!(
            "SHA-256 del modelo Sortformer no coincide: esperado {}, obtenido {} \
             (descarga corrupta o el archivo upstream cambió -- no continuar sin \
             re-verificar la licencia)",
            SORTFORMER_MODEL_SHA256,
            actual_sha256
        );
    }

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

    #[test]
    fn sortformer_model_path_joins_filename() {
        let dir = Path::new("/tmp/dilo-app-data/models");
        assert_eq!(
            sortformer_model_path(dir),
            dir.join("diar_streaming_sortformer_4spk-v2.onnx")
        );
    }

    #[test]
    fn is_sortformer_model_downloaded_false_when_missing() {
        let dir = Path::new("/tmp/dilo-app-data-does-not-exist/models");
        assert!(!is_sortformer_model_downloaded(dir));
    }

    #[test]
    fn sha256_hex_of_file_matches_known_vector() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("abc.txt");
        std::fs::write(&path, b"abc").unwrap();
        assert_eq!(
            sha256_hex_of_file(&path).unwrap(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    /// Descarga real (~470&nbsp;MB) contra Hugging Face -- no corre en CI,
    /// pensada para validar a mano el fix de la revisión de Task 2
    /// (Important 3: streaming a disco + resume, no todo el archivo en
    /// RAM). Ejercita las dos ramas reales: descarga fresca y, truncando el
    /// archivo ya bajado a un `.partial` incompleto, resume vía `Range`.
    #[tokio::test]
    #[ignore = "descarga ~470 MB reales desde Hugging Face -- correr a mano"]
    async fn ensure_sortformer_model_downloaded_baja_y_resume_de_verdad() {
        let dir = tempfile::tempdir().unwrap();
        let models_dir = dir.path();

        // Rama 1: descarga fresca (sin .partial previo).
        let dest = ensure_sortformer_model_downloaded(models_dir)
            .await
            .expect("descarga fresca");
        assert!(dest.is_file());
        assert_eq!(dest.metadata().unwrap().len(), SORTFORMER_MODEL_SIZE_BYTES);

        // Rama 2: resume. Se trunca una copia del archivo completo a un
        // `.partial` (simula un corte de red a mitad de descarga) y se
        // vuelve a llamar -- debe completar sólo el resto vía `Range`, no
        // rehacer todo, y el resultado final tiene que verificar igual.
        let partial = models_dir.join(format!("{SORTFORMER_MODEL_FILENAME}.partial"));
        let full_bytes = std::fs::read(&dest).unwrap();
        std::fs::remove_file(&dest).unwrap();
        std::fs::write(&partial, &full_bytes[..full_bytes.len() / 2]).unwrap();

        let dest2 = ensure_sortformer_model_downloaded(models_dir)
            .await
            .expect("resume");
        assert_eq!(dest2, dest);
        assert!(!partial.exists(), ".partial se renombra al terminar");
        assert_eq!(sha256_hex_of_file(&dest2).unwrap(), SORTFORMER_MODEL_SHA256);
    }
}
