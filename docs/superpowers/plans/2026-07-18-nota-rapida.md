# Nota rápida con sincronización — Implementation Plan (tanda 2 de v0.1.12)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un atajo global "Nota rápida" que dicta y guarda la transcripción como nota markdown local (siempre) y la sincroniza por captura a Notas de Apple y/o Notion, con cola de pendientes si un destino falla.

**Architecture:** `quick_note` es un binding fijo nuevo (default vacío) mapeado en `ACTION_MAP` a un `TranscribeAction { post_process: false, output: OutputDestination::Note }`. El único punto que cambia del pipeline es el sitio de paste en `TranscribeAction::stop`: con `Note`, en vez de `utils::paste` se llama `notes::capture_note(...)`. Todo lo de notas vive en un módulo nuevo `src-tauri/src/notes.rs` (archivo local + osascript + Notion + cola de pendientes). La config vive en `AppSettings` (campos `notes_*`), el token de Notion en un `SecretMap`.

**Tech Stack:** Rust (Tauri 2, reqwest ya presente, osascript vía `std::process::Command`), React/TS, tauri-plugin-dialog (ya presente) para el picker de carpeta.

**Spec:** `docs/superpowers/specs/2026-07-18-atajos-por-modo-y-notas-design.md` (sección 2)

## Global Constraints

- Copy es-first; claves i18n en los 22 locales (`bun run check:translations` lo exige).
- Offline-first: guardar el `.md` local jamás depende de red; Notion falla suave a la cola.
- Sin dependencias nuevas: osascript vía std, Notion vía `reqwest` (ya en Cargo.toml), picker vía `tauri-plugin-dialog` (ya en Cargo.toml).
- Apple Notes solo compila/aparece en macOS (`#[cfg(target_os = "macos")]` + gating en UI por os type).
- Antes de commitear: `cargo fmt`/`clippy` sin warnings nuevos, `bun run lint`, tests con `cargo test --lib`.
- Regenerar `src/bindings.ts` tras agregar comandos (breve `bun run tauri dev`; matar Dilo instalado antes por single-instance y relanzarlo después).

## Estructura de archivos

- **Create** `src-tauri/src/notes.rs` — todo el dominio de notas (archivo, sync, cola, comandos).
- **Modify** `src-tauri/src/settings.rs` — campos `notes_*`, `PendingNote`, binding `quick_note`.
- **Modify** `src-tauri/src/actions.rs` — `OutputDestination` en `TranscribeAction`, entrada `quick_note` en `ACTION_MAP`, branch de output en `stop`.
- **Modify** `src-tauri/src/transcription_coordinator.rs` — `is_transcribe_binding` incluye `quick_note` (PTT + manos libres).
- **Modify** `src-tauri/src/lib.rs` — `mod notes;`, registrar comandos, flush de pendientes al iniciar.
- **Create** `src/components/settings/NotesSettings.tsx` — sección "Notas".
- **Modify** navegación de settings (donde se listan las secciones) + i18n 22 locales.

---

### Task 1: Settings de notas + binding `quick_note`

**Files:**
- Modify: `src-tauri/src/settings.rs`

**Interfaces (Produces):**
- `AppSettings.notes_folder: Option<String>` (None → default `~/Documents/Dilo/Notas`)
- `AppSettings.notes_apple_enabled: bool` (default false), `notes_apple_folder: String` (default `"Dilo"`)
- `AppSettings.notes_notion_enabled: bool` (default false), `notes_notion_parent: String` (default `""`)
- `AppSettings.notes_secrets: SecretMap` (clave `"notion"` = token)
- `AppSettings.notes_pending: Vec<PendingNote>` con `PendingNote { title: String, body: String, targets: Vec<String>, last_error: Option<String> }` (targets: `"apple"` / `"notion"`)
- Binding fijo `"quick_note"` con `default_binding: ""` (el merge de `get_settings` lo agrega a stores viejos)

- [ ] **Step 1: Test fallando** (en `mod tests` de settings.rs):

```rust
#[test]
fn notes_settings_default_and_roundtrip() {
    let s = get_default_settings();
    assert!(s.notes_folder.is_none());
    assert!(!s.notes_apple_enabled);
    assert_eq!(s.notes_apple_folder, "Dilo");
    assert!(!s.notes_notion_enabled);
    assert!(s.notes_pending.is_empty());
    assert_eq!(s.bindings["quick_note"].current_binding, "");

    let json = serde_json::to_value(&s).unwrap();
    let back: AppSettings = serde_json::from_value(json).unwrap();
    assert_eq!(back.notes_apple_folder, "Dilo");
}
```

- [ ] **Step 2:** `cargo test --lib notes_settings` → FAIL (campos no existen).
- [ ] **Step 3:** Implementar: structs + `#[serde(default)]` en cada campo (`notes_apple_folder` con `default = "default_notes_apple_folder"` que devuelve `"Dilo".to_string()`); `PendingNote` derive `Serialize, Deserialize, Clone, Debug, specta::Type`; insertar el binding en `get_default_settings()`:

```rust
bindings.insert(
    "quick_note".to_string(),
    ShortcutBinding {
        id: "quick_note".to_string(),
        name: "Quick Note".to_string(),
        description: "Dictates into a local note instead of pasting.".to_string(),
        default_binding: String::new(),
        current_binding: String::new(),
    },
);
```

- [ ] **Step 4:** `cargo test --lib` → PASS. Verificar además que `init_shortcuts`/registro salta bindings con combo vacío (hay guard `if shortcut.trim().is_empty()` en `shortcut/mod.rs:92`; si el path de init no pasa por ahí, agregar el skip). El input de atajo existente (`ShortcutInput` con `shortcutId="quick_note"`) debe poder editarlo sin código nuevo.
- [ ] **Step 5:** Commit `feat(notas): settings de notas + binding quick_note`.

---

### Task 2: `notes.rs` — archivo local puro + cola

**Files:**
- Create: `src-tauri/src/notes.rs` · Modify: `src-tauri/src/lib.rs` (`mod notes;`)

**Interfaces (Produces):**
- `pub fn note_title(now: &chrono::DateTime<chrono::Local>) -> String` → `"AAAA-MM-DD HH.mm.ss — Nota"`
- `pub fn write_local_note(folder: &Path, title: &str, body: &str) -> Result<PathBuf, String>` — crea carpeta si falta, escribe `<title>.md` con frontmatter `---\nfecha: <ISO>\n---\n\n<body>\n`
- `pub fn notes_folder(settings: &AppSettings) -> PathBuf` — `notes_folder` o `dirs::document_dir()/Dilo/Notas` (crate `dirs` ya es dependencia transitiva; si no está directa, usar `tauri::Manager::path().document_dir()`)

- [ ] **Step 1: Tests fallando** (usar `tempfile::tempdir()`, ya en dev-deps; si no, `std::env::temp_dir()` + subcarpeta única por test):

```rust
#[test]
fn note_title_is_sortable_and_filename_safe() {
    let t = chrono::Local.with_ymd_and_hms(2026, 7, 18, 9, 5, 3).unwrap();
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
```

- [ ] **Step 2:** `cargo test --lib notes` → FAIL. **Step 3:** implementar mínimo. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(notas): nota markdown local`.

---

### Task 3: Sync Apple Notes + Notion + cola de pendientes

**Files:**
- Modify: `src-tauri/src/notes.rs`

**Interfaces (Produces):**
- `#[cfg(target_os = "macos")] pub fn sync_apple(folder: &str, title: &str, body: &str) -> Result<(), String>` — osascript: crear carpeta "Dilo" si no existe + `make new note`; escapar comillas del texto.
- `pub async fn sync_notion(token: &str, parent_id: &str, title: &str, body: &str) -> Result<(), String>` — `POST https://api.notion.com/v1/pages` con `Notion-Version: 2022-06-28`; detectar por forma del id si el parent es página (`parent: {page_id}`) — v1: probar `page_id` y si Notion responde error de tipo de parent reintentar como `database_id` (título en la propiedad `title`).
- `pub async fn capture_note(app: &AppHandle, text: &str)` — orquestador: escribir local (error → log + `emit("paste-error")` no; usar evento propio `note-error`), luego por destino habilitado intentar sync; fallo → push a `notes_pending` (con `write_settings`); éxito de todo → nada más.
- `pub async fn flush_pending(app: &AppHandle)` — recorre `notes_pending`, reintenta cada target restante, persiste lo que quede; se llama al iniciar app y al comienzo de cada `capture_note`.
- Comandos tauri-specta: `#[tauri::command] pub async fn test_notion_connection(app) -> Result<(), String>` (GET `https://api.notion.com/v1/users/me` con el token guardado), `pub fn pending_notes_count(app) -> u32`, `pub async fn flush_pending_notes(app) -> Result<u32, String>` (devuelve cuántas quedan).

- [ ] **Step 1: Tests** (solo lo puro es testeable sin red; testear el escape de osascript y el armado del JSON de Notion):

```rust
#[test]
fn apple_script_escapes_quotes() {
    let s = apple_note_script("Dilo", r#"ti"tulo"#, "cuer\"po");
    assert!(!s.contains(r#""ti"tulo""#)); // quotes escapadas
}

#[test]
fn notion_page_payload_shape() {
    let v = notion_payload_page("abc123", "Titulo", "Cuerpo");
    assert_eq!(v["parent"]["page_id"], "abc123");
    assert_eq!(v["children"][0]["paragraph"]["rich_text"][0]["text"]["content"], "Cuerpo");
}
```

(factorizar `apple_note_script(folder, title, body) -> String` y `notion_payload_page/_database(...) -> serde_json::Value` como funciones puras; `sync_*` las usan.)

- [ ] **Step 2:** FAIL → implementar → PASS. osascript de referencia:

```applescript
tell application "Notes"
  if not (exists folder "Dilo") then make new folder with properties {name:"Dilo"}
  make new note at folder "Dilo" with properties {name:"<title>", body:"<body>"}
end tell
```

- [ ] **Step 3:** registrar comandos en `lib.rs` (`collect_commands![... notes::test_notion_connection, notes::pending_notes_count, notes::flush_pending_notes]`) y llamar `notes::flush_pending` (spawn) al final del setup.
- [ ] **Step 4:** `cargo test --lib && cargo clippy` verdes. Commit `feat(notas): sync Apple Notes/Notion + cola de pendientes`.

---

### Task 4: Acción `quick_note` en el pipeline

**Files:**
- Modify: `src-tauri/src/actions.rs`, `src-tauri/src/transcription_coordinator.rs`

**Interfaces:**
- Consumes: `notes::capture_note(app, text)` (T3).
- Produces: `ACTION_MAP["quick_note"]`, `TranscribeAction { post_process: false, output: OutputDestination::Note }`.

- [ ] **Step 1: Test fallando** (junto a los tests de resolve_action existentes):

```rust
#[test]
fn quick_note_is_a_transcribe_binding_and_resolves() {
    assert!(crate::transcription_coordinator::is_transcribe_binding("quick_note"));
    assert!(resolve_action("quick_note").is_some());
}
```

- [ ] **Step 2:** FAIL. **Step 3:** implementar:
  - `#[derive(Clone, Copy, PartialEq)] enum OutputDestination { Paste, Note }`, campo `output` en `TranscribeAction` (entradas existentes del mapa usan `Paste`).
  - `ACTION_MAP`: `map.insert("quick_note", Arc::new(TranscribeAction { post_process: false, output: OutputDestination::Note }))`.
  - En `stop`, en el sitio del paste (`utils::paste(final_text, ...)` ~línea 845): si `output == Note`, en vez de `run_on_main_thread`+paste, `notes::capture_note(&ah, &final_text).await` y luego hide overlay + tray Idle. La entrada de historial se guarda igual.
  - `is_transcribe_binding`: agregar `|| id == "quick_note"` (PTT y doble toque quedan gratis).
- [ ] **Step 4:** `cargo test --lib` PASS, clippy limpio. Commit `feat(notas): acción quick_note conectada al pipeline`.

---

### Task 5: UI "Notas" + i18n

**Files:**
- Create: `src/components/settings/NotesSettings.tsx` · Modify: navegación/rutas de settings (buscar dónde se registra p. ej. la sección de post-proceso y calcar), `src/i18n/locales/*/translation.json` (22). Regenerar `src/bindings.ts` primero.

**Contenido de la sección (usar `SettingContainer`/`SettingsGroup`/`Input`/`Button`/`Dropdown` existentes):**
- Atajo: `<ShortcutInput shortcutId="quick_note" />` (ya funciona: es un binding normal).
- Carpeta local: ruta actual (o default) + botón "Elegir carpeta" → `open({ directory: true })` de `@tauri-apps/plugin-dialog` → `updateSetting("notes_folder", path)`; botón reset → `null`.
- Apple Notes (solo si `osType === "macos"`): toggle `notes_apple_enabled` + input `notes_apple_folder`.
- Notion: toggle `notes_notion_enabled` + input token (mismo patrón de campo secreto que `ApiKeyField` de post-proceso) + input `notes_notion_parent` + botón "Probar conexión" → `commands.testNotionConnection()` con toast ok/error.
- Pendientes: si `pendingNotesCount > 0`, línea "N notas pendientes de sincronizar" + botón reintentar → `commands.flushPendingNotes()`.

- [ ] **Step 1:** regen bindings (matar Dilo, `bun run tauri dev` breve, relanzar Dilo) — verificar `testNotionConnection`, `flushPendingNotes`, campos `notes_*` en `AppSettings`.
- [ ] **Step 2:** componente + registro en navegación.
- [ ] **Step 3:** i18n es (autoral) — grupo `settings.notes.*`: `title: "Notas"`, `shortcut: "Atajo de nota rápida"`, `shortcutHint: "Dicta y guarda como nota, sin pegar en la app activa."`, `folder: "Carpeta de notas"`, `folderPick: "Elegir carpeta"`, `apple: "Notas de Apple"`, `appleFolder: "Carpeta en Notas"`, `notion: "Notion"`, `notionToken: "Token de integración"`, `notionParent: "ID de página o base de datos"`, `notionTest: "Probar conexión"`, `pending: "{{count}} notas pendientes de sincronizar"`, `retry: "Reintentar ahora"` (+ en base y 20 traducciones razonables).
- [ ] **Step 4:** `bun run check:translations && bun run lint && bunx tsc --noEmit` verdes.
- [ ] **Step 5:** Commit `feat(notas): sección Notas en configuración + i18n`.

---

### Task 6 (correr al final, tras Tasks 7-8): Verificación integral (tanda 2 + release v0.1.12)

- [ ] **Step 1:** `cargo test --lib && cargo clippy` · `bun run lint && bun run format && bun run build && bun run check:translations` — todo verde.
- [ ] **Step 2:** Build local firmado, instalar en /Applications; prueba en vivo de Alfonso según spec §Verificación puntos 2–7 (nota local, Obsidian, Apple Notes, Notion, cola sin internet, atajos existentes intactos).
- [ ] **Step 3:** con su OK: bump a 0.1.12 (tauri.conf.json + Cargo.toml + package.json), notas de release en español (mencionar: primera release firmada — un último re-otorgar de Accesibilidad y no vuelve a pasar), `gh workflow run release.yml`, verificar ambos assets Mac, publicar.

---

### Task 7: Arrastre de la ventana principal

**Files:**
- Modify: `src/App.css` (región de arrastre), `src/App.tsx` si hace falta
- Contexto: la ventana macOS usa `TitleBarStyle::Overlay` + `hidden_title` (lib.rs `create_main_window`); el frontend tiene `.dilo-titlebar-drag-region` (`data-tauri-drag-region`, 36px alto, z-20, App.tsx:290) presente en todas las ramas. Alfonso reporta que no puede arrastrar desde ninguna parte.

- [ ] **Step 1:** Reproducir/diagnosticar: correr `bun run tauri dev` (matar Dilo instalado antes; relanzar después) y probar arrastre desde la franja superior. Revisar en el inspector si algún elemento tapa la franja (WhatsNewGate, AccessibilityPermissions, sidebar) o si un ancestro le quita pointer-events.
- [ ] **Step 2:** Fix mínimo según diagnóstico. Además ampliar superficie: agregar `data-tauri-drag-region` al encabezado vacío del área principal y al tope del sidebar (solo zonas sin controles interactivos — el atributo solo aplica al elemento exacto, no a hijos, así que usar elementos "spacer" dedicados).
- [ ] **Step 3:** Verificar en dev: arrastre desde franja superior y encabezado; los botones/links de esas zonas siguen cliqueables.
- [ ] **Step 4:** Commit `fix(ventana): arrastre de la ventana principal`.

---

### Task 8: Inicio — tarjetas de modo con atajo y Personalizar

**Files:**
- Modify: `src/components/home/DictationModes.tsx`, `src/components/home/HomeDashboard.tsx`, `src/App.tsx` (navegación a sección), CSS del segment en `src/App.css`
- Modify: `src/i18n/locales/*/translation.json` (22)

**Interfaces:**
- Consumes: `ModeShortcutInput` (tanda 1, `src/components/settings/ModeShortcutInput.tsx`), `settings.post_process_prompts` (con `shortcut`), navegación por secciones (`currentSection`/`setCurrentSection` viven en App.tsx y Sidebar).

**Diseño (pedido de Alfonso):**
- Cada modo con un espacio más dedicado: convertir la grilla de botones compactos en tarjetas más altas (label + descripción corta + atajo). El modo "literal" sigue primero; los modos de post-proceso NO desaparecen al elegir literal (siempre visibles, el seleccionado marcado).
- Incluir también los modos creados por el usuario (hoy solo salen los 5 presets `DICTATION_MODE_PRESETS`): derivar la lista de `settings.post_process_prompts` (presets primero, luego custom).
- En cada tarjeta (menos literal): el atajo del modo, mostrado y editable con `ModeShortcutInput` (o una variante compacta del mismo componente si el layout lo pide). Cuidado: el click en el input NO debe seleccionar el modo (stopPropagation).
- Acción "Personalizar" por tarjeta (o un botón general de la sección) que navegue a la sección Post-proceso. Mecanismo: levantar un callback — `DictationModes` recibe `onCustomize: () => void` que HomeDashboard recibe de App (`setCurrentSection("postprocess")` — verificar el id real de la sección en `SECTIONS_CONFIG`/Sidebar).
- i18n: `home.modes.customize: "Personalizar"` (es) + 21 traducciones; reusar claves de atajo existentes.

- [ ] **Step 1:** Lista de modos desde settings + tarjetas rediseñadas (sin atajo aún); literal no oculta el resto.
- [ ] **Step 2:** Atajo editable en tarjeta con `ModeShortcutInput` + stopPropagation.
- [ ] **Step 3:** Botón "Personalizar" → navegación a Post-proceso (prop drilling desde App).
- [ ] **Step 4:** i18n 22 locales + `bun run check:translations && bun run lint && bunx tsc --noEmit` verdes.
- [ ] **Step 5:** Commit `feat(inicio): tarjetas de modo con atajo y acceso a personalizar`.

## Self-review del plan

- **Cobertura spec §2:** acción+atajo (T1/T4), md local+carpeta configurable (T2), Apple/Notion/cola (T3), sección Notas+picker+probar conexión+pendientes (T5), verificación y release (T6). ✓
- **Placeholders:** los `sync_*` dependen de servicios externos; sus partes puras (script/payload) quedan testeadas y el resto se verifica en vivo (T6) — señalizado, no TBD. ✓
- **Consistencia:** `quick_note` como id en T1/T4/T5; `notes_*` en T1/T3/T5; `capture_note(app, text)` T3/T4. ✓
