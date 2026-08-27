# Bitácora de agentes — Dilo

> Entradas nuevas arriba. Hecho, próximo paso, cuidado y estado Git; el
> detalle fino vive en Git y en `docs/superpowers/specs/`.

## 2026-08-27 · Norte (Claude)

- **Hecho:** diseño aprobado del motor de dictado en línea **Gemini 3.5
  Transcribe** (spec `2026-08-27-motor-gemini-transcribe-design.md`), con el
  protocolo verificado con probe en vivo: batch `interactions` acepta WAV
  directo (3,3 s / 9,6 s de audio) y el live por WebSocket da el final 0,6 s
  después de soltar la tecla, ambos con smart impecable en español. Referencia:
  Jot (github.com/google-gemini/jot-gemini-transcribe-macOS, Apache 2.0).
  Además, limpieza de disco en el Mac de Alfonso: borrados Nemotron streaming
  (716 M) y Canary (734 M); queda Cohere como único STT local (symlink a la
  caché HF — ese enlace de 0 bytes es normal, no borrarlo).
- **Próximo paso:** plan de implementación de la fase 1 (writing-plans) y, tras
  ella, diseño propio de la fase 2 (live por WS, que reemplaza el preview en
  vivo actual que Alfonso da por inservible).
- **Cuidado:** la key vive en `post_process_api_keys["google"]` (id `google`,
  no `gemini`). Nunca mandar `language_codes` con `mode: "smart"` — lo
  desactiva en silencio. Dilo estaba corriendo durante la limpieza: el selector
  puede mostrar estado viejo hasta reiniciar la app.
- **Git:** main, 4 commits locales sin push (3 previos + este de docs).
