# Atajos por modo — Implementation Plan (tanda 1 de v0.1.12)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cada modo de dictado (`LLMPrompt`) puede tener un atajo global opcional que dicta directamente con ese modo, sin cambiar el modo seleccionado global.

**Architecture:** El atajo de un modo se registra como binding dinámico con id `mode:<prompt_id>`. `resolve_action()` reemplaza los lookups directos a `ACTION_MAP` y mapea cualquier `mode:*` a un `TranscribeAction` con post-proceso; el prompt a usar viaja como override en un estado global (`MODE_PROMPT_OVERRIDE`) que setea el start del binding y consume `process_transcription_output` — así `post_process_selected_prompt_id` no se toca. El atajo se persiste dentro del propio `LLMPrompt` y su ciclo de vida (registro/desregistro) acompaña al CRUD de modos.

**Tech Stack:** Rust (Tauri 2, tauri-specta), React/TS, sistema de bindings existente (`shortcut/` con impls Tauri y HandyKeys).

**Spec:** `docs/superpowers/specs/2026-07-18-atajos-por-modo-y-notas-design.md` (sección 1)

## Global Constraints

- Copy es-first; claves i18n en los 22 locales (`bun run check:translations` lo exige).
- PTT + doble toque manos libres deben funcionar igual con atajos de modo (pasan por el coordinador con su binding id — no requiere cambios ahí, verificar en vivo).
- Antes de commitear: `bun run lint` + `bun run format`; `cargo clippy` sin warnings nuevos.
- El modo seleccionado global (`post_process_selected_prompt_id`) NUNCA cambia por usar un atajo de modo.
- Regenerar `src/bindings.ts` (correr `bun run tauri dev` unos segundos) tras agregar comandos.

## Estructura de archivos

- **Modify** `src-tauri/src/settings.rs` — `LLMPrompt.shortcut: Option<String>` (+ test serde).
- **Modify** `src-tauri/src/actions.rs` — `resolve_action()`, `MODE_PROMPT_OVERRIDE`, consumo del override en `process_transcription_output` (+ tests).
- **Modify** `src-tauri/src/transcription_coordinator.rs` y `src-tauri/src/shortcut/handler.rs` — usar `resolve_action`.
- **Modify** `src-tauri/src/shortcut/mod.rs` — registro dinámico al init, comando `change_mode_shortcut`, hooks en CRUD de prompts.
- **Modify** `src-tauri/src/lib.rs` — registrar comando.
- **Modify** `src/components/settings/PostProcessingSettingsPrompts.tsx` — input de atajo por modo.
- **Modify** `src/i18n/locales/*/translation.json` (22) — claves nuevas.

---

### Task 1: `LLMPrompt.shortcut` en settings

**Files:**

- Modify: `src-tauri/src/settings.rs` (struct `LLMPrompt` ~línea 90; tests al final)

**Interfaces:**

- Produces: `LLMPrompt { id, name, prompt, shortcut: Option<String> }` — `shortcut` con `#[serde(default)]` (stores viejos deserializan a `None`). Tasks 3/4 lo leen/escriben.

- [ ] **Step 1: Test que falla** — en el `mod tests` de settings.rs:

```rust
    #[test]
    fn llm_prompt_shortcut_defaults_to_none_and_roundtrips() {
        let p: LLMPrompt = serde_json::from_value(serde_json::json!({
            "id": "x", "name": "X", "prompt": "haz X"
        }))
        .expect("prompt viejo sin shortcut debe deserializar");
        assert!(p.shortcut.is_none());

        let p2 = LLMPrompt {
            id: "y".into(),
            name: "Y".into(),
            prompt: "haz Y".into(),
            shortcut: Some("ctrl+alt+y".into()),
        };
        let back: LLMPrompt =
            serde_json::from_value(serde_json::to_value(&p2).unwrap()).unwrap();
        assert_eq!(back.shortcut.as_deref(), Some("ctrl+alt+y"));
    }
```

- [ ] **Step 2:** `cargo test llm_prompt_shortcut` → FAIL (campo no existe; los literales de `LLMPrompt` en presets no compilan).
- [ ] **Step 3:** agregar a `LLMPrompt`:

```rust
    /// Atajo global opcional del modo (binding dinámico `mode:<id>`).
    #[serde(default)]
    pub shortcut: Option<String>,
```

y `shortcut: None,` en cada literal `LLMPrompt { ... }` de `dilo_post_process_presets()` (y cualquier otro constructor que el compilador acuse).

- [ ] **Step 4:** `cargo test llm_prompt_shortcut` → PASS; `cargo test` completo verde.
- [ ] **Step 5:** `git commit -m "feat(modos): campo de atajo opcional por modo en settings"`

---

### Task 2: `resolve_action` + override de prompt por modo

**Files:**

- Modify: `src-tauri/src/actions.rs` (junto a `ACTION_MAP` y en `process_transcription_output`)
- Modify: `src-tauri/src/transcription_coordinator.rs` (2 call sites de `ACTION_MAP.get`)
- Modify: `src-tauri/src/shortcut/handler.rs` (1 call site)

**Interfaces:**

- Produces:
  - `pub fn resolve_action(binding_id: &str) -> Option<Arc<dyn ShortcutAction>>` — ids exactos van a `ACTION_MAP`; `mode:*` devuelve el `TranscribeAction { post_process: true }` compartido.
  - `pub fn mode_prompt_id(binding_id: &str) -> Option<&str>` — `"mode:abc"` → `Some("abc")`.
  - `pub static MODE_PROMPT_OVERRIDE: Mutex<Option<String>>` — prompt_id del modo en curso; lo setea el start del binding de modo y lo CONSUME (take) `process_transcription_output`.

- [ ] **Step 1: Tests que fallan** — en el `mod tests` de actions.rs:

```rust
    #[test]
    fn mode_binding_ids_resolve_to_transcribe_action() {
        assert!(super::resolve_action("transcribe").is_some());
        assert!(super::resolve_action("mode:cualquiera").is_some());
        assert!(super::resolve_action("inexistente").is_none());
    }

    #[test]
    fn mode_prompt_id_parses_only_mode_ids() {
        assert_eq!(super::mode_prompt_id("mode:abc"), Some("abc"));
        assert_eq!(super::mode_prompt_id("transcribe"), None);
        assert_eq!(super::mode_prompt_id("mode:"), None); // vacío no es un modo
    }
```

- [ ] **Step 2:** `cargo test --lib actions` → FAIL de compilación.
- [ ] **Step 3: Implementación** en actions.rs:

```rust
/// Prompt del modo en curso cuando el dictado partió por un atajo `mode:<id>`.
/// Lo setea TranscribeAction::start y lo consume process_transcription_output,
/// así el modo seleccionado global no se toca.
pub static MODE_PROMPT_OVERRIDE: Mutex<Option<String>> = Mutex::new(None);

/// `"mode:<prompt_id>"` → `Some(prompt_id)`.
pub fn mode_prompt_id(binding_id: &str) -> Option<&str> {
    binding_id
        .strip_prefix("mode:")
        .filter(|id| !id.is_empty())
}

/// Como ACTION_MAP.get, pero los bindings dinámicos de modo (`mode:*`)
/// resuelven al TranscribeAction con post-proceso.
pub fn resolve_action(binding_id: &str) -> Option<Arc<dyn ShortcutAction>> {
    if mode_prompt_id(binding_id).is_some() {
        return ACTION_MAP.get("transcribe_with_post_process").cloned();
    }
    ACTION_MAP.get(binding_id).cloned()
}
```

En `TranscribeAction::start` (primeras líneas): si `let Some(pid) = mode_prompt_id(binding_id)`, guardar `Some(pid.to_string())` en `MODE_PROMPT_OVERRIDE`; si no, limpiar a `None` (un dictado normal no debe heredar un override viejo).

En `process_transcription_output` (~línea 442), al elegir prompt:

```rust
            let override_id = MODE_PROMPT_OVERRIDE
                .lock()
                .ok()
                .and_then(|mut o| o.take());
            let prompt_id = override_id
                .as_ref()
                .or(settings.post_process_selected_prompt_id.as_ref());
            if let Some(prompt_id) = prompt_id {
                // (lookup existente en settings.post_process_prompts, sin cambios)
```

Reemplazar los 3 call sites externos (`transcription_coordinator.rs` ×2, `shortcut/handler.rs` ×1): `ACTION_MAP.get(binding_id)` → `crate::actions::resolve_action(binding_id)` (ajustar el patrón: devuelve `Option<Arc<...>>` ya clonado). El import `use crate::actions::ACTION_MAP;` se cambia por `resolve_action`.

**Cuidado:** el binding de modo debe post-procesar aunque `post_process_enabled` esté apagado globalmente — revisar el gate en `process_transcription_output` (~línea 425-442): si el override está presente, tratar como habilitado para esta captura (el usuario pidió ese modo explícitamente).

- [ ] **Step 4:** `cargo test --lib` → todo verde (los 2 tests nuevos incluidos).
- [ ] **Step 5:** `git commit -m "feat(modos): bindings mode:<id> con override de prompt por captura"`

---

### Task 3: registro dinámico + comando `change_mode_shortcut`

**Files:**

- Modify: `src-tauri/src/shortcut/mod.rs`
- Modify: `src-tauri/src/lib.rs` (collect_commands)

**Interfaces:**

- Consumes: `LLMPrompt.shortcut` (T1), ids `mode:<prompt_id>` (T2).
- Produces:
  - `fn mode_binding(prompt: &LLMPrompt) -> Option<ShortcutBinding>` — None si el modo no tiene atajo.
  - `pub fn sync_mode_shortcuts(app: &AppHandle)` — desregistra todos los `mode:*` vigentes y registra los actuales desde settings (idempotente; se llama al init y tras cualquier CRUD de prompts).
  - Comando specta `change_mode_shortcut(app, prompt_id: String, shortcut: String) -> Result<(), String>` — `""` = quitar atajo. Persiste en el prompt y re-sincroniza. Error legible si la tecla ya está tomada (el register de la impl falla → propagar).

- [ ] **Step 1: Implementación** (sin test unitario — es pegamento sobre las impls de teclado; se cubre con la verificación en vivo):

```rust
fn mode_binding(prompt: &crate::settings::LLMPrompt) -> Option<ShortcutBinding> {
    let shortcut = prompt.shortcut.clone()?;
    if shortcut.is_empty() {
        return None;
    }
    Some(ShortcutBinding {
        id: format!("mode:{}", prompt.id),
        name: prompt.name.clone(),
        description: String::new(),
        default_binding: String::new(),
        current_binding: shortcut,
    })
}

/// Alinea los atajos globales de modos con settings. Idempotente: desregistra
/// todo `mode:*` y vuelve a registrar lo vigente. Llamar al init y tras
/// cualquier alta/edición/borrado de modos.
pub fn sync_mode_shortcuts(app: &AppHandle) {
    let settings = settings::get_settings(app);
    for prompt in &settings.post_process_prompts {
        // Desregistrar versión previa (ignorando errores: puede no existir).
        let stale = ShortcutBinding {
            id: format!("mode:{}", prompt.id),
            name: prompt.name.clone(),
            description: String::new(),
            default_binding: String::new(),
            current_binding: String::new(),
        };
        let _ = unregister_shortcut(app, stale);
        if let Some(binding) = mode_binding(prompt) {
            if let Err(e) = register_shortcut(app, binding) {
                warn!("No se pudo registrar el atajo del modo '{}': {}", prompt.name, e);
            }
        }
    }
}
```

**OJO implementación real:** revisar la firma de `unregister_shortcut` en ambas impls — si desregistran por `current_binding` (la tecla) y no por id, `sync` debe recordar la tecla anterior: en ese caso, cambiar la estrategia a: leer el prompt ANTES de mutarlo en el comando, desregistrar con la tecla vieja, registrar la nueva (sin pasada global). Ajustar a lo que las impls soporten — el plan fija el CONTRATO (tras el comando, queda registrado exactamente lo que dicen settings), no la táctica interna.

Comando:

```rust
#[tauri::command]
#[specta::specta]
pub fn change_mode_shortcut(
    app: AppHandle,
    prompt_id: String,
    shortcut: String,
) -> Result<(), String> {
    let mut settings = settings::get_settings(&app);
    let prompt = settings
        .post_process_prompts
        .iter_mut()
        .find(|p| p.id == prompt_id)
        .ok_or_else(|| format!("No existe el modo '{prompt_id}'"))?;
    let previous = prompt.shortcut.clone();
    prompt.shortcut = if shortcut.is_empty() {
        None
    } else {
        Some(shortcut.clone())
    };
    settings::write_settings(&app, settings);
    // Re-sincronizar; si la tecla nueva no se puede registrar, revertir.
    ...según táctica elegida arriba; en error: restaurar `previous`, write_settings,
    re-sync y devolver Err con mensaje legible...
}
```

Hooks: llamar `sync_mode_shortcuts(&app)` al final de `init_shortcuts` y de los comandos existentes `add_post_process_prompt`, `update_post_process_prompt`, `delete_post_process_prompt` (borrar un modo desregistra su atajo vía la pasada de sync). Registrar `shortcut::change_mode_shortcut,` en collect_commands (lib.rs).

- [ ] **Step 2:** `cargo test` verde + `cargo clippy` sin warnings nuevos.
- [ ] **Step 3:** `git commit -m "feat(modos): registro dinámico de atajos por modo + comando change_mode_shortcut"`

---

### Task 4: UI + i18n

**Files:**

- Modify: `src/components/settings/PostProcessingSettingsPrompts.tsx`
- Modify: `src/i18n/locales/*/translation.json` (22)
- Regenerated: `src/bindings.ts`

**Interfaces:**

- Consumes: `commands.changeModeShortcut(promptId, shortcut)` (T3), `LLMPrompt.shortcut` en el tipo generado.

- [ ] **Step 1:** regenerar bindings (`bun run tauri dev` unos segundos; verificar `changeModeShortcut` y `shortcut` en el tipo `LLMPrompt` de `src/bindings.ts`).
- [ ] **Step 2:** en la tarjeta de edición de cada modo en `PostProcessingSettingsPrompts.tsx`, agregar el campo de atajo reutilizando el componente de captura de atajos existente (`ShortcutInput` — revisar sus props reales: value/onChange/onCapture). Comportamiento: al capturar una combinación → `commands.changeModeShortcut(prompt.id, captured)`; botón/acción de limpiar → `commands.changeModeShortcut(prompt.id, "")`; error del comando → toast/mensaje con el texto devuelto (tecla en conflicto). Etiqueta `t("settings.postProcess.modeShortcut")`, hint `t("settings.postProcess.modeShortcutHint")`.
- [ ] **Step 3:** i18n — agregar en los 22 locales (es autoral, en base, resto traducción razonable):
  - es: `"modeShortcut": "Atajo del modo (opcional)"`, `"modeShortcutHint": "Dicta directo con este modo desde cualquier app, sin cambiar el modo seleccionado."`
  - en: `"modeShortcut": "Mode shortcut (optional)"`, `"modeShortcutHint": "Dictate straight into this mode from any app, without changing the selected mode."`
- [ ] **Step 4:** `bun run check:translations` verde; `bun run lint` + `bunx tsc --noEmit` verdes.
- [ ] **Step 5:** `git commit -m "feat(modos): atajo configurable por modo en la UI"`

---

### Task 5: Verificación integral

- [ ] **Step 1:** `cd src-tauri && cargo test && cargo clippy` · `bun run lint && bun run format && bun run build && bun run check:translations` — todo verde.
- [ ] **Step 2:** Build local (`bun run tauri build`), instalar en /Applications (borrar bundles de target/ después), y verificación en vivo de Alfonso según el spec §Verificación punto 1: atajo en un modo → dicta con ese modo desde otra app; PTT y doble toque OK; el modo global no cambió; atajos originales intactos; conflicto de tecla reporta error legible.
- [ ] **Step 3:** commit final si hubo ajustes.

## Self-review del plan

- **Cobertura del spec §1:** persistencia (T1), semántica mode-binding + no tocar selección global + post-proceso forzado (T2), ciclo de vida registro/CRUD + conflictos (T3), UI seleccionable + i18n (T4), verificación PTT/manos libres (T5). ✓
- **Placeholders:** T3 deja explícita una decisión táctica dependiente de las firmas reales de `unregister_shortcut` (contrato fijado; el ejecutor elige la táctica al leer las impls) — señalizado a propósito, no es un TBD de diseño.
- **Consistencia de tipos:** `mode:<prompt_id>` en T2/T3; `change_mode_shortcut(prompt_id, shortcut)` T3/T4; `LLMPrompt.shortcut: Option<String>` T1/T3/T4. ✓
