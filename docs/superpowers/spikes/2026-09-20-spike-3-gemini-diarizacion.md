# Spike 3 — diarización de Gemini por `:generateContent` (2026-09-20)

Compuerta de entrada del plan de reuniones
(`specs/2026-08-27-reuniones-en-linea-design.md` → "Verificación pendiente").
El probe original es TypeScript y esta máquina no tiene bun ni node, así que se
portó a Python 3.9 de sistema.

## Qué se portó

`scripts/probes/gc-probe.py` — port de `gc-probe.ts`, sin dependencias externas
(`urllib`, `json`, `subprocess`, `wave`). Diferencias con el original:

- **Key desde el Llavero**, no desde el settings store de Dilo (que en esta
  máquina no existe): `security find-generic-password -a dilo -s
  dilo-gemini-api-key -w`. Viaja solo en el header `x-goog-api-key`; nunca en la
  URL ni en un log. Sin key: mensaje con el comando para agregarla y **salida 2**.
- **Genera sus audios** con `say` y los arma con `wave` (400 ms de silencio entre
  turnos), en `/Volumes/SSD2/scratch/dilo-probes/` — fuera del repo, porque SSD2
  es caché regenerable. Dos archivos, 16 kHz mono PCM 16-bit:
  - `reunion-2.wav` — 20,4 s, 2 voces (Mónica es_ES / Eddy es_MX), 5 turnos.
  - `reunion-5.wav` — 21,5 s, 5 voces (Mónica, Eddy es_MX, Paulina, Rocko es_ES,
    Grandma es_ES), un turno cada una. Hay 18 voces en español instaladas, así
    que los 5 hablantes del spec se cubren de verdad.
- **Reintento único** ante 429/503 con 8 s de espera (el 503 de congestión fue lo
  que bloqueó el probe del 2026-08-27).
- Imprime por audio: código HTTP y tiempo, si aceptó `audio/wav`, la forma exacta
  de la respuesta (árbol de claves + las claves tipo `speaker`/`time`/`word`/
  `segment` que aparezcan en cualquier nivel), si hay etiquetas de hablante
  dentro del texto, el texto transcrito y 3000 caracteres del JSON crudo.

El body es el mismo del probe TS: `inline_data` con `audio/wav` y
`generationConfig.audioTranscriptionConfig {wordTimestamp: true, diarization:
true}`. Se mantiene sin `mode` a propósito: el spec del motor documenta que
`mode` no funciona en `:generateContent` y la salida sale verbatim.

## Cómo correrlo

```bash
security add-generic-password -a dilo -s dilo-gemini-api-key -U -w   # pide la key por teclado
python3 scripts/probes/gc-probe.py
```

`--solo-audio` regenera los WAV sin llamar a la API ni necesitar la key;
`--solo 2` / `--solo 5` corren un audio solo. Cada respuesta cruda queda en
`<scratch>/respuesta-<audio>.json`.

## Resultados (2026-09-20, 13:31–13:34 -03)

**La compuerta se abre.** Evidencia cruda en
`/Volumes/SSD2/scratch/dilo-probes/`: `respuesta-reunion-2.json`,
`respuesta-reunion-5-20s.json`, `respuesta-reunion-5.json` (el 403) y
`salida-2026-09-20.txt`.

**1 · Formato.** No hay etiquetas de hablante dentro del texto: la diarización
es **estructural**. `candidates[0].content.parts[]` trae **una part por turno**,
cada una con `text` y `audioTranscription {text, speakerLabel, words[]}`, donde
`speakerLabel` es `"spk:0"`, `"spk:1"`… y cada `word` es
`{word, startOffset, endOffset}` en segundos con string tipo `"12.600s"`.
Timestamps **por palabra**, y el rango del turno sale del primer y último word.
La salida es verbatim con puntuación (confirma que `mode` no aplica acá).

**2 · `audio/wav`.** Aceptado: HTTP 200 con `inline_data` `audio/wav` directo,
3,0–3,6 s por audio de 20 s. **No exige FLAC.**

**3 · Hablantes.** Con **2 voces** (20,4 s, 5 turnos): 2 etiquetas exactas,
turnos bien cortados y texto perfecto salvo puntuación. Con **5 voces** (recorte
de 20 s, 5 turnos): 5 turnos pero **4 etiquetas** — fundió a las dos voces
femeninas (Mónica es_ES y Paulina es_MX) en `spk:0`; un error de texto
("va bien, cerramos" → "va de cerramos"). O sea: separa bien turnos y timbres
distintos, y confunde voces parecidas.

**Trampa nueva — 403 mentiroso por tamaño.** El archivo de 5 voces completo
(21,5 s, 687.632 bytes) devolvió **403 `PERMISSION_DENIED` / `SERVICE_DISABLED`**
("Gemini API has not been used in project…"), dos veces, con 200 de la misma key
y el mismo endpoint antes y después. Recortado a 20 s (640.044 bytes) pasa a
200. El de 2 voces (654.070 bytes) también pasa. El umbral está entre 654 KB y
688 KB de WAV (~872–917 KB ya en base64): el envelope culpa al proyecto, pero es
el tamaño del request. Hay que confirmarlo y **el cliente no debe creerle al 403**.
También aparecieron **429** al encadenar llamadas seguidas; el reintento a 8 s
del probe las absorbe.
