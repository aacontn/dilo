# Dilo — Design doc (rebranding y remake de Handy)

**Fecha:** 2026-07-12 · **Estado:** aprobado por Alfonso · **Base:** Handy v0.9.2 (cjpais/handy, MIT)

## Qué es

Dilo es un fork con dirección propia de Handy: dictado por voz offline para escritorio (Tauri 2 / Rust + React), relanzado en español para vibe coders de Latinoamérica — gente que programa con IA, dicta prompts en vez de escribirlos y vive entre Cursor, Claude y el terminal.

Criterio de éxito: un dev latino ve la landing y dice "esto es para mí".

## Decisiones ya tomadas (con el usuario)

1. **Alcance:** fork profundo. Núcleo Rust intacto; cambian marca, UI, defaults y copy. Nada de reescritura.
2. **Recursos v1:** defaults español-primero y livianos + reposo casi-cero (destruir webviews ocultas). Overlay nativo queda para v2. Modo nube: descartado (rompe el pitch offline).
3. **Nombre:** Dilo. Aprobado junto con identidad, defaults, landing y estructura.

## Marca

- **Nombre:** Dilo — imperativo universal en español, dos sílabas, es la promesa del producto.
- **Tagline:** "Dilo y listo." · **Hero:** "Deja de tipear tus prompts. Dilo."
- **Personalidad:** el compa dev que te pasa el dato. Directo, cálido, cero corporativismo. Spanglish natural ("el build", "deployar"), sin memes forzados.
- **Frases de la casa:** "Aprieta, habla, suelta. Ya está escrito." · "Ni un byte de tu voz sale de tu compu." · "Gratis de verdad, open source de verdad."
- **Atribución:** "Dilo es un fork con cariño de Handy (CJ Pais, MIT)" en README y footer de landing. La licencia MIT y el copyright de CJ Pais se conservan; se añade línea de copyright propia.

## Identidad visual

- **Wordmark:** `dilo▌` minúsculas + caret ámbar parpadeante (un prompt esperando que hables).
- **Paleta (dark-first):** fondo tinta `#0D1117` · acento mango `#FF9E1B` · menta `#2EE6A8` (activo/éxito) · rojo suave `#FF5C5C` (grabando) · papel `#F7F2EA` (modo claro).
- **Tipografía:** Space Grotesk (display) · Inter (texto) · JetBrains Mono (atajos, código).
- **Motivo:** onda de audio que se convierte en caracteres monoespaciados.
- **Ícono app/tray:** cuadrado redondeado tinta, caret ámbar + onda mínima, legible a 16 px.

## Producto (cambios sobre Handy)

### Defaults español-primero y livianos

- Modelo recomendado en onboarding según RAM detectada:
  - > 8 GB → **Nemotron Streaming 3.5 Q8** (751 MB, 28 idiomas incl. es, streaming en vivo).
  - ≤ 8 GB → **Canary 180M Flash Q8** (218 MB, es/en/de/fr, velocísimo).
  - ≤ 8 GB y modelo 0.6B elegido a mano → sugerir cuantización **Q4_K_M**.
- `model_unload_timeout`: default **Min2** (upstream: Min5).
- `overlay_style`: default **Minimal**.
- Idioma de transcripción: `auto` (los modelos con lang_detect lo resuelven); UI es-first.

### Reposo casi-cero (RAM)

- Ventana de ajustes: al cerrarse se **destruye** el webview (hoy se oculta); se recrea al abrir. Objetivo: reposo ~60–80 MB (hoy ~150–250 MB).
- Overlay: crear la ventana al iniciar grabación y destruirla tras unos segundos de inactividad (hoy vive siempre). Elimina también el CPU residual (issue upstream #1418).
- Riesgo aceptado: +100–300 ms al reabrir ajustes / primer overlay. Aceptable.

### Re-skin y voz

- Tema nuevo (paleta/tipos de arriba) sobre la UI de settings existente; iconos lucide se mantienen.
- Onboarding rediseñado, 3 pasos: (1) permisos explicados en cristiano, (2) modelo auto-recomendado mostrando MB y trade-offs, (3) prueba en vivo ("di: hola mundo").
- Locale `es` reescrito con voz de marca (no traducción literal). Los otros 21 idiomas quedan intactos (heredan de upstream).
- Rebrand técnico: nombre de app/binario `dilo`, bundle ID `cl.espaciodigital.dilo`, iconos nuevos, sonidos se mantienen.

### v2 (documentado, no se construye ahora)

Overlay nativo sin webview · Homebrew cask · winget · firma de código (Apple Developer US$99/año).

## Landing (repo aparte: dilo-landing)

One-page estática HTML + Tailwind (sin framework), en español, dark-first, deploy en **Cloudflare Pages** (`dilo.pages.dev`; dominio propio pendiente — decisión de Alfonso).

Secciones: Hero (headline + CTA descarga con detección de OS + animación onda→texto) · Cómo funciona (3 teclas) · Hecho para vibe coders (Cursor/Claude/terminal) · Privado de verdad (offline, MIT, sin telemetría) · Modelos con RAM real · FAQ corta · Footer (GitHub, crédito Handy).

Los botones de descarga apuntan a GitHub Releases. La landing dice sin vergüenza que los binarios van sin firma y cómo abrirlos igual (macOS: clic derecho > Abrir; Windows: SmartScreen > Más info > Ejecutar).

## README (del fork)

Español primero: qué es, gif, descarga por OS, requisitos con RAM honesta, cómo compilar, crédito a Handy arriba (no en letra chica), sección breve en inglés al final.

## Estructura y repos

```
carpeta sin título/
├── handy-upstream/   ← referencia de solo lectura (clon shallow)
├── dilo/             ← fork app; remote upstream=cjpais/handy, origin=aacontn/dilo
└── dilo-landing/     ← landing; origin=aacontn/dilo-landing → Cloudflare Pages
```

Estrategia de fork: cambios de marca/UI/defaults como commits propios sobre main; fixes de upstream se absorben con `git fetch upstream && git merge upstream/main`. Mantener el core sin tocar minimiza conflictos.

## Salida hoy (v0.1.0)

1. Fork rebrandeado compilando (`bun run tauri build` local para verificar en macOS).
2. Landing live en Cloudflare Pages.
3. Repos publicados en GitHub (aacontn) + release v0.1.0 con binarios de GitHub Actions (workflow heredado de upstream, artefactos renombrados, sin firma).
4. README nuevo.

## Errores y pruebas

- Verificación funcional en la máquina de Alfonso (macOS): dictado end-to-end en español, unload a los 2 min (visible en Actividad), reposo sin overlay vivo.
- CI de upstream (lint + build) se mantiene; los tests Playwright existentes deben seguir verdes.
- Riesgo principal: destruir/recrear webviews puede romper estado reactivo del frontend → se prueba manualmente abrir/cerrar ajustes repetido y grabación con overlay lazy.

## Fuera de alcance v1

Reescrituras del pipeline de audio · overlay nativo · firma/notarización · dominio definitivo · modo nube · cambios a los 21 locales no-es.
