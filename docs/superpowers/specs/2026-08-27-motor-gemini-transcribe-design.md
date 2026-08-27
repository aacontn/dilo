# Dilo — Motor de dictado Gemini 3.5 Transcribe (en línea)

**Fecha:** 2026-08-27 · **Estado:** diseño aprobado por Alfonso en conversación; protocolo verificado con probe en vivo · **Base:** catálogo de motores (`EngineType`), patrón LOCAL/EN LÍNEA del spec [2026-07-29 Proveedor por modo](2026-07-29-proveedor-por-modo-design.md)

## El problema

Todos los motores de dictado de Dilo son locales. Google publicó ayer
(2026-08-26) **Gemini 3.5 Transcribe**: WER 2,6 % batch / 4,0 % live, 85+
idiomas con detección automática, free tier en preview público y ~US$0,005 por
minuto después. Su modo *smart* elimina muletillas y colapsa autocorrecciones
("a las tres… no, mejor a las cuatro" → "a las cuatro") en el propio motor.

Referencia de implementación: **Jot**
(<https://github.com/google-gemini/jot-gemini-transcribe-macOS>, Apache 2.0),
la demo oficiosa de Google — un dictador macOS análogo a Dilo. Su código trae
el protocolo verificado contra la API viva, con las trampas documentadas.

## Decisiones tomadas (con Alfonso)

- **Es un motor más del catálogo**, no un selector aparte: tarjeta "Gemini 3.5
  Transcribe" con badge **EN LÍNEA**, 0 MB, sin descarga. Descartado el
  selector paralelo: duplica UI y complica la caída a local.
- **Si Gemini falla, cae a un modelo local** (el último usado) y avisa
  **después del hecho** — espejo de la caída proveedor-del-modo → global. El
  dictado nunca sale vacío.
- **Smart por defecto**, con toggle a verbatim. Con smart activo se salta el
  filtro local de muletillas (limpiar dos veces muerde texto bueno). Los modos
  LLM corren igual que siempre encima.
- **La key es la que ya existe**: `post_process_api_keys["google"]` (id
  `google`, no `gemini`). Una key de AI Studio sirve para dictar y transformar.
- **Solo dictado batch en fase 1.** Reuniones siguen locales (la diarización
  necesita timestamps por token que esta integración no da). El live por
  WebSocket queda para fase 2 — ya evaluado, ver abajo.
- Nunca es el motor por defecto ni el recomendado del onboarding: Dilo sigue
  plenamente útil sin conexión.

## Diseño

### 1 · Catálogo y datos

- `EngineType::GeminiTranscribe`.
- `ModelSource::Cloud` — sin archivo, sin descarga; `is_downloaded` siempre
  true, `size_mb` 0, `DiskStatus` trivial.
- Capacidades: `supports_language_detection: true`,
  `supports_language_selection: false` (ver trampa `language_codes`),
  `supports_token_timestamps: false` (reuniones excluidas),
  `supports_streaming: false` (fase 1), `supports_translation: false`.

### 2 · Cliente Rust (`gemini_stt.rs`, espejo de `llm_client.rs`)

- `reqwest` (ya en las dependencias). Audio **WAV 16 kHz mono** en base64 —
  verificado hoy: `interactions` acepta `audio/wav` directo, así que la fase 1
  no necesita encoder FLAC (queda anotado como optimización de payload).
- `POST {endpoint}/v1beta/interactions`, modelo en el body:

```json
{
  "model": "gemini-3.5-transcribe",
  "input": [{ "type": "audio", "mime_type": "audio/wav", "data": "<b64>" }],
  "generation_config": { "transcription_config": { "mode": "smart",
                          "custom_vocabulary": ["…"] } }
}
```

- Verbatim = **omitir** `transcription_config` (es el default del servidor);
  con vocabulario, mandar solo `custom_vocabulary`.
- Respuesta: `{"status":"completed","steps":[{"type":"model_output",
  "content":[{"type":"text","text":…}]}]}`. Texto vacío se devuelve como `""`
  (el silencio no es error).
- Auth: header `x-goog-api-key`, **nunca** query string.
- Las **palabras personalizadas** de Dilo (`CustomWords`) viajan como
  `custom_vocabulary`.

### 3 · Trampas del protocolo (pagadas por Jot, verificadas por ellos contra la API viva)

- **NUNCA `language_codes` junto a `mode: "smart"`**: HTTP 200, sin error, y
  smart se desactiva en silencio. Por eso el motor no ofrece selección manual
  de idioma — solo Auto. Un test unitario fija esta regla.
- `mode` **no funciona** en `:generateContent` (parsea y devuelve texto
  vacío). El transporte es `interactions` y es el único que la fase 1
  implementa; `:generateContent` con `audioTranscriptionConfig
  {wordTimestamp:true}` (obligatorio) queda documentado como transporte de
  emergencia sin smart, por si `interactions` se cae del preview.
- Key mala = **400** `API_KEY_INVALID` (no 401). 403/404 en `interactions` es
  el endpoint, no el modelo — el mensaje debe apuntar bien.
- 429: respetar `retryDelay` (header o `RetryInfo`) una vez si ≤ 8 s; un
  `quotaId` con `PerDay` es terminal (cuota diaria), el resto es transitorio.
- El envelope de error difiere por endpoint (objeto vs array) — parser propio.
- Validación barata de key: `GET /v1beta/models?pageSize=1`.

### 4 · Caída a local

- Al seleccionar un modelo local se persiste `last_local_model_id`.
- Fallo de Gemini (sin red, timeout, 400 de key, cuota diaria) → cargar ese
  modelo al vuelo, transcribir, y evento post-hoc que el frontend muestra:
  *"Se transcribió con Cohere porque Gemini no respondió"*.
- Sin ningún modelo local descargado → el aviso lo dice y el dictado queda en
  el historial.
- Resolución pura y testeable sin red, como `resolve_mode_provider`.

### 5 · UI

- Tarjeta en el selector: badge EN LÍNEA, "Requiere API key de Google AI
  Studio", estado de la key en línea (validación con el GET barato) y enlace a
  la pestaña de claves. Toggle smart/verbatim.
- Privacidad explícita en la tarjeta: el audio del dictado se envía a Google.
- Selector de idioma muestra solo "Auto" para este motor.

### 6 · Pruebas

- Constructores de request y parsers como funciones puras con tests sin red
  (patrón `llm_client.rs`): body smart/verbatim/vocabulario, prohibición de
  `language_codes`, envelope `interactions`, mapeo de errores 400/429/PerDay.
- Verificación end-to-end por CI (artifacts de `test-macos-signing.yml`), no
  builds locales.

## Probe en vivo (2026-08-27, Mac de Alfonso, key real, audio es-MX de 9,6 s con muletilla y autocorrección)

- **Batch `interactions` smart con WAV directo:** HTTP 200 en **3,3 s**;
  salida limpia perfecta: eliminó el "eh" y colapsó "a las 3. No, mejor a las
  4" → *"…la reunión queda para el jueves a las 4 de la tarde…"*.
- **Live `gemini-3.5-transcribe-live` (WebSocket):** setup 1,4 s; primer
  parcial 1,5 s después de empezar el audio; parciales siguen el habla en
  tiempo real (verbatim durante el parcial, smart en el final); **final 0,6 s
  después del fin del audio**, mismo texto limpio. Sesión con tope de 10 min
  (`goAway`).

## Fase 2 — Live por WebSocket (evaluado, pendiente de diseño propio)

La transcripción en vivo actual no satisface (evaluación de Alfonso:
2026-08-27) y el probe muestra que el live de Gemini la supera de lejos.
Protocolo ya documentado: WS a
`…/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent`,
setup `{model: "models/gemini-3.5-transcribe-live", inputAudioTranscription:
{mode: "SMART"}, realtimeInputConfig: {automaticActivityDetection: {disabled:
true}}}` (VAD manual: los turnos los decide el atajo, no el servidor), audio
`audio/pcm;rate=16000` base64, eventos `interim/inputTranscription`
(camelCase **y** snake_case), `activityStart/End`. Cuidados: pool de sockets
pre-calentados para que el primer parcial no pague el setup (Jot:
`WarmEnginePool`), reconexión ante `goAway`, y `supports_streaming: true`
solo para el preview de dictado — reuniones siguen fuera. **No autoriza
implementación: necesita su diseño y plan.**

## Fuera de alcance

Reuniones/diarización con Gemini, traducción, streaming en fase 1, FLAC.
