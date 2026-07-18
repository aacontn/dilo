//! Notas rápidas: dictar a una nota markdown local en lugar de pegar el texto.
//!
//! Este módulo mantiene las funciones puras del archivo local (sin dependencia
//! de `AppHandle`), para que sean testeables de forma aislada. La sincronización
//! con Apple Notes / Notion y los comandos Tauri se agregan en tareas
//! posteriores.

use crate::settings::AppSettings;
use std::path::{Path, PathBuf};

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
}
