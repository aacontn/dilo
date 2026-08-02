<p align="center">
  <img src="brand/dilo-wordmark.svg" alt="dilo" width="220" />
</p>

<h3 align="center">Deja de tipear tus prompts. Dilo.</h3>

<p align="center">
  Dictado por voz para los que programan con IA.<br/>
  <strong>Offline, gratis, open source y en español.</strong>
</p>

<p align="center">
  <a href="https://github.com/aacontn/dilo/releases/latest">⬇️ Descargar</a> ·
  <a href="#cómo-funciona">Cómo funciona</a> ·
  <a href="#modelos-y-cuánta-ram-usan">Modelos y RAM</a> ·
  <a href="#compilar-desde-el-código">Compilar</a> ·
  <a href="#english">English</a>
</p>

---

## Qué es Dilo

Aprietas un atajo, hablas, sueltas. Tu dictado aparece escrito donde tengas el cursor: Cursor, Claude Code, el terminal, Slack, donde sea. Todo se procesa **en tu compu** — ni un byte de tu voz sale de tu máquina.

Si dictas tus prompts en vez de tipearlos, esto es para ti.

- 🎙️ **Un atajo y listo** — mantén apretado para hablar (o modo toggle si prefieres)
- 🇪🇸 **Español primero** — modelos recomendados que entienden español de verdad, interfaz en español
- 🔌 **100% offline** — sin cuenta, sin nube, sin telemetría
- 🪶 **Liviano** — el modelo se descarga solo de la RAM cuando no dictas (~60–80 MB en reposo)
- 🧠 **Post-proceso opcional con IA** — pulir gramática, formato de prompt, lo que quieras
- 🖥️ **macOS, Windows y Linux**

## Descarga

**macOS y Linux — un comando y listo** (baja el último release, instala y resuelve los permisos solo; correrlo de nuevo actualiza):

```bash
curl -fsSL https://raw.githubusercontent.com/aacontn/dilo/main/install.sh | sh
```

O baja el instalador para tu sistema desde **[Releases](https://github.com/aacontn/dilo/releases/latest)**.

Los binarios v0.1.x van **sin firma de código** (la firma de Apple cuesta US$99/año; está en el roadmap). Tu sistema te va a advertir la primera vez — así se abre igual:

| Sistema     | Cómo abrir                                                                                                   |
| ----------- | ------------------------------------------------------------------------------------------------------------ |
| **macOS**   | Clic derecho sobre Dilo.app → **Abrir** → Abrir. Si no aparece la opción: `xattr -cr /Applications/Dilo.app` |
| **Windows** | SmartScreen → **Más información** → **Ejecutar de todas formas**                                             |
| **Linux**   | AppImage: `chmod +x` y ejecutar · también hay .deb y .rpm                                                    |

## Cómo funciona

1. **Aprieta** el atajo (por defecto <kbd>⌥ Option</kbd>+<kbd>Espacio</kbd> en macOS, <kbd>Ctrl</kbd>+<kbd>Espacio</kbd> en Windows/Linux)
2. **Habla** — verás una pastilla discreta mientras grabas
3. **Suelta** — el texto aparece donde estaba tu cursor. Ya está escrito.

La primera vez, Dilo te guía: dos permisos (micrófono y accesibilidad, explicados sin letra chica), un modelo recomendado según la RAM de tu compu, y a dictar.

## Modelos y cuánta RAM usan

Trece modelos, **todos entienden español**. Regla simple: más preciso suele ser más lento y más pesado. Dilo te recomienda según tu máquina, y **libera la RAM solo** a los 2 minutos sin dictar (configurable).

Precisión y velocidad son las del catálogo, en escala de 0 a 100 — sirven para comparar entre ellos, no como nota absoluta.

| Modelo                        | Precisión | Velocidad | Descarga | Ideal para                                |
| ----------------------------- | --------- | --------- | -------- | ----------------------------------------- |
| **Parakeet V3** (recomendado) | 88        | 79        | 739 MB   | El día a día: rápido y preciso            |
| **Canary 1B Flash**           | 90        | 83        | 769 MB   | Le gana al recomendado en ambas cosas     |
| **Cohere Transcribe**         | 92        | 63        | 1.8 GB   | La máxima precisión                       |
| **Granite Speech 4.1 2B**     | 92        | 37        | 1.8 GB   | Precisión pareja, sin apuro               |
| **Qwen3-ASR 1.7B**            | 90        | 38        | 1.5 GB   | Multilingüe serio (30 idiomas)            |
| **Canary 1B v2**              | 88        | 81        | 836 MB   | Rápido y con 25 idiomas                   |
| **Qwen3-ASR 0.6B**            | 87        | 63        | 850 MB   | Balance moderno, multilingüe              |
| **Whisper Large v3 Turbo**    | 87        | 35        | 886 MB   | Whisper de alta calidad                   |
| **Whisper Medium**            | 84        | 42        | 831 MB   | Idiomas poco comunes                      |
| **Nemotron Streaming 3.5**    | 82        | 84        | 751 MB   | Ver el texto en vivo mientras hablas      |
| **Whisper Small**             | 80        | 78        | 269 MB   | Equipos modestos (8 GB o menos)           |
| **Voxtral Mini 3B**           | 88        | 14        | 3.5 GB   | Preciso pero lento: mejor para reuniones  |
| **Voxtral Mini 4B Realtime**  | 87        | 11        | 3.3 GB   | Multilingüe en vivo, pide máquina potente |

De regla, la RAM mientras dictas es **1,5 a 2 veces la descarga**. En reposo (modelo liberado, ventana cerrada): **~60–80 MB**. Puedes elegir cuantizaciones más chicas (Q4) de cualquier modelo si tu RAM anda justa.

## Hecho para vibe coders

- Dicta el prompt largo en Cursor o Claude Code en vez de tipearlo — hablar es 3× más rápido que escribir
- `dilo --toggle-transcription` desde el terminal, scripts o tu window manager
- Envío automático opcional: dicta y que se mande solo con Enter
- Post-proceso con cualquier API compatible con OpenAI (o Apple Intelligence en macOS 26+): "mejora la gramática", "formatea como conventional commit", tu prompt manda
- Historial local de todo lo que dictaste, re-transcribible al cambiar de modelo

## Requisitos

- **macOS**: Apple Silicon o Intel (Metal para modelos Whisper)
- **Windows**: CPU moderna; GPU (Vulkan) opcional para Whisper
- **Linux**: Ubuntu 22.04/24.04 probado; Wayland con limitaciones (ver abajo)
- Los modelos recomendados (Parakeet/Nemotron/Qwen3) corren **bien en CPU pura** — no necesitas GPU

## Compilar desde el código

```bash
# Requisitos: Rust estable + Bun
git clone https://github.com/aacontn/dilo
cd dilo
bun install
mkdir -p src-tauri/resources/models
curl -o src-tauri/resources/models/silero_vad_v4.onnx https://blob.handy.computer/silero_vad_v4.onnx
bun run tauri dev     # desarrollo
bun run tauri build   # producción
```

Detalle por plataforma en [BUILD.md](BUILD.md).

Dilo se desarrolla con asistentes de IA — Claude Code y Codex, con las mismas
instrucciones (`CLAUDE.md` = `AGENTS.md`). Guía de Codex:
[Desarrollar con Codex](docs/desarrollar-con-codex.md).

## Solución de problemas

- **macOS: el permiso de Accesibilidad queda en "Esperando…" aunque ya lo activaste** → en Ajustes del Sistema → Privacidad y seguridad → Accesibilidad, quita Dilo con **−** y agrégalo de nuevo. Pasa porque los binarios van sin firma de Apple: tras cada actualización macOS trata la app como si fuera otra y el permiso viejo deja de calzar. Vía rápida por terminal: `tccutil reset Accessibility cl.espaciodigital.dilo` y vuelve a abrir Dilo. (Se resuelve de raíz al firmar los binarios — está en el roadmap.)
- **macOS: el atajo no escribe nada** → mismo remedio de arriba: el permiso de Accesibilidad quedó apuntando a una versión anterior.
- **No se pega el texto en algunas apps** → prueba otro Método de pegado en Ajustes → Avanzado.
- **Linux Wayland: atajos globales no funcionan** → configura el atajo en tu DE/WM apuntando a `dilo --toggle-transcription`. Overlay: se recomienda "Ninguno" (o `DILO_NO_GTK_LAYER_SHELL=1`).
- **La primera transcripción tarda** → es la carga del modelo a RAM (1–2 s). Si te molesta, sube el tiempo de "Liberar RAM" en Ajustes → Avanzado.

## Roadmap

Las apuestas grandes de producto:

- [ ] **Notetaker de reuniones** — graba la reunión, separa quién habla, y te deja el transcript con resumen y acciones. **Empezando por las reuniones online**, donde el audio de los demás llega limpio por el sistema; las presenciales vienen después, porque con el micrófono de un laptop al centro de la mesa no se puede hacer bien.
  - [x] Grabar, transcribir y separar voces en presencial
  - [x] Registro de reuniones pasadas, en su propia ventana
  - [ ] Capturar el audio del sistema (lo que dicen los demás en Meet, Zoom o Teams)
  - [ ] Detectar solo que empezó una videollamada y ofrecerte grabarla
  - [ ] Resumen, acciones y preguntarle cosas al transcript
  - [ ] Notas propias junto al transcript, y sincronizarlas con Obsidian o Apple Notes
- [ ] **Control de agentes por voz** — Dilo como intermediario: le hablas, un agente hace el trabajo (Claude Code y otros) y Dilo te lee la respuesta en voz alta, con palabra de activación. La voz de salida ya llega en v0.1.12; falta conectar el otro extremo.
- [ ] **Panel en la barra de menú** — el ícono de Dilo abre lo que usas seguido sin abrir la app: copiar lo último dictado, cambiar de modelo, grabar una reunión.
- [ ] **Modo según la app en la que estás** — Dilo detecta dónde escribes y aplica el modo que corresponde (en el correo escribe como correo, en el editor como código), sin que tengas que acordarte de ningún atajo. Foco en macOS y Windows; en Linux el comportamiento actual se mantiene.
- [ ] **Diccionario que aprende solo** — Dilo aprende de las correcciones que ya hace la IA y las incorpora al arreglo local, así deja de necesitar la IA para las palabras que usas siempre. Todo en tu equipo.
- [ ] **Conectores por MCP** — enchufar Dilo a tus herramientas con permisos explícitos, sin acoplar el núcleo a ningún servicio.

Empaquetado y sistema:

- [ ] Firma y notarización de binarios (Apple Developer)
- [ ] Overlay nativo sin webview (menos RAM aún)
- [ ] Homebrew cask y winget
- [ ] Actualizador integrado propio
- [ ] Reactivar el empaquetado Nix del upstream (flake aún apunta al crate viejo)

## Créditos

Dilo existe gracias a:

- **[Handy](https://github.com/cjpais/Handy)** de CJ Pais — el proyecto original (MIT). Este fork mantiene su núcleo Rust y absorbe sus fixes.
- **[ggml / whisper.cpp](https://github.com/ggml-org/ggml)** de Georgi Gerganov — inferencia local rápida.
- Los equipos de NVIDIA (Parakeet/Canary/Nemotron), OpenAI (Whisper), Cohere, Qwen y Mistral por liberar sus modelos de voz.

Licencia [MIT](LICENSE).

---

## English

**Dilo** ("say it" in Spanish) is a Spanish-first fork of [Handy](https://github.com/cjpais/Handy): free, open-source, fully offline push-to-talk dictation for macOS, Windows and Linux, aimed at Latin American developers who dictate their AI prompts instead of typing them. UI and docs are in Spanish; the app itself supports 22 UI languages and dozens of transcription languages. Lightweight by default: the model auto-unloads from RAM after 2 idle minutes (~60–80 MB at rest). Download from [Releases](https://github.com/aacontn/dilo/releases/latest) — binaries are unsigned for now (see the table above for how to open them).
