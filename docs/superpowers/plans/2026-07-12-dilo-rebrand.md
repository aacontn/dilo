# Dilo Rebrand & Remake — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convertir el fork de Handy v0.9.2 en **Dilo** — dictado offline es-first para vibe coders LATAM — con defaults livianos, reposo casi-cero de RAM, re-skin de marca, landing en Cloudflare Pages y release v0.1.0.

**Architecture:** Fork profundo con núcleo Rust intacto. Los cambios viven en 3 capas: (1) config/identidad (Tauri, Cargo, icons), (2) defaults + 2 cambios quirúrgicos de ciclo de vida de webviews en Rust, (3) piel/copy (CSS tokens, locale es, onboarding, README). Landing es un repo estático aparte.

**Tech Stack:** Tauri 2.10 / Rust · React 18 + TS + Tailwind v4 + i18next · Bun · GitHub Actions · Cloudflare Pages (wrangler).

## Global Constraints

- Paleta exacta: tinta `#0D1117` · mango `#FF9E1B` · menta `#2EE6A8` · rojo `#FF5C5C` · papel `#F7F2EA`.
- Tipos: Space Grotesk (display), Inter (texto), JetBrains Mono (mono) — **bundled woff2, jamás CDN** (la app es offline).
- Todo copy de usuario en español neutro-LATAM, tuteo, voz "compa dev" según spec (`docs/superpowers/specs/2026-07-12-dilo-rebrand-design.md` §Marca). Sin corporativismo.
- Atribución obligatoria: "Dilo es un fork con cariño de Handy (CJ Pais, MIT)" en README y footer de landing. LICENSE conserva el copyright de CJ Pais.
- Identifier `cl.espaciodigital.dilo` · binario/paquete `dilo` · versión `0.1.0`.
- El updater de Tauri queda **desactivado** en v0.1.0 (endpoints/pubkey upstream removidos; `default_update_checks_enabled() -> false`).
- Los 21 locales no-`es` no se tocan. ESLint prohíbe strings hardcodeados en JSX: todo texto nuevo entra por i18n (`en` + `es` como mínimo).
- Commits convencionales (`feat:`/`fix:`/`docs:`/`chore:`) + footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Verificación mínima por task: `bun run build` (tsc+vite) y, si tocó Rust, `cargo check` en `src-tauri/`. Antes del release: `bun run lint` + `bun run format:check` + `cargo fmt --check`.

---

## Fase A — Fork (repo `dilo/`)

### Task A1: Identidad técnica (config) + updater off

**Files:**

- Modify: `src-tauri/tauri.conf.json` (productName, identifier, plugins.updater, bundle.createUpdaterArtifacts)
- Modify: `src-tauri/Cargo.toml:1-9` (package name/description/authors/default-run) y `src-tauri/src/main.rs` si referencia `handy` como crate
- Modify: `package.json` (name `dilo`, version `0.1.0`), `src-tauri/tauri.conf.json` version `0.1.0`, `Cargo.toml` version `0.1.0`
- Modify: `src-tauri/src/lib.rs:804-806` (título ventana "Dilo")
- Modify: `src-tauri/src/settings.rs:499-501` (update checks default false)

**Interfaces:**

- Produces: crate/binario `dilo` (los workflows de la Task A9 y el CLI lo referencian), identifier `cl.espaciodigital.dilo`.

- [ ] **Paso 1: tauri.conf.json** — `productName: "Dilo"`, `identifier: "cl.espaciodigital.dilo"`, `version: "0.1.0"`; eliminar el bloque `plugins.updater` completo (pubkey+endpoints de cjpais); en `bundle`: `createUpdaterArtifacts: false`.
- [ ] **Paso 2: Cargo.toml** — `name = "dilo"`, `description = "Dilo — dictado por voz offline, en español"`, `authors = ["Alfonso Contreras", "cjpais"]`, `default-run = "dilo"`, `version = "0.1.0"`. Buscar `[[bin]]`/referencias al nombre viejo: `grep -rn "handy" src-tauri/Cargo.toml src-tauri/src/main.rs`.
- [ ] **Paso 3: lib.rs** — título de ventana `.title("Dilo")` (línea ~805). Grep de cortesía: `grep -rn '"Handy"' src-tauri/src/ | grep -v test` y renombrar strings de cara al usuario (tray tooltip, notificaciones). Los identificadores internos (`HANDY_NO_GTK_LAYER_SHELL`, structs) NO se tocan.
- [ ] **Paso 4: settings.rs** — `fn default_update_checks_enabled() -> bool { false }` con comentario `// v0.1.0 sin updater propio; reactivar al firmar releases`.
- [ ] **Paso 5: package.json** — `"name": "dilo"`, `"version": "0.1.0"`.
- [ ] **Paso 6: Verificar** — `bun install && bun run build` → PASS; `cd src-tauri && cargo check` → PASS (la 1ª vez compila C++ de transcribe-cpp, 5–15 min; es normal).
- [ ] **Paso 7: Commit** — `feat: rebrand técnico a Dilo (identifier, binario, updater off)`

### Task A2: Iconos y assets de marca

**Files:**

- Create: `brand/dilo-icon.svg` (fuente maestra: cuadrado redondeado tinta #0D1117, caret ámbar #FF9E1B centrado-izquierda, onda mínima de 3 barras menta #2EE6A8 abajo-derecha)
- Create: `brand/dilo-wordmark.svg` (`dilo▌` Space Grotesk semibold, caret mango)
- Modify: `src-tauri/icons/*` (regenerados), `src-tauri/resources/tray_*.png` y `recording.png`/`transcribing.png` (variantes tinta/mango/rojo del caret)

- [ ] **Paso 1:** Dibujar `brand/dilo-icon.svg` a mano (viewBox 1024, sin texto — solo caret+onda para legibilidad 16px).
- [ ] **Paso 2:** Exportar PNG 1024 con `rsvg-convert` o `qlmanage`/`sips` (macOS): `rsvg-convert -w 1024 brand/dilo-icon.svg -o /tmp/dilo-1024.png` (si no está rsvg: `brew install librsvg` o usar sips sobre un render). Luego `bun run tauri icon /tmp/dilo-1024.png` → regenera `src-tauri/icons/`.
- [ ] **Paso 3:** Tray icons: generar `tray_idle` (caret tinta/blanco según dark), `tray_recording` (caret rojo #FF5C5C), `tray_transcribing` (caret mango) en los mismos tamaños que los PNG existentes (verificar con `file src-tauri/resources/tray_*.png`).
- [ ] **Paso 4:** Verificar — `bun run tauri dev` levanta con icono nuevo en tray. Commit `feat: iconos y assets de marca Dilo`.

### Task A3: Defaults livianos + catálogo ES-first

**Files:**

- Modify: `src-tauri/src/settings.rs:135-145` (ModelUnloadTimeout default), `:521-527` (overlay default)
- Modify: `src-tauri/src/catalog/catalog.json` (recommended/ranks)

**Interfaces:**

- Produces: ranks nuevos que la UI de onboarding (A4) muestra tal cual.

- [ ] **Paso 1: settings.rs** — mover `#[default]` de `Min5` a `Min2` en `ModelUnloadTimeout`. En `fn default_overlay_style()`: retornar `OverlayStyle::Minimal` en todas las plataformas salvo Linux (mantener su `None` por el tema layer-shell).
- [ ] **Paso 2: catalog.json** — reordenar recomendados es-first: rank1 `nemotron-3.5-asr-streaming-0.6b` (streaming, 28 idiomas incl. es) · rank2 `canary-180m-flash` (218 MB) · rank3 `parakeet-tdt-0.6b-v3` (`recommended: true`) · rank4 `cohere-transcribe-03-2026` · rank5 `whisper-medium` · `parakeet-unified-en-0.6b` pasa a `recommended: false`, rank6 (sigue disponible, ya no es el default empujado).
- [ ] **Paso 3:** Verificar — `cargo check` PASS; `python3 -c "import json;json.load(open('src-tauri/src/catalog/catalog.json'))"` PASS; `cargo test` de settings si existe (`cargo test settings -- --nocapture`, esperar PASS o "0 tests").
- [ ] **Paso 4:** Commit `feat: defaults livianos (unload 2min, overlay minimal) y catálogo es-first`

### Task A4: Recomendación de modelo por RAM en onboarding

**Files:**

- Modify: `src-tauri/Cargo.toml` (dep `sysinfo = { version = "0.33", default-features = false, features = ["system"] }`)
- Create: comando en `src-tauri/src/commands/mod.rs` (o archivo nuevo `src-tauri/src/commands/system.rs`)
- Modify: `src/components/onboarding/Onboarding.tsx` + `src/components/onboarding/ModelCard.tsx`
- Modify: `src/i18n/locales/en/translation.json` y `es/translation.json` (claves nuevas de copy)

**Interfaces:**

- Produces: comando Tauri `get_total_memory_gb() -> u32` (specta-bound, aparece en `src/bindings.ts` regenerado por el dev run).
- Consumes: ranks del catálogo (A3).

- [ ] **Paso 1 (Rust):**

```rust
#[tauri::command]
#[specta::specta]
pub fn get_total_memory_gb() -> u32 {
    let mut sys = sysinfo::System::new();
    sys.refresh_memory();
    (sys.total_memory() / (1024 * 1024 * 1024)) as u32
}
```

Registrarlo donde se registran los demás commands (buscar `collect_commands!` o `invoke_handler` en `lib.rs`) para que specta lo exporte.

- [ ] **Paso 2:** `bun run tauri dev` una vez para regenerar `src/bindings.ts`; verificar que expone `getTotalMemoryGb`.
- [ ] **Paso 3 (React):** en el paso de modelo del onboarding: si `ram <= 8` → destacar `canary-180m-flash` como "Recomendado para tu equipo" y mostrar aviso de cuantización Q4 al elegir modelos 0.6B; si `> 8` → destacar `nemotron-3.5-asr-streaming-0.6b`. El resto de la lista sigue el orden del catálogo. Copy vía i18n (`onboarding.recommendedForYourMachine`, `onboarding.ramDetected` con interpolación `{{gb}}`).
- [ ] **Paso 4:** Verificar — `bun run build` PASS + prueba manual del onboarding (borrar el store de settings o usar el reset de debug `Cmd+Shift+D` si existe).
- [ ] **Paso 5:** Commit `feat: onboarding recomienda modelo según RAM detectada`

### Task A5: Reposo casi-cero — ventana principal destruible

**Files:**

- Modify: `src-tauri/src/lib.rs` (~796-830 creación; ~884-886 CloseRequested; `show_main_window` :96)

**Interfaces:**

- Produces: `fn create_main_window(app: &AppHandle) -> tauri::Result<WebviewWindow>` reutilizada por setup y por `show_main_window`.

- [ ] **Paso 1:** Extraer la construcción actual (`WebviewWindowBuilder::new(app, "main", …)` con title/size/portable data_dir) a `create_main_window`. El setup la llama igual que hoy.
- [ ] **Paso 2:** En `WindowEvent::CloseRequested` de "main": mantener `api.prevent_close()` pero llamar `window.destroy()` en vez de `hide()` (comentario: `// liberar el webview en reposo; se recrea al reabrir`).
- [ ] **Paso 3:** En `show_main_window` (lib.rs:96): si `app.get_webview_window("main")` es `None` → `create_main_window(app)` y luego show+focus.
- [ ] **Paso 4:** Verificar — `cargo check` PASS; manual: abrir/cerrar ajustes 5 veces desde tray (sin crash, estado de settings persiste porque vive en el store Rust); en Monitor de Actividad el proceso webview de "main" desaparece al cerrar.
- [ ] **Paso 5:** Commit `feat: la ventana de ajustes libera su webview al cerrarse`

### Task A6: Reposo casi-cero — overlay perezoso

**Files:**

- Modify: `src-tauri/src/overlay.rs` (creación :278-340, show/hide) y su call-site de setup en `src-tauri/src/lib.rs`

**Interfaces:**

- Consumes: eventos existentes de grabación/transcripción (los mismos que hoy muestran/ocultan el overlay).

- [ ] **Paso 1:** Leer `overlay.rs` completo para mapear el flujo show/hide actual (funciones que responden a recording started/stopped/transcribing).
- [ ] **Paso 2:** No crear el overlay en setup. En el "show": get-or-create (misma builder config actual). En el "hide": lanzar un timer de 5 s (tokio::spawn + sleep, cancelable con un generation counter `AtomicU64` para no destruir si volvió a grabar) que haga `window.destroy()`.
- [ ] **Paso 3:** Respetar `OverlayStyle::None` (no crear jamás — ya existe el guard en :366).
- [ ] **Paso 4:** Verificar — `cargo check` PASS; manual: dictar 3 veces seguidas (overlay reaparece rápido, sin flicker raro), esperar 10 s (proceso webview del overlay muere en Actividad), dictar de nuevo (vuelve). CPU en reposo ~0%.
- [ ] **Paso 5:** Commit `feat: overlay se crea al grabar y se destruye en reposo`

### Task A7: Re-skin — tokens, fuentes y wordmark

**Files:**

- Create: `src/assets/fonts/` (SpaceGrotesk-{Medium,SemiBold}.woff2, Inter-{Regular,Medium,SemiBold}.woff2, JetBrainsMono-{Regular,Medium}.woff2 — descargadas de Google Fonts/repos oficiales, licencias OFL)
- Create: `src/styles/brand.css` (@font-face + design tokens CSS)
- Modify: `src/App.css` (importar brand.css, mapear tokens a Tailwind theme vars existentes)
- Create: `src/components/shared/Wordmark.tsx` (logo `dilo▌` con caret animado)
- Modify: componentes de cabecera/footer donde hoy aparece el nombre/logo Handy (grep `Handy` en `src/`)

**Interfaces:**

- Produces: variables CSS `--dilo-ink #0D1117`, `--dilo-mango #FF9E1B`, `--dilo-menta #2EE6A8`, `--dilo-rojo #FF5C5C`, `--dilo-papel #F7F2EA`; clase `font-display`; componente `<Wordmark size="sm|lg" />`.

- [ ] **Paso 1:** Bajar las 7 woff2 a `src/assets/fonts/` (curl desde github oficial de cada fuente); crear `brand.css` con los @font-face (`font-display: swap`) y los tokens de arriba en `:root` + overrides dark (la app ya tiene Theme enum — mapear a su mecanismo actual, grep `data-theme\|dark` en `src/styles/`).
- [ ] **Paso 2:** Integrar tokens al theme Tailwind v4 (`@theme` en el CSS raíz): acento primario → mango; success → menta; danger → rojo; fondos → tinta/papel. Ajustar el CSS del overlay (`src/overlay/`) a los mismos tokens.
- [ ] **Paso 3:** `Wordmark.tsx`: texto `dilo` en Space Grotesk + `<span>` caret `▌` mango con `animation: blink 1.2s steps(1) infinite`. Reemplazar usos del nombre/logo viejo en header/footer/about.
- [ ] **Paso 4:** Verificar — `bun run build` PASS; `bun run tauri dev`: settings y overlay se ven tinta+mango, tipografía nueva, cero regresiones de layout gruesas.
- [ ] **Paso 5:** Commit `feat: re-skin Dilo (tokens, fuentes bundled, wordmark)`

### Task A8: Locale es con voz de marca + onboarding copy

**Files:**

- Modify: `src/i18n/locales/es/translation.json` (las 385 claves, reescritas — no traducción literal)
- Modify: `src/i18n/locales/en/translation.json` (solo claves NUEVAS del onboarding/A4 y las que digan "Handy" → "Dilo")

Reglas de autoría (fuente: spec §Marca — el ejecutor escribe el contenido final aplicándolas):

- Tuteo, LATAM neutro; "tu compu", "aprieta", "listo".
- Términos dev en spanglish natural: "el prompt", "pegar", "atajo", "el modelo".
- Nada de "por favor espere", "¡Ups!", "¡Genial!" corporativo. Sí: "Un segundo…", "Eso no salió. Reintenta.", "Listo."
- Claves de marca: `app.name = "Dilo"`; tagline donde aplique: "Dilo y listo."
- Ejemplos de tono (aplicar el patrón al resto): `onboarding.micPermission.title`: "Dilo necesita escucharte" · `.body`: "Solo cuando aprietes el atajo. Ni un byte de tu voz sale de tu compu." · `models.download.progress`: "Bajando tu modelo ({{mb}} MB)… una sola vez."

- [ ] **Paso 1:** Reescribir `es/translation.json` completo con las reglas (mantener TODAS las claves e interpolaciones `{{var}}` idénticas).
- [ ] **Paso 2:** Verificar paridad de claves e interpolaciones: `bun run scripts/check-translations.ts` (existe en el repo) → PASS; `bun run lint` PASS.
- [ ] **Paso 3:** Revisión visual en dev (settings + onboarding en es).
- [ ] **Paso 4:** Commit `feat: locale es reescrito con voz Dilo`

### Task A9: README, LICENSE y CI

**Files:**

- Rewrite: `README.md` (es-first según spec §README; badges a `aacontn/dilo`; tabla de modelos con RAM real del análisis: Canary 180M ~0.4–0.5 GB · 0.6B Q8 ~1.1–1.4 GB · reposo ~60–80 MB; sección EN breve al final; crédito a Handy arriba)
- Modify: `LICENSE` (mantener MIT CJ Pais, añadir línea `Copyright (c) 2026 Alfonso Contreras (Dilo)`)
- Modify: `.github/workflows/release.yml` y `main-build.yml` y `build.yml` (nombres de artefactos `dilo_*`, quitar pasos de firma/notarización y de updater `latest.json` o condicionarlos a `if: ${{ secrets.X != '' }}`; los workflows que publican a infra de handy.computer se eliminan)
- Modify: `AGENTS.md` (referencias de repo/nombre; quitar la sección de PRs upstream que ya no aplica al fork)

- [ ] **Paso 1:** README nuevo completo (es) + EN corto. Incluir aviso de binarios sin firma con pasos de apertura por OS y el roadmap v2 (overlay nativo, brew, winget, firma).
- [ ] **Paso 2:** LICENSE + AGENTS.md.
- [ ] **Paso 3:** Workflows: renombrar artefactos, `tauri-action`/steps de firma condicionados, target release en el repo propio. Validar YAML: `python3 -c "import yaml,glob;[yaml.safe_load(open(f)) for f in glob.glob('.github/workflows/*.yml')]"` → PASS.
- [ ] **Paso 4:** Commit `docs+ci: README es-first, licencia dual-copyright, workflows Dilo`

### Task A10: Verificación integral local

- [ ] `bun run lint && bun run format:check && cargo fmt --check` (en src-tauri) → todo PASS.
- [ ] `bun run tauri build` (macOS local) → genera `Dilo.app`/dmg sin firma.
- [ ] Prueba end-to-end: instalar el .app, onboarding es completo, bajar Canary 180M, dictar en español dentro de Cursor o terminal, texto aparece; a los 2 min el modelo se descarga de RAM (Actividad); reposo <100 MB; abrir/cerrar ajustes estable.
- [ ] Commit final de ajustes que salgan de la prueba.

## Fase B — Landing (repo nuevo `dilo-landing/`)

### Task B1: Sitio estático completo

**Files:**

- Create: `dilo-landing/index.html`, `dilo-landing/styles.css`, `dilo-landing/app.js` (detección de OS + links release), `dilo-landing/assets/` (logo.svg, favicon.svg, og.png), `dilo-landing/README.md`, `dilo-landing/.gitignore`

Contenido (el ejecutor lo redacta completo con spec §Marca + §Landing):

- Hero: "Deja de tipear tus prompts. **Dilo.**" + sub: "Dictado por voz para los que programan con IA. Offline, gratis y en español." + CTA por OS + animación CSS onda→texto.
- Secciones: Cómo funciona (aprieta/habla/suelta con `<kbd>`) · Hecho para vibe coders (Cursor, Claude, terminal) · Privado de verdad (offline, MIT, sin telemetría) · Modelos y RAM (tabla del README) · FAQ (gratis / mi voz / precisión es / requisitos / sin firma cómo abrir) · Footer (GitHub, crédito Handy-CJ Pais MIT, hecho en LATAM).
- Sin frameworks; CSS a mano con los tokens; fuentes woff2 locales (mismas de A7); JS mínimo para detectar OS y armar el link a GitHub Releases latest.
- SEO/OG básicos en es; `lang="es"`.

- [ ] **Paso 1:** Escribir todo (HTML/CSS/JS/assets).
- [ ] **Paso 2:** Verificar local con Browser pane (responsive 375px y 1280px, dark), links correctos a `github.com/aacontn/dilo/releases/latest`.
- [ ] **Paso 3:** `git init` + commit inicial `feat: landing Dilo v1`.

### Task B2: Deploy Cloudflare Pages + repo GitHub

- [ ] `gh auth status` → si falta auth, pedir a Alfonso. `gh repo create aacontn/dilo-landing --public --source . --push`.
- [ ] `wrangler whoami` → si falta auth/cuenta correcta, pedir a Alfonso cuál cuenta CF usar. `wrangler pages project create dilo && wrangler pages deploy . --project-name dilo` → URL `dilo.pages.dev`.
- [ ] Verificar la URL pública en Browser pane. Registrar proyecto en OrbitDeck (skill orbitdeck) con deploy/cuenta/repos.

## Fase C — Publicación del fork

### Task C1: Repo + release v0.1.0

- [ ] `gh repo create aacontn/dilo --public --source dilo/ --push` (main). Añadir remote origin, push con tags.
- [ ] Tag `v0.1.0` + push → workflow release construye artefactos multi-OS; si el workflow requiere secretos ausentes, los steps condicionados los saltan (A9).
- [ ] Verificar artefactos en la página de releases; descargar el de macOS y abrirlo (flujo sin firma documentado).
- [ ] Actualizar links de la landing si cambia algo; anuncio listo para compartir.

## Self-review (hecho al escribir)

- **Cobertura del spec:** marca→A2/A7/A8, defaults→A3/A4, reposo→A5/A6, re-skin→A7, onboarding→A4/A8, locale→A8, README→A9, landing→B1/B2, release hoy→C1, estructura repos→B2/C1, v2 documentado→A9(README). Modo nube: descartado (no hay task, correcto).
- **Placeholders:** los tasks creativos (A8, B1) definen reglas + ejemplos concretos y el contenido final se autoriza en el task — es autoría, no TBD. Ningún "TODO/handle edge cases".
- **Consistencia de nombres:** `create_main_window`, `get_total_memory_gb`/`getTotalMemoryGb`, tokens `--dilo-*`, slugs de modelos idénticos al catálogo (nemotron-3.5-asr-streaming-0.6b, canary-180m-flash, parakeet-tdt-0.6b-v3).
