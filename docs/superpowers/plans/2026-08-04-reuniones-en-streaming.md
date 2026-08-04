# Reuniones en streaming — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que el transcript de una reunión se escriba mientras se habla y no pierda las interrupciones, reemplazando el troceo por turnos con dos flujos continuos.

**Architecture:** Nemotron Streaming reconoce de forma continua y emite tokens **con marca de tiempo por token** (`"timestamps": "token"` en su catálogo). Streaming Sortformer diariza de forma continua y emite tramos con hablante y tiempo. Un alineador pega hablante a cada token por búsqueda temporal. Desaparecen el acumulador de turnos, el tope de 8 s, el umbral de silencio y los umbrales de similitud.

**Tech Stack:** Rust + Tauri 2, ONNX vía `ort` (ya en el árbol), `transcribe-rs`/`transcribe-cpp` para el ASR, React + TypeScript para la presentación.

## Global Constraints

- **El dictado no cambia.** Su camino, su VAD y su modelo se quedan idénticos. Todo lo de este plan es aditivo o sólo del camino de reuniones.
- **Sin dependencias nuevas.** Sortformer entra por el `ort` que ya está. Verificar con `cargo tree` y el diff de `Cargo.lock` en cada tarea que lo toque.
- **Copy es-first, autoral, tuteo chileno.** Nunca voseo ("preferís", "querés", "podés", "elegí", "mirá"). El locale `es` no se genera a máquina. Claves en los 21 idiomas o `bun run check:translations` falla.
- **Nada de `Co-Authored-By` ni atribución de IA** en los mensajes de commit.
- **Un `settings.json` viejo debe cargar sin tocarse**: campos nuevos con `#[serde(default)]`.
- **El catálogo de modelos sólo crece**: no se borra ninguno de los 13 existentes.
- **El tope de 4 hablantes se dice en la interfaz**, no se esconde.
- **`src/bindings.ts` NO se edita a mano.** Se regenera con `cd src-tauri && cargo build && ./target/debug/dilo --list-devices`.
- Gates antes de cada commit: `cargo fmt`, `cargo clippy --all-targets` (0 warnings nuevos), `cargo test --lib`, `bun test tests/unit`, `bun run build`, `bun run lint`, `bun run format:check`, `bun run check:translations`. **Corridos de verdad, no declarados.**

## Estructura de archivos

| Archivo                                                      | Responsabilidad                                                                                                         |
| ------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------- |
| `src-tauri/src/managers/diarization/sortformer.rs` _(nuevo)_ | Inferencia de Sortformer en ONNX: sesión, ventana deslizante, caché de hablantes. Sólo el modelo.                       |
| `src-tauri/src/managers/diarization/align.rs` _(nuevo)_      | Alineación pura entre tokens con tiempo y tramos con hablante. Sin ONNX, sin estado: es donde vive la lógica testeable. |
| `src-tauri/src/managers/diarization.rs` _(modificar)_        | Pasa a ser el módulo padre; conserva la diarización por lotes actual, que sigue sirviendo a lo ya grabado.              |
| `src-tauri/src/managers/meeting.rs` _(modificar)_            | Reemplaza el acumulador de turnos por el consumo de los dos flujos. Es el archivo que más adelgaza.                     |
| `src-tauri/src/catalog/catalog.json` _(modificar)_           | Entrada del modelo Sortformer.                                                                                          |
| `src/components/meeting/TranscriptList.tsx` _(modificar)_    | Presenta texto que crece, con hablante por tramo.                                                                       |
| `src/i18n/locales/*/translation.json` _(modificar)_          | Copia del aviso de tope de hablantes.                                                                                   |

---

### Task 1: ¿Sirve Sortformer en español? (bloqueante — puede matar el plan)

Sortformer está entrenado principalmente en inglés y NVIDIA advierte degradación fuera de él. **Si no rinde en español, este plan se detiene acá.** Por eso es la primera tarea y no la última.

**Files:**

- Create: `src-tauri/src/managers/diarization/sortformer_probe.rs` (temporal, se borra en la Task 2 si el plan sigue)
- Test: el mismo archivo, con un test `#[ignore]` que corre a mano

**Interfaces:**

- Consumes: nada.
- Produces: sólo un veredicto humano. No deja API para las tareas siguientes.

- [ ] **Step 1: Descargar el modelo a mano, fuera del catálogo**

```bash
mkdir -p /tmp/sortformer && cd /tmp/sortformer
curl -L -o sortformer.onnx \
  "https://huggingface.co/Scrybl/diar_streaming_sortformer_4spk-v2.1/resolve/main/model.onnx"
ls -la sortformer.onnx
```

Si el nombre del archivo no es ese, míralo en la página del repo antes de inventar una ruta. **No lo agregues al catálogo todavía** — hasta que la prueba pase, este modelo no existe para Dilo.

- [ ] **Step 2: Escribir la sonda**

Un test `#[ignore]` que:

1. Lee un WAV de 16 kHz mono desde una ruta pasada por variable de entorno (`DILO_SORTFORMER_WAV`).
2. Corre Sortformer sobre él con `ort`.
3. Imprime los tramos detectados: `inicio → fin | hablante`.
4. Corre **también** la diarización actual (`DiarizationEngine::diarize`) sobre el mismo audio e imprime sus tramos.

Usa `audio_toolkit::audio::read_wav_samples`, que ya existe, para leer el WAV.

El objetivo es **comparar las dos salidas sobre el mismo audio**, no medir en abstracto.

- [ ] **Step 3: Correrla con audio real en español**

Alfonso tiene reuniones grabadas. Para extraer el audio de una, o para grabar una de prueba, **pídeselo a él** — no inventes un corpus sintético, que es justo lo que no prueba nada.

Run:

```bash
DILO_SORTFORMER_WAV=/ruta/al/audio.wav cargo test --manifest-path src-tauri/Cargo.toml --lib -- --ignored sortformer_probe --nocapture
```

- [ ] **Step 4: Escribir el veredicto**

En el reporte, con números, no impresiones:

- ¿Cuántos hablantes detectó cada uno, contra cuántos hay de verdad?
- ¿Los cambios de hablante caen donde corresponde?
- ¿Cuánto tardó Sortformer por segundo de audio?

**Si Sortformer es peor que lo que ya tenemos en español, di eso y detente.** El plan no continúa. Es un resultado válido y barato, no un fracaso.

- [ ] **Step 5: Commit sólo si el veredicto es favorable**

```bash
git add src-tauri/src/managers/diarization/sortformer_probe.rs
git commit -m "test(diarization): sonda para comparar Sortformer contra la diarización actual en español"
```

---

### Task 2: Sortformer en streaming

Convertir la sonda en un motor de verdad: ventana deslizante, caché de hablantes entre trozos, y salida incremental.

**Files:**

- Create: `src-tauri/src/managers/diarization/sortformer.rs`
- Modify: `src-tauri/src/managers/diarization.rs` (pasa a módulo padre, `mod sortformer;`)
- Delete: `src-tauri/src/managers/diarization/sortformer_probe.rs`

**Interfaces:**

- Consumes: nada de tareas previas.
- Produces:
  - `pub struct SpeakerSpan { pub start_ms: u64, pub end_ms: u64, pub speaker: u8 }`
  - `pub struct StreamingDiarizer` con:
    - `pub fn load(model_path: &Path) -> Result<Self>`
    - `pub fn push(&mut self, samples: &[f32]) -> Result<Vec<SpeakerSpan>>` — recibe audio a 16 kHz y devuelve los tramos **nuevos** desde la última llamada.
    - `pub fn reset(&mut self)` — limpia el caché de hablantes al terminar una reunión.
  - `pub const SORTFORMER_MAX_SPEAKERS: u8 = 4;`

- [ ] **Step 1: Escribir los tests que fallan**

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spans_no_se_solapan_ni_retroceden() {
        // Invariante del contrato: `push` devuelve tramos nuevos, en orden,
        // sin pisarse. Quien consuma esto asume que puede concatenar.
        let spans = vec![
            SpeakerSpan { start_ms: 0, end_ms: 1000, speaker: 0 },
            SpeakerSpan { start_ms: 1000, end_ms: 2500, speaker: 1 },
            SpeakerSpan { start_ms: 2500, end_ms: 3000, speaker: 0 },
        ];
        assert!(spans_are_monotonic(&spans));
    }

    #[test]
    fn spans_solapados_se_detectan() {
        let spans = vec![
            SpeakerSpan { start_ms: 0, end_ms: 2000, speaker: 0 },
            SpeakerSpan { start_ms: 1000, end_ms: 3000, speaker: 1 },
        ];
        assert!(!spans_are_monotonic(&spans));
    }

    #[test]
    fn el_tope_de_hablantes_es_el_del_modelo() {
        // Sortformer 4spk: cualquier id por encima de esto es un bug de
        // interpretación de la salida, no un hablante real.
        assert_eq!(SORTFORMER_MAX_SPEAKERS, 4);
    }
}
```

- [ ] **Step 2: Correr los tests y verificar que fallan**

Run: `cargo test --manifest-path src-tauri/Cargo.toml --lib sortformer::`
Expected: FAIL — `cannot find function spans_are_monotonic`

- [ ] **Step 3: Implementar**

Escribe `spans_are_monotonic(spans: &[SpeakerSpan]) -> bool` como función pura (cada tramo empieza donde o después de donde terminó el anterior), y el `StreamingDiarizer` alrededor.

Para la inferencia, **lee primero la implementación de referencia** del fork de sherpa-onnx (`https://github.com/scottyeager/sherpa-onnx/tree/sortformer-di`, del issue #3497) — reporta ~99,5% de paridad con NeMo y es C++ legible. Nuestra diarización actual se portó de sherpa-onnx, así que `managers/diarization.rs` te muestra cómo se hizo esa traducción a Rust: síguela.

El modelo tiene **caché de hablantes por orden de llegada** (Arrival-Order Speaker Cache): ese estado vive entre llamadas a `push` y es lo que mantiene la identidad. `reset()` lo limpia.

Elige el tamaño de chunk con criterio: el model card ofrece desde 3 frames (0,32 s de latencia) hasta 340 (30,4 s), con frames de 80 ms. **Justifica el elegido en el reporte** — para transcript en vivo, la latencia baja importa más que el contexto largo.

- [ ] **Step 4: Correr los tests y verificar que pasan**

Run: `cargo test --manifest-path src-tauri/Cargo.toml --lib sortformer::`
Expected: PASS

- [ ] **Step 5: Agregar el modelo al catálogo**

En `src-tauri/src/catalog/catalog.json`, con su `revision`, `sha256` y `size_bytes` reales — **verifícalos contra el archivo que descargaste**, no los inventes. Licencia CC-BY-4.0.

**No borres ninguno de los 13 modelos existentes.**

- [ ] **Step 6: Gates y commit**

```bash
cargo fmt --manifest-path src-tauri/Cargo.toml
cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets
cargo test --manifest-path src-tauri/Cargo.toml --lib
git add -A
git commit -m "feat(diarization): motor de diarización en streaming con Sortformer"
```

---

### Task 3: Marcas de tiempo por token en el reconocimiento continuo

El ASR hoy pide `TimestampGranularity::Segment`. Para alinear con los tramos de hablante hacen falta marcas **por token**, que Nemotron declara soportar (`"timestamps": "token"` en el catálogo).

**Files:**

- Modify: `src-tauri/src/managers/transcription.rs:1452` (la granularidad) y donde se emite `StreamTextEvent`
- Test: en el mismo archivo

**Interfaces:**

- Consumes: nada de tareas previas.
- Produces:
  - `pub struct TimedToken { pub text: String, pub start_ms: u64, pub end_ms: u64 }`
  - El evento de streaming pasa a llevar los tokens con tiempo además del texto plano que ya lleva. **No cambies la forma del texto que el overlay del dictado ya consume** — agrega, no reemplaces, o rompes el dictado.

- [ ] **Step 1: Escribir el test que falla**

```rust
#[test]
fn los_tokens_con_tiempo_conservan_el_texto_plano() {
    // El overlay del dictado consume `committed`/`tentative` como texto.
    // Agregar tokens con tiempo no puede cambiar lo que ese camino ve.
    let tokens = vec![
        TimedToken { text: "hola".into(), start_ms: 0, end_ms: 300 },
        TimedToken { text: " mundo".into(), start_ms: 300, end_ms: 700 },
    ];
    assert_eq!(plain_text(&tokens), "hola mundo");
}

#[test]
fn tokens_vacios_dan_texto_vacio() {
    assert_eq!(plain_text(&[]), "");
}
```

- [ ] **Step 2: Correr el test y verificar que falla**

Run: `cargo test --manifest-path src-tauri/Cargo.toml --lib timed_token`
Expected: FAIL — `cannot find type TimedToken`

- [ ] **Step 3: Implementar**

Define `TimedToken` y `plain_text(tokens: &[TimedToken]) -> String`. Cambia la granularidad a token **sólo en el camino de reuniones**: el dictado se queda con la que tiene hoy, salvo que comprobar lo contrario sea trivial y no cambie su comportamiento — y si lo cambias, dilo en el reporte.

Si el motor no expone marcas por token para el modelo elegido, **repórtalo en vez de fabricarlas interpolando**: sin marcas reales la alineación de la Task 4 no tiene base, y es mejor saberlo acá.

- [ ] **Step 4: Correr los tests y verificar que pasan**

Run: `cargo test --manifest-path src-tauri/Cargo.toml --lib timed_token`
Expected: PASS

- [ ] **Step 5: Gates y commit**

```bash
cargo fmt --manifest-path src-tauri/Cargo.toml
cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets
cargo test --manifest-path src-tauri/Cargo.toml --lib
git add -A
git commit -m "feat(transcription): marcas de tiempo por token para alinear con la diarización"
```

---

### Task 4: El alineador

Pegar hablante a cada token por búsqueda temporal. **Es pura, sin ONNX ni estado**: acá vive la lógica que de verdad se puede probar.

**Files:**

- Create: `src-tauri/src/managers/diarization/align.rs`
- Modify: `src-tauri/src/managers/diarization.rs` (`mod align;`)

**Interfaces:**

- Consumes: `SpeakerSpan` de la Task 2, `TimedToken` de la Task 3.
- Produces:
  - `pub struct AttributedRun { pub text: String, pub speaker: Option<u8>, pub start_ms: u64, pub end_ms: u64 }`
  - `pub fn attribute(tokens: &[TimedToken], spans: &[SpeakerSpan]) -> Vec<AttributedRun>` — agrupa tokens consecutivos del mismo hablante en un `AttributedRun`.

- [ ] **Step 1: Escribir los tests que fallan**

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn tok(text: &str, start_ms: u64, end_ms: u64) -> TimedToken {
        TimedToken { text: text.into(), start_ms, end_ms }
    }

    fn span(start_ms: u64, end_ms: u64, speaker: u8) -> SpeakerSpan {
        SpeakerSpan { start_ms, end_ms, speaker }
    }

    #[test]
    fn tokens_del_mismo_hablante_se_agrupan_en_una_intervencion() {
        let tokens = vec![tok("hola", 0, 300), tok(" que", 300, 600), tok(" tal", 600, 900)];
        let spans = vec![span(0, 1000, 0)];
        let runs = attribute(&tokens, &spans);
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].text, "hola que tal");
        assert_eq!(runs[0].speaker, Some(0));
    }

    #[test]
    fn el_cambio_de_hablante_parte_la_intervencion() {
        let tokens = vec![tok("hola", 0, 400), tok(" chao", 600, 900)];
        let spans = vec![span(0, 500, 0), span(500, 1000, 1)];
        let runs = attribute(&tokens, &spans);
        assert_eq!(runs.len(), 2);
        assert_eq!(runs[0].speaker, Some(0));
        assert_eq!(runs[1].speaker, Some(1));
    }

    #[test]
    fn una_interrupcion_corta_sobrevive_como_intervencion_propia() {
        // El caso que motivó todo el plan: media palabra de otro hablante
        // en medio, que el troceo por turnos perdía.
        let tokens = vec![
            tok("estaba", 0, 400),
            tok(" no", 450, 600),      // interrupción
            tok(" diciendo", 650, 1000),
        ];
        let spans = vec![span(0, 430, 0), span(430, 620, 1), span(620, 1000, 0)];
        let runs = attribute(&tokens, &spans);
        assert_eq!(runs.len(), 3, "la interrupción no puede fundirse con lo de al lado");
        assert_eq!(runs[1].text.trim(), "no");
        assert_eq!(runs[1].speaker, Some(1));
    }

    #[test]
    fn un_token_fuera_de_todo_tramo_queda_sin_hablante() {
        // Nunca adivinar: sin tramo que lo cubra, el hablante es None.
        let tokens = vec![tok("hola", 5000, 5300)];
        let spans = vec![span(0, 1000, 0)];
        let runs = attribute(&tokens, &spans);
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].speaker, None);
    }

    #[test]
    fn un_token_a_caballo_entre_dos_tramos_va_al_de_mayor_solape() {
        let tokens = vec![tok("hola", 400, 800)];
        let spans = vec![span(0, 500, 0), span(500, 1000, 1)];
        let runs = attribute(&tokens, &spans);
        // 100 ms en el hablante 0, 300 ms en el 1.
        assert_eq!(runs[0].speaker, Some(1));
    }

    #[test]
    fn sin_tokens_no_hay_intervenciones() {
        assert!(attribute(&[], &[span(0, 1000, 0)]).is_empty());
    }

    #[test]
    fn sin_tramos_todo_queda_sin_hablante() {
        // Degradación honesta: si la diarización falla, el texto igual sale.
        let tokens = vec![tok("hola", 0, 300)];
        let runs = attribute(&tokens, &[]);
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].speaker, None);
    }
}
```

- [ ] **Step 2: Correr los tests y verificar que fallan**

Run: `cargo test --manifest-path src-tauri/Cargo.toml --lib align::`
Expected: FAIL — `cannot find function attribute`

- [ ] **Step 3: Implementar**

Para cada token, calcula el solape con cada tramo y quédate con el de mayor solape; sin solape, `None`. Después agrupa tokens consecutivos que compartan hablante.

**Regla dura, la misma que ya rige la diarización actual: nunca adivinar.** Un token sin tramo que lo cubra queda en `None`, y en pantalla se ve como "sin identificar". Es preferible a atribuirle a alguien algo que no dijo.

- [ ] **Step 4: Correr los tests y verificar que pasan**

Run: `cargo test --manifest-path src-tauri/Cargo.toml --lib align::`
Expected: PASS — 7 passed

- [ ] **Step 5: Gates y commit**

```bash
cargo fmt --manifest-path src-tauri/Cargo.toml
cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets
cargo test --manifest-path src-tauri/Cargo.toml --lib
git add -A
git commit -m "feat(diarization): alinear tokens con hablantes por solape temporal"
```

---

### Task 5: Reemplazar el troceo por turnos en la captura de reunión

La tarea que borra código. El acumulador de turnos, su tope y su umbral dejan de existir en el camino de reuniones.

**Files:**

- Modify: `src-tauri/src/managers/meeting.rs`

**Interfaces:**

- Consumes: `StreamingDiarizer` (Task 2), tokens con tiempo (Task 3), `attribute` (Task 4).
- Produces, sólo dentro del módulo: `fn segments_from_runs(runs: &[AttributedRun]) -> Vec<MeetingSegment>`, que convierte intervenciones atribuidas en los segmentos que ya se persisten. Hacia afuera **nada cambia**: los segmentos guardados y los eventos emitidos conservan su forma actual, así que la base de datos y el frontend no cambian de contrato en esta tarea.

- [ ] **Step 1: Escribir el test que falla**

```rust
#[test]
fn una_interrupcion_corta_se_persiste_como_segmento_propio() {
    // El síntoma que motivó el plan, expresado como test sobre la pieza
    // que arma segmentos a partir de intervenciones atribuidas.
    let runs = vec![
        AttributedRun { text: "estaba".into(), speaker: Some(0), start_ms: 0, end_ms: 430 },
        AttributedRun { text: "no".into(), speaker: Some(1), start_ms: 430, end_ms: 620 },
        AttributedRun { text: "diciendo".into(), speaker: Some(0), start_ms: 620, end_ms: 1000 },
    ];
    let segments = segments_from_runs(&runs);
    assert_eq!(segments.len(), 3);
    assert_eq!(segments[1].speaker_id, Some(1));
}
```

- [ ] **Step 2: Correr el test y verificar que falla**

Run: `cargo test --manifest-path src-tauri/Cargo.toml --lib segments_from_runs`
Expected: FAIL — `cannot find function segments_from_runs`

- [ ] **Step 3: Implementar el consumo de los dos flujos**

El audio capturado alimenta **los dos** motores en paralelo: el ASR en streaming y el `StreamingDiarizer`. Los tokens y los tramos se juntan con `attribute`, y cada `AttributedRun` se persiste y se emite como segmento.

**Qué se borra del camino de reuniones:** `TurnAccumulator` y su uso, `MAX_TURN_MS`, `TURN_SILENCE_GAP`, `split_turn_into_pieces` y los umbrales de similitud del registro incremental (`ASSIGN_MIN_SIMILARITY`, `NEW_SPEAKER_MAX_SIMILARITY`, `MIN_SIMILARITY_MARGIN`, `SECONDARY_SPEAKER_RATIO` si existe).

**Qué NO se borra:** la compuerta de energía (`ENERGY_GATE_RMS`) sigue siendo útil para no mandarle silencio digital a los modelos. Y la diarización por lotes de `diarization.rs` se queda: sirve a lo ya grabado y a cualquier camino que no sea el vivo.

**Cuida el intercambio de modelos.** Hoy la reunión carga su modelo y `stop_capture` devuelve el del dictado. Ahora hay **dos** modelos de reunión (ASR streaming + Sortformer): verifica que se carguen y liberen juntos, y que el watchdog siga llamando `touch_activity()` para que el descargador por inactividad no saque uno a mitad de reunión.

- [ ] **Step 4: Correr los tests y verificar que pasan**

Run: `cargo test --manifest-path src-tauri/Cargo.toml --lib`
Expected: PASS. Los tests del acumulador de turnos que quedaron sin objeto **se borran junto con el código que probaban** — no se dejan pasando en vacío.

- [ ] **Step 5: Gates y commit**

```bash
cargo fmt --manifest-path src-tauri/Cargo.toml
cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets
cargo test --manifest-path src-tauri/Cargo.toml --lib
git add -A
git commit -m "feat(meeting): reemplazar el troceo por turnos por dos flujos continuos"
```

---

### Task 6: Que se vea escribiéndose, y que el tope de hablantes se diga

**Files:**

- Modify: `src/components/meeting/TranscriptList.tsx`
- Modify: `src/i18n/locales/*/translation.json` (los 21)
- Test: `tests/unit/meetingSession.test.ts`

**Interfaces:**

- Consumes: los eventos de segmento que ya existen.
- Produces: `export const SORTFORMER_MAX_SPEAKERS = 4;` en `src/components/meeting/meetingFormat.ts`, y `export function exceedsSpeakerCap(speakerIds: number[]): boolean`.

- [ ] **Step 1: Escribir el test que falla**

```ts
import {
  SORTFORMER_MAX_SPEAKERS,
  exceedsSpeakerCap,
} from "@/components/meeting/meetingFormat";

describe("exceedsSpeakerCap", () => {
  test("cuatro hablantes distintos todavía no supera el tope", () => {
    expect(exceedsSpeakerCap([1, 2, 3, 4])).toBe(false);
  });

  test("cinco lo superan", () => {
    expect(exceedsSpeakerCap([1, 2, 3, 4, 5])).toBe(true);
  });

  test("los repetidos no cuentan doble", () => {
    expect(exceedsSpeakerCap([1, 1, 1, 2])).toBe(false);
  });

  test("sin hablantes no supera nada", () => {
    expect(exceedsSpeakerCap([])).toBe(false);
  });

  test("el tope es el del modelo", () => {
    expect(SORTFORMER_MAX_SPEAKERS).toBe(4);
  });
});
```

- [ ] **Step 2: Correr el test y verificar que falla**

Run: `bun test tests/unit/meetingSession.test.ts`
Expected: FAIL — no se exporta `exceedsSpeakerCap`

- [ ] **Step 3: Implementar**

```ts
/**
 * Sortformer detecta como máximo 4 hablantes y degrada con 5 o más. No es
 * un límite nuestro: es del modelo, y hay que decirlo en vez de esconderlo
 * (restricción del diseño 2026-08-04).
 */
export const SORTFORMER_MAX_SPEAKERS = 4;

export function exceedsSpeakerCap(speakerIds: number[]): boolean {
  return new Set(speakerIds).size > SORTFORMER_MAX_SPEAKERS;
}
```

- [ ] **Step 4: El aviso, en español autoral**

En `src/i18n/locales/es/translation.json`:

```json
"speakerCapReached": "Dilo separa hasta 4 voces. De ahí en adelante puede confundirlas."
```

En `en`: `"Dilo tells apart up to 4 voices. Beyond that it may mix them up."`

Para los 19 restantes, traduce de verdad respetando el registro de cada locale. **No copies el inglés como relleno** — `check:translations` sólo verifica que la clave exista.

Muéstralo en el transcript cuando `exceedsSpeakerCap` sea cierto, como aviso discreto y no como error: no es una falla, es un límite.

- [ ] **Step 5: El texto que crece**

`TranscriptList` ya agrupa intervenciones consecutivas del mismo hablante (`groupConsecutiveSegments`). Con los flujos continuos, la última intervención se actualiza mientras se habla en vez de aparecer entera. Que el bloque en curso se distinga del ya cerrado — igual que el overlay del dictado distingue `tentative` de `committed`.

- [ ] **Step 6: Gates y commit**

```bash
bun test tests/unit
bun run build
bun run lint
bun run format:check
bun run check:translations
grep -nE "preferís|querés|podés|tenés|elegí |mirá|ponele|sabés|hacé" src/i18n/locales/es/translation.json
git add -A
git commit -m "feat(meeting): transcript que se escribe en vivo y aviso del tope de hablantes"
```

---

### Task 7: Verificación en vivo

Lo que ningún test unitario puede probar.

**Files:** ninguno. Los arreglos que salgan van con su propio commit.

- [ ] **Step 1: Avisar antes de compilar**

Alfonso usa esta máquina para dictar en vivo y compilar le degrada el dictado de ~1 s a ~17 s. **Avísale antes**, y que la verificación la haga él sobre un artifact de CI firmado — no sobre una build local, que stubbea Apple Intelligence.

- [ ] **Step 2: Recorrer la lista de verificación del diseño**

- [ ] **Las interrupciones aparecen**: grabar una conversación donde alguien pise a otro, y confirmar que la interrupción queda con su hablante.
- [ ] **Se escribe en vivo**, como ya se ve en el dictado con Nemotron.
- [ ] **Cobertura**: medir contra la base que el porcentaje de audio capturado no baja del 82% logrado al sacar el VAD. Consulta de referencia:

```sql
SELECT m.id, (m.ended_at-m.started_at) AS dur_s,
       ROUND(100.0*SUM(s.ended_at_ms-s.started_at_ms)/1000.0/(m.ended_at-m.started_at)) AS pct
FROM meetings m JOIN meeting_segments s ON s.meeting_id=m.id
GROUP BY m.id ORDER BY m.id DESC LIMIT 5;
```

- [ ] **Memoria medida** con los dos modelos cargados, en la máquina de 16 GB.
- [ ] **El dictado intacto**: su latencia y su reposo no cambian.
- [ ] **El tope de hablantes se ve** cuando hay más de cuatro.

- [ ] **Step 3: Commit de los arreglos que salgan**

Uno por arreglo, prefijo `fix(meeting):`, mensaje explicando el **por qué**.

---

## Lo que este plan NO construye

- **El resumen, los action items y preguntar al transcript.** Donde estaban.
- **Las notas propias estilo Wispr** ("My thoughts").
- **Re-diarizar reuniones ya grabadas.** Lo persistido no se re-procesa.
- **Más de 4 hablantes.** Es el límite del modelo y se avisa, no se resuelve.
- **El presencial de campo lejano.** Sigue detrás del micrófono que no existe sin app móvil.
