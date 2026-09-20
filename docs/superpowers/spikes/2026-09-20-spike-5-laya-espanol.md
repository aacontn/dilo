# Spike 5 — Laya multilingüe en español, y desde Swift

**2026-09-20** · Apple M1, 16 GB, macOS 27, Xcode 27 / Swift 6.4. Cubre el punto 5
de "Verificación pendiente" de `2026-09-20-dilo-mac-nativo-design.md`. Modelo:
`convaiinnovations/laya-multilingual` (mmBERT-base, 322M, Apache 2.0). Puerto:
`mizorewww/laya-coreml`, bundles `aac6fef/laya-multilingual-coreml{,-ane}`.

## Veredicto

**No entra como implementación por defecto.** El 65 % de acierto de Laya queda
bajo "usa la app que está al frente", que acierta 100 % en este set y cuesta
cero. El puerto Core ML funciona y desde Swift da el mismo número con 5e-05 de
deriva: el problema es el modelo, no el camino.

## Set de evaluación

40 dictados sintéticos en español chileno (muletillas, spanglish técnico), 8 por
modo: `codigo`, `correo`, `chat`, `nota`, `terminal`, cada uno con la app al
frente. Archivo: `laya-eval-es.json`. **Limitación honesta:** acá la app
determina el modo uno a uno; sirve para ver si el modelo le gana a la heurística
trivial, no para medir el caso difícil (dos modos dentro de la misma app).

## Parte A — Python

| Variante | Acierto | P clase correcta | P50 | P95 |
|---|---:|---:|---:|---:|
| Laya, pregunta en español, **con app** — CPU | **65,0 %** | 0,619 | 138,2 ms | 210,1 ms |
| Laya, pregunta en español, **con app** — MPS | 65,0 % | 0,619 | **65,6 ms** | 178,5 ms |
| Laya, pregunta en español, **sin app** — CPU | 42,5 % | 0,377 | 119,4 ms | 175,6 ms |
| Laya, pregunta en español, **sin app** — MPS | 42,5 % | 0,377 | 62,0 ms | 173,1 ms |
| Laya, **pregunta en inglés**, dictado en español — MPS | 77,5 % | — | 57,3 ms | — |
| Base: keywords (20 líneas), con app | 100 % | — | 0,013 ms | — |
| Base: keywords (20 líneas), sin app | 85,0 % | — | 0,010 ms | — |
| Base: "el modo es la app al frente" | 100 % | — | ~0 ms | — |

CPU y MPS dan exactamente las mismas respuestas; MPS solo baja la latencia ~2×.
Azar = 20 %. El contexto de app vale 22,5 puntos, pero ese contexto solo ya vale 100 %.

### Qué confunde con qué (con app)

| Modo real | Aciertos | Se va a |
|---|---:|---|
| `nota` | 8/8 | — |
| `terminal` | 8/8 | — |
| `chat` | 7/8 | `terminal` ×1 |
| `codigo` | **2/8** | `terminal` ×5, `nota` ×1 |
| `correo` | **1/8** | `nota` ×5, `chat` ×2 |

1. **`codigo` colapsa en `terminal`.** "agrégame un test pal endpoint de login" y
   "mata el proceso del puerto 3000" caen en la misma clase. Para Laya, pedir
   algo técnico es una sola categoría. Es justo el corte que Dilo necesita.
2. **`correo` colapsa en `nota`.** Un mail con "Estimado" y "quedo atento" se
   clasifica como nota para uno mismo: el registro formal no le dice nada.

La pregunta en inglés sube 12,5 puntos con los mismos dictados en español, así
que parte del problema es que entiende peor las **instrucciones** en español.
Aun así `codigo` sigue cayendo 6/8 en `terminal`: la distinción no está en el modelo.

## Parte B — Core ML y Swift

### Fidelidad (compuerta: < 0,02)

| Comparación | Deriva máxima | Elecciones iguales |
|---|---:|---:|
| PyTorch CPU vs Core ML CPU+GPU (Python) | 0,0039 | 40/40 |
| Core ML Python vs **Core ML Swift** | **0,00005** | **40/40** |

### Latencia en este M1 (40 dictados × 19 repeticiones = 760 muestras)

| Camino | Unidades | P50 | P95 | Acierto |
|---|---|---:|---:|---:|
| Core ML 1024, Python | CPU+GPU | 42,2 ms | 564,6 ms | 65,0 % |
| Core ML 1024, Python | CPU | 290,7 ms | 396,4 ms | 65,0 % |
| **Core ML 1024, Swift** | **CPU+GPU** | **38,0 ms** | **38,9 ms** | 65,0 % |
| Core ML 1024, Swift | CPU | 258,7 ms | 300,7 ms | 65,0 % |
| Core ML 1024, Swift | CPU+ANE | 262,4 ms | 312,7 ms | 65,0 % |
| Core ML ANE 96 tok (pregunta corta), Python | CPU+ANE | **7,0 ms** | 7,3 ms | 57,5 % |

- El `.mlpackage` general **no corre en el Neural Engine**: `cpu_ne` da lo mismo
  que CPU. Es el export SDPA, no el grafo ANE; el README del puerto lo dice.
- Los **5 ms del M3 Max son 7,0 ms acá**, y solo con el bundle ANE de 96 tokens.
  Nuestro prompt con las descripciones de los modos pide **204 tokens**: no cabe.
  Recortado a solo las etiquetas (71 tokens) corre, y el acierto baja a 57,5 %.
- **La ANE no es usable desde Swift hoy.** Su grafo no recibe `input_ids`, sino
  `embeddings [1,768,1,96]`, `full_mask`, `local_mask`, `type_vectors` y
  `marker_map`. La tabla de embeddings (256000×768) y la cabeza de acción
  (772→256→2) viven en `host_weights.safetensors` y hoy las corre numpy.
  Portarlas a Swift: estimo **1 a 2 días**, no 50 líneas. No se hizo.

### El Swift sí funciona (variante general)

~160 líneas en `/Volumes/SSD2/laya/swift-spike/` (fuera del repo): carga el
`.mlpackage`, tokeniza con `swift-transformers` 0.1.24, rearma la secuencia
`[CLS] tipo question: … [SEP] [MASK] opt … [SEP] estado [SEP]` y hace softmax
sobre los marcadores. Dos cosas que saber si esto se retoma: **(a)
`swift-transformers` ignora `prepend_scheme: "always"`** del pre-tokenizador
Metaspace — sin corregirlo dos tokens por secuencia salen distintos (`choice` en
vez de `▁choice`) y la deriva llega a **0,196**, diez veces la compuerta; el
parche acá es anteponer un espacio, en producción es un bug a reportar. **(b)**
`rl_agent_config.json` trae `temperature = [1,1,1]` y `temperature_by_options`
vacío: no hay calibración que replicar, pero un checkpoint futuro podría traerla.

## Qué hacer

1. **La implementación por defecto se queda en Apple** (FoundationModels guiado),
   como decía el riesgo 7 del spec.
2. Para v1.5 ("un atajo, Dilo decide") **la app al frente es casi toda la señal**
   y cuesta cero. Ese es el primer clasificador, no un modelo de 647 MB.
3. Laya vuelve a la mesa solo si se mide **reentrenada con dictados reales de
   Alfonso** — lo único que el spec le pedía de verdad y que este spike no midió.
4. Queda pendiente el número de FoundationModels guiado sobre este mismo set.

## Reproducir

Los scripts son regenerables y viven en `/Volumes/SSD2/laya/`, no en el repo.

```bash
brew install python@3.12
/opt/homebrew/bin/python3.12 -m venv /Volumes/SSD2/laya/venv
cd /Volumes/SSD2/laya && venv/bin/pip install laya laya-coreml torch coremltools numpy
export HF_HOME=/Volumes/SSD2/hf-cache LAYA_COREML_CACHE=/Volumes/SSD2/laya/coreml-cache
venv/bin/python eval_py.py cpu con_app        # y: mps / sin_app
venv/bin/python eval_keywords.py con_app
venv/bin/hf download aac6fef/laya-multilingual-coreml     --local-dir models/ml-1024
venv/bin/hf download aac6fef/laya-multilingual-coreml-ane --local-dir models/ml-ane
venv/bin/python eval_coreml.py
cd swift-spike && swift build -c release --scratch-path /Volumes/SSD2/laya/swift-build
/Volumes/SSD2/laya/swift-build/out/Products/Release/LayaSpike /Volumes/SSD2/laya/models/ml-1024 \
  "/Volumes/SSD 1/Dilo/app/docs/superpowers/spikes/laya-eval-es.json" cpu_gpu 20
```
