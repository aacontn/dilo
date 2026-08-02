# Proveedor de IA por modo — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que cada modo de post-proceso pueda usar su propio proveedor de IA, con la distinción local/online visible, cayendo al proveedor global cuando el suyo falla.

**Architecture:** Dos campos opcionales en `LLMPrompt` (`provider_id`, `model`) donde `None` = hereda el global, así no hay migración. Una función pura resuelve qué proveedor le toca a cada modo; otra decide la caída al global. `is_local` se **calcula** (no se persiste como verdad) a partir del id del proveedor y de su `base_url`, y se refresca al cargar settings para que el frontend lo vea sin duplicar la regla en TypeScript.

**Tech Stack:** Rust (Tauri 2, serde, tauri-specta), React + TypeScript, Zustand, i18next.

## Global Constraints

- **Sin dependencias nuevas** (Rust ni npm).
- **Campos nuevos con `#[serde(default)]`**: un settings.json de v0.1.13 debe cargar sin tocarse.
- **Copy es-first**, autoral, **tuteo chileno** (nunca voseo: "elige", no "elegí"). El locale `es` no se genera por máquina.
- **`bun run check:translations` exige las 21 lenguas completas** — es un gate, no un opcional.
- **Antes de cada commit:** `cargo fmt`, `cargo clippy --all-targets` (sin warnings nuevos), `cargo test --lib`, y en tareas de frontend además `bun run lint` y `bun run build`.
- **Bindings:** si cambia la superficie de comandos/eventos/tipos, regenerar con `cargo build && ./target/debug/dilo --list-devices` **corrido desde `src-tauri/`** (el export usa la ruta relativa `../src/bindings.ts`; desde otro directorio escribe el archivo en el lugar equivocado).
- Rama: `feat/proveedor-por-modo` (ya creada, con el spec commiteado).
- Spec: `docs/superpowers/specs/2026-07-29-proveedor-por-modo-design.md`.

---

## Estructura de archivos

| Archivo                                                              | Responsabilidad                                                                                   |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `src-tauri/src/settings.rs`                                          | Campos nuevos, regla `provider_is_local`, resolución del proveedor de un modo, refresco al cargar |
| `src-tauri/src/actions.rs`                                           | Orden de resolución, caída al global, señal de cruce local→online                                 |
| `src-tauri/src/shortcut/mod.rs`                                      | Comando para guardar el proveedor/modelo de un modo                                               |
| `src-tauri/src/lib.rs`                                               | Registro del comando y del evento nuevos                                                          |
| `src/components/settings/post-processing/ModeProviderSelect.tsx`     | **Nuevo.** Bloque "IA de este modo"                                                               |
| `src/components/settings/post-processing/PostProcessingSettings.tsx` | Monta el bloque junto al atajo                                                                    |
| `src/components/home/DictationModes.tsx`                             | Etiqueta LOCAL/ONLINE por modo                                                                    |
| `src/App.tsx`                                                        | Toast del aviso de caída                                                                          |
| `src/i18n/locales/*/translation.json`                                | Claves nuevas en 21 lenguas                                                                       |

---

### Task 1: `is_local` calculado en el catálogo de proveedores

**Files:**

- Modify: `src-tauri/src/settings.rs` (struct `PostProcessProvider` ~línea 112, `default_post_process_providers` ~661, `ensure_post_process_defaults` ~847)
- Test: mismo archivo, `mod tests` (~1278)

**Interfaces:**

- Produces: `pub fn provider_is_local(provider: &PostProcessProvider) -> bool`; campo `PostProcessProvider.is_local: bool` (calculado al cargar, visible en `bindings.ts`).

- [ ] **Step 1: Escribir el test que falla**

En `mod tests` de `src-tauri/src/settings.rs`:

```rust
#[test]
fn apple_intelligence_is_local_and_the_cloud_providers_are_not() {
    let providers = default_post_process_providers();
    let find = |id: &str| providers.iter().find(|p| p.id == id).cloned();

    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        let apple = find(APPLE_INTELLIGENCE_PROVIDER_ID).expect("Apple Intelligence en el catálogo");
        assert!(provider_is_local(&apple), "corre en el chip, no sale del equipo");
    }

    let openai = find("openai").expect("openai en el catálogo");
    assert!(!provider_is_local(&openai));
    let gemini = find("google").expect("google en el catálogo");
    assert!(!provider_is_local(&gemini));
}

#[test]
fn custom_provider_is_local_only_while_it_points_at_this_machine() {
    let mut custom = default_post_process_providers()
        .into_iter()
        .find(|p| p.id == "custom")
        .expect("custom en el catálogo");

    // Viene apuntando a Ollama en la propia máquina.
    assert!(provider_is_local(&custom), "el default apunta a localhost");

    for url in [
        "http://127.0.0.1:1234/v1",
        "http://[::1]:11434/v1",
        "http://LOCALHOST:11434/v1",
    ] {
        custom.base_url = url.to_string();
        assert!(provider_is_local(&custom), "{url} es esta máquina");
    }

    // Si el usuario lo apunta afuera, deja de ser local solo.
    custom.base_url = "https://api.midominio.com/v1".to_string();
    assert!(
        !provider_is_local(&custom),
        "un servidor remoto no puede seguir diciendo LOCAL"
    );
}
```

- [ ] **Step 2: Correr y ver que falla**

Run: `cd src-tauri && cargo test --lib settings::tests::custom_provider_is_local -- --nocapture`
Expected: FAIL — `cannot find function 'provider_is_local'`.

- [ ] **Step 3: Implementar la regla**

En `src-tauri/src/settings.rs`, junto a `default_post_process_providers`:

```rust
/// Si el destino de un proveedor es la propia máquina del usuario.
///
/// **Se calcula, no se guarda como verdad.** Apple Intelligence lo es por
/// definición (corre en el chip). `custom` es el único cuyo destino define el
/// usuario: viene apuntando a Ollama en `localhost:11434`, pero si lo cambia a
/// un servidor remoto tiene que dejar de decir LOCAL sin depender de que
/// alguien se acuerde de actualizar una bandera.
pub fn provider_is_local(provider: &PostProcessProvider) -> bool {
    if provider.id == APPLE_INTELLIGENCE_PROVIDER_ID {
        return true;
    }
    is_loopback_url(&provider.base_url)
}

fn is_loopback_url(base_url: &str) -> bool {
    let lowered = base_url.to_ascii_lowercase();
    let host = lowered
        .split("://")
        .nth(1)
        .unwrap_or(&lowered)
        .split('/')
        .next()
        .unwrap_or("");
    let host = host.rsplit_once(':').map_or(host, |(h, _)| h);
    let host = host.trim_start_matches('[').trim_end_matches(']');

    host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "0.0.0.0"
}
```

Agregar el campo a la struct `PostProcessProvider`:

```rust
    /// Calculado al cargar settings (ver `ensure_post_process_defaults`), no
    /// editable por el usuario. Está en la struct para que el frontend lo lea
    /// del binding en vez de repetir la regla en TypeScript.
    #[serde(default)]
    pub is_local: bool,
```

En **cada** literal de `default_post_process_providers()` agregar `is_local: false` salvo el de Apple Intelligence, que lleva `is_local: true`.

- [ ] **Step 4: Refrescar el valor al cargar**

En `ensure_post_process_defaults`, dentro del brazo `Some(existing) =>`, después del bloque que sincroniza `supports_structured_output` (mismo patrón):

```rust
                // `is_local` se recalcula siempre: el usuario pudo cambiar la
                // base_url de `custom`, y un settings.json viejo no lo trae.
                let computed = provider_is_local(existing);
                if existing.is_local != computed {
                    existing.is_local = computed;
                    changed = true;
                }
```

- [ ] **Step 5: Test de que un settings viejo se repara al cargar**

```rust
#[test]
fn loading_recomputes_is_local_for_a_settings_file_without_the_field() {
    let mut settings = get_default_settings();
    // Simula un settings.json de v0.1.13: el campo no existía.
    for provider in settings.post_process_providers.iter_mut() {
        provider.is_local = false;
    }
    settings
        .post_process_providers
        .iter_mut()
        .find(|p| p.id == "custom")
        .expect("custom")
        .base_url = "http://localhost:11434/v1".to_string();

    assert!(ensure_post_process_defaults(&mut settings));

    let custom = settings
        .post_process_providers
        .iter()
        .find(|p| p.id == "custom")
        .unwrap();
    assert!(custom.is_local, "apunta a esta máquina: es local");
}
```

- [ ] **Step 6: Verificar**

Run: `cd src-tauri && cargo test --lib settings:: && cargo clippy --all-targets 2>&1 | grep -c '^warning: [a-z]'`
Expected: tests PASS; el conteo de warnings no sube respecto de `main`.

- [ ] **Step 7: Commit**

```bash
cargo fmt
git add src-tauri/src/settings.rs
git commit -m "feat(modos): distinguir proveedores locales de los que salen a la nube

Apple Intelligence corre en el chip y Ollama en localhost, pero en la app se
veían igual que OpenAI. La distinción se calcula en vez de guardarse: el
proveedor Custom es el único cuyo destino lo define el usuario, así que si lo
apunta a un servidor remoto deja de decir local solo."
```

---

### Task 2: `provider_id` y `model` por modo, con su resolución

**Files:**

- Modify: `src-tauri/src/settings.rs` (struct `LLMPrompt` ~línea 90, `dilo_post_process_presets` ~788, `add_post_process_prompt` en `shortcut/mod.rs` ~1151 construye un `LLMPrompt`)
- Test: `src-tauri/src/settings.rs`, `mod tests`

**Interfaces:**

- Consumes: `provider_is_local` (Task 1).
- Produces: `LLMPrompt.provider_id: Option<String>`, `LLMPrompt.model: Option<String>`; `pub struct ResolvedProvider { pub provider: PostProcessProvider, pub model: String, pub is_local: bool, pub inherited: bool }`; `pub fn resolve_mode_provider(settings: &AppSettings, prompt: &LLMPrompt) -> Option<ResolvedProvider>`.

- [ ] **Step 1: Escribir los tests que fallan**

```rust
fn settings_with_mode(provider_id: Option<&str>, model: Option<&str>) -> AppSettings {
    let mut settings = get_default_settings();
    settings.post_process_provider_id = "openai".to_string();
    settings
        .post_process_models
        .insert("openai".to_string(), "gpt-4o-mini".to_string());
    settings
        .post_process_models
        .insert("google".to_string(), "gemini-2.5-flash".to_string());
    let prompt = settings
        .post_process_prompts
        .iter_mut()
        .find(|p| p.id == "dilo-code")
        .expect("el modo Código viene de fábrica");
    prompt.provider_id = provider_id.map(str::to_string);
    prompt.model = model.map(str::to_string);
    settings
}

fn code_mode(settings: &AppSettings) -> LLMPrompt {
    settings
        .post_process_prompts
        .iter()
        .find(|p| p.id == "dilo-code")
        .cloned()
        .unwrap()
}

#[test]
fn a_mode_without_its_own_provider_inherits_the_global_one() {
    let settings = settings_with_mode(None, None);
    let resolved = resolve_mode_provider(&settings, &code_mode(&settings)).expect("resuelve");

    assert_eq!(resolved.provider.id, "openai");
    assert_eq!(resolved.model, "gpt-4o-mini");
    assert!(resolved.inherited, "hereda: la UI lo muestra como 'General'");
}

#[test]
fn a_mode_with_its_own_provider_uses_it() {
    let settings = settings_with_mode(Some("google"), Some("gemini-2.5-pro"));
    let resolved = resolve_mode_provider(&settings, &code_mode(&settings)).expect("resuelve");

    assert_eq!(resolved.provider.id, "google");
    assert_eq!(resolved.model, "gemini-2.5-pro", "el modelo del modo manda");
    assert!(!resolved.inherited);
    assert!(!resolved.is_local);
}

#[test]
fn a_mode_without_its_own_model_falls_back_to_the_provider_default_model() {
    let settings = settings_with_mode(Some("google"), None);
    let resolved = resolve_mode_provider(&settings, &code_mode(&settings)).expect("resuelve");

    assert_eq!(resolved.provider.id, "google");
    assert_eq!(
        resolved.model, "gemini-2.5-flash",
        "sin modelo propio usa el que ya está configurado para ese proveedor"
    );
}

#[test]
fn a_mode_pointing_at_a_deleted_provider_falls_back_to_the_global_one() {
    let settings = settings_with_mode(Some("proveedor-que-el-usuario-borro"), None);
    let resolved = resolve_mode_provider(&settings, &code_mode(&settings)).expect("resuelve");

    assert_eq!(
        resolved.provider.id, "openai",
        "configuración vieja no es una falla: se usa el general en silencio"
    );
    assert!(resolved.inherited);
}

#[test]
fn a_provider_without_any_model_configured_does_not_resolve() {
    let mut settings = settings_with_mode(Some("anthropic"), None);
    settings.post_process_models.remove("anthropic");
    assert!(
        resolve_mode_provider(&settings, &code_mode(&settings)).is_none(),
        "sin modelo no hay a qué llamar: cuenta como no disponible"
    );
}
```

- [ ] **Step 2: Correr y ver que falla**

Run: `cd src-tauri && cargo test --lib settings::tests::a_mode_ -- --nocapture`
Expected: FAIL — `no field 'provider_id' on type 'LLMPrompt'`.

- [ ] **Step 3: Agregar los campos**

En `struct LLMPrompt` (`src-tauri/src/settings.rs`), después de `shortcut`:

```rust
    /// Proveedor propio de este modo. `None` = usa el global
    /// (`post_process_provider_id`), que es el comportamiento histórico y por
    /// eso no necesita migración.
    #[serde(default)]
    pub provider_id: Option<String>,
    /// Modelo propio de este modo. `None` = el que esté configurado para su
    /// proveedor en `post_process_models`.
    #[serde(default)]
    pub model: Option<String>,
```

En `dilo_post_process_presets()`, agregar `provider_id: None, model: None,` a los cinco presets. En `shortcut/mod.rs::add_post_process_prompt`, agregar los mismos dos campos al `LLMPrompt` que construye.

- [ ] **Step 4: Implementar la resolución**

En `src-tauri/src/settings.rs`:

```rust
/// Qué IA le toca a un modo, ya resuelta contra el catálogo y los modelos
/// configurados.
#[derive(Debug, Clone)]
pub struct ResolvedProvider {
    pub provider: PostProcessProvider,
    pub model: String,
    pub is_local: bool,
    /// `true` si salió del proveedor global en vez del propio del modo.
    pub inherited: bool,
}

/// Resuelve el proveedor de un modo. `None` significa "no hay nada a qué
/// llamar" (sin proveedor global válido, o sin modelo configurado), que el
/// llamador trata como proveedor no disponible.
///
/// Un modo que apunta a un proveedor inexistente —el usuario lo borró— cae al
/// global **en silencio**: eso no es una falla, es configuración vieja.
pub fn resolve_mode_provider(
    settings: &AppSettings,
    prompt: &LLMPrompt,
) -> Option<ResolvedProvider> {
    let own = prompt
        .provider_id
        .as_deref()
        .and_then(|id| settings.post_process_provider(id));

    let (provider, inherited) = match own {
        Some(provider) => (provider, false),
        None => (settings.active_post_process_provider()?, true),
    };

    let model = if inherited {
        settings.post_process_models.get(&provider.id).cloned()
    } else {
        prompt
            .model
            .clone()
            .or_else(|| settings.post_process_models.get(&provider.id).cloned())
    }?;

    if model.trim().is_empty() {
        return None;
    }

    Some(ResolvedProvider {
        is_local: provider_is_local(provider),
        provider: provider.clone(),
        model,
        inherited,
    })
}
```

- [ ] **Step 5: Verificar**

Run: `cd src-tauri && cargo test --lib settings::`
Expected: PASS, incluidos los cinco tests nuevos.

- [ ] **Step 6: Commit**

```bash
cargo fmt
git add src-tauri/src/settings.rs src-tauri/src/shortcut/mod.rs
git commit -m "feat(modos): cada modo puede tener su propio proveedor y modelo

Los campos son opcionales y ausentes significan 'usa el general', así que un
settings existente sigue comportándose igual sin migrar nada. Un modo que
apunta a un proveedor borrado cae al general en silencio: eso no es una falla,
es configuración que quedó vieja."
```

---

### Task 3: Caída al proveedor global y señal de cruce a la nube

**Files:**

- Modify: `src-tauri/src/actions.rs` (`post_process_transcription` ~137-381, y su llamador ~486)
- Test: `src-tauri/src/actions.rs`, `mod tests` (~1070)

**Interfaces:**

- Consumes: `resolve_mode_provider`, `ResolvedProvider` (Task 2).
- Produces: `pub struct PostProcessOutcome { pub text: String, pub used_provider_id: String, pub crossed_to_cloud: Option<PostProcessFallback> }`; el evento `pub struct PostProcessFallback { pub mode_name: String, pub provider_label: String }` (nombre de cable `post-process-fallback`, binding `events.postProcessFallback`); `fn crossing_to_report(mode_was_local: bool, fallback_is_local: bool, mode_name: &str, provider_label: &str) -> Option<PostProcessFallback>`.

- [ ] **Step 1: Escribir el test de la decisión que falla**

En `mod tests` de `actions.rs`:

```rust
#[test]
fn crossing_is_reported_only_when_a_local_mode_ends_up_in_the_cloud() {
    // Modo local que terminó procesándose en la nube: hay que avisar.
    assert!(crossing_to_report(true, false, "Código", "Google Gemini").is_some());

    // Modo local que cayó a otro proveedor local: no salió nada del equipo.
    assert!(crossing_to_report(true, true, "Código", "Ollama").is_none());

    // El modo ya era online: caer a otro online no cambia nada para el usuario.
    assert!(crossing_to_report(false, false, "Correo", "OpenAI").is_none());

    // Un modo online que cae a uno local tampoco es noticia.
    assert!(crossing_to_report(false, true, "Correo", "Apple Intelligence").is_none());
}

#[test]
fn the_crossing_report_names_the_mode_and_the_provider_that_ran() {
    let crossing = crossing_to_report(true, false, "Código", "Google Gemini")
        .expect("hay cruce que reportar");
    assert_eq!(crossing.mode_name, "Código");
    assert_eq!(crossing.provider_label, "Google Gemini");
}
```

- [ ] **Step 2: Correr y ver que falla**

Run: `cd src-tauri && cargo test --lib actions::tests::crossing -- --nocapture`
Expected: FAIL — `cannot find function 'crossing_to_report'`.

- [ ] **Step 3: Implementar la decisión**

En `src-tauri/src/actions.rs`:

```rust
/// Datos del aviso cuando la caída al proveedor global mandó a la nube un
/// texto que el modo quería procesar localmente.
#[derive(Debug, Clone, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct PostProcessFallback {
    pub mode_name: String,
    pub provider_label: String,
}

/// El aviso sale **sólo** cuando se cruzó de local a nube. Caer entre dos
/// proveedores online no cambia nada para el usuario, y caer hacia uno local
/// tampoco es noticia: lo único que hay que contar es que un texto que iba a
/// quedarse en el equipo terminó saliendo.
fn crossing_to_report(
    mode_was_local: bool,
    fallback_is_local: bool,
    mode_name: &str,
    provider_label: &str,
) -> Option<PostProcessFallback> {
    if mode_was_local && !fallback_is_local {
        return Some(PostProcessFallback {
            mode_name: mode_name.to_string(),
            provider_label: provider_label.to_string(),
        });
    }
    None
}
```

- [ ] **Step 4: Reordenar la resolución y agregar la caída**

En `post_process_transcription`, **mover la resolución del prompt antes que la del proveedor** (hoy el proveedor se resuelve en la línea ~147 y el prompt en la ~169; el orden tiene que invertirse porque el proveedor ahora depende del modo). Reemplazar el bloque `let provider = match settings.active_post_process_provider()...` por:

```rust
    // El proveedor depende del modo, así que primero hay que saber qué modo es.
    let mode = match settings
        .post_process_prompts
        .iter()
        .find(|p| p.id == selected_prompt_id)
    {
        Some(mode) => mode.clone(),
        None => {
            debug!(
                "Post-processing skipped because prompt '{}' was not found",
                selected_prompt_id
            );
            return None;
        }
    };

    let resolved = crate::settings::resolve_mode_provider(settings, &mode);
    let global = settings
        .active_post_process_provider()
        .cloned()
        .and_then(|provider| {
            let model = settings.post_process_models.get(&provider.id).cloned()?;
            Some((provider, model))
        });
```

Extraer el cuerpo actual (desde `let api_key = ...` hasta el final) a una función propia:

```rust
async fn run_post_process_with(
    settings: &AppSettings,
    provider: &PostProcessProvider,
    model: &str,
    prompt: &str,
    transcription: &str,
) -> Option<String> {
    // ... cuerpo actual, sin cambios de lógica ...
}
```

y dejar `post_process_transcription` como el orquestador:

```rust
    if let Some(resolved) = &resolved {
        if let Some(text) =
            run_post_process_with(settings, &resolved.provider, &resolved.model, &prompt, transcription).await
        {
            return Some(PostProcessOutcome { text, used_provider_id: resolved.provider.id.clone(), crossed_to_cloud: None });
        }
        warn!(
            "El proveedor '{}' del modo '{}' no pudo procesar; se reintenta con el general",
            resolved.provider.id, mode.name
        );
    }

    // Caída al general. Si el modo ya usaba el general, no hay nada que
    // reintentar: sería llamar dos veces al mismo proveedor caído.
    let (global_provider, global_model) = global?;
    if resolved.as_ref().is_some_and(|r| r.provider.id == global_provider.id) {
        return None;
    }

    let text = run_post_process_with(settings, &global_provider, &global_model, &prompt, transcription).await?;
    let crossed_to_cloud = crossing_to_report(
        resolved.as_ref().is_some_and(|r| r.is_local),
        crate::settings::provider_is_local(&global_provider),
        &mode.name,
        &global_provider.label,
    );
    Some(PostProcessOutcome { text, used_provider_id: global_provider.id, crossed_to_cloud })
```

Definir el tipo de retorno junto a `crossing_to_report`:

```rust
pub struct PostProcessOutcome {
    pub text: String,
    pub used_provider_id: String,
    pub crossed_to_cloud: Option<PostProcessFallback>,
}
```

- [ ] **Step 5: Emitir el aviso desde el llamador**

En el llamador (~línea 486), que ya tiene `app: &AppHandle`:

```rust
        if let Some(outcome) =
            post_process_transcription(&settings, &final_text, mode_override.as_deref()).await
        {
            if let Some(crossing) = outcome.crossed_to_cloud.clone() {
                use tauri_specta::Event as _;
                if let Err(e) = crossing.emit(app) {
                    warn!("No se pudo avisar del cruce a la nube: {}", e);
                }
            }
            let processed_text = outcome.text;
            // ... resto igual que hoy ...
```

- [ ] **Step 6: Registrar el evento**

En `src-tauri/src/lib.rs`, dentro de `collect_events![...]`, agregar:

```rust
            actions::PostProcessFallback,
```

- [ ] **Step 7: Verificar**

Run: `cd src-tauri && cargo test --lib && cargo clippy --all-targets 2>&1 | grep -A3 '^warning: [a-z]' | grep '\-\->' | sort -u`
Expected: todos los tests PASS; la lista de archivos con warnings no incluye `actions.rs` ni `settings.rs`.

- [ ] **Step 8: Regenerar bindings y commitear**

```bash
cd src-tauri && cargo build && ./target/debug/dilo --list-devices >/dev/null 2>&1; cd ..
cargo fmt --manifest-path src-tauri/Cargo.toml
git add src-tauri/src/actions.rs src-tauri/src/lib.rs src/bindings.ts
git commit -m "feat(modos): si el proveedor de un modo falla, procesa el general

El dictado casi nunca sale sin procesar. Pero cuando esa caída manda a la nube
un texto que el modo quería resolver en el equipo, se avisa: quien puso un modo
en local casi siempre lo hizo por privacidad, y enterarse tarde es mejor que no
enterarse."
```

---

### Task 4: Comando para guardar el proveedor de un modo

**Files:**

- Modify: `src-tauri/src/shortcut/mod.rs` (junto a `update_post_process_prompt` ~1164)
- Modify: `src-tauri/src/lib.rs` (`collect_commands![...]`, junto a `add_post_process_prompt`)

**Interfaces:**

- Produces: comando `set_post_process_prompt_provider(id: String, provider_id: Option<String>, model: Option<String>)` → binding `commands.setPostProcessPromptProvider(id, providerId, model)`.

- [ ] **Step 1: Implementar el comando**

```rust
/// Guarda el proveedor/modelo propio de un modo. `None` en `provider_id`
/// devuelve el modo a heredar el proveedor general.
#[tauri::command]
#[specta::specta]
pub fn set_post_process_prompt_provider(
    app: AppHandle,
    id: String,
    provider_id: Option<String>,
    model: Option<String>,
) -> Result<(), String> {
    let mut settings = settings::get_settings(&app);

    if let Some(provider_id) = provider_id.as_deref() {
        validate_provider_exists(&settings, provider_id)?;
    }

    match settings
        .post_process_prompts
        .iter_mut()
        .find(|p| p.id == id)
    {
        Some(prompt) => {
            // Heredar el general implica soltar también el modelo propio: un
            // modelo sin proveedor no significa nada.
            if provider_id.is_none() {
                prompt.model = None;
            } else {
                prompt.model = model;
            }
            prompt.provider_id = provider_id;
            settings::write_settings(&app, settings);
            Ok(())
        }
        None => Err(format!("Prompt with id '{}' not found", id)),
    }
}
```

- [ ] **Step 2: Registrar en `lib.rs`**

En `collect_commands![...]`, inmediatamente después de la línea 622
(`shortcut::update_post_process_prompt,`):

```rust
            shortcut::set_post_process_prompt_provider,
```

- [ ] **Step 3: Verificar que compila y que el binding sale**

```bash
cd src-tauri && cargo build && ./target/debug/dilo --list-devices >/dev/null 2>&1; cd ..
grep -n "setPostProcessPromptProvider" src/bindings.ts
```

Expected: la función aparece en `src/bindings.ts`.

- [ ] **Step 4: Commit**

```bash
cargo fmt --manifest-path src-tauri/Cargo.toml
git add src-tauri/src/shortcut/mod.rs src-tauri/src/lib.rs src/bindings.ts
git commit -m "feat(modos): comando para fijar el proveedor propio de un modo

Volver a 'general' borra también el modelo propio: un modelo sin proveedor no
significa nada y quedaría como basura en el settings."
```

---

### Task 5: Bloque "IA de este modo" en la UI

**Files:**

- Create: `src/components/settings/post-processing/ModeProviderSelect.tsx`
- Modify: `src/components/settings/post-processing/PostProcessingSettings.tsx` (junto a `<ModeShortcutInput ... />`, ~línea 328)

**Interfaces:**

- Consumes: `commands.setPostProcessPromptProvider` (Task 4), `settings.post_process_providers[].is_local` (Task 1), `LLMPrompt.provider_id/model` (Task 2).
- Produces: `<ModeProviderSelect promptId providerId model />`.

- [ ] **Step 1: Crear el componente**

```tsx
import React, { useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { Cloud, Laptop } from "lucide-react";
import { toast } from "sonner";
import { commands } from "@/bindings";
import { Dropdown } from "../../ui/Dropdown";
import { useSettings } from "../../../hooks/useSettings";

type Scope = "general" | "local" | "online";

interface ModeProviderSelectProps {
  promptId: string;
  providerId: string | null;
  model: string | null;
}

export const ModeProviderSelect: React.FC<ModeProviderSelectProps> = ({
  promptId,
  providerId,
  model,
}) => {
  const { t } = useTranslation();
  const { settings, refreshSettings } = useSettings();
  const providers = settings?.post_process_providers ?? [];

  const current = providers.find((p) => p.id === providerId) ?? null;
  const [scope, setScope] = useState<Scope>(
    providerId === null ? "general" : current?.is_local ? "local" : "online",
  );

  const globalProvider = providers.find(
    (p) => p.id === settings?.post_process_provider_id,
  );

  const options = useMemo(
    () =>
      providers
        .filter((p) => (scope === "local" ? p.is_local : !p.is_local))
        .map((p) => ({ value: p.id, label: p.label })),
    [providers, scope],
  );

  const save = async (
    nextProviderId: string | null,
    nextModel: string | null,
  ) => {
    const result = await commands.setPostProcessPromptProvider(
      promptId,
      nextProviderId,
      nextModel,
    );
    if (result.status === "error") {
      toast.error(t("settings.postProcessing.modeProvider.saveFailed"), {
        description: result.error,
      });
      return;
    }
    await refreshSettings();
  };

  const handleScope = async (next: Scope) => {
    setScope(next);
    if (next === "general") {
      await save(null, null);
      return;
    }
    // Al cambiar de lado, se preselecciona el primero de ese lado para que el
    // bloque nunca quede en un estado a medias.
    const first = providers.find((p) =>
      next === "local" ? p.is_local : !p.is_local,
    );
    if (first) await save(first.id, null);
  };

  return (
    <div className="space-y-2">
      <label className="text-sm font-semibold">
        {t("settings.postProcessing.modeProvider.label")}
      </label>

      <div className="flex gap-1 rounded-lg bg-text/[0.04] p-1 w-fit">
        {(["general", "local", "online"] as const).map((option) => (
          <button
            key={option}
            type="button"
            onClick={() => void handleScope(option)}
            className={`rounded-md px-3 py-1 text-xs font-medium transition-colors cursor-pointer ${
              scope === option
                ? "bg-logo-primary/20 text-text"
                : "text-muted-text hover:text-text"
            }`}
          >
            {t(`settings.postProcessing.modeProvider.scope.${option}`)}
          </button>
        ))}
      </div>

      {scope === "general" ? (
        <p className="text-xs text-muted-text">
          {t("settings.postProcessing.modeProvider.inherits", {
            provider: globalProvider?.label ?? "—",
          })}
        </p>
      ) : (
        <div className="space-y-2">
          <Dropdown
            options={options}
            selectedValue={providerId ?? ""}
            onSelect={(value) => void save(value, null)}
          />
          <p className="inline-flex items-center gap-1.5 text-xs text-muted-text">
            {scope === "local" ? (
              <Laptop className="size-3.5" />
            ) : (
              <Cloud className="size-3.5" />
            )}
            {t(`settings.postProcessing.modeProvider.hint.${scope}`)}
          </p>
          {model && (
            <p className="text-xs text-muted-text">
              {t("settings.postProcessing.modeProvider.model", { model })}
            </p>
          )}
          {/* Aviso, no bloqueo: el modo queda configurado igual y el usuario
              decide cuándo ir a poner la clave. Apple Intelligence no lleva
              clave, así que se excluye del chequeo. */}
          {providerId !== null &&
            providerId !== "apple_intelligence" &&
            !(settings?.post_process_api_keys?.[providerId] ?? "").trim() && (
              <p className="text-xs text-warning-text">
                {t("settings.postProcessing.modeProvider.missingKey")}
              </p>
            )}
        </div>
      )}
    </div>
  );
};
```

- [ ] **Step 2: Montarlo junto al atajo**

En `PostProcessingSettings.tsx`, inmediatamente después del `<ModeShortcutInput ... />`:

```tsx
<ModeProviderSelect
  promptId={selectedPrompt.id}
  providerId={selectedPrompt.provider_id}
  model={selectedPrompt.model}
/>
```

y su import arriba: `import { ModeProviderSelect } from "./ModeProviderSelect";`

- [ ] **Step 3: Verificar que compila**

Run: `bun run build && bun run lint`
Expected: ambos limpios. (Las claves i18n todavía no existen: se ven como la clave cruda en pantalla hasta la Task 7. No es error de build.)

- [ ] **Step 4: Commit**

```bash
bun run format:frontend
git add src/components/settings/post-processing/
git commit -m "feat(modos): elegir la IA de cada modo desde su panel

Primero local u online, después cuál: la decisión de privacidad va antes que la
de proveedor, porque es la que el usuario necesita ver de un vistazo."
```

---

### Task 6: Etiqueta LOCAL/ONLINE en Inicio y aviso de caída

**Files:**

- Modify: `src/components/home/DictationModes.tsx`
- Modify: `src/App.tsx` (junto al listener de `recording-error`, ~línea 118)

**Interfaces:**

- Consumes: `events.postProcessFallback` (Task 3), `is_local` (Task 1).

- [ ] **Step 1: Etiqueta por modo en Inicio**

Los ítems de la lista `modes` (`DictationModes.tsx` ~línea 83) tienen
`promptId: string | null`. El primero es "literal", que **no usa IA** y por lo
tanto no lleva etiqueta — de ahí el `promptId === null` del guard.

Agregar el helper antes del `return` del componente:

```tsx
const providerBadgeFor = (promptId: string | null) => {
  if (promptId === null) return null; // "literal" no pasa por IA
  const prompt = prompts.find((p) => p.id === promptId);
  const providerId = prompt?.provider_id ?? settings.post_process_provider_id;
  const provider = settings.post_process_providers.find(
    (p) => p.id === providerId,
  );
  if (!provider) return null;
  return provider.is_local
    ? t("settings.postProcessing.modeProvider.badgeLocal")
    : t("settings.postProcessing.modeProvider.badgeOnline");
};
```

y usarlo dentro de la tarjeta de cada modo, junto al nombre:

```tsx
{
  providerBadgeFor(mode.promptId) && (
    <span className="ml-2 rounded-full bg-text/[0.06] px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-muted-text">
      {providerBadgeFor(mode.promptId)}
    </span>
  );
}
```

- [ ] **Step 2: Toast del cruce a la nube**

En `src/App.tsx`, junto al listener existente de `recording-error`:

```tsx
useEffect(() => {
  const unlisten = events.postProcessFallback.listen((event) => {
    const { mode_name, provider_label } = event.payload;
    toast.info(
      t("settings.postProcessing.modeProvider.fallbackNotice", {
        mode: mode_name,
        provider: provider_label,
      }),
    );
  });
  return () => {
    void unlisten.then((fn) => fn());
  };
}, [t]);
```

Asegurarse de que `events` esté importado desde `@/bindings` en ese archivo.

- [ ] **Step 3: Verificar**

Run: `bun run build && bun run lint`
Expected: limpios.

- [ ] **Step 4: Commit**

```bash
bun run format:frontend
git add src/App.tsx src/components/home/DictationModes.tsx
git commit -m "feat(modos): mostrar cuáles modos salen del computador

La etiqueta en Inicio responde de un vistazo qué modos mandan tu texto afuera, y
el aviso aparece cuando una caída al proveedor general cruzó esa línea."
```

---

### Task 7: Copy en 21 idiomas

**Files:**

- Modify: `src/i18n/locales/{es,en}/translation.json` (a mano)
- Modify: los otros 19 locales

**Interfaces:**

- Consumes: las claves usadas en Tasks 5 y 6.

- [ ] **Step 1: Escribir `es` a mano (tuteo chileno)**

Bajo `settings.postProcessing`, agregar el objeto `modeProvider`:

```json
"modeProvider": {
  "label": "IA de este modo",
  "scope": { "general": "General", "local": "Local", "online": "Online" },
  "inherits": "Usa el proveedor general: {{provider}}.",
  "hint": {
    "local": "Corre en tu computador. El texto no sale de acá.",
    "online": "El texto viaja al servidor del proveedor."
  },
  "model": "Modelo: {{model}}",
  "badgeLocal": "Local",
  "badgeOnline": "Online",
  "missingKey": "A este proveedor le falta la clave de API. Ponla en la pestaña de API para que el modo funcione.",
  "saveFailed": "No se pudo guardar la IA de este modo",
  "fallbackNotice": "{{mode}} se procesó con {{provider}} porque su IA local no respondió."
}
```

- [ ] **Step 2: Escribir `en`**

```json
"modeProvider": {
  "label": "This mode's AI",
  "scope": { "general": "General", "local": "Local", "online": "Online" },
  "inherits": "Uses the general provider: {{provider}}.",
  "hint": {
    "local": "Runs on your computer. The text never leaves it.",
    "online": "The text travels to the provider's server."
  },
  "model": "Model: {{model}}",
  "badgeLocal": "Local",
  "badgeOnline": "Online",
  "missingKey": "This provider has no API key yet. Add it in the API tab so the mode works.",
  "saveFailed": "Couldn't save this mode's AI",
  "fallbackNotice": "{{mode}} was processed with {{provider}} because its local AI didn't respond."
}
```

- [ ] **Step 3: Completar los 19 restantes**

Traducir el mismo bloque en `ar, bg, cs, de, fr, he, it, ja, ko, ne, nl, pl, pt, ru, sv, tr, uk, vi, zh, zh-TW`, respetando los placeholders `{{provider}}`, `{{model}}` y `{{mode}}` exactamente como están.

- [ ] **Step 4: Verificar el gate**

Run: `bun run check:translations`
Expected: `✓ All 21 languages have complete translations!`

- [ ] **Step 5: Revisar que el `es` no se haya ido a voseo**

```bash
grep -nE "\b(mirá|ponele|elegí|tenés|querés|podés|hacé|fijate|guardá|probá|escribí)\b" src/i18n/locales/es/translation.json
```

Expected: sin resultados.

- [ ] **Step 6: Commit**

```bash
bun run format:frontend
git add src/i18n/locales
git commit -m "i18n: copy de la IA por modo en los 21 idiomas"
```

---

### Task 8: Verificación visual y cierre

**Files:**

- Ninguno nuevo. Usa el andamio de preview del worktree del notetaker como referencia (`.superpowers/preview/`, gitignored).

- [ ] **Step 1: Mirar el bloque en el navegador**

Levantar Vite apuntando a un preview que renderice `ModeProviderSelect` con `@/bindings` mockeado (proveedores de ejemplo: uno local, dos online), y revisar en claro y oscuro que el segmentado, el desplegable y la línea de ayuda se lean bien.

Run: `./node_modules/.bin/vite --config .superpowers/preview/vite.config.ts --port 1427`

- [ ] **Step 2: Correr toda la verificación**

```bash
cd src-tauri && cargo fmt --check && cargo clippy --all-targets && cargo test --lib && cd ..
bun run build && bun run lint && bun run check:translations
```

Expected: todo verde; los warnings de clippy sólo en los archivos preexistentes (`recorder.rs`, `gguf_meta.rs`, `transcription.rs`, `portable.rs`, `transcription_coordinator.rs`).

- [ ] **Step 3: Prueba en vivo (Alfonso)**

Del spec, sección Verificación:

1. Modo Código con Gemini y modo Limpio con Apple Intelligence; dictar con los dos seguidos → cada uno llama al suyo.
2. Un modo sin proveedor propio sigue usando el general.
3. Modo Código apuntando a Ollama con Ollama apagado → sale procesado por el general + aviso de cruce.
4. Las etiquetas LOCAL/ONLINE de Inicio coinciden con lo configurado.

- [ ] **Step 4: Actualizar el spec con lo aprendido**

Si algo se apartó del diseño, anotarlo al final del spec (`docs/superpowers/specs/2026-07-29-proveedor-por-modo-design.md`) antes de mergear, para que el documento siga describiendo lo que existe.

---

## Notas de riesgo

- **`post_process_providers` se persiste en settings.** Por eso `is_local` va con `#[serde(default)]` y se recalcula al cargar: un archivo viejo no trae el campo, y uno viejo con `custom` remoto no debe quedar marcado como local.
- **El orden de resolución cambia en `actions.rs`** (prompt antes que proveedor). Es el único cambio estructural en un archivo compartido con upstream; mantenerlo acotado a mover bloques, sin reescribir el cuerpo de la llamada al LLM.
- **Apple Intelligence no existe fuera de macOS ARM.** Un settings con un modo apuntando a `apple_intelligence` abierto en Linux resuelve a "proveedor inexistente" → cae al general, que es el comportamiento correcto y ya está cubierto por el test de proveedor borrado.
