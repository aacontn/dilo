# Motor Gemini 3.5 Transcribe (fase 1, dictado) — Plan de implementación

> **Para agentes:** SUB-SKILL REQUERIDA: usar superpowers:subagent-driven-development (recomendado) o superpowers:executing-plans para implementar tarea por tarea. Los pasos usan casillas (`- [ ]`) para seguimiento.

**Objetivo:** que "Gemini 3.5 Transcribe" aparezca como motor de dictado EN LÍNEA en el selector, transcriba por la Interactions API con modo smart, y caiga a un modelo local con aviso cuando falle.

**Arquitectura:** un `EngineType::GeminiTranscribe` con `ModelSource::Cloud` (sin descarga) en el catálogo; un cliente `gemini_stt.rs` de funciones puras + una async (espejo de `llm_client.rs`); el despacho en `TranscriptionManager::transcribe` con `tauri::async_runtime::block_on`, y una caída pura y testeable al último modelo local usado.

**Stack:** Rust (reqwest, serde_json — ya en deps; **sin dependencias nuevas**), React/TS, tauri-specta.

**Spec:** `docs/superpowers/specs/2026-08-27-motor-gemini-transcribe-design.md` — el plan argumenta desde ahí; leer ambos.

## Restricciones globales

- **Sin dependencias nuevas** en Cargo.toml ni package.json.
- **Cómo compilar en esta máquina:** 16 GB, se ha congelado por compilaciones. **Un solo comando cargo a la vez, nunca en paralelo ni de fondo. NO `tauri dev`, NO `--release`, NO clippy local** (clippy es de CI). Agrupar por tarea: todos los cambios Rust de la tarea y al final UNA cadena `cargo build && cargo test --lib`. Los gates de bun son livianos y van cuando sea. La verificación final es de CI (`test.yml` en push).
- **Copia es-first en tuteo chileno, NUNCA voseo** ("puedes", no "podés"). Toda clave i18n nueva en los 21 idiomas con traducción real (el gate `check:translations` sólo mira que exista la clave).
- **`src/bindings.ts` es generado, nunca a mano**: desde `src-tauri/`, `cargo build && ./target/debug/dilo --list-devices` (cuenta como el build de la tarea).
- **Un `settings.json` existente carga sin pérdidas**: todo campo nuevo de `AppSettings` lleva `#[serde(default…)]`.
- **NUNCA `Co-Authored-By` ni atribución de IA en commits.** Prefijos convencionales, mensaje enfocado en el porqué.
- **La API key jamás se loguea ni se serializa en claro en logs/eventos** (el `SecretMap` ya redacta el Debug; mantenerlo).
- Reglas de protocolo del spec que los tests deben fijar: **nunca `language_codes` en `transcription_config`**; auth por header `x-goog-api-key`, nunca query string.

---

## Estructura de archivos

| Archivo                                          | Responsabilidad                                                            | Tarea |
| ------------------------------------------------ | -------------------------------------------------------------------------- | ----- |
| `src-tauri/src/managers/model.rs`                | `ModelSource::Cloud`, `EngineType::GeminiTranscribe`, entrada de catálogo   | 1     |
| `src-tauri/src/gemini_stt.rs` (nuevo)            | WAV, cuerpo del request, parser, clasificación de errores, llamada async    | 2     |
| `src-tauri/src/lib.rs`                           | Declarar `gemini_stt`; registrar evento `GeminiFallback` en `collect_events!` | 2, 4  |
| `src-tauri/src/settings.rs`                      | `gemini_smart_mode`, `last_local_model_id`                                  | 3, 4  |
| `src-tauri/src/managers/transcription.rs`        | Variante `LoadedEngine`, despacho, salto de muletillas, caída               | 3, 4  |
| `src/components/model-selector/ModelDropdown.tsx`| Los modelos Cloud cuentan como disponibles                                  | 5     |
| `src/components/model-selector/ModelStatusButton.tsx` | Badge EN LÍNEA, estado de key, sin botón de descarga                   | 5     |
| `src/components/settings/GeminiSmartToggle.tsx` (nuevo) | Toggle smart/verbatim                                                | 5     |
| `src/hooks/useSettings.ts` + stores              | Ajustes nuevos y toast de caída                                             | 4, 5  |
| `src/i18n/locales/*/translation.json`            | Claves nuevas, 21 idiomas                                                   | 5     |

### Task 1: Catálogo — el motor cloud existe

**Files:**
- Modify: `src-tauri/src/managers/model.rs` (enums ~línea 26-57; entrada de catálogo junto a Cohere, ~línea 1268)

**Interfaces:**
- Produces: `EngineType::GeminiTranscribe`, `ModelSource::Cloud`, id de modelo `"gemini-3.5-transcribe"` (constante `GEMINI_STT_MODEL_ID` pública). `ModelInfo` para ese id con `is_downloaded: true`, `size_mb: 0`, `supports_language_detection: true`, `supports_language_selection: false`, `supports_token_timestamps: false`, `supports_streaming: false`.

- [ ] **Paso 1: test que falla** — en el `mod tests` de `model.rs`:

```rust
#[test]
fn gemini_cloud_model_is_always_available_and_auto_language_only() {
    let models = ModelManager::builtin_models_for_test();
    let g = models.get(GEMINI_STT_MODEL_ID).expect("gemini en el catálogo");
    assert!(matches!(g.source, ModelSource::Cloud));
    assert!(g.is_downloaded, "un motor cloud nunca 'se descarga'");
    assert_eq!(g.size_mb, 0);
    assert!(g.supports_language_detection);
    assert!(!g.supports_language_selection); // language_codes mata smart — spec §3
    assert!(!g.supports_token_timestamps); // reuniones quedan fuera
    assert!(!g.supports_streaming);
}
```

Si no existe un constructor de prueba del catálogo, extraer la tabla a una función asociada que el test pueda llamar sin `AppHandle` (mismo patrón que ya usan los tests de `effective_language`).

- [ ] **Paso 2: correr y ver fallar** — anotar el error de compilación esperado (`GEMINI_STT_MODEL_ID` no existe). NO compilar todavía: escribir también el paso 3 y compilar una sola vez.
- [ ] **Paso 3: implementación mínima** — `ModelSource::Cloud` (variante sin campos), `EngineType::GeminiTranscribe`, `pub const GEMINI_STT_MODEL_ID: &str = "gemini-3.5-transcribe";` y la entrada de catálogo (nombre "Gemini 3.5 Transcribe", descripción es-first vía el mecanismo existente, `accuracy_score: 0.97`, `speed_score: 0.85`, idiomas: lista vacía + detección automática — revisar cómo el selector trata `supported_languages` vacío con `supports_language_detection: true`; si la UI exige al menos un idioma, poner `vec!["es","en"]` y documentarlo en el código). Actualizar TODO `match` sobre `ModelSource`/`EngineType` que el compilador reclame: descarga = no-op para `Cloud`, borrado = no-op, `DiskStatus` = siempre descargado.
- [ ] **Paso 4: compilar y testear (una sola cadena):** `cd src-tauri && cargo build && cargo test --lib model` → PASS, y regenerar bindings: `./target/debug/dilo --list-devices`.
- [ ] **Paso 5: commit** — `feat(dictado): Gemini 3.5 Transcribe existe como motor cloud del catálogo`

### Task 2: Cliente `gemini_stt.rs` — funciones puras + llamada

**Files:**
- Create: `src-tauri/src/gemini_stt.rs`
- Modify: `src-tauri/src/lib.rs` (declarar `pub mod gemini_stt;`)

**Interfaces:**
- Produces:
  - `pub fn encode_wav_16k_mono(samples: &[f32]) -> Vec<u8>`
  - `pub fn build_interactions_body(smart: bool, custom_vocabulary: &[String], wav_b64: &str) -> serde_json::Value`
  - `pub fn parse_interactions_response(body: &str) -> Result<String, GeminiSttError>`
  - `pub fn classify_failure(status: u16, body: &str) -> GeminiSttError`
  - `pub enum GeminiSttError { MissingKey, InvalidKey(String), Offline, Timeout, DailyQuota, Transient(String), BadRequest(String) }` (con `Display`)
  - `pub async fn transcribe(samples: &[f32], api_key: &str, smart: bool, custom_vocabulary: &[String]) -> Result<String, GeminiSttError>`

- [ ] **Paso 1: tests que fallan** (todos puros, sin red):

```rust
#[test]
fn wav_header_is_16k_mono_pcm16() {
    let wav = encode_wav_16k_mono(&[0.0f32; 1600]); // 100 ms
    assert_eq!(&wav[0..4], b"RIFF");
    assert_eq!(&wav[8..12], b"WAVE");
    assert_eq!(u32::from_le_bytes(wav[24..28].try_into().unwrap()), 16_000);
    assert_eq!(u16::from_le_bytes(wav[22..24].try_into().unwrap()), 1);
    assert_eq!(wav.len(), 44 + 1600 * 2);
}

#[test]
fn smart_body_never_carries_language_codes() {
    let body = build_interactions_body(true, &["Dilo".into()], "QUJD");
    let config = &body["generation_config"]["transcription_config"];
    assert_eq!(config["mode"], "smart");
    assert_eq!(config["custom_vocabulary"][0], "Dilo");
    assert!(config.get("language_codes").is_none(), "language_codes desactiva smart en silencio");
    assert_eq!(body["model"], GEMINI_STT_MODEL_ID);
    assert_eq!(body["input"][0]["mime_type"], "audio/wav");
}

#[test]
fn verbatim_without_vocabulary_omits_generation_config() {
    let body = build_interactions_body(false, &[], "QUJD");
    assert!(body.get("generation_config").is_none(), "verbatim es el default del servidor");
}

#[test]
fn parses_interactions_envelope_and_empty_text_is_ok() {
    let ok = r#"{"status":"completed","steps":[{"type":"model_output","content":[{"type":"text","text":"hola"}]}]}"#;
    assert_eq!(parse_interactions_response(ok).unwrap(), "hola");
    let silencio = r#"{"status":"completed","steps":[]}"#;
    assert_eq!(parse_interactions_response(silencio).unwrap(), ""); // el silencio no es error
}

#[test]
fn classifies_the_failures_the_spec_names() {
    assert!(matches!(classify_failure(400, r#"{"error":{"message":"API key not valid. API_KEY_INVALID"}}"#), GeminiSttError::InvalidKey(_)));
    assert!(matches!(classify_failure(429, r#"{"error":{"details":[{"quotaId":"GenerateRequestsPerDayPerProjectPerModel"}]}}"#), GeminiSttError::DailyQuota));
    assert!(matches!(classify_failure(429, "{}"), GeminiSttError::Transient(_)));
    assert!(matches!(classify_failure(503, ""), GeminiSttError::Transient(_)));
    // el envelope de error de interactions puede venir envuelto en array — spec §3
    assert!(matches!(classify_failure(400, r#"[{"error":{"message":"API key not valid"}}]"#), GeminiSttError::InvalidKey(_)));
}
```

- [ ] **Paso 2: implementación.** WAV: f32 → i16 con clamp a [-1,1], header de 44 bytes little-endian. Cuerpo: exactamente el JSON del spec §2. Parser: filtrar `steps[].type == "model_output"`, concatenar `content[].type == "text"`. `classify_failure`: 400 con "API_KEY_INVALID"/"key not valid" → `InvalidKey` (¡no 401!); 429 con `PerDay` en el body → `DailyQuota`, si no `Transient`; 5xx → `Transient`; otro 400 → `BadRequest`. `transcribe`: `reqwest::Client` con timeout total de 45 s, `POST https://generativelanguage.googleapis.com/v1beta/interactions`, header `x-goog-api-key` (constante privada del endpoint; NUNCA en la URL), errores de red → `Offline` si `is_connect()`/`is_timeout()` los distingue (timeout → `Timeout`). En 429 `Transient` con `retryDelay ≤ 8 s` en el body, dormir una vez y reintentar una sola vez (flag interno, mismo patrón que Jot).
- [ ] **Paso 3: compilar y testear:** `cd src-tauri && cargo build && cargo test --lib gemini_stt` → PASS.
- [ ] **Paso 4: commit** — `feat(dictado): cliente Interactions de Gemini con las trampas del protocolo fijadas en tests`

### Task 3: Despacho en TranscriptionManager + salto de muletillas

**Files:**
- Modify: `src-tauri/src/managers/transcription.rs` (variante en `LoadedEngine` ~línea 274; carga ~787; despacho dentro de `transcribe()` ~1519; post-proceso: la función libre que recibe `custom_words_already_prompted`, ~línea 2030)
- Modify: `src-tauri/src/settings.rs` (`gemini_smart_mode: bool`, `#[serde(default = "default_true")]`)

**Interfaces:**
- Consumes: `gemini_stt::transcribe`, `GeminiSttError`, `EngineType::GeminiTranscribe`.
- Produces: `LoadedEngine::GeminiTranscribe` (variante sin datos); la señal interna `smart_cleanup_done: bool` que el post-proceso usa para saltarse `filter_transcription_output`.

- [ ] **Paso 1: test que falla** — el salto de muletillas es lo testeable puro. Extraer la decisión a una función:

```rust
/// Con smart activo Google ya sacó las muletillas; limpiar dos veces muerde texto bueno.
pub(crate) fn should_skip_filler_filter(engine: &EngineType, smart_mode: bool) -> bool { … }

#[test]
fn smart_gemini_skips_local_filler_filter_but_verbatim_does_not() {
    assert!(should_skip_filler_filter(&EngineType::GeminiTranscribe, true));
    assert!(!should_skip_filler_filter(&EngineType::GeminiTranscribe, false));
    assert!(!should_skip_filler_filter(&EngineType::Parakeet, true));
}
```

- [ ] **Paso 2: implementación.** (a) `LoadedEngine::GeminiTranscribe`: en la carga (~787) esa rama no lee disco — valida que `post_process_api_keys["google"]` no esté vacía (si lo está, `Err` con mensaje que la UI ya sabe mostrar) y guarda la variante. (b) En `transcribe()`: rama para la variante ANTES del camino local — `tauri::async_runtime::block_on(gemini_stt::transcribe(&audio, &key, settings.gemini_smart_mode, &settings.custom_words))` (mismo patrón `block_on` que `actions.rs:1444`). La key se lee al momento del uso, nunca se guarda en la variante. (c) `apply_custom_words` local sigue corriendo (es inofensivo y cubre lo que el biasing no pilló); `filter_transcription_output` se salta cuando `should_skip_filler_filter`. (d) `custom_words` viajan también como `custom_vocabulary` (biasing en origen).
- [ ] **Paso 3: compilar y testear:** `cd src-tauri && cargo build && cargo test --lib transcription && ./target/debug/dilo --list-devices` (bindings: cambió `AppSettings`).
- [ ] **Paso 4: commit** — `feat(dictado): Gemini transcribe de verdad — smart salta el filtro local de muletillas`

### Task 4: Caída a local con aviso después del hecho

**Files:**
- Modify: `src-tauri/src/settings.rs` (`last_local_model_id: Option<String>`, `#[serde(default)]`)
- Modify: `src-tauri/src/managers/transcription.rs` (resolver + camino de error)
- Modify: `src-tauri/src/lib.rs` (evento en `collect_events!`)
- Modify: `src/hooks/useSettings.ts` o el hook de eventos equivalente (toast)

**Interfaces:**
- Consumes: `GeminiSttError`, `ModelInfo`.
- Produces: `pub(crate) fn resolve_local_fallback(last_local: Option<&str>, models: &[ModelInfo]) -> Option<String>`; evento `GeminiFallback { fallback_model: String, reason: String }` (tauri-specta, snake_case como los demás).

- [ ] **Paso 1: tests que fallan:**

```rust
#[test]
fn fallback_prefers_last_local_then_any_downloaded_local_never_cloud() {
    let cohere = model_info_stub("cohere", /*downloaded*/ true, /*cloud*/ false);
    let gemini = model_info_stub("gemini-3.5-transcribe", true, true);
    let parakeet = model_info_stub("parakeet-v3", false, false); // no descargado
    assert_eq!(resolve_local_fallback(Some("cohere"), &[gemini.clone(), cohere.clone()]), Some("cohere".into()));
    // el último local ya no está descargado → cualquier local descargado
    assert_eq!(resolve_local_fallback(Some("parakeet-v3"), &[parakeet, cohere.clone(), gemini.clone()]), Some("cohere".into()));
    // sin ningún local descargado → None (el aviso lo dice; el dictado va al historial)
    assert_eq!(resolve_local_fallback(None, &[gemini]), None);
}
```

(`model_info_stub` es un helper del test que arma un `ModelInfo` mínimo.)

- [ ] **Paso 2: implementación.** (a) `last_local_model_id` se persiste donde se cambia `selected_model` (el comando de settings), sólo cuando el modelo elegido NO es `ModelSource::Cloud`. (b) En la rama Gemini de `transcribe()`, todo `Err` no-`BadRequest` resuelve la caída: cargar el modelo local (el camino de carga existente, esperando el condvar), transcribir con él, y emitir `GeminiFallback { fallback_model: <nombre visible>, reason: <Display del error> }`. `BadRequest` no cae (request malformado: reintentar con otro motor no arregla nada y esconde el bug). (c) Frontend: listener del evento → toast con la clave i18n `gemini.fallback_notice` — *"Se transcribió con {{model}} porque Gemini no respondió"* — y variante `gemini.fallback_none` cuando `resolve_local_fallback` dio `None` y el error sube.
- [ ] **Paso 3: compilar y testear:** `cd src-tauri && cargo build && cargo test --lib && ./target/debug/dilo --list-devices`. Gates de bun: `bun run lint && bun run format:check`.
- [ ] **Paso 4: commit** — `feat(dictado): si Gemini falla, cae al último modelo local y avisa después del hecho`

### Task 5: UI — tarjeta EN LÍNEA, key, toggle smart, idioma Auto

**Files:**
- Modify: `src/components/model-selector/ModelDropdown.tsx` (línea 21: `is_downloaded` ya deja pasar a Cloud; verificar orden/agrupación)
- Modify: `src/components/model-selector/ModelStatusButton.tsx` (sin botón descargar/eliminar para Cloud; badge)
- Create: `src/components/settings/GeminiSmartToggle.tsx` (patrón de `AudioFeedback.tsx`: un toggle sobre `gemini_smart_mode`)
- Modify: `src/components/settings/LanguageSelector.tsx` (con `supports_language_selection: false` + detección, sólo "Auto" — verificar que ya lo hace; si no, ajustar)
- Modify: `src/i18n/locales/*/translation.json` (21 idiomas)

**Interfaces:**
- Consumes: `ModelInfo.source` (los bindings ya exponen la variante `Cloud` tras la Task 1), `gemini_smart_mode` del store de settings.

- [ ] **Paso 1: recorrido de las claves nuevas** (es primero, redacción propia; el resto traducción real): `models.online_badge` ("EN LÍNEA"), `models.gemini_requires_key` ("Necesita tu API key de Google AI Studio — configúrala en Claves"), `models.gemini_privacy` ("El audio de tu dictado se envía a Google"), `gemini.smart_label`/`gemini.smart_description` (toggle), `gemini.fallback_notice`, `gemini.fallback_none`.
- [ ] **Paso 2: implementación** de los cuatro componentes. La tarjeta Cloud: badge + nota de privacidad + estado de key (¿hay key bajo `google`? el estado ya viaja en settings; si el frontend no puede saberlo sin exponer el valor, agregar en Task 5 un comando `has_google_api_key() -> bool` en `commands/` — nunca exponer el valor). Sin `DownloadProgressDisplay` ni `UnloadModelButton` para Cloud.
- [ ] **Paso 3: gates:** `bun run lint && bun run format:check && bun run build`. Si algún cambio Rust fue necesario (comando `has_google_api_key`): una sola cadena `cargo build && cargo test --lib && ./target/debug/dilo --list-devices`.
- [ ] **Paso 4: commit** — `feat(dictado): la tarjeta de Gemini dice EN LÍNEA, pide la key y no esconde adónde va el audio`

### Task 6: Cierre — verificación por CI y bitácora

- [ ] **Paso 1:** revisar que ninguna tarea tocó `AGENTS.md`/`CLAUDE.md` sin copiar (el test `agentInstructions.test.ts` lo vigila) y que no quedó `console.log`/`dbg!`.
- [ ] **Paso 2:** entrada nueva arriba en `docs/BITACORA-AGENTES.md` (hecho, próximo paso — probar en vivo con la key real y luego diseñar reuniones-en-línea —, cuidado, estado git).
- [ ] **Paso 3:** commit de la bitácora y **avisar a Alfonso para el push** (el push dispara `test.yml`; puede pedir además un build de prueba vía `test-macos-signing.yml` para probar el motor en vivo — los builds locales no sirven para eso y en esta máquina no se hacen).

## Autorrevisión del plan (hecha)

- Cobertura del spec: catálogo (§1→T1), cliente y trampas (§2-3→T2), caída (§4→T4), UI/privacidad (§5→T5), pruebas sin red (§6→T1-T4). El transporte de emergencia `:generateContent` queda documentado y sin tarea, como el spec manda (fase 1 no lo implementa).
- Tipos consistentes entre tareas (`GeminiSttError`, `GEMINI_STT_MODEL_ID`, `resolve_local_fallback`, `should_skip_filler_filter`).
- Sin placeholders: cada paso trae código o comando concreto.
