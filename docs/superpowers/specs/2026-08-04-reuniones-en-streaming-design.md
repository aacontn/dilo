# Dilo — Reuniones en streaming: sin turnos, con diarización continua

**Fecha:** 2026-08-04 · **Estado:** diseño aprobado por Alfonso en conversación · **Base:** [notetaker usable](2026-07-31-notetaker-usable-design.md) §2, que proponía la doble vía, y las mediciones sobre la base real del 2026-08-03/04

## De dónde sale esto

Alfonso probó reuniones reales durante dos días y llegó al diagnóstico antes que yo:

> "Y por qué no va haciendo streaming como Wispr Flow, y va reconociendo cuando cambia el hablante, por identificación de audio. Creo que por turnos no es la solución."

Tiene razón, y las mediciones sobre su propia base lo respaldan.

### Lo que se midió

| Grabación                            | Capturado | Trozo promedio |
| ------------------------------------ | --------- | -------------- |
| Video con música (antes)             | **21%**   | 2,6 s          |
| Debate, habla limpia                 | 87%       | 6,3 s          |
| Video con música (tras sacar el VAD) | **82%**   | 4,4 s          |

Sacar el VAD del camino de reuniones subió la captura de 21% a 82% y redujo el hueco máximo de **39 segundos a 2,6**. Eso ya está hecho y en `main`.

Pero quedaron dos síntomas que **no se arreglan afinando constantes**:

1. **Las interrupciones cortas se pierden.** Media frase de alguien pisando a otro no cabe en el modelo de "turnos".
2. **No se ve como streaming.** Pasa un rato y aparece un bloque, en vez de escribirse a medida que se habla — a diferencia del dictado, donde Nemotron sí lo hace.

## Por qué el turno es el problema

El pipeline actual decide tres veces qué descartar: el VAD marca qué es voz (ya salió), un acumulador junta un turno hasta que hay silencio o se llega al tope de 8 segundos, y recién ahí se transcribe ese pedazo **aislado**.

Una interrupción es lo que peor le cae a ese diseño: es corta, cae **encima** de otra voz, y no tiene principio ni final propios. El sistema o la absorbe en el turno del que ya hablaba, o la descarta por mezclada.

**Google Live Caption y Wispr Flow no las pierden porque nunca deciden qué es un turno.** Corren dos flujos continuos en paralelo y el texto sale y se corrige solo. (Verificado en el binario de Wispr: manda audio por WebSocket sin cortar y recibe `partial`/`final`, con la diarización resuelta en su servidor.)

### Una corrección importante sobre el diseño anterior

§2 del diseño del 31 de julio proponía **doble vía**: un modelo con streaming para el texto tentativo y el modelo bueno reemplazándolo al cerrar el turno. **Eso no arregla las interrupciones**, y es un error que casi se implementa: el tentativo las mostraría y la versión definitiva —que sigue siendo por turnos— las borraría al reemplazar. Peor que no mostrarlas.

La doble vía arregla que _se vea_ vivo. No arregla lo que se pierde.

## El diseño

**El turno deja de existir como unidad.** Dos flujos continuos, en paralelo, ninguno decidiendo dónde empieza y termina una intervención:

### 1 · Reconocimiento continuo

Un modelo con streaming consume el audio y emite texto que se corrige sobre la marcha. **Nemotron Streaming 3.5** ya está en el catálogo, ya funciona en el camino de dictado, y `StreamTextEvent { committed, tentative }` ya existe y lo consume el overlay.

Lo que falta no es la cañería: es conectarla a reuniones. Hoy `meeting.rs` no la usa — su único rastro es un comentario diciendo que no se usa.

### 2 · Diarización continua

**Streaming Sortformer** (NVIDIA) reemplaza las tres piezas actuales —segmentación, embeddings y el registro incremental con umbrales— por **una sola** que hace detección de voz, cambio de hablante, solapes y atribución, en streaming, con un caché interno que mantiene la identidad entre trozos.

Las etiquetas de hablante se **pegan al texto según cambia la voz**, en vivo. No hay corte previo del audio.

### Por qué Sortformer y no otro

| Modelo                      | DER                   | Hablantes   | Por qué no                                |
| --------------------------- | --------------------- | ----------- | ----------------------------------------- |
| **Sortformer v2 streaming** | **7,0%** (AliMeeting) | 4           | **Elegido**                               |
| LS-EEND                     | peor                  | 8, flexible | Menos preciso y sin implementación usable |
| DiariZen                    | 13,3%                 | flexible    | Python + PyTorch: no entra en Tauri       |
| PyannoteAI                  | 11,2%                 | flexible    | Comercial                                 |

Sortformer le gana a LS-EEND y EEND-GLA en pruebas reales y es el más rápido por lejos (214× tiempo real). Es **ONNX opset 17** → corre con `ort`, que Dilo ya usa, sin dependencias nuevas. Licencia **CC-BY-4.0** en la versión **v2** — la misma de canary, que ya distribuimos.

**Ojo con la versión, verificado el 2026-08-04:** `diar_streaming_sortformer_4spk-v2` es CC-BY-4.0, pero `…-v2.1` cambió a `nvidia-open-model-license`, que hay que leer antes de distribuir. **Se usa v2**, y no v2.1, precisamente por eso.

**Y hay una implementación de referencia:** el fork de sherpa-onnx del [issue #3497](https://github.com/k2-fsa/sherpa-onnx/issues/3497) reporta ~99,5% de paridad con NeMo, probado con 2-4 hablantes en audios de 10 a 60 minutos. Nuestra diarización actual la portamos de sherpa-onnx, así que traducir ese código a Rust es territorio conocido.

## La primera tarea es bloqueante y puede matar el plan

**Probar Sortformer contra audio real en español de Alfonso y comparar contra la diarización actual, antes de tocar el pipeline.**

Sortformer está entrenado principalmente en inglés y NVIDIA advierte degradación en otros idiomas. La diarización depende de características de la voz más que de las palabras, así que suele sufrir menos que un ASR — **pero es un supuesto**, y creerle a un supuesto de este tipo ya salió caro antes (ver la nota sobre licencias y modelos).

Si no rinde en español, se sabe en un día y no en tres semanas, y el plan se detiene ahí.

## Lo que se gana y lo que se pierde

**Se gana:** las interrupciones aparecen, el texto se escribe mientras se habla, y desaparecen tres constantes que hoy hay que adivinar (`TURN_SILENCE_GAP`, `MAX_TURN_MS`, los umbrales de similitud).

**Se pierde el tope de hablantes.** Hoy el registro incremental no tiene límite porque agrupa por similitud; Sortformer topa en **4** y degrada con 5 o más. Para reuniones de 2 o 3 —el caso de Alfonso— sobra. Para una clase, no.

**Cuesta memoria:** dos modelos cargados a la vez, el de reconocimiento continuo (Nemotron, 751 MB) y Sortformer (471 MB), además de lo que ya corre. En 16 GB hay que medirlo, no suponerlo.

## Alcance

**Entra:** la prueba en español como paso bloqueante, el reconocimiento continuo conectado a reuniones, Sortformer portado y sustituyendo la diarización actual en el camino de reuniones, y la presentación del transcript escribiéndose en vivo.

**No entra:**

- **El dictado no cambia.** Su camino, su VAD y su modelo se quedan exactamente como están.
- **Sortformer no reemplaza la diarización de reuniones ya grabadas.** Lo persistido no se re-procesa.
- **Resumen, action items y preguntar al transcript.** Donde estaban.
- **La app móvil y el presencial de campo lejano.** El presencial sigue detrás del micrófono que no tenemos.

## Restricciones transversales

- **Sin dependencias nuevas**: Sortformer entra por el `ort` que ya está.
- **Copy es-first**, autoral, tuteo chileno; claves en los 21 idiomas.
- Un `settings.json` viejo tiene que cargar sin tocarse.
- El tope de 4 hablantes hay que **decirlo en la interfaz**, no esconderlo: cuando se detecten más, el usuario tiene que entender por qué la atribución se degrada.

## Verificación

- **La prueba en español**, primero y bloqueante: comparar Sortformer contra la diarización actual sobre audio real de Alfonso, con números, no impresiones.
- **Las interrupciones aparecen**: grabar una conversación donde alguien pise a otro y confirmar que la interrupción queda en el transcript con su hablante.
- **Se escribe en vivo**: que el texto crezca mientras se habla, como ya se ve en el dictado con Nemotron.
- **Memoria medida** con los dos modelos cargados, en una máquina de 16 GB.
- **El dictado intacto**: medir que su latencia y su reposo no cambian.
- **Cobertura**: que el porcentaje de audio capturado no baje del 82% que se logró al sacar el VAD.
