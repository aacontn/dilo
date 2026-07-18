//! Notas rápidas: dictar a una nota markdown local en lugar de pegar el texto.
//!
//! Además del archivo local (funciones puras, testeables de forma aislada), este
//! módulo sincroniza la nota con Apple Notes (osascript) y Notion (REST), con una
//! cola de pendientes que reintenta lo que quedó sin enviar. Los comandos Tauri
//! (`test_notion_connection`, `pending_notes_count`, `flush_pending_notes`) viven
//! aquí y se registran en `lib.rs`.

use crate::settings::{get_settings, write_settings, AppSettings, PendingNote};
use log::{debug, error, warn};
use serde_json::json;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tauri::{AppHandle, Emitter};

/// Timeout de cada request a Notion: una red caída no puede colgar una captura.
const NOTION_TIMEOUT: Duration = Duration::from_secs(10);
const NOTION_VERSION: &str = "2022-06-28";

/// Título de la nota derivado de la marca de tiempo: `"AAAA-MM-DD HH.mm.ss — Nota"`.
///
/// Ordenable lexicográficamente (fecha ISO al frente) y seguro como nombre de
/// archivo: usa puntos en la hora en lugar de dos puntos, que `:` no es válido en
/// rutas de Windows/macOS.
pub fn note_title(now: &chrono::DateTime<chrono::Local>) -> String {
    format!("{} — Nota", now.format("%Y-%m-%d %H.%M.%S"))
}

/// Escribe `<title>.md` dentro de `folder` (creando la carpeta si falta) con un
/// frontmatter YAML mínimo y el cuerpo dictado. Devuelve la ruta escrita.
pub fn write_local_note(folder: &Path, title: &str, body: &str) -> Result<PathBuf, String> {
    std::fs::create_dir_all(folder)
        .map_err(|e| format!("no se pudo crear la carpeta {}: {e}", folder.display()))?;

    let path = folder.join(format!("{title}.md"));
    let fecha = chrono::Local::now().to_rfc3339();
    let contents = format!("---\nfecha: {fecha}\n---\n\n{body}\n");

    std::fs::write(&path, contents)
        .map_err(|e| format!("no se pudo escribir la nota {}: {e}", path.display()))?;

    Ok(path)
}

/// Carpeta donde guardar las notas locales: la configurada por el usuario, o el
/// default `~/Documents/Dilo/Notas`.
pub fn notes_folder(settings: &AppSettings) -> PathBuf {
    if let Some(folder) = settings.notes_folder.as_deref() {
        if !folder.trim().is_empty() {
            return PathBuf::from(folder);
        }
    }

    // `dirs::document_dir()` es puro (no necesita `AppHandle`); si el SO no lo
    // resuelve, caemos al directorio actual para nunca escribir en la raíz.
    let base = dirs::document_dir().unwrap_or_else(|| PathBuf::from("."));
    base.join("Dilo").join("Notas")
}

// ---------------------------------------------------------------------------
// Funciones puras de armado (osascript + payload de Notion). Testeables sin red.
// ---------------------------------------------------------------------------

/// Escapa una cadena para incrustarla en un literal de AppleScript: barra
/// invertida y comillas se escapan, y los saltos de línea pasan a la secuencia
/// `\n` (un literal de AppleScript no admite un salto de línea crudo).
fn escape_applescript(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\r', "\\r")
        .replace('\n', "\\n")
}

/// AppleScript que crea la carpeta `folder` si falta y agrega una nota nueva con
/// `title` y `body`. Todo el texto va escapado para no romper el literal ni
/// permitir inyección de comandos.
pub fn apple_note_script(folder: &str, title: &str, body: &str) -> String {
    let folder = escape_applescript(folder);
    let title = escape_applescript(title);
    let body = escape_applescript(body);
    format!(
        "tell application \"Notes\"\n\
         if not (exists folder \"{folder}\") then make new folder with properties {{name:\"{folder}\"}}\n\
         make new note at folder \"{folder}\" with properties {{name:\"{title}\", body:\"{body}\"}}\n\
         end tell"
    )
}

/// Cuerpo compartido del `POST /v1/pages`: un `parent` dado (page o database),
/// el título en la propiedad `title` y el cuerpo como un bloque `paragraph`.
fn notion_payload(parent: serde_json::Value, title: &str, body: &str) -> serde_json::Value {
    json!({
        "parent": parent,
        "properties": {
            "title": {
                "title": [ { "text": { "content": title } } ]
            }
        },
        "children": [
            {
                "object": "block",
                "type": "paragraph",
                "paragraph": {
                    "rich_text": [ { "text": { "content": body } } ]
                }
            }
        ]
    })
}

/// Payload para un parent que es una página de Notion (`parent: {page_id}`).
pub fn notion_payload_page(parent_id: &str, title: &str, body: &str) -> serde_json::Value {
    notion_payload(json!({ "page_id": parent_id }), title, body)
}

/// Payload para un parent que es una base de datos (`parent: {database_id}`).
pub fn notion_payload_database(parent_id: &str, title: &str, body: &str) -> serde_json::Value {
    notion_payload(json!({ "database_id": parent_id }), title, body)
}

// ---------------------------------------------------------------------------
// Sincronización con destinos externos.
// ---------------------------------------------------------------------------

/// Crea una nota en la app Notas de Apple vía `osascript`. Solo macOS.
#[cfg(target_os = "macos")]
pub fn sync_apple(folder: &str, title: &str, body: &str) -> Result<(), String> {
    let script = apple_note_script(folder, title, body);
    let output = std::process::Command::new("/usr/bin/osascript")
        .arg("-e")
        .arg(&script)
        .output()
        .map_err(|e| format!("no se pudo ejecutar osascript: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("osascript falló: {}", stderr.trim()));
    }
    Ok(())
}

/// `POST /v1/pages` a Notion. Como la forma del id no dice si el parent es una
/// página o una base, probamos primero como página y, si Notion responde un
/// error de tipo de parent, reintentamos como base de datos.
pub async fn sync_notion(
    token: &str,
    parent_id: &str,
    title: &str,
    body: &str,
) -> Result<(), String> {
    let client = reqwest::Client::builder()
        .timeout(NOTION_TIMEOUT)
        .build()
        .map_err(|e| format!("no se pudo crear el cliente HTTP: {e}"))?;

    let page = notion_payload_page(parent_id, title, body);
    match notion_create_page(&client, token, &page).await {
        Ok(()) => Ok(()),
        Err((parent_mismatch, message)) => {
            if parent_mismatch {
                let db = notion_payload_database(parent_id, title, body);
                notion_create_page(&client, token, &db)
                    .await
                    .map_err(|(_, message)| message)
            } else {
                Err(message)
            }
        }
    }
}

/// Envía un payload a `POST /v1/pages`. En el `Err`, el `bool` indica si el fallo
/// parece ser un desajuste del tipo de parent (400 mencionando `parent` /
/// `page_id` / `database_id`), para decidir el reintento como base de datos.
async fn notion_create_page(
    client: &reqwest::Client,
    token: &str,
    payload: &serde_json::Value,
) -> Result<(), (bool, String)> {
    let resp = client
        .post("https://api.notion.com/v1/pages")
        .bearer_auth(token)
        .header("Notion-Version", NOTION_VERSION)
        .json(payload)
        .send()
        .await
        .map_err(|e| (false, format!("error de red con Notion: {e}")))?;

    let status = resp.status();
    if status.is_success() {
        return Ok(());
    }

    let text = resp.text().await.unwrap_or_default();
    let parent_mismatch = status == reqwest::StatusCode::BAD_REQUEST
        && (text.contains("database_id") || text.contains("page_id") || text.contains("parent"));
    Err((
        parent_mismatch,
        format!("Notion respondió {status}: {text}"),
    ))
}

/// Sincroniza un único destino (`"apple"` / `"notion"`) con la config actual.
async fn sync_target(
    settings: &AppSettings,
    target: &str,
    title: &str,
    body: &str,
) -> Result<(), String> {
    match target {
        "apple" => {
            #[cfg(target_os = "macos")]
            {
                sync_apple(&settings.notes_apple_folder, title, body)
            }
            #[cfg(not(target_os = "macos"))]
            {
                let _ = (settings, title, body);
                Err("Notas de Apple solo está disponible en macOS".to_string())
            }
        }
        "notion" => {
            let token = settings
                .notes_secrets
                .get("notion")
                .cloned()
                .unwrap_or_default();
            if token.trim().is_empty() {
                return Err("Falta el token de Notion".to_string());
            }
            sync_notion(&token, &settings.notes_notion_parent, title, body).await
        }
        other => Err(format!("destino de nota desconocido: {other}")),
    }
}

// ---------------------------------------------------------------------------
// Orquestación: captura + cola de pendientes.
// ---------------------------------------------------------------------------

/// Guard simple contra flushes concurrentes: el flush de arranque y el del
/// comienzo de cada `capture_note` no pueden reenviar la misma nota dos veces.
static FLUSHING: AtomicBool = AtomicBool::new(false);

/// Libera el guard `FLUSHING` aunque el flush salga por un `return` temprano o
/// un panic.
struct FlushGuard;
impl Drop for FlushGuard {
    fn drop(&mut self) {
        FLUSHING.store(false, Ordering::SeqCst);
    }
}

/// Dicta a una nota: escribe el archivo local (fuente de verdad) y sincroniza
/// los destinos habilitados. El mismo `title` correlaciona archivo, nota de
/// Apple y página de Notion. Si el archivo local falla, se registra y se emite
/// `note-error`, pero igual se intentan los syncs (la cola también los protege).
/// Los destinos que fallen se acumulan en UN `PendingNote` por captura.
///
// Consumido por la acción `quick_note` del pipeline (Task 4); hasta que ese
// call-site aterrice, `capture_note` y sus helpers exclusivos del archivo local
// (`note_title`, `write_local_note`, `notes_folder`) no tienen consumidor en un
// build sin tests, así que se permite dead_code de forma acotada aquí.
#[allow(dead_code)]
pub async fn capture_note(app: &AppHandle, text: &str) {
    // La cola se comparte con esta captura: reintentar antes de empezar.
    flush_pending(app).await;

    let settings = get_settings(app);
    let title = note_title(&chrono::Local::now());

    // 1) Archivo local.
    let folder = notes_folder(&settings);
    if let Err(e) = write_local_note(&folder, &title, text) {
        error!("no se pudo escribir la nota local: {e}");
        let _ = app.emit("note-error", e);
    }

    // 2) Destinos habilitados.
    let mut targets = Vec::new();
    if settings.notes_apple_enabled {
        targets.push("apple".to_string());
    }
    if settings.notes_notion_enabled {
        targets.push("notion".to_string());
    }

    let mut failed = Vec::new();
    let mut last_error = None;
    for target in &targets {
        if let Err(e) = sync_target(&settings, target, &title, text).await {
            warn!("sync de nota a '{target}' falló: {e}");
            failed.push(target.clone());
            last_error = Some(e);
        }
    }

    // 3) Lo que quedó pendiente: un solo PendingNote con los targets fallidos.
    if !failed.is_empty() {
        let mut settings = get_settings(app);
        settings.notes_pending.push(PendingNote {
            title,
            body: text.to_string(),
            targets: failed,
            last_error,
        });
        write_settings(app, settings);
    }
}

/// Recorre `notes_pending`, reintenta cada target restante y persiste lo que
/// siga fallando. Se llama al iniciar la app y al comienzo de cada
/// `capture_note`; el guard `FLUSHING` evita que ambos reenvíen a la vez.
pub async fn flush_pending(app: &AppHandle) {
    if FLUSHING.swap(true, Ordering::SeqCst) {
        debug!("flush_pending: ya hay un flush en curso; se omite");
        return;
    }
    let _guard = FlushGuard;

    let mut settings = get_settings(app);
    if settings.notes_pending.is_empty() {
        return;
    }

    let pending = std::mem::take(&mut settings.notes_pending);
    let mut still_pending = Vec::new();
    for note in pending {
        if let Some(remaining) = retry_note(&settings, note).await {
            still_pending.push(remaining);
        }
    }

    settings.notes_pending = still_pending;
    write_settings(app, settings);
}

/// Reintenta los targets de un `PendingNote`. Devuelve `None` si todos pasaron,
/// o un `PendingNote` con solo los targets que siguen fallando.
async fn retry_note(settings: &AppSettings, note: PendingNote) -> Option<PendingNote> {
    let mut failed = Vec::new();
    let mut last_error = None;
    for target in &note.targets {
        if let Err(e) = sync_target(settings, target, &note.title, &note.body).await {
            warn!("reintento de nota '{}' a '{target}' falló: {e}", note.title);
            failed.push(target.clone());
            last_error = Some(e);
        }
    }

    if failed.is_empty() {
        None
    } else {
        Some(PendingNote {
            title: note.title,
            body: note.body,
            targets: failed,
            last_error,
        })
    }
}

// ---------------------------------------------------------------------------
// Comandos Tauri.
// ---------------------------------------------------------------------------

/// Verifica el token de Notion guardado con `GET /v1/users/me`.
#[tauri::command]
#[specta::specta]
pub async fn test_notion_connection(app: AppHandle) -> Result<(), String> {
    let token = get_settings(&app)
        .notes_secrets
        .get("notion")
        .cloned()
        .unwrap_or_default();
    if token.trim().is_empty() {
        return Err("Falta el token de Notion".to_string());
    }

    let client = reqwest::Client::builder()
        .timeout(NOTION_TIMEOUT)
        .build()
        .map_err(|e| format!("no se pudo crear el cliente HTTP: {e}"))?;

    let resp = client
        .get("https://api.notion.com/v1/users/me")
        .bearer_auth(&token)
        .header("Notion-Version", NOTION_VERSION)
        .send()
        .await
        .map_err(|e| format!("error de red con Notion: {e}"))?;

    let status = resp.status();
    if status.is_success() {
        Ok(())
    } else {
        let text = resp.text().await.unwrap_or_default();
        Err(format!("Notion respondió {status}: {text}"))
    }
}

/// Cuántas notas quedan pendientes de sincronizar.
#[tauri::command]
#[specta::specta]
pub fn pending_notes_count(app: AppHandle) -> u32 {
    get_settings(&app).notes_pending.len() as u32
}

/// Fuerza un reintento de la cola y devuelve cuántas notas siguen pendientes.
#[tauri::command]
#[specta::specta]
pub async fn flush_pending_notes(app: AppHandle) -> Result<u32, String> {
    flush_pending(&app).await;
    Ok(get_settings(&app).notes_pending.len() as u32)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn note_title_is_sortable_and_filename_safe() {
        let t = chrono::Local
            .with_ymd_and_hms(2026, 7, 18, 9, 5, 3)
            .unwrap();
        assert_eq!(note_title(&t), "2026-07-18 09.05.03 — Nota");
    }

    #[test]
    fn write_local_note_creates_folder_and_file() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("sub/Notas");
        let path = write_local_note(&target, "2026-07-18 09.05.03 — Nota", "hola").unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.starts_with("---\nfecha:"));
        assert!(text.ends_with("hola\n"));
    }

    #[test]
    fn notes_folder_prefers_configured_folder_else_default() {
        let mut settings = crate::settings::get_default_settings();
        // Sin configurar: default termina en Dilo/Notas.
        assert!(notes_folder(&settings).ends_with("Dilo/Notas"));

        settings.notes_folder = Some("/tmp/mis-notas".to_string());
        assert_eq!(notes_folder(&settings), PathBuf::from("/tmp/mis-notas"));
    }

    #[test]
    fn apple_script_escapes_quotes() {
        let s = apple_note_script("Dilo", r#"ti"tulo"#, "cuer\"po");
        assert!(!s.contains(r#""ti"tulo""#)); // quotes escapadas
        assert!(s.contains(r#"ti\"tulo"#));
        assert!(s.contains(r#"cuer\"po"#));
    }

    #[test]
    fn apple_script_escapes_backslash_and_newline() {
        let s = apple_note_script("Dilo", "t", "a\\b\nc");
        // La barra invertida se duplica y el salto pasa a la secuencia \n.
        assert!(s.contains(r"a\\b\nc"));
        // El cuerpo no debe contener un salto de línea crudo.
        assert!(!s.contains("a\\b\nc"));
    }

    #[test]
    fn notion_page_payload_shape() {
        let v = notion_payload_page("abc123", "Titulo", "Cuerpo");
        assert_eq!(v["parent"]["page_id"], "abc123");
        assert_eq!(
            v["children"][0]["paragraph"]["rich_text"][0]["text"]["content"],
            "Cuerpo"
        );
        assert_eq!(
            v["properties"]["title"]["title"][0]["text"]["content"],
            "Titulo"
        );
    }

    #[test]
    fn notion_database_payload_uses_database_id() {
        let v = notion_payload_database("db123", "Titulo", "Cuerpo");
        assert_eq!(v["parent"]["database_id"], "db123");
        assert!(v["parent"].get("page_id").is_none());
        assert_eq!(
            v["properties"]["title"]["title"][0]["text"]["content"],
            "Titulo"
        );
    }
}
