# Dilo — Reuniones en línea (transcripción cloud detrás de un contrato)

**Fecha:** 2026-08-27 · **Estado:** diseño aprobado por Alfonso en conversación; **compuerta de entrada pendiente** (ver §Verificación) · **Base:** [2026-08-27 Motor Gemini Transcribe](2026-08-27-motor-gemini-transcribe-design.md), plan [2026-08-07 Capturar y no botar](../plans/2026-08-07-capturar-y-no-botar.md), spec [2026-07-22 Plataforma conversacional abierta](2026-07-22-dilo-plataforma-conversacional-abierta.md)

## El problema

El motor de reuniones local no satisface (evaluación de Alfonso, 2026-08-27:
"no da el ancho, el motor de reuniones es pobre, no sirve como están").
Nemotron streaming —el único modelo del catálogo con streaming + timestamps
por token— fue borrado de su disco por decisión explícita y **no se
restaura**: las reuniones se rearman sobre transcripción en línea. Sortformer
además topa en 4 hablantes; el batch de Gemini 3.5 Transcribe diariza hasta 8.

## Decisiones tomadas (con Alfonso)

- **No re-descargar Nemotron.** Reuniones deja de depender de ASR streaming
  local.
- **Gemini primero, detrás de un contrato reemplazable** (`MeetingTranscriber`).
  Segunda implementación futura: AWS (Amazon Transcribe o Nova, con los
  créditos existentes) — el "quizás también Bedrock" entra por ahí, sin que el
  núcleo sepa de ningún proveedor concreto. Es la regla de la dirección de
  producto: capacidades externas por contratos genéricos.
- **Reuniones pasa a ser una feature con-red.** Sin conexión, la grabación
  igual queda (capturar y no botar) y el repaso corre al reconectar. Coherente
  con la prioridad online-antes-que-presencial.
- **Orden de trabajo:** fase 1 del dictado primero (construye el cliente
  Gemini que reuniones reutiliza); reuniones-en-línea después.

## Diseño

### 1 · Contrato

`MeetingTranscriber` (trait): recibe audio mezclado 16 kHz mono y devuelve
(a) texto corrido en vivo y (b) transcript final con hablantes y tiempos.
Implementación 1: Gemini. El resto de la tubería de reuniones (resumen,
action items, notas) consume el contrato, no al proveedor.

### 2 · En vivo (durante la reunión)

- La **mezcla** de las dos fuentes (capa −1 de capturar-y-no-botar) alimenta
  **Gemini live por WebSocket** (`gemini-3.5-transcribe-live`, protocolo ya
  documentado en el spec del motor de dictado).
- Transcript corrido, limpio (smart), **sin hablantes** — limitación real del
  modelo live, la doc lo dice explícito.
- Reconexión transparente en el tope de 10 min por sesión (`goAway`); los
  cortes de red no detienen la grabación, sólo el texto en vivo.

### 3 · Al terminar (el transcript que vale)

- El audio completo grabado va por **batch con diarización**: hoy eso vive en
  `:generateContent` con `audioTranscriptionConfig { wordTimestamp: true,
diarization: true }` (verificado por Jot que el campo existe en esa
  superficie; `interactions` lo rechaza — probado 2026-08-27: `Unknown
parameter 'diarization'`).
- Trozos de **≤ 30 min** (límite documentado con diarización/timestamps
  activos), hasta 8 hablantes.
- El transcript final con hablantes **reemplaza** al corrido en la nota, y
  alimenta resumen y action items como hoy. La limpieza smart del final la
  aporta el paso de resumen LLM que ya existe (smart no funciona en
  `:generateContent`).
- Sirve también para reparación retroactiva de reuniones ya grabadas
  (opcional, se decide en el plan).

### 4 · Lo local queda, pero deja de mandar

- Sortformer y 3dspeaker **no se borran**: el plan de captura usa Sortformer
  como árbitro de cobertura (capa 1). Su semántica ("lo que el ASR realmente
  recibió") tendrá que adaptarse cuando el ASR sea cloud — se resuelve en el
  plan de este spec, no se rompe capturar-y-no-botar.
- El dictado no cambia: su motor, su VAD y su camino son otros.

### 5 · Privacidad y costo

- El audio de la reunión —incluidas las voces de otras personas— sale a
  Google: la UI de reunión lo dice de forma visible antes de grabar, con la
  misma honestidad LOCAL/EN LÍNEA del resto del producto.
- Costo estimado: ~US$0,54/h el vivo + ~US$0,30/h el repaso; gratis durante el
  preview público.

## Verificación pendiente (compuerta de entrada del plan)

El endpoint `:generateContent` del modelo estuvo **503 por congestión de
lanzamiento** todo el probe del 2026-08-27, así que quedan sin verificar:

1. El **formato de respuesta** de la diarización (¿etiquetas de hablante en el
   texto? ¿estructura con tiempos?).
2. Si diarización + timestamps aceptan `audio/wav` como `interactions`, o
   exigen FLAC.
3. El comportamiento real con 2 y con 5+ hablantes en español.

El plan de implementación **no se ejecuta** hasta correr esa verificación.
Los probes viven en `scripts/probes/` (`gc-probe.ts` es el de diarización;
leen la key del settings store en runtime y no la contienen): repetir
`bun scripts/probes/gc-probe.ts` cuando afloje el 503 y pegar los resultados
aquí. Los audios de prueba se regeneran con `say` (ver bitácora 2026-08-27).

## Fuera de alcance

Reuniones presenciales (siguen sólo-micrófono y locales como estén),
implementación AWS (sólo el contrato queda listo), reemplazo de Sortformer en
el arbitraje de cobertura, y cualquier cambio al dictado.
