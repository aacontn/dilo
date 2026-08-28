# Bitácora de agentes — Dilo

> Entradas nuevas arriba. Hecho, próximo paso, cuidado y estado Git; el
> detalle fino vive en Git y en `docs/superpowers/specs/`.

## 2026-08-28 · Norte (Claude, orquestando subagentes Opus)

- **Hecho:** fase 1 del motor Gemini implementada completa en la rama
  `feat/motor-gemini-transcribe` (10 commits, 48 archivos): catálogo cloud,
  cliente `gemini_stt.rs` (28 tests, base64 y WAV propios, techo 45 s),
  despacho en el manager (el `block_on` directo del plan paniqueaba dentro del
  runtime — va en hilo propio con scope/join), caída a local con aviso que
  sobrevive a la ventana cerrada (cola `PendingNotices<T>` generalizada), UI
  con tarjeta EN LÍNEA y ~10 claves i18n × 21 locales. Cada tarea con revisión
  independiente; 521 tests Rust + 166 bun verdes.
- **Próximo paso:** revisión final de rama completa → push de Alfonso (CI
  `test.yml`) → probar en vivo con su key → merge a main → release. Después:
  diseño de fase 2 (live WS) y reuniones-en-línea (compuerta: diarización).
- **Cuidado:** la key va en `post_process_api_keys["google"]` y su presencia
  se lee client-side (precedente `DictationModes.tsx`). Tras una caída, el
  próximo dictado vuelve solo a Gemini (`decide_model_load_action`, fijado por
  test). El aviso puede verse dos veces (vivo + al reabrir): contrato heredado
  de las colas existentes.
- **Git:** rama `feat/motor-gemini-transcribe` sobre main local (que sigue
  4 commits adelante de origin); nada pusheado.

## 2026-08-27 (2) · Norte (Claude)

- **Hecho:** diseño aprobado de **reuniones en línea**
  (`2026-08-27-reuniones-en-linea-design.md`): Nemotron no se restaura, la
  transcripción de reunión pasa a contrato `MeetingTranscriber` con Gemini
  primero (vivo por WS sin hablantes + repaso batch con diarización de hasta 8) y AWS como implementación futura. Probes versionados en
  `scripts/probes/` con su README.
- **Próximo paso:** plan de fase 1 del dictado (orden aprobado: dictado →
  reuniones). El plan de reuniones tiene compuerta de entrada: verificar el
  formato de la diarización cuando `:generateContent` deje de dar 503
  (congestión del lanzamiento).
- **Cuidado:** `interactions` rechaza `diarization` (`Unknown parameter`);
  la diarización vive en `:generateContent`, donde smart NO funciona — el
  transcript final con hablantes sale verbatim y lo limpia el LLM del
  resumen.
- **Git:** main, commits locales sin push.

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
