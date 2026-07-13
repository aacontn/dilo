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

> Dilo es un **fork con cariño de [Handy](https://github.com/cjpais/Handy)** (CJ Pais, licencia MIT). Le cambiamos la ropa, los defaults y el idioma; el motor probado sigue ahí abajo. Gracias CJ. 💛

## Descarga

Baja el instalador para tu sistema desde **[Releases](https://github.com/aacontn/dilo/releases/latest)**.

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

Regla simple: más grande = más preciso y más RAM; más chico = vuela. Dilo te recomienda según tu máquina, y **libera la RAM solo** a los 2 minutos sin dictar (configurable).

| Modelo                                   | Español        | Descarga | RAM dictando | Ideal para                           |
| ---------------------------------------- | -------------- | -------- | ------------ | ------------------------------------ |
| **Nemotron Streaming 3.5** (recomendado) | ✅ +27 idiomas | 751 MB   | ~1.1–1.4 GB  | Ver el texto en vivo mientras hablas |
| **Canary 180M Flash**                    | ✅ es/en/de/fr | 218 MB   | ~0.4–0.5 GB  | Compus con 8 GB de RAM o menos       |
| **Parakeet V3**                          | ✅ 25 idiomas  | 740 MB   | ~1.1–1.4 GB  | Precisión sin streaming              |
| **Cohere Transcribe**                    | ✅ 14 idiomas  | 1.8 GB   | ~2.5 GB      | Máxima precisión, máquinas potentes  |
| **Whisper Medium**                       | ✅ 99 idiomas  | 832 MB   | ~1.5 GB      | Idiomas poco comunes                 |

En reposo (modelo liberado, ventana cerrada): **~60–80 MB**. Puedes elegir cuantizaciones más chicas (Q4) de cualquier modelo si tu RAM anda justa.

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
- Los modelos recomendados (Parakeet/Nemotron/Canary) corren **bien en CPU pura** — no necesitas GPU

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

## Solución de problemas

- **macOS: el permiso de Accesibilidad queda en "Esperando…" aunque ya lo activaste** → en Ajustes del Sistema → Privacidad y seguridad → Accesibilidad, quita Dilo con **−** y agrégalo de nuevo. Pasa porque los binarios van sin firma de Apple: tras cada actualización macOS trata la app como si fuera otra y el permiso viejo deja de calzar. Vía rápida por terminal: `tccutil reset Accessibility cl.espaciodigital.dilo` y vuelve a abrir Dilo. (Se resuelve de raíz al firmar los binarios — está en el roadmap.)
- **macOS: el atajo no escribe nada** → mismo remedio de arriba: el permiso de Accesibilidad quedó apuntando a una versión anterior.
- **No se pega el texto en algunas apps** → prueba otro Método de pegado en Ajustes → Avanzado.
- **Linux Wayland: atajos globales no funcionan** → configura el atajo en tu DE/WM apuntando a `dilo --toggle-transcription`. Overlay: se recomienda "Ninguno" (o `DILO_NO_GTK_LAYER_SHELL=1`).
- **La primera transcripción tarda** → es la carga del modelo a RAM (1–2 s). Si te molesta, sube el tiempo de "Liberar RAM" en Ajustes → Avanzado.

## Roadmap

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
