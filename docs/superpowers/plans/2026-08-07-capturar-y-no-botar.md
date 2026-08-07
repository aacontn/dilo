# Capturar y no botar (Fase 1) — Plan de implementación

> **Para agentes:** SUB-SKILL REQUERIDA: usar superpowers:subagent-driven-development (recomendado) o superpowers:executing-plans para implementar tarea por tarea. Los pasos usan casillas (`- [ ]`) para seguimiento.

**Objetivo:** que una reunión online capture la conversación completa —los dos lados— y que la compuerta deje de botar habla real; y que cuando igual se pierda algo, se mida y se muestre en vez de descubrirse con SQL una semana después.

**Arquitectura:** cuatro capas, cada una cubriendo la falla de la anterior. **Capa −1**: la reunión online abre las dos fuentes (audio del sistema + micrófono) y las mezcla a una sola señal de 16 kHz mono antes del pipeline. **Capa 0**: la compuerta binaria por trozo (`ENERGY_GATE_RMS`, constante fija) se reemplaza por una máquina de estados con piso de ruido medido, veto de Silero, histéresis, cola y pre-búfer. **Capa 1**: Sortformer, que ya ve el audio sin filtrar, se usa como árbitro — sus tramos de voz cruzados contra lo que el ASR realmente recibió dan la cobertura en vivo. **Capa 2**: esa cobertura se muestra en las dos superficies de grabación y, cuando el desacuerdo es alto, se avisa qué hacer.

Las capas 3 (lazo que adapta el piso, persistencia por dispositivo) y 4 (reparación retroactiva) son la Fase 2 y **no entran en este plan**.

**Stack:** Tauri 2 (Rust) + React/TypeScript; `vad-rs` (Silero, ya en el repo), CoreAudio process taps (`system_audio/macos.rs`), Sortformer (`managers/diarization/sortformer.rs`).

**Diseño:** [`docs/superpowers/specs/2026-08-07-compuerta-que-se-corrige-design.md`](../specs/2026-08-07-compuerta-que-se-corrige-design.md)

## Restricciones globales

- **Sin dependencias nuevas.**
- **El dictado no cambia.** Su VAD, su camino y su modelo quedan como están.
- **Presencial no cambia**: sigue siendo sólo micrófono.
- **Copia es-first en tuteo chileno, NUNCA voseo** — "podés", "querés", "elegí" son defectos; van "puedes", "quieres", "elige". Toda clave nueva en los 21 idiomas, traducida de verdad: `check:translations` sólo verifica que la clave exista, así que el relleno en inglés pasa el gate y le llega al usuario.
- **`src/bindings.ts` es generado, nunca a mano**: desde `src-tauri/`, `cargo build && ./target/debug/dilo --list-devices`.
- **NUNCA agregar `Co-Authored-By` ni atribución de IA a los commits.**
- **Un `settings.json` existente tiene que cargar sin que nadie pierda su configuración.** La Fase 1 **no agrega ningún campo a `AppSettings`** (el piso persistido por dispositivo es Capa 3, Fase 2), así que esta restricción se cumple por construcción — pero verifícala igual antes de cerrar cada tarea que toque `settings.rs`: ninguna debería tocarlo.

### Cómo compilar en esta máquina — LEER

La máquina del dueño tiene 16 GB y **se le congeló dos veces por compilaciones de Rust**, con apagado forzado y más de una hora perdida cada vez.

- **Un solo comando de cargo a la vez. NUNCA dos en paralelo, ni de fondo.**
- **NO correr `tauri dev`, NI `cargo build --release`, NI `cargo clippy`** (clippy queda para CI).
- **Agrupar las compilaciones por TAREA, no por paso**: hacer todos los cambios de Rust de la tarea y compilar una sola vez al final, encadenado (`cargo build && … && cargo test --lib`), nunca en dos terminales.
- Los gates de `bun` son livianos y se pueden correr cuando sea.
- **La verificación de Rust es responsabilidad de CI** (`test.yml` corre en cada push). Preferir CI antes que compilar local.

---

## Decisiones de diseño fijadas en este plan

**1. La compuerta vive en un módulo propio, y el veto entra como cierre.**
`meeting.rs` ya pasa las 6.400 líneas; meterle una máquina de estados con piso rodante, histéresis, cola y anillo de pre-búfer la vuelve intestable. La compuerta va en `src-tauri/src/managers/audio_gate.rs` como tipo puro (`MeetingGate`), sin conocer ni a Silero ni a Tauri: el veto se inyecta por parámetro (`impl FnOnce(&[f32]) -> Option<bool>`). Así toda la lógica delicada se prueba con `vec![0.004; 480]` y sin ONNX, y la instancia de Silero (propia de la reunión, **no** la del dictado) se conecta en `start_capture`. `Option<bool>`: `Some(true)` = "suena a habla" (veta el cierre), `Some(false)` = "confirmo que no es habla" (deja cerrar), `None` = motor no disponible → **manda la energía sola**, que es exactamente el comportamiento de hoy pero con piso medido en vez de constante: estrictamente mejor, nunca peor, y una instalación sin `silero_vad_v4.onnx` no deja de grabar reuniones.

**2. La mezcla es un tipo puro con una fuente primaria que marca el ritmo.**
Las dos fuentes ya entregan frames de 30 ms a 16 kHz mono (`FrameResampler::new(…, Duration::from_millis(30))` en `recorder.rs:527` y en `system_audio/macos.rs:563`), así que la mezcla no necesita remuestrear nada: sólo alinear dos flujos con relojes de hardware distintos. `AudioMixer` (`managers/audio_mix.rs`) tiene una **primaria** (el audio del sistema en una reunión online; el micrófono cuando es la única fuente) que es la que **emite** frames mezclados, y una **secundaria** que sólo se bufferiza. Consecuencias buscadas: el reloj de reunión (`total_ms`) sigue siendo el de una sola fuente continua, así que nada de los relojes existentes cambia por la mezcla; y si la secundaria se atrasa, se cae o nunca entrega nada, la reunión **no se detiene** — se mezcla con lo que haya. La deriva de la secundaria se acota a 400 ms tirando lo **más viejo** (audio ya desfasado, inservible) y no lo más nuevo. Suma con saturación a [-1, 1]: sumar dos señales normalizadas puede exceder el rango y el clipping duro es preferible a un wrap.

**3. El orden: primero la mezcla, después la compuerta.**
La mezcla es el arreglo de mayor impacto (en la reunión 27 la voz de Alfonso **nunca entró a la captura**: no es que se filtrara, es que no existía) y se puede vender sola — no toca `step_audio_clock` ni `AudioToWallClock`, los dos puntos que ya rompieron dos veces. La compuerta va después y en dos tareas: primero la máquina de estados pura con sus tests, después el cableado con el ancla del reloj. Hay además una razón técnica para este orden y no el inverso: la mezcla **cambia la señal que la compuerta ve** — el micrófono de campo cercano sube el nivel varios dB sobre el tap del sistema — así que calibrar la compuerta contra la señal vieja sería calibrarla contra una entrada que está por desaparecer.

---

## Estructura de archivos

| Archivo                                            | Responsabilidad                                                                       | Tarea   |
| -------------------------------------------------- | ------------------------------------------------------------------------------------- | ------- |
| `src-tauri/src/managers/audio_mix.rs` (nuevo)      | `AudioMixer`: dos cursores, suma con saturación, tope de deriva. Puro, sin audio real | 1       |
| `src-tauri/src/managers/mod.rs`                    | Declarar `audio_mix` y `audio_gate`                                                   | 1, 2    |
| `src-tauri/src/managers/meeting.rs`                | Fuentes resueltas, `MeetingRecorder::Mixed`, `audio_cb`, relojes, watchdog, avisos    | 1, 3, 4 |
| `src-tauri/src/managers/audio_gate.rs` (nuevo)     | `MeetingGate` (Capa 0) y `GateTimeline`/`speech_coverage` (Capa 1). Puros             | 2, 4    |
| `src-tauri/src/lib.rs`                             | Registrar el evento `MeetingAudioCoverage` en `collect_events!`                       | 4       |
| `src/hooks/useMeetings.ts`                         | Toasts de los avisos nuevos; listener de cobertura hacia el store                     | 1, 4, 5 |
| `src/stores/meetingStore.ts`                       | Última cobertura recibida                                                             | 5       |
| `src/lib/meetingCoverage.ts` (nuevo)               | Razón y umbrales del medidor. Puro, testeable sin React                               | 5       |
| `src/components/meeting/CoverageMeter.tsx` (nuevo) | El medidor, compartido por las dos superficies                                        | 5       |
| `src/components/meeting/LiveTranscript.tsx`        | Medidor en la ventana de reuniones                                                    | 5       |
| `src/components/popover/PopoverBody.tsx`           | Medidor en la tarjeta de grabación del popover                                        | 5       |
| `src/i18n/locales/*/translation.json`              | Copia nueva (avisos y medidor), 21 idiomas                                            | 1, 4, 5 |

---

## Task 1: Capa −1 — la reunión online captura las dos fuentes y las mezcla

**Por qué primero:** ver la decisión 3. Una reunión online hoy abre **sólo** el tap del sistema (`meeting.rs:929`), y la propia voz no suena por los parlantes durante una llamada — el 43 % de cobertura de la reunión 27 es, casi entero, esto.

**Files:**

- Create: `src-tauri/src/managers/audio_mix.rs`
- Modify: `src-tauri/src/managers/mod.rs`
- Modify: `src-tauri/src/managers/meeting.rs` (`resolve_meeting_audio_source` y su vecindad `:897-932`, `enum MeetingRecorder` `:1007-1078`, `MeetingAudioWarningKind` `:317-358`, `start_capture` `:2353-2576`)
- Modify: `src/hooks/useMeetings.ts` (`showAudioWarningToast`)
- Modify: `src/i18n/locales/*/translation.json` (21 idiomas)
- Test: `src-tauri/src/managers/audio_mix.rs` (`#[cfg(test)] mod tests` al final del propio archivo) y el `mod tests` de `meeting.rs` (`:3765`)

**Interfaces:**

- Produce, en `managers/audio_mix.rs`:

  ```rust
  /// 30 ms a 16 kHz — la cadencia que las dos fuentes ya entregan.
  pub const MIX_FRAME_SAMPLES: usize = 480;
  /// Cuánto puede adelantarse la secundaria antes de que se le tire lo más viejo.
  pub const MIX_MAX_DRIFT_MS: u64 = 400;

  pub fn mix_saturating(a: f32, b: f32) -> f32;

  pub struct AudioMixer { /* privado */ }

  impl AudioMixer {
      pub fn new(frame_samples: usize, max_drift_ms: u64, sample_rate: u32) -> Self;
      /// Sólo bufferiza. Recorta por lo más viejo si excede el tope de deriva.
      pub fn push_secondary(&mut self, samples: &[f32]);
      /// Bufferiza y devuelve TODOS los frames completos ya mezclados.
      pub fn push_primary(&mut self, samples: &[f32]) -> Vec<Vec<f32>>;
      pub fn secondary_backlog_samples(&self) -> usize;
      pub fn dropped_secondary_samples(&self) -> u64;
      /// Vacía las dos colas — lo llama el camino de degradación de
      /// `start_capture` cuando el audio del sistema falló al abrir y el
      /// micrófono pasa a ser primaria.
      pub fn reset(&mut self);
  }
  ```

- Produce, en `managers/meeting.rs`:

  ```rust
  #[derive(Debug, Clone, Copy, PartialEq, Eq)]
  pub struct MeetingCaptureSources { pub system_audio: bool, pub microphone: bool }

  pub fn resolve_meeting_capture_sources(
      kind: MeetingKind,
      system_audio_available: bool,
  ) -> MeetingCaptureSources;
  ```

  y una variante nueva de `MeetingAudioWarningKind`: `MicrophoneUnavailable` (serde: `"microphone_unavailable"`).

- Consume: `MicrophoneArbiter::try_acquire(MicOwner::Meeting)` tal cual está (`meeting.rs:2349`) — **no cambia**: la reunión ya lo reclama siempre, y ahora por fin lo usa de verdad. `AudioRecorder::with_audio_callback`, `SystemAudioRecorder::with_frame_callback`.
- **NO cambia** `MeetingAudioSource` ni `resolve_meeting_audio_source`: ese enum se persiste en `settings.meeting_audio_source` y lo lee el frontend (`src/lib/meetingKind.ts`) para el indicador. Agregar una tercera variante rompería bindings, ajustes y UI por una distinción que sólo importa adentro de `start_capture`.

- [ ] **Paso 1: Escribir los tests de la mezcla, que fallan**

Al final de `src-tauri/src/managers/audio_mix.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn la_mezcla_suma_las_dos_fuentes_y_satura() {
        let mut mixer = AudioMixer::new(4, 400, 16_000);
        mixer.push_secondary(&[0.5, 0.9, -0.9, 0.0]);
        let frames = mixer.push_primary(&[0.25, 0.5, -0.5, 0.0]);
        assert_eq!(frames, vec![vec![0.75, 1.0, -1.0, 0.0]]);
    }

    #[test]
    fn sin_secundaria_la_primaria_pasa_tal_cual() {
        let mut mixer = AudioMixer::new(4, 400, 16_000);
        assert_eq!(
            mixer.push_primary(&[0.1, 0.2, 0.3, 0.4]),
            vec![vec![0.1, 0.2, 0.3, 0.4]]
        );
    }

    #[test]
    fn la_primaria_marca_el_ritmo_y_no_espera_a_la_secundaria() {
        // El micrófono se cayó a mitad de reunión: la captura NO se detiene.
        let mut mixer = AudioMixer::new(4, 400, 16_000);
        mixer.push_secondary(&[1.0, 1.0]); // media trama, incompleta
        let frames = mixer.push_primary(&[0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]);
        assert_eq!(frames.len(), 2, "dos frames completos de primaria, dos frames de salida");
    }

    #[test]
    fn frames_incompletos_esperan_al_siguiente_bloque() {
        let mut mixer = AudioMixer::new(4, 400, 16_000);
        assert!(mixer.push_primary(&[0.1, 0.2]).is_empty());
        assert_eq!(
            mixer.push_primary(&[0.3, 0.4, 0.5]),
            vec![vec![0.1, 0.2, 0.3, 0.4]]
        );
    }

    #[test]
    fn la_deriva_de_la_secundaria_se_recorta_por_lo_mas_viejo() {
        // 1 ms de tope a 16 kHz = 16 muestras de backlog máximo.
        let mut mixer = AudioMixer::new(4, 1, 16_000);
        let secondary: Vec<f32> = (0..40).map(|i| i as f32 * 0.01).collect();
        mixer.push_secondary(&secondary);
        assert_eq!(mixer.secondary_backlog_samples(), 16);
        assert_eq!(mixer.dropped_secondary_samples(), 24);
        let frames = mixer.push_primary(&[0.0, 0.0, 0.0, 0.0]);
        assert_eq!(
            frames,
            vec![vec![24.0 * 0.01, 25.0 * 0.01, 26.0 * 0.01, 27.0 * 0.01]],
            "se conserva lo más reciente, se tira lo ya desfasado"
        );
    }

    #[test]
    fn reset_deja_las_dos_colas_vacias() {
        let mut mixer = AudioMixer::new(4, 400, 16_000);
        mixer.push_secondary(&[0.5, 0.5, 0.5, 0.5]);
        assert!(mixer.push_primary(&[0.1, 0.1]).is_empty());
        mixer.reset();
        assert_eq!(mixer.secondary_backlog_samples(), 0);
        assert_eq!(
            mixer.push_primary(&[0.1, 0.2, 0.3, 0.4]),
            vec![vec![0.1, 0.2, 0.3, 0.4]],
            "tras reset no queda nada de la sesión anterior mezclándose"
        );
    }
}
```

Y en el `mod tests` de `meeting.rs`:

```rust
#[test]
fn una_reunion_online_captura_las_dos_fuentes() {
    let s = resolve_meeting_capture_sources(MeetingKind::Virtual, true);
    assert!(s.system_audio && s.microphone);
}

#[test]
fn una_reunion_online_sin_audio_de_sistema_graba_solo_micrófono() {
    let s = resolve_meeting_capture_sources(MeetingKind::Virtual, false);
    assert!(!s.system_audio && s.microphone);
}

#[test]
fn presencial_nunca_toca_el_audio_del_sistema() {
    let s = resolve_meeting_capture_sources(MeetingKind::Presencial, true);
    assert!(!s.system_audio && s.microphone);
}
```

- [ ] **Paso 2: NO compiles todavía.** Sigue a los pasos 3-7 y compila UNA vez en el paso 8 (ver las restricciones de arriba).

- [ ] **Paso 3: Implementar `AudioMixer`**

`VecDeque<f32>` por fuente. `push_secondary` hace `extend` y luego, mientras `len() > max_secondary_samples` (`max_drift_ms * sample_rate / 1000`), `pop_front()` sumando a `dropped_secondary_samples`. `push_primary` hace `extend` y luego, mientras la primaria tenga `frame_samples`, saca un frame y lo mezcla muestra a muestra con lo que haya en la secundaria (`pop_front()` por muestra; si la secundaria está vacía, la muestra de la primaria pasa sola). `mix_saturating(a, b) = (a + b).clamp(-1.0, 1.0)`.

Doc comment obligatorio en el módulo: por qué existe (la reunión 27 y su 43 %), por qué la primaria marca el ritmo, por qué se tira lo más viejo, y la limitación conocida del **eco** — con parlantes en vez de audífonos la voz remota entra dos veces (por el tap y re-captada por el micrófono); no crea texto doble porque el ASR transcribe la mezcla, sólo ensucia la diarización. Se anota, no se resuelve acá (cancelación de eco es un proyecto en sí; el diseño lo declara fuera de alcance de esta fase).

- [ ] **Paso 4: Declarar el módulo**

En `src-tauri/src/managers/mod.rs`, agregar `pub mod audio_mix;` en orden alfabético (queda entre `audio` y `diarization`).

- [ ] **Paso 5: `resolve_meeting_capture_sources` y la variante de aviso**

En `meeting.rs`, junto a `resolve_meeting_audio_source` (que se conserva tal cual, con su tabla; agregarle una línea de doc comment aclarando que desde este cambio decide **el indicador y la fuente primaria**, no si el micrófono se abre). La función nueva:

```rust
/// Qué fuentes abre REALMENTE una sesión de captura. Deroga el mandato
/// anterior ("por el audio del computador, no del micrófono") en el único
/// punto donde dañaba: una reunión online sin micrófono no captura la voz
/// de quien está frente al computador — la llamada la manda al otro lado,
/// no la reproduce localmente, así que nunca pasa por el tap del sistema.
///
/// | `kind`       | audio del sistema disponible | fuentes                  |
/// |--------------|------------------------------|--------------------------|
/// | `Virtual`    | sí                           | sistema + micrófono      |
/// | `Virtual`    | no                           | micrófono                |
/// | `Presencial` | (no aplica)                  | micrófono                |
pub fn resolve_meeting_capture_sources(
    kind: MeetingKind,
    system_audio_available: bool,
) -> MeetingCaptureSources {
    MeetingCaptureSources {
        system_audio: matches!(kind, MeetingKind::Virtual) && system_audio_available,
        microphone: true,
    }
}
```

Y en `MeetingAudioWarningKind`, la variante nueva con su doc comment:

```rust
/// Capa −1: la reunión online abrió el audio del sistema pero el micrófono
/// no (ocupado por otra app, sin permiso, desconectado). La reunión graba
/// igual con la fuente que sí abrió — capturar a los demás sin ti es mejor
/// que no capturar nada — pero se dice, porque el resultado es exactamente
/// el modo de falla de la reunión 27: la mitad de la conversación no queda.
MicrophoneUnavailable,
```

- [ ] **Paso 6: `MeetingRecorder::Mixed`**

```rust
enum MeetingRecorder {
    Microphone(AudioRecorder),
    SystemAudio(Arc<Mutex<SystemAudioRecorder>>),
    /// Capa −1: las dos fuentes a la vez. `mic` es `Option` porque puede
    /// caerse sola (ver `MicrophoneUnavailable`) sin que la sesión muera.
    Mixed {
        system: Arc<Mutex<SystemAudioRecorder>>,
        mic: Option<AudioRecorder>,
        mic_unavailable: bool,
    },
}
```

- `open(&mut self, device)`: para `Mixed`, abre `system` con `?` (si el tap no abre, sube el error — el camino de degradación a micrófono-solo de `start_capture` lo maneja); después intenta `mic.open(device)` y, si falla, `warn!`, `mic = None`, `mic_unavailable = true`.
- `start(&mut self)` (**cambia de `&self` a `&mut self`**): arranca `system`; después `mic.start(VadPolicy::Disabled)` y, si falla, `mic.close()`, `mic = None`, `mic_unavailable = true`.
- `stop(&self)` / `close(&mut self)`: los dos lados; el `CaptureDiagnosis` que se propaga sigue siendo el del audio del sistema.
- `fn microphone_unavailable(&self) -> bool`: `mic_unavailable` para `Mixed`, `false` para el resto.

Como `start` pasa a `&mut self`, el `recorder.open(selected_device).and_then(|_| recorder.start())` de `:2502` y `:2538` no compila: el `and_then` mantiene vivo el préstamo mutable de `open` mientras la clausura pide otro. Reemplazar los dos sitios por:

```rust
let started = match recorder.open(selected_device) {
    Ok(()) => recorder.start(),
    Err(e) => Err(e),
};
if let Err(e) = started { /* mismo cuerpo que hoy */ }
```

- [ ] **Paso 7: Cablear la mezcla en `start_capture`**

Import nuevo en la cabecera de `meeting.rs` (`:48-75`): `use crate::managers::audio_mix::{AudioMixer, MIX_FRAME_SAMPLES, MIX_MAX_DRIFT_MS};`.

Reemplazar `build_audio_cb` por tres piezas — el trabajo por frame se extrae a `process_frame` porque a partir de la Task 3 lo va a llamar además la compuerta:

```rust
let mixer = Arc::new(Mutex::new(AudioMixer::new(
    MIX_FRAME_SAMPLES,
    MIX_MAX_DRIFT_MS,
    16_000,
)));

// Lo que antes hacía `build_audio_cb` por frame, ahora sobre el frame YA
// mezclado. No cambia nada de los relojes: sigue llegando un frame de 30 ms
// por vez, de una sola secuencia.
let process_frame: Arc<dyn Fn(&[f32]) + Send + Sync> = {
    let stream_router = Arc::clone(&stream_router);
    let diar_tx = diar_tx.clone();
    let diar_queue_depth = Arc::clone(&diar_queue_depth);
    let clock = Arc::clone(&clock);
    let asr_clock = Arc::clone(&asr_clock);
    Arc::new(move |frame: &[f32]| {
        /* cuerpo actual de `build_audio_cb`, sin cambios en esta tarea */
    })
};

let build_primary_cb = || {
    let mixer = Arc::clone(&mixer);
    let process = Arc::clone(&process_frame);
    move |block: &[f32]| {
        // El lock de la mezcla se suelta ANTES de procesar: `process_frame`
        // alimenta al ASR y encola audio para el diarizador, y hacerlo con
        // el lock puesto bloquearía al hilo de la otra fuente por todo ese
        // trabajo. Mismo criterio que el callback de `system_audio/macos.rs`,
        // que llama al frame_cb sin el lock de `buffer`.
        let frames = { mixer.lock().unwrap().push_primary(block) };
        for frame in frames {
            process(&frame);
        }
    }
};
let build_secondary_cb = || {
    let mixer = Arc::clone(&mixer);
    move |block: &[f32]| {
        mixer.lock().unwrap().push_secondary(block);
    }
};
```

Construcción del recorder (reemplaza `:2456-2473`):

```rust
let sources = resolve_meeting_capture_sources(kind, system_audio_available());
let mut recorder = if sources.system_audio {
    let system = Arc::new(Mutex::new(build_meeting_system_audio_recorder(
        build_primary_cb(),
    )?));
    match build_meeting_recorder(build_secondary_cb()) {
        Ok(mic) => MeetingRecorder::Mixed { system, mic: Some(mic), mic_unavailable: false },
        Err(e) => {
            warn!("Meeting {}: no se pudo construir el micrófono, la reunión graba \
                   sólo con el audio del sistema: {}", meeting_id, e);
            MeetingRecorder::SystemAudio(system)
        }
    }
} else {
    MeetingRecorder::Microphone(build_meeting_recorder(build_primary_cb())?)
};
// Desde la Capa −1 TODA reunión abre el micrófono, así que el dispositivo
// elegido en Ajustes manda siempre — ya no hay una rama que lo ignore.
let selected_device = mic_device();
```

El comentario existente de `:2464-2469` —"El audio del sistema no toma dispositivo de entrada"— hay que reescribirlo: sigue siendo cierto del tap (un tap global no elige entrada), y dejó de ser cierto de la sesión, que ahora abre además un micrófono con el dispositivo de Ajustes.

En el camino de degradación (`:2507-2542`): la condición pasa de `audio_source != MeetingAudioSource::SystemAudio` a `!sources.system_audio`, y **antes** de reconstruir como `Microphone` hay que llamar `mixer.lock().unwrap().reset()` — el intento fallido puede haber dejado muestras del micrófono en la cola secundaria, y el micrófono está por pasar a ser primaria: sin el reset se mezclaría consigo mismo con 400 ms de desfase.

Después del bloque de arranque, junto al aviso de `FellBackToMicrophone` (`:2545`):

```rust
if recorder.microphone_unavailable() {
    report_audio_warning(
        Some(&app_handle),
        meeting_id,
        &AtomicBool::new(false),
        MeetingAudioWarningKind::MicrophoneUnavailable,
    );
}
```

Y las dos coincidencias de patrón sobre `&recorder` (`audio_diagnostics_handle` `:2565`, `audio_warning_state` `:2573`) necesitan su brazo `Mixed { system, .. } => Some(Arc::clone(system))` / `Some(Arc::new(AudioWarningState::default()))`.

- [ ] **Paso 8: La ÚNICA compilación de esta tarea**

Desde `src-tauri/`, encadenado, un solo comando:

```bash
cargo build && ./target/debug/dilo --list-devices && cargo test --lib
```

(El `--list-devices` regenera `src/bindings.ts` con la variante nueva de `MeetingAudioWarningKind`.)

- [ ] **Paso 9: El toast del aviso nuevo**

En `src/hooks/useMeetings.ts`, dentro de `showAudioWarningToast`, agregar el caso — el `switch` es exhaustivo sobre el tipo generado, así que TypeScript va a exigirlo:

```ts
case "microphone_unavailable":
  toast.warning(t("meeting.errors.audioMicrophoneUnavailable"), {
    description: t("meeting.errors.audioMicrophoneUnavailableDescription"),
    duration: 15000,
  });
  break;
```

- [ ] **Paso 10: Claves i18n en los 21 idiomas, traducidas de verdad**

Español (autoral, tuteo chileno, **no** voseo):

```
"meeting.errors.audioMicrophoneUnavailable": "No se pudo abrir tu micrófono"
"meeting.errors.audioMicrophoneUnavailableDescription": "La reunión graba igual con el audio del computador, pero lo que tú digas no va a quedar. Cierra la app que esté usando el micrófono y vuelve a empezar la grabación."
```

Inglés:

```
"meeting.errors.audioMicrophoneUnavailable": "Couldn't open your microphone"
"meeting.errors.audioMicrophoneUnavailableDescription": "The meeting is still recording this computer's audio, but what you say won't be captured. Close whatever app is using the microphone and start the recording again."
```

Los otros 19 idiomas se traducen de verdad, no se rellenan en inglés.

Además, la copia del indicador deja de ser cierta: `meeting.controls.kindOnlineSystemAudio` decía "Reunión online, con el audio de este equipo" y ahora son las dos fuentes. Español: `"Reunión online, con el audio del computador y tu micrófono"`. Inglés: `"Online meeting, using this computer's audio and your microphone"`. Actualizar en los 21 idiomas (la clave ya existe; sólo cambia el texto).

- [ ] **Paso 11: Gates de front**

`bun test tests/unit`, `bun run build`, `bun run lint`, `bun run format:check`, `bun run check:translations`.

- [ ] **Paso 12: Mutar y confirmar**

Cambia `push_secondary` para que recorte por el final (`pop_back()` en vez de `pop_front()`) y confirma que `la_deriva_de_la_secundaria_se_recorta_por_lo_mas_viejo` lo caza. Revierte y verifica con `git diff` que quedó igual. (Esto **no** requiere una compilación nueva si lo haces junto al paso 8: corre el mutante y la reversión dentro de esa misma tanda de `cargo test --lib`.)

- [ ] **Paso 13: Commit**

```bash
git add src-tauri/src/managers/audio_mix.rs src-tauri/src/managers/mod.rs src-tauri/src/managers/meeting.rs src/hooks/useMeetings.ts src/i18n src/bindings.ts
git commit -m "feat(reuniones): una reunión online captura el audio del computador y tu micrófono"
```

---

## Task 2: Capa 0 — la máquina de estados de la compuerta, pura y probada

**Sin cableado.** Esta tarea entrega el módulo y sus tests; `meeting.rs` no la usa todavía. Se separa a propósito: la compuerta es lo más delicado del sistema (histéresis + cola + pre-búfer + piso adaptativo, cada uno con su borde), y tenerla verde antes de tocar los relojes es lo que evita depurar dos cosas a la vez.

**Files:**

- Create: `src-tauri/src/managers/audio_gate.rs`
- Modify: `src-tauri/src/managers/mod.rs`
- Test: `src-tauri/src/managers/audio_gate.rs` (`#[cfg(test)] mod tests` al final del propio archivo)

**Interfaces:**

- Produce:

  ```rust
  /// 30 ms a 16 kHz. Silero exige EXACTAMENTE este tamaño de frame
  /// (`SILERO_FRAME_SAMPLES` en `audio_toolkit/vad/silero.rs`), y es lo que
  /// `AudioMixer` entrega — la compuerta hereda el contrato.
  pub const GATE_FRAME_SAMPLES: usize = 480;
  pub const GATE_FRAME_MS: u64 = 30;
  /// ~300 ms que se sueltan al abrir (los bordes con memoria del diseño).
  pub const PREBUFFER_FRAMES: usize = 10;
  /// ~1 s de cola abierta tras caer la energía.
  pub const HANGOVER_FRAMES: usize = 33;
  /// 30 s de ventana rodante para medir el piso de ruido.
  pub const FLOOR_WINDOW_FRAMES: usize = 1000;
  /// Cada cuántos frames se recalcula el percentil (≈1 s).
  pub const FLOOR_REFRESH_FRAMES: usize = 33;
  pub const FLOOR_PERCENTILE: f32 = 0.10;
  pub const OPEN_MARGIN_DB: f32 = 8.0;
  pub const CLOSE_MARGIN_DB: f32 = 4.0;
  pub const FLOOR_MIN_RMS: f32 = 1.0e-5;
  /// Tope del piso medido. Con `OPEN_MARGIN_DB`, un piso de 0.01 pone el
  /// umbral de apertura en ≈0.025 (-32 dBFS), todavía cómodamente bajo el
  /// habla conversacional (-25 a -15 dBFS de RMS): el piso no puede "perseguir"
  /// a la voz por más ruidoso que sea el ambiente.
  pub const FLOOR_MAX_RMS: f32 = 0.01;

  pub fn rms_energy(samples: &[f32]) -> f32;
  pub fn is_digital_silence(samples: &[f32]) -> bool;

  #[derive(Debug, Default, Clone, PartialEq)]
  pub struct GateOutput {
      /// Frames a entregar al ASR, en orden (pre-búfer primero). Vacío si la
      /// compuerta está cerrada.
      pub frames: Vec<Vec<f32>>,
      /// Milisegundos de audio PASADO incluidos al principio de `frames`.
      /// El ancla del reloj tiene que retroceder exactamente esto (Task 3).
      pub prebuffer_ms: u64,
  }

  pub struct MeetingGate { /* privado */ }

  impl Default for MeetingGate { /* = new() */ }

  impl MeetingGate {
      pub fn new() -> Self;
      /// `sounds_like_speech`: el veto, inyectado. `Some(true)` = suena a
      /// habla (no cerrar), `Some(false)` = confirmado que no lo es,
      /// `None` = sin motor disponible → manda la energía sola. Se consulta
      /// COMO MUCHO una vez por frame, y sólo cuando la energía ya quiere
      /// cerrar.
      pub fn push(
          &mut self,
          frame: &[f32],
          sounds_like_speech: impl FnOnce(&[f32]) -> Option<bool>,
      ) -> GateOutput;
      pub fn noise_floor_rms(&self) -> f32;
      pub fn is_open(&self) -> bool;
  }
  ```

- Consume: nada. El módulo no importa Tauri, ni `vad-rs`, ni `meeting.rs`.

**Reglas que la máquina implementa** (del diseño, sección Capa 0):

1. **Silencio digital (ceros exactos) se bloquea SIEMPRE** — piso absoluto, sin consultar el veto, y además pone la cola en cero (una racha de ceros exactos significa que el stream murió, no que alguien hizo una pausa).
2. **Piso medido, no constante**: percentil 10 de las RMS de los últimos 1000 frames (30 s), recalculado cada ~1 s y cacheado, acotado a `[FLOOR_MIN_RMS, FLOOR_MAX_RMS]`. Con la ventana vacía el piso es `FLOOR_MIN_RMS` — el default es **abrir**.
3. **Histéresis**: cerrada, abre con `rms >= piso · 10^(8/20)`; abierta, se mantiene con `rms >= piso · 10^(4/20)`.
4. **Veto**: si la energía quiere cerrar, se consulta el veto; `Some(true)` mantiene abierto.
5. **Cola**: al dejar de haber razón para estar abierta, siguen pasando `HANGOVER_FRAMES` frames.
6. **Pre-búfer**: mientras está cerrada (y sólo entonces), cada frame entra a un anillo de `PREBUFFER_FRAMES`; al abrir, el anillo se suelta delante del frame actual y se vacía. **Invariante que la Task 3 necesita**: el pre-búfer nunca cubre audio anterior al momento en que la compuerta se cerró, porque el anillo se limpia al soltarlo y sólo se llena estando cerrada.

- [ ] **Paso 1: Escribir los tests, que fallan**

```rust
#[cfg(test)]
mod tests {
    use super::*;

    /// Frame constante: su RMS es exactamente |v|, así los tests hablan en
    /// la misma unidad que los umbrales.
    fn frame(rms: f32) -> Vec<f32> {
        vec![rms; GATE_FRAME_SAMPLES]
    }
    fn feed(gate: &mut MeetingGate, rms: f32, frames: usize) {
        for _ in 0..frames {
            gate.push(&frame(rms), |_| Some(false));
        }
    }

    #[test]
    fn el_silencio_digital_nunca_pasa() {
        let mut gate = MeetingGate::new();
        feed(&mut gate, 0.2, 20); // abierta de par en par
        let out = gate.push(&vec![0.0; GATE_FRAME_SAMPLES], |_| Some(true));
        assert!(out.frames.is_empty(), "ceros exactos se bloquean aunque el veto diga habla");
    }

    #[test]
    fn una_llamada_baja_abre_la_compuerta_que_hoy_la_botaba() {
        // La reunión 27: piso de ruido bajo, voz a 0.004 RMS — bajo el
        // ENERGY_GATE_RMS = 0.005 fijo de hoy.
        let mut gate = MeetingGate::new();
        feed(&mut gate, 0.0008, 400);
        let out = gate.push(&frame(0.004), |_| Some(false));
        assert!(!out.frames.is_empty());
    }

    #[test]
    fn el_piso_alto_no_deja_que_el_ruido_abra_sola_la_compuerta() {
        // Un ventilador constante a 0.001 no es voz: el piso sube con él.
        let mut gate = MeetingGate::new();
        feed(&mut gate, 0.001, 400);
        let out = gate.push(&frame(0.001), |_| Some(false));
        assert!(out.frames.is_empty());
    }

    #[test]
    fn el_veto_manda_sobre_la_energia() {
        let mut gate = MeetingGate::new();
        feed(&mut gate, 0.001, 400);
        let out = gate.push(&frame(0.001), |_| Some(true));
        assert!(!out.frames.is_empty(), "Silero dice habla: no se cierra");
    }

    #[test]
    fn sin_motor_de_veto_manda_la_energia_sola() {
        let mut gate = MeetingGate::new();
        feed(&mut gate, 0.001, 400);
        let out = gate.push(&frame(0.001), |_| None);
        assert!(out.frames.is_empty());
    }

    #[test]
    fn al_abrir_suelta_el_prebufer_completo() {
        let mut gate = MeetingGate::new();
        feed(&mut gate, 0.001, 400); // piso alto y compuerta cerrada
        let out = gate.push(&frame(0.2), |_| Some(false));
        assert_eq!(out.frames.len(), PREBUFFER_FRAMES + 1);
        assert_eq!(out.prebuffer_ms, PREBUFFER_FRAMES as u64 * GATE_FRAME_MS);
    }

    #[test]
    fn el_prebufer_nunca_es_mas_largo_que_el_tramo_cerrado() {
        // Invariante del que depende el ancla del reloj (Task 3): soltar más
        // audio del que estuvo cerrada haría retroceder el punto de
        // referencia por debajo del anterior.
        let mut gate = MeetingGate::new();
        feed(&mut gate, 0.2, 40); // abierta
        // Dos frames de ceros exactos: cierran de inmediato — el silencio
        // digital manda sobre la cola.
        gate.push(&vec![0.0; GATE_FRAME_SAMPLES], |_| Some(false));
        gate.push(&vec![0.0; GATE_FRAME_SAMPLES], |_| Some(false));
        let out = gate.push(&frame(0.2), |_| Some(false));
        assert_eq!(out.prebuffer_ms, 2 * GATE_FRAME_MS);
    }

    #[test]
    fn la_cola_no_corta_el_final_de_la_palabra() {
        let mut gate = MeetingGate::new();
        feed(&mut gate, 0.001, 400);
        gate.push(&frame(0.2), |_| Some(false)); // abre
        // El nivel cae, pero la cola mantiene abierto ~1 s.
        for i in 0..HANGOVER_FRAMES {
            let out = gate.push(&frame(0.001), |_| Some(false));
            assert!(!out.frames.is_empty(), "frame {i} de la cola tiene que pasar");
        }
        let out = gate.push(&frame(0.001), |_| Some(false));
        assert!(out.frames.is_empty(), "pasada la cola, cierra");
    }

    #[test]
    fn la_histeresis_evita_el_parpadeo() {
        let mut gate = MeetingGate::new();
        feed(&mut gate, 0.001, 400);
        let floor = gate.noise_floor_rms();
        // Nivel entre el umbral de cierre y el de apertura.
        let entre = floor * 10f32.powf(6.0 / 20.0);
        assert!(gate.push(&frame(entre), |_| Some(false)).frames.is_empty(),
                "estando cerrada, un nivel intermedio no alcanza para abrir");
        gate.push(&frame(0.2), |_| Some(false)); // abre de verdad
        assert!(!gate.push(&frame(entre), |_| Some(false)).frames.is_empty(),
                "estando abierta, el mismo nivel la mantiene abierta");
    }

    #[test]
    fn el_veto_no_se_consulta_cuando_la_energia_ya_abre() {
        // Silero cuesta ~1 ms por frame; no se paga sobre audio fuerte.
        let mut gate = MeetingGate::new();
        feed(&mut gate, 0.0008, 400);
        let mut consultado = false;
        gate.push(&frame(0.2), |_| { consultado = true; Some(false) });
        assert!(!consultado);
    }
}
```

- [ ] **Paso 2: NO compiles todavía.** Sigue al paso 3.

- [ ] **Paso 3: Implementar `MeetingGate`**

Estado: `VecDeque<f32>` de RMS (ventana del piso), `f32` de piso cacheado + contador para el refresco, `VecDeque<Vec<f32>>` del pre-búfer, `usize` de cola restante, `bool` de abierta. Orden exacto de `push`:

```rust
pub fn push(&mut self, frame: &[f32], sounds_like_speech: impl FnOnce(&[f32]) -> Option<bool>) -> GateOutput {
    debug_assert_eq!(frame.len(), GATE_FRAME_SAMPLES);
    if is_digital_silence(frame) {
        self.open = false;
        self.hangover = 0;
        self.remember(frame);           // entra al anillo
        return GateOutput::default();   // frames vacíos, prebuffer_ms 0
    }
    let rms = rms_energy(frame);
    self.observe_floor(rms);            // ventana + refresco cacheado
    let floor = self.floor;
    let threshold = if self.open { floor * db_gain(CLOSE_MARGIN_DB) } else { floor * db_gain(OPEN_MARGIN_DB) };
    let deliver = if rms >= threshold {
        true
    } else {
        matches!(sounds_like_speech(frame), Some(true))
    };
    if deliver {
        self.hangover = HANGOVER_FRAMES;
    } else if self.hangover > 0 {
        self.hangover -= 1;
    }
    if !deliver && self.hangover == 0 {
        self.open = false;
        self.remember(frame);
        return GateOutput::default();
    }
    // Se entrega: soltar el anillo delante del frame actual y vaciarlo.
    let prebuffer: Vec<Vec<f32>> = self.prebuffer.drain(..).collect();
    let prebuffer_ms = prebuffer.len() as u64 * GATE_FRAME_MS;
    self.open = true;
    let mut frames = prebuffer;
    frames.push(frame.to_vec());
    GateOutput { frames, prebuffer_ms }
}
```

`db_gain(db) = 10f32.powf(db / 20.0)`. `observe_floor` empuja el RMS a la ventana (descartando el más viejo si excede `FLOOR_WINDOW_FRAMES`) y, cada `FLOOR_REFRESH_FRAMES`, recalcula el percentil copiando la ventana a un `Vec`, `sort_by(f32::total_cmp)`, e indexando en `(len as f32 * FLOOR_PERCENTILE) as usize`, con `clamp(FLOOR_MIN_RMS, FLOOR_MAX_RMS)`. Con la ventana vacía, `FLOOR_MIN_RMS`.

Doc comment del módulo obligatorio, con: las tres fallas de la tabla del diseño (Silero como portero botó el 79 %; RMS constante botó la llamada baja; los dos deciden por trozo sin memoria), por qué la carga de la prueba se invierte para reuniones (perder habla es irrecuperable; dejar pasar un tramo dudoso cuesta un pedazo sin texto), y el invariante del pre-búfer del que depende el ancla del reloj.

- [ ] **Paso 4: Declarar el módulo**

`pub mod audio_gate;` en `src-tauri/src/managers/mod.rs`, en orden alfabético (queda entre `audio` y `audio_mix`).

- [ ] **Paso 5: La ÚNICA compilación de esta tarea**

Desde `src-tauri/`: `cargo test --lib`. (Esta tarea no cambia ningún tipo expuesto a specta, así que **no** hay que regenerar bindings.)

- [ ] **Paso 6: Mutar y confirmar**

Dos mutantes, uno por invariante crítico, corriendo en la misma tanda de `cargo test --lib`:

1. Que `is_digital_silence` devuelva siempre `false` → tiene que caer `el_silencio_digital_nunca_pasa`.
2. Que el anillo del pre-búfer se llene también estando abierta (sacar la condición de `remember`) → tiene que caer `el_prebufer_nunca_es_mas_largo_que_el_tramo_cerrado`.

Revierte los dos y verifica con `git diff` que quedó igual.

- [ ] **Paso 7: Commit**

```bash
git add src-tauri/src/managers/audio_gate.rs src-tauri/src/managers/mod.rs
git commit -m "feat(reuniones): compuerta con piso medido, veto y bordes con memoria"
```

---

## Task 3: Capa 0 — cablear la compuerta y anclar el reloj al pre-búfer

**El paso más delicado del plan.** Los relojes de reunión ya se rompieron dos veces (N1 del fix round 2, N2 del fix round 3) y el pre-búfer los toca de frente: al abrir se sueltan ~300 ms de audio **pasado**, así que el punto de referencia de `AudioToWallClock` debe anclarse a `total_ms − prebuffer_ms`, **no** a `total_ms`. Sin eso, todas las marcas de tiempo de ese tramo quedan corridas hacia adelante 300 ms, `align::attribute` cruza tokens contra los `SpeakerSpan` equivocados y las intervenciones salen atribuidas a quien no habló.

**Files:**

- Modify: `src-tauri/src/managers/meeting.rs` (`ENERGY_GATE_RMS`/`rms_energy`/`has_energy` `:556-610`, `step_audio_clock` `:1244-1264` y su doc comment, `AudioClockState` `:1187-1220`, `process_frame` dentro de `start_capture`)
- Test: `mod tests` de `src-tauri/src/managers/meeting.rs` (`:3765`)

**Interfaces:**

- Consume: `audio_gate::{MeetingGate, GateOutput, GATE_FRAME_MS}` (Task 2), `audio_toolkit::vad::{SileroVad, VoiceActivityDetector}`.
- Produce (firma cambiada):

  ```rust
  /// `fed_to_asr`: si ESTE frame se le entregó al ASR (la compuerta lo dejó
  /// pasar, sea por energía, por veto o por cola).
  /// `prebuffer_ms`: cuánto audio PASADO se entregó junto con él
  /// (`GateOutput::prebuffer_ms`); `0` salvo en el frame que abre.
  fn step_audio_clock(
      state: AudioClockState,
      fed_to_asr: bool,
      frame_ms: u64,
      prebuffer_ms: u64,
  ) -> (AudioClockState, AudioClockMark);
  ```

- **Se van de `meeting.rs`**: `ENERGY_GATE_RMS`, `rms_energy`, `has_energy` (y sus tests). `rms_energy` vive ahora en `audio_gate.rs`. Conservar, movido al doc comment del módulo nuevo, el razonamiento de dBFS del comentario viejo: es la única memoria escrita de por qué 0.005 parecía razonable y por qué no lo era.

- [ ] **Paso 1: Escribir los tests del reloj, que fallan**

En el `mod tests` de `meeting.rs`, junto a los de `step_audio_clock` que ya están:

```rust
#[test]
fn el_prebufer_ancla_el_reloj_donde_empieza_el_audio_soltado() {
    let mut state = AudioClockState::default();
    // 10 frames cerrados: 300 ms de reunión que el ASR no vio.
    for _ in 0..10 {
        let (next, mark) = step_audio_clock(state, false, 30, 0);
        state = next;
        assert!(mark.is_none());
    }
    // El frame 11 abre y suelta los 10 anteriores como pre-búfer.
    let (state, mark) = step_audio_clock(state, true, 30, 300);
    assert_eq!(
        mark,
        Some((0, 0)),
        "el ASR arranca en su ms 0, que en reloj de reunión es el ms 0 — no el 300"
    );
    assert_eq!(state.asr_ms, 330, "el ASR recibió el pre-búfer Y el frame actual");
    assert_eq!(state.total_ms, 330);
}

#[test]
fn el_segundo_hueco_tambien_descuenta_el_prebufer() {
    let mut state = AudioClockState::default();
    for _ in 0..33 { state = step_audio_clock(state, true, 30, 0).0; }   // 990 ms hablando
    for _ in 0..67 { state = step_audio_clock(state, false, 30, 0).0; }  // 2.010 ms callado
    let (state, mark) = step_audio_clock(state, true, 30, 300);
    assert_eq!(mark, Some((990, 2700)));
    assert_eq!(state.asr_ms, 1320);
    assert_eq!(state.total_ms, 3030);
}

#[test]
fn un_token_del_prebufer_cae_donde_de_verdad_se_dijo() {
    // El cruce completo: reloj → AudioToWallClock → token.
    let mut clock = AudioToWallClock::default();
    clock.mark(990, 2700);
    let token = TimedToken { text: "hola".into(), start_ms: 1000, end_ms: 1300 };
    let converted = convert_token_to_meeting_clock(token, &clock);
    assert_eq!(converted.start_ms, 2710);
    assert_eq!(converted.end_ms, 3010);
}

#[test]
fn sin_prebufer_el_reloj_se_comporta_igual_que_antes() {
    // La regresión que este parámetro no debe introducir.
    let (state, mark) = step_audio_clock(AudioClockState::default(), true, 30, 0);
    assert_eq!(mark, Some((0, 0)));
    assert_eq!(state.asr_ms, 30);
    assert_eq!(state.total_ms, 30);
}
```

- [ ] **Paso 2: NO compiles todavía.** Sigue a los pasos 3-5.

- [ ] **Paso 3: `step_audio_clock` con pre-búfer**

```rust
fn step_audio_clock(
    mut state: AudioClockState,
    fed_to_asr: bool,
    frame_ms: u64,
    prebuffer_ms: u64,
) -> (AudioClockState, AudioClockMark) {
    let mut mark = None;
    if fed_to_asr {
        if state.was_gap {
            // `total_ms` es el ms de reunión donde EMPIEZA este frame; el
            // pre-búfer es audio ANTERIOR a él que igual se le entrega al
            // ASR, así que el punto donde los dos relojes coinciden está
            // `prebuffer_ms` más atrás. Anclar a `total_ms` a secas corre
            // todas las marcas de ese tramo hacia adelante — el mismo tipo
            // de desalineación que N1, por otra puerta.
            mark = Some((state.asr_ms, state.total_ms.saturating_sub(prebuffer_ms)));
            state.was_gap = false;
        }
        state.asr_ms += frame_ms + prebuffer_ms;
    } else {
        state.was_gap = true;
    }
    // Fuera del `if` a propósito: ver el comentario existente.
    state.total_ms += frame_ms;
    (state, mark)
}
```

Ampliar el doc comment de la función con el párrafo del pre-búfer y con el invariante que lo hace correcto (`prebuffer_ms` nunca excede el tramo cerrado — ver `MeetingGate::push` y su test).

- [ ] **Paso 4: La compuerta y Silero dentro de `start_capture`**

Imports nuevos en la cabecera de `meeting.rs` (`:48-75`): `crate::audio_toolkit::vad::{SileroVad, VoiceActivityDetector}` (el trait hace falta para `is_voice`), `crate::managers::audio_gate::{MeetingGate, GATE_FRAME_MS}` y `crate::managers::audio_mix::{AudioMixer, MIX_FRAME_SAMPLES, MIX_MAX_DRIFT_MS}` (estos últimos ya entraron en la Task 1). `tauri::Manager` ya está importado (`:74`), así que `app_handle.path()` compila sin tocar nada.

Antes de construir `process_frame`:

```rust
// Instancia PROPIA de la reunión: el dictado tiene la suya
// (`create_audio_recorder`, `managers/audio.rs`) con su umbral y su
// `SmoothedVad`, y compartirla acoplaría los dos caminos. Umbral bajo a
// propósito: acá Silero es VETO ("¿confirmas que NO es habla?"), no
// portero — con 0.10, `is_voice()` sólo da `false` cuando el modelo está
// bastante seguro de que no hay voz.
const MEETING_VAD_VETO_THRESHOLD: f32 = 0.10;
let meeting_vad: Arc<Mutex<Option<SileroVad>>> = Arc::new(Mutex::new(
    app_handle
        .path()
        .resolve("resources/models/silero_vad_v4.onnx", tauri::path::BaseDirectory::Resource)
        .ok()
        .and_then(|path| match SileroVad::new(&path, MEETING_VAD_VETO_THRESHOLD) {
            Ok(vad) => Some(vad),
            Err(e) => {
                // No mata la reunión: sin veto manda la energía sola, que es
                // el comportamiento de hoy pero con piso medido.
                warn!("Meeting {}: sin veto de voz para la compuerta ({}); \
                       la compuerta decide sólo por energía", meeting_id, e);
                None
            }
        }),
));
let gate = Arc::new(Mutex::new(MeetingGate::new()));
```

Y el cuerpo de `process_frame` pasa a:

```rust
Arc::new(move |frame: &[f32]| {
    let frame_ms = (frame.len() as u64 * 1000) / 16_000;

    // Orden de locks, SIEMPRE el mismo y nunca al revés: `gate` primero,
    // `meeting_vad` adentro (`MeetingGate::push` llama al veto como mucho
    // una vez, y ningún otro camino toma estos dos). El resto de los locks
    // de este callback —`asr_clock`, `clock`, `gate_timeline`— se toman
    // DESPUÉS, con éstos ya soltados.
    let out = {
        let mut gate = gate.lock().unwrap();
        gate.push(frame, |f| {
            let mut vad = meeting_vad.lock().unwrap();
            vad.as_mut().map(|vad| vad.is_voice(f).unwrap_or(true))
        })
    };

    let fed = !out.frames.is_empty();
    let mark = {
        let mut guard = asr_clock.lock().unwrap();
        let (next, mark) = step_audio_clock(*guard, fed, frame_ms, out.prebuffer_ms);
        *guard = next;
        mark
    };
    if let Some((asr_ms, total_ms)) = mark {
        clock.lock().unwrap().mark(asr_ms, total_ms);
    }
    for gated in &out.frames {
        stream_router.feed(gated);
    }

    // Sin filtrar: `StreamingDiarizer` necesita ver el silencio real para
    // cortar turnos (Important 4 del fix round 1) — y desde la Capa 1 es
    // además el árbitro que mide lo que la compuerta botó.
    let depth = diar_queue_depth.fetch_add(1, Ordering::Relaxed) + 1;
    if depth == QUEUE_DEPTH_WARN_THRESHOLD { /* warn! como hoy */ }
    let _ = diar_tx.send(DiarizerCmd::Audio(frame.to_vec()));
})
```

Nota sobre el `unwrap_or(true)` del veto: un error del motor a mitad de sesión se lee como "suena a habla", es decir, **no cierra**. Es la dirección segura según el principio del diseño (perder habla es irrecuperable) y la única que no convierte un fallo transitorio del ONNX en un hueco de transcript.

- [ ] **Paso 5: Borrar la compuerta vieja**

Sacar `ENERGY_GATE_RMS`, `rms_energy` y `has_energy` de `meeting.rs` con sus tests, y actualizar los doc comments que las nombran: el del módulo (`:1130-1164`), el de `DiarizerCmd::Audio` (`:1171-1177`), el de `build_meeting_recorder` (`:831-853`), el de `build_meeting_system_audio_recorder` (`:954-970`), el de `MeetingRecorder::start` (`:1024-1029`), el de `NO_SEGMENTS_VOICE_WARNING_MS` (`:666-674`) y el de `AudioClockState` (`:1187-1204`). En todos, "la compuerta de energía (`ENERGY_GATE_RMS`)" pasa a "la compuerta (`audio_gate::MeetingGate`)". La semántica de `asr_ms` **no cambia**: sigue siendo "audio con voz que el ASR recibió", ahora incluyendo el pre-búfer.

- [ ] **Paso 6: La ÚNICA compilación de esta tarea**

Desde `src-tauri/`: `cargo test --lib`.

- [ ] **Paso 7: Mutar y confirmar**

Cambia `state.total_ms.saturating_sub(prebuffer_ms)` por `state.total_ms` y confirma que caen `el_prebufer_ancla_el_reloj_donde_empieza_el_audio_soltado` y `el_segundo_hueco_tambien_descuenta_el_prebufer`. Después saca el `+ prebuffer_ms` de `state.asr_ms` y confirma que también los caza. Revierte los dos y verifica con `git diff`.

- [ ] **Paso 8: Commit**

```bash
git add src-tauri/src/managers/meeting.rs
git commit -m "feat(reuniones): la compuerta nueva entra al camino y el pre-búfer ancla el reloj"
```

---

## Task 4: Capa 1 — Sortformer como árbitro que mide

Sortformer ya ve el audio **sin filtrar** y emite `SpeakerSpan`s. Cruzarlos contra lo que la compuerta dejó pasar da, en vivo, la métrica que hoy sólo se obtiene con SQL después del desastre. Esa evidencia hoy existe y se tira.

**Files:**

- Modify: `src-tauri/src/managers/audio_gate.rs` (agregar `GateTimeline`, `Coverage`, `speech_coverage`)
- Modify: `src-tauri/src/managers/meeting.rs` (`process_frame`, watchdog `:2629-2767`, `MeetingAudioWarningKind`, evento nuevo)
- Modify: `src-tauri/src/lib.rs` (`collect_events!` `:947-963`)
- Modify: `src/hooks/useMeetings.ts`
- Modify: `src/i18n/locales/*/translation.json`
- Test: `#[cfg(test)] mod tests` de `audio_gate.rs`

**Interfaces:**

- Produce, en `audio_gate.rs`:

  ```rust
  /// Ventana rodante del medidor: la cobertura se calcula sobre los últimos
  /// 5 minutos, no sobre la reunión entera. Dos razones: es lo que le sirve a
  /// quien está mirando ("¿cómo va AHORA?"), y acota la memoria de la línea
  /// de tiempo sin necesitar una poda por tamaño.
  pub const COVERAGE_WINDOW_MS: u64 = 300_000;

  #[derive(Debug, Default, Clone)]
  pub struct GateTimeline { /* privado: VecDeque<(u64, u64)> de tramos abiertos */ }

  impl GateTimeline {
      /// Tramo `[start_ms, end_ms)` en reloj de REUNIÓN que sí llegó al ASR.
      /// Funde con el anterior si son contiguos o se solapan.
      pub fn push_open(&mut self, start_ms: u64, end_ms: u64);
      pub fn prune_before(&mut self, ms: u64);
      pub fn open_ms_within(&self, from_ms: u64, to_ms: u64) -> u64;
      pub fn len(&self) -> usize;
      pub fn is_empty(&self) -> bool;
  }

  #[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
  pub struct Coverage { pub detected_ms: u64, pub fed_ms: u64 }

  /// `detected`: tramos de voz de Sortformer, en reloj de reunión.
  pub fn speech_coverage(
      detected: &[(u64, u64)],
      timeline: &GateTimeline,
      from_ms: u64,
      to_ms: u64,
  ) -> Coverage;
  ```

- Produce, en `meeting.rs`:

  ```rust
  /// Capa 2: cuánta voz detectó el árbitro y cuánta llegó al ASR, sobre la
  /// ventana rodante. El frontend decide qué mostrar (ver
  /// `src/lib/meetingCoverage.ts`) — acá van números, no un mensaje.
  #[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
  pub struct MeetingAudioCoverage {
      pub meeting_id: i64,
      pub detected_ms: u64,
      pub fed_ms: u64,
      pub window_ms: u64,
  }
  ```

  y la variante `LowAudioCoverage` (serde: `"low_audio_coverage"`) de `MeetingAudioWarningKind`.

- Consume: `SpeakerSpan { start_ms, end_ms, speaker }` desde `TranscriptState::spans`; `AudioClockState { asr_ms, total_ms }` para el porcentaje por minuto en el log; `report_audio_warning` tal cual.

**Constantes de la Capa 1** (en `meeting.rs`, junto a `WATCHDOG_POLL_INTERVAL`):

```rust
/// Cada cuánto el watchdog calcula y emite la cobertura.
const COVERAGE_POLL: Duration = Duration::from_secs(10);
/// Cada cuánto queda el porcentaje de compuerta en el log.
const GATE_LOG_INTERVAL: Duration = Duration::from_secs(60);
/// Cuánta voz detectada hace falta en la ventana antes de sacar cualquier
/// conclusión — bajo esto no se emite nada y el medidor no aparece.
const COVERAGE_MIN_SAMPLE_MS: u64 = 15_000;
/// Bajo esta razón, sostenida, se avisa que el audio llega muy bajo.
const LOW_COVERAGE_RATIO: f32 = 0.60;
/// Cuánta voz detectada tiene que acumularse bajo el umbral antes de avisar
/// — un mal minuto no es un problema de configuración.
const LOW_COVERAGE_SUSTAINED_MS: u64 = 60_000;
```

- [ ] **Paso 1: Escribir los tests del árbitro, que fallan**

En el `mod tests` de `audio_gate.rs`:

```rust
#[test]
fn la_cobertura_cuenta_solo_el_solape_con_lo_alimentado() {
    let mut t = GateTimeline::default();
    t.push_open(0, 1000);
    t.push_open(2000, 3000);
    let detected = [(500, 2500)];
    assert_eq!(
        speech_coverage(&detected, &t, 0, 3000),
        Coverage { detected_ms: 2000, fed_ms: 1000 }
    );
}

#[test]
fn los_tramos_contiguos_se_funden() {
    let mut t = GateTimeline::default();
    t.push_open(0, 30);
    t.push_open(30, 60);
    t.push_open(60, 90);
    assert_eq!(t.len(), 1, "una reunión de 40 min no puede guardar 80.000 tramos");
    assert_eq!(t.open_ms_within(0, 90), 90);
}

#[test]
fn la_ventana_recorta_lo_viejo() {
    let mut t = GateTimeline::default();
    t.push_open(0, 1000);
    t.push_open(400_000, 401_000);
    t.prune_before(300_000);
    assert_eq!(t.len(), 1);
    assert_eq!(t.open_ms_within(300_000, 500_000), 1000);
}

#[test]
fn la_reunion_27_se_ve_como_desastre_y_el_video_como_normal() {
    // Los dos casos medidos del diseño, en miniatura.
    let mut mala = GateTimeline::default();
    mala.push_open(0, 2_800);
    let detected = [(0, 10_000)];
    let c = speech_coverage(&detected, &mala, 0, 10_000);
    assert!((c.fed_ms as f32 / c.detected_ms as f32) < 0.30);

    let mut buena = GateTimeline::default();
    buena.push_open(0, 9_520);
    let c = speech_coverage(&detected, &buena, 0, 10_000);
    assert!((c.fed_ms as f32 / c.detected_ms as f32) > 0.95);
}

#[test]
fn sin_voz_detectada_no_hay_division_por_cero() {
    let t = GateTimeline::default();
    assert_eq!(speech_coverage(&[], &t, 0, 1000), Coverage::default());
}
```

- [ ] **Paso 2: NO compiles todavía.** Sigue a los pasos 3-8.

- [ ] **Paso 3: Implementar `GateTimeline` y `speech_coverage`**

`push_open`: si el último tramo termina en `start_ms` o después, extenderlo (`end = end.max(end_ms)`); si no, empujar uno nuevo. `prune_before`: sacar por el frente todo tramo con `end <= ms`, y recortar el primero que lo cruce. `open_ms_within`: sumar `min(end, to) - max(start, from)` sobre los tramos que se solapan, saturando. `speech_coverage`: por cada tramo detectado recortado a `[from, to]`, sumar su duración a `detected_ms` y `timeline.open_ms_within(inicio, fin)` a `fed_ms`.

- [ ] **Paso 4: Alimentar la línea de tiempo desde `process_frame`**

En `start_capture`, junto al `gate` de la Task 3:

```rust
let gate_timeline = Arc::new(Mutex::new(GateTimeline::default()));
```

Se clona hacia `process_frame` (escritor) y hacia el watchdog (lector + poda). El `gate` de la Task 3 necesita **un clon más** hacia el watchdog, para el piso de ruido de la línea del log.

La línea de tiempo se llena con el **reloj de reunión**, que `process_frame` ya tiene a mano en `asr_clock.total_ms`. Capturar `let frame_start_ms = guard.total_ms;` **dentro** del bloque del reloj (antes de reemplazar el estado) y hacer el `push_open` **fuera**, ya soltado ese lock — dos locks tomados a la vez en el camino caliente del audio es exactamente la clase de cosa que se convierte en un deadlock cuando alguien agrega un tercero:

```rust
if fed {
    // El tramo que ESTE frame entregó, en reloj de reunión: empieza donde
    // empieza el pre-búfer (si lo hubo) y termina al final del frame actual.
    let end_ms = frame_start_ms + frame_ms;
    let start_ms = frame_start_ms.saturating_sub(out.prebuffer_ms);
    gate_timeline.lock().unwrap().push_open(start_ms, end_ms);
}
```

donde `frame_start_ms` es el `total_ms` **anterior** al `step_audio_clock` (léelo del guard antes de reemplazarlo: `let frame_start_ms = guard.total_ms;`). Es exactamente el mismo número que el ancla del reloj usa, y ese acoplamiento es deliberado: si alguna vez se separan, el medidor y el transcript van a contar cosas distintas.

- [ ] **Paso 5: El árbitro en el watchdog**

El watchdog ya late cada 100 ms y ya tiene canal de aviso de una sola vez, así que la telemetría se cuelga de ahí sin hilos nuevos. Necesita tres clones más (`gate_timeline`, `gate`, y el `asr_clock`/`transcript_state` que ya tiene) y tres variables locales de estado: `last_coverage_poll: Instant`, `last_gate_log: Instant` y `last_coverage: Coverage` (la última calculada, para que la línea del log no tenga que recalcularla). Cada `COVERAGE_POLL`:

```rust
let now_ms = watchdog_asr_clock.lock().unwrap().total_ms;
let from_ms = now_ms.saturating_sub(COVERAGE_WINDOW_MS);
let detected: Vec<(u64, u64)> = {
    let state = watchdog_transcript_state.lock().unwrap();
    state.spans.iter()
        .filter(|s| s.end_ms > from_ms)
        .map(|s| (s.start_ms, s.end_ms))
        .collect()
};
let coverage = {
    let mut timeline = watchdog_gate_timeline.lock().unwrap();
    timeline.prune_before(from_ms);
    speech_coverage(&detected, &timeline, from_ms, now_ms)
};
last_coverage = coverage;
if coverage.detected_ms >= COVERAGE_MIN_SAMPLE_MS {
    let payload = MeetingAudioCoverage {
        meeting_id,
        detected_ms: coverage.detected_ms,
        fed_ms: coverage.fed_ms,
        window_ms: COVERAGE_WINDOW_MS,
    };
    if let Err(e) = payload.emit(&app_handle) {
        warn!("Failed to emit meeting-audio-coverage for {}: {}", meeting_id, e);
    }
    let ratio = coverage.fed_ms as f32 / coverage.detected_ms as f32;
    if ratio < LOW_COVERAGE_RATIO && coverage.detected_ms >= LOW_COVERAGE_SUSTAINED_MS {
        report_audio_warning(
            Some(&app_handle),
            meeting_id,
            &low_coverage_warning_reported,
            MeetingAudioWarningKind::LowAudioCoverage,
        );
    }
}
```

`low_coverage_warning_reported: AtomicBool` local al watchdog, igual que `no_segments_warning_reported`. **No se encola en `PendingMeetingAudioNotices` de forma distinta**: `report_audio_warning` ya hace eso solo.

Y cada `GATE_LOG_INTERVAL`, en su propio bloque (independiente del de `COVERAGE_POLL`), la línea que hace que el próximo diagnóstico tarde un minuto y no una tarde:

```rust
let clock = *watchdog_asr_clock.lock().unwrap();
let pct = if clock.total_ms == 0 {
    0.0
} else {
    clock.asr_ms as f64 * 100.0 / clock.total_ms as f64
};
let floor = watchdog_gate.lock().unwrap().noise_floor_rms();
info!(
    "Meeting {}: compuerta {:.1}% ({} ms de {} ms al ASR) · cobertura ventana {}/{} ms · piso {:.5}",
    meeting_id, pct, clock.asr_ms, clock.total_ms,
    last_coverage.fed_ms, last_coverage.detected_ms, floor
);
```

`last_coverage` puede venir en `Coverage::default()` durante el primer minuto (todavía no hubo suficiente voz detectada); la línea igual sirve, porque el porcentaje de compuerta —que es el dato que faltaba el 2026-08-07— no depende de ella.

- [ ] **Paso 6: La variante de aviso y el registro del evento**

`LowAudioCoverage` en `MeetingAudioWarningKind`, con doc comment que diga qué la dispara (razón bajo `LOW_COVERAGE_RATIO` sostenida `LOW_COVERAGE_SUSTAINED_MS` de voz detectada) y por qué es un aviso y no un error (la reunión sigue grabando; lo que falta es que la persona suba el volumen de la llamada).

En `src-tauri/src/lib.rs`, dentro de `collect_events![`, después de `managers::meeting::MeetingAudioWarning`:

```rust
managers::meeting::MeetingAudioCoverage,
```

- [ ] **Paso 7: La ÚNICA compilación de esta tarea**

Desde `src-tauri/`, encadenado: `cargo build && ./target/debug/dilo --list-devices && cargo test --lib`.

- [ ] **Paso 8: El toast del aviso nuevo + i18n en 21 idiomas**

En `showAudioWarningToast`:

```ts
case "low_audio_coverage":
  toast.warning(t("meeting.errors.audioLowCoverage"), {
    description: t("meeting.errors.audioLowCoverageDescription"),
    duration: 15000,
  });
  break;
```

Español (autoral, tuteo chileno):

```
"meeting.errors.audioLowCoverage": "El audio llega muy bajo"
"meeting.errors.audioLowCoverageDescription": "Se está hablando bastante más de lo que alcanza a transcribirse. Sube el volumen de la llamada o acércate al micrófono."
```

Inglés:

```
"meeting.errors.audioLowCoverage": "The audio is coming in too quiet"
"meeting.errors.audioLowCoverageDescription": "A lot more is being said than what makes it into the transcript. Turn up the call volume or move closer to the microphone."
```

Los otros 19, traducidos de verdad.

- [ ] **Paso 9: Gates de front**

`bun test tests/unit`, `bun run build`, `bun run lint`, `bun run format:check`, `bun run check:translations`.

- [ ] **Paso 10: Mutar y confirmar**

Cambia `open_ms_within` para que devuelva la duración del tramo detectado entero en vez del solape (es decir, que siempre reporte 100 % de cobertura) y confirma que caen `la_cobertura_cuenta_solo_el_solape_con_lo_alimentado` y `la_reunion_27_se_ve_como_desastre_y_el_video_como_normal`. Revierte y verifica con `git diff`.

- [ ] **Paso 11: Commit**

```bash
git add src-tauri/src/managers/audio_gate.rs src-tauri/src/managers/meeting.rs src-tauri/src/lib.rs src/hooks/useMeetings.ts src/i18n src/bindings.ts
git commit -m "feat(reuniones): medir cuánta voz detectada no llega al transcript"
```

---

## Task 5: Capa 2 — el medidor a la vista

Un indicador discreto en la tarjeta de grabación, en las **dos** superficies. Misma filosofía que el tope de 4 voces: el límite se muestra, no se esconde.

**Files:**

- Create: `src/lib/meetingCoverage.ts`
- Create: `tests/unit/meetingCoverage.test.ts`
- Create: `src/components/meeting/CoverageMeter.tsx`
- Modify: `src/components/meeting/index.ts` (exportar `CoverageMeter`)
- Modify: `src/stores/meetingStore.ts`
- Modify: `src/hooks/useMeetings.ts` (listener del evento hacia el store)
- Modify: `src/components/meeting/LiveTranscript.tsx`
- Modify: `src/components/popover/PopoverBody.tsx`
- Modify: `src/i18n/locales/*/translation.json`

**Interfaces:**

- Consume: `events.meetingAudioCoverage` y el tipo `MeetingAudioCoverage` de `@/bindings` (generados en la Task 4).
- Produce:

  ```ts
  // src/lib/meetingCoverage.ts
  export interface CoverageSample {
    detectedMs: number;
    fedMs: number;
  }
  /** Bajo esto no se saca ninguna conclusión: el medidor no aparece. */
  export const COVERAGE_MIN_SAMPLE_MS = 15_000;
  export type CoverageLevel = "unknown" | "ok" | "low" | "critical";
  /** `null` cuando no hay muestra suficiente — nunca divide por cero. */
  export function coverageRatio(sample: CoverageSample): number | null;
  export function coverageLevel(sample: CoverageSample): CoverageLevel;
  ```

  ```tsx
  // src/components/meeting/CoverageMeter.tsx
  export const CoverageMeter: React.FC<{ sample: CoverageSample | null }>;
  ```

**Umbrales** (los mismos números que el diseño usa para juzgar las dos mediciones): `ok` con razón ≥ 0,90 (el video del 2026-08-04 dio 0,952); `low` entre 0,60 y 0,90; `critical` bajo 0,60 (la reunión 27 dio 0,433). `unknown` mientras `detectedMs < COVERAGE_MIN_SAMPLE_MS`.

- [ ] **Paso 1: Escribir el test que falla**

`tests/unit/meetingCoverage.test.ts`:

```ts
import { describe, expect, it } from "bun:test";
import {
  COVERAGE_MIN_SAMPLE_MS,
  coverageLevel,
  coverageRatio,
} from "@/lib/meetingCoverage";

describe("medidor de voz captada", () => {
  it("sin muestra suficiente no dice nada", () => {
    expect(coverageLevel({ detectedMs: 5_000, fedMs: 1_000 })).toBe("unknown");
    expect(coverageRatio({ detectedMs: 5_000, fedMs: 1_000 })).toBeNull();
  });

  it("no divide por cero cuando nadie habló todavía", () => {
    expect(coverageRatio({ detectedMs: 0, fedMs: 0 })).toBeNull();
    expect(coverageLevel({ detectedMs: 0, fedMs: 0 })).toBe("unknown");
  });

  it("la llamada de WhatsApp del 2026-08-07 sale crítica", () => {
    expect(coverageLevel({ detectedMs: 600_000, fedMs: 260_000 })).toBe(
      "critical",
    );
  });

  it("el video de YouTube del 2026-08-04 sale bien", () => {
    expect(coverageLevel({ detectedMs: 600_000, fedMs: 571_000 })).toBe("ok");
  });

  it("el punto justo entre bien y bajo cae del lado permisivo", () => {
    expect(coverageLevel({ detectedMs: 100_000, fedMs: 90_000 })).toBe("ok");
    expect(coverageLevel({ detectedMs: 100_000, fedMs: 89_999 })).toBe("low");
  });

  it("el mínimo de muestra es exactamente inclusivo", () => {
    expect(
      coverageLevel({ detectedMs: COVERAGE_MIN_SAMPLE_MS, fedMs: 15_000 }),
    ).toBe("ok");
  });
});
```

- [ ] **Paso 2: Correr y confirmar que falla.** `bun test tests/unit`

- [ ] **Paso 3: Implementar `src/lib/meetingCoverage.ts`**

Puro, sin React ni Tauri, con doc comment que explique de dónde salen los umbrales (las dos mediciones del diseño) y por qué hay un mínimo de muestra: los primeros segundos de cualquier reunión tienen cobertura ridícula porque Sortformer todavía está cargando y el ASR todavía no comprometió nada — mostrar eso sería asustar a la persona con un número que no significa nada.

- [ ] **Paso 4: Correr y confirmar que pasa.**

- [ ] **Paso 5: El componente**

`CoverageMeter` recibe la muestra y no calcula nada por su cuenta (todo lo decidible está en `meetingCoverage.ts`). Con `unknown` **no renderiza nada** (`return null`). Con `ok`, una línea discreta con el porcentaje. Con `low`/`critical`, el mismo indicador en color de advertencia más la línea de qué hacer. Sin barra de progreso ni animación: es un dato, no un tablero. Estilo tomado de las etiquetas en versalitas que ya usa la tarjeta de grabación (`RecordingControls.tsx`), no un componente nuevo de diseño.

- [ ] **Paso 6: El estado y el listener**

En `src/stores/meetingStore.ts`, un campo `coverage: { detectedMs: number; fedMs: number } | null` con su setter, limpiado en los mismos lugares donde hoy se limpia `pendingSegments` (arranque, `markFinished`, `markErrored`, `reset`) — que el medidor de la reunión anterior sobreviva a la siguiente sería mentir.

En `useMeetingEvents` (que ya es el único lugar donde viven los listeners de la ventana de reuniones, ver su doc comment):

```ts
const unlistenCoverage = events.meetingAudioCoverage.listen((event) => {
  setCoverage({
    detectedMs: event.payload.detected_ms,
    fedMs: event.payload.fed_ms,
  });
});
```

con su limpieza en el `return` del `useEffect`, igual que los demás.

- [ ] **Paso 7: Las dos superficies**

- `LiveTranscript.tsx`: `<CoverageMeter sample={coverage} />` en el bloque de cabecera, junto al contador de hablantes. `coverage` sale de `useMeetings()` (agregar el campo a lo que el hook expone, siguiendo el patrón de `pendingSegments`).
- `PopoverBody.tsx`: dentro de la tarjeta de reunión en curso, bajo el cronómetro. **Este componente no usa el store** (su webview monta una vez en toda la vida del proceso y su Zustand es propio de esa ventana — leer su doc comment antes de tocarlo): el estado va en un `useState` local alimentado por su propio `events.meetingAudioCoverage.listen`, exactamente como ya hace con `meeting-segment`, y se resetea cuando la sesión activa cambia o termina.

- [ ] **Paso 8: Claves i18n en los 21 idiomas**

Español (autoral, tuteo chileno):

```
"meeting.coverage.label": "Voz captada"
"meeting.coverage.value": "{{percent}} % de lo que se habla llega al transcript"
"meeting.coverage.lowHint": "Sube el volumen de la llamada o acércate al micrófono."
```

Inglés:

```
"meeting.coverage.label": "Speech captured"
"meeting.coverage.value": "{{percent}}% of what's being said reaches the transcript"
"meeting.coverage.lowHint": "Turn up the call volume or move closer to the microphone."
```

Los otros 19, traducidos de verdad.

- [ ] **Paso 9: Gates de front**

`bun test tests/unit`, `bun run build`, `bun run lint`, `bun run format:check`, `bun run check:translations`.

- [ ] **Paso 10: Mutar y confirmar**

Cambia el umbral de `ok` de 0,90 a 0,40 y confirma que `la llamada de WhatsApp del 2026-08-07 sale crítica` y `el punto justo entre bien y bajo cae del lado permisivo` lo cazan. Revierte verificando con `git diff`.

- [ ] **Paso 11: Commit**

```bash
git add src/lib/meetingCoverage.ts tests/unit/meetingCoverage.test.ts src/components/meeting src/components/popover/PopoverBody.tsx src/stores/meetingStore.ts src/hooks/useMeetings.ts src/i18n
git commit -m "feat(reuniones): mostrar cuánta voz llega al transcript mientras se graba"
```

---

## Verificación final (requiere la máquina del dueño, con un build de CI)

Esto no se puede probar sin audio real y **no debe intentarse con compilaciones locales** — sale de un artifact de `test-macos-signing.yml`, porque además los builds locales stubean Apple Intelligence.

- **La prueba de fuego:** repetir una llamada de WhatsApp como la de la reunión 27 y que la cobertura pase de 43 % a **≥ 90 %**, **sin texto alucinado en las pausas** (revisar a mano los tramos de silencio del transcript).
- **Los dos lados quedan:** en esa misma llamada, verificar que aparecen intervenciones de **Alfonso** y de la otra persona — no sólo de la otra. Es la prueba directa de la Capa −1; si sólo hay un hablante, la mezcla no está entrando.
- **El caso que motivó la compuerta no vuelve:** grabar una reunión online con nada sonando (silencio digital) y verificar que no produce ni una línea de texto.
- **El video fuerte no empeora:** repetir la medición del 2026-08-04 y que siga **≥ 95 %**.
- **Las palabras dejan de cortarse:** las filas de una palabra pegadas a huecos ("pa", "y mejor") desaparecen del patrón de la base.
- **El medidor dice la verdad:** cruzar el porcentaje que muestra el popover contra el que queda en `dilo.log` cada minuto y contra el conteo por SQL al final de la reunión.
- **El aviso de micrófono ocupado sale:** abrir Zoom (o cualquier app que tome el micrófono en exclusiva), empezar una reunión online, y verificar que graba igual y avisa.
- **CPU y memoria medidas** con la mezcla y el veto activos en la máquina de 16 GB: la reunión completa, no un minuto.
