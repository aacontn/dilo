//! Voz de salida — motor de síntesis de voz (TTS) de Dilo.
//!
//! Módulo nuevo, propio de Dilo (no existe en Handy/upstream): todo vive
//! bajo `src-tauri/src/tts/`, aditivo. Ver
//! `docs/plans/dilo-v2-voz.md` (Command Center) para el diseño completo;
//! este código implementa solo el núcleo local — nada de nube ni de UI
//! todavía.
//!
//! ## La interfaz es de flujo, no de archivo
//!
//! El objetivo central de este diseño es no obligar al llamador a esperar
//! un WAV completo antes de poder reproducir nada — eso destruiría el TTFA
//! (tiempo hasta el primer audio), que es el requisito que motivó este
//! trabajo (ver `spikes/voz/RESULTADOS.md` en Command Center, medido en
//! 543–653 ms con streaming por frases vs. ~3.4 s sintetizando la frase
//! completa de una).
//!
//! El plan original especifica esto como
//! `fn speak(&self, text, voice) -> Result<impl Stream<Item = AudioChunk>>`
//! (un `Stream` async). [`TtsEngine::speak_streaming`] logra el mismo
//! objetivo — el llamador nunca espera el audio completo — con un callback
//! síncrono en vez de un `Stream` async, por dos razones concretas:
//!
//! 1. **Todo el resto del pipeline de audio de Dilo es síncrono/bloqueante**
//!    (`rodio::Sink`, `audio_feedback.rs`, `audio_toolkit/`) — no hay ningún
//!    executor async corriendo en el hilo que reproduce audio. El motor
//!    local además es CPU-bound: sintetiza cada fragmento de una sola
//!    pasada ONNX y nunca "empieza a emitir muestras" antes de terminar —
//!    un `Stream` real sobre eso sería `Poll::Ready` siempre, jamás
//!    `Pending`, así que solo agregaría la maquinaria de polling de un
//!    executor sin ningún beneficio real.
//! 2. **`impl Stream` en un método de trait no es *object safe*** (RPITIT
//!    rompe `dyn Trait`), lo que impediría `Box<dyn TtsEngine>` — y eso es
//!    justo lo que la fase 1b (proveedores de nube, opt-in) necesita para
//!    cambiar de motor en runtime sin recompilar. El callback síncrono no
//!    tiene ese problema: `TtsEngine` es `dyn`-compatible tal como está.
//!
//! Cualquier motor — local o un futuro cliente de nube leyendo una
//! respuesta HTTP chunked en su propio hilo — puede invocar `on_chunk` una
//! o más veces a medida que hay audio listo, sin acumular la frase
//! completa en memoria antes de devolver el control.

pub mod streaming;
pub mod supertonic;

use std::fmt;
use std::sync::{Arc, Mutex};

/// Estado de Tauri para el motor TTS activo.
///
/// Cargado perezosamente en el primer `tts_speak` (ver
/// `commands/tts.rs`) — evita pagar los ~0,6 s de carga de las 4 sesiones
/// ONNX al arrancar la app si el dueño nunca usa la voz de salida. Una vez
/// cargado queda cacheado detrás del `Mutex` para toda la vida de la app:
/// cambiar de voz no recarga nada (ver `supertonic::SupertonicEngine`).
#[derive(Default)]
pub struct TtsState {
    pub engine: Mutex<Option<Arc<supertonic::SupertonicEngine>>>,
}

/// Identificador opaco de una voz. Para el motor local (`supertonic.rs`) es
/// `"F5"`, `"M1"`, etc. Para un proveedor de nube (fase 1b) será el id que
/// use ese proveedor — el trait no le da ninguna estructura, solo lo pasa
/// de un lado a otro.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct VoiceId(pub String);

impl VoiceId {
    pub fn new(id: impl Into<String>) -> Self {
        Self(id.into())
    }
}

impl fmt::Display for VoiceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl From<&str> for VoiceId {
    fn from(s: &str) -> Self {
        Self(s.to_string())
    }
}

impl From<String> for VoiceId {
    fn from(s: String) -> Self {
        Self(s)
    }
}

/// Género de voz declarado — puramente informativo para un selector de UI,
/// no afecta la síntesis.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VoiceGender {
    Female,
    Male,
}

/// Metadatos de una voz disponible en un motor — lo que la UI necesita para
/// mostrar un selector, sin exponer nada interno del motor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VoiceInfo {
    pub id: VoiceId,
    pub name: String,
    pub gender: VoiceGender,
}

/// Un fragmento de audio PCM ya sintetizado, listo para encolar en el
/// reproductor. `channels`/`sample_rate` viajan con cada fragmento (no son
/// globales del motor) porque un backend de nube podría, en teoría, variar
/// entre llamadas.
#[derive(Debug, Clone)]
pub struct AudioChunk {
    pub samples: Vec<f32>,
    pub sample_rate: u32,
    pub channels: u16,
}

/// Errores que puede producir un motor TTS.
///
/// `Network` existe desde el día uno aunque el motor local
/// (`supertonic.rs`) nunca lo produce: los backends de nube de la fase 1b
/// (Deepgram, ElevenLabs — ver el plan) sí lo necesitan, y es mucho más
/// barato tenerlo en el trait ahora que reabrir esta interfaz después de
/// que el flujo de streaming ya esté enganchado en todos lados.
#[derive(Debug)]
pub enum TtsError {
    /// La voz pedida no existe en este motor.
    UnknownVoice(VoiceId),
    /// Fallo de red al hablar con un backend remoto. El motor local nunca
    /// produce esta variante.
    Network(String),
    /// El motor no pudo sintetizar el texto dado (entrada inválida, fallo
    /// del modelo, etc.).
    Synthesis(String),
}

impl fmt::Display for TtsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TtsError::UnknownVoice(id) => write!(f, "voz desconocida: {id}"),
            TtsError::Network(msg) => write!(f, "error de red: {msg}"),
            TtsError::Synthesis(msg) => write!(f, "error de síntesis: {msg}"),
        }
    }
}

impl std::error::Error for TtsError {}

pub type TtsResult<T> = Result<T, TtsError>;

/// Motor de síntesis de voz. Ver la documentación del módulo para por qué
/// `speak_streaming` usa un callback síncrono en vez de `impl Stream`.
///
/// `Send + Sync` porque Dilo va a guardar el motor activo detrás de un
/// `Box<dyn TtsEngine>` en el estado de la app (compartido entre threads de
/// Tauri).
pub trait TtsEngine: Send + Sync {
    /// Sintetiza `text` con la voz `voice`, invocando `on_chunk` una o más
    /// veces a medida que hay audio listo. `text` debe ser ya un fragmento
    /// corto (una frase o menos) — la segmentación de texto largo vive en
    /// [`streaming`], no aquí.
    ///
    /// Si `on_chunk` devuelve `Err`, la síntesis se corta ahí (por ejemplo,
    /// porque el reproductor fue cancelado) y ese error se propaga tal
    /// cual.
    fn speak_streaming(
        &self,
        text: &str,
        voice: &VoiceId,
        on_chunk: &mut dyn FnMut(AudioChunk) -> TtsResult<()>,
    ) -> TtsResult<()>;

    /// Las voces que ofrece este motor.
    fn voices(&self) -> Vec<VoiceInfo>;
}

#[cfg(test)]
pub(crate) mod test_support {
    //! Motor fake compartido por los tests de este módulo y de
    //! `streaming.rs` — no depende de ONNX ni de ningún archivo en disco.
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Mutex;

    /// Motor de prueba: "sintetiza" devolviendo N fragmentos silenciosos
    /// cuyo largo total de muestras es proporcional al largo del texto (para
    /// que se pueda distinguir un fragmento de otro en los tests). Registra
    /// cada llamada a `speak_streaming` para que los tests puedan verificar
    /// cuántas veces y con qué texto se invocó.
    pub struct FakeEngine {
        pub voices: Vec<VoiceInfo>,
        /// Cuántos `AudioChunk` emitir por llamada a `speak_streaming`.
        pub chunks_per_call: usize,
        pub calls: Mutex<Vec<String>>,
        pub call_count: AtomicUsize,
    }

    impl FakeEngine {
        pub fn new() -> Self {
            Self {
                voices: vec![VoiceInfo {
                    id: VoiceId::new("FAKE1"),
                    name: "Fake Uno".to_string(),
                    gender: VoiceGender::Female,
                }],
                chunks_per_call: 1,
                calls: Mutex::new(Vec::new()),
                call_count: AtomicUsize::new(0),
            }
        }

        pub fn call_texts(&self) -> Vec<String> {
            self.calls.lock().unwrap().clone()
        }
    }

    impl Default for FakeEngine {
        fn default() -> Self {
            Self::new()
        }
    }

    impl TtsEngine for FakeEngine {
        fn speak_streaming(
            &self,
            text: &str,
            voice: &VoiceId,
            on_chunk: &mut dyn FnMut(AudioChunk) -> TtsResult<()>,
        ) -> TtsResult<()> {
            if !self.voices.iter().any(|v| &v.id == voice) {
                return Err(TtsError::UnknownVoice(voice.clone()));
            }
            self.calls.lock().unwrap().push(text.to_string());
            self.call_count.fetch_add(1, Ordering::SeqCst);

            let samples_per_chunk = text.chars().count().max(1);
            for _ in 0..self.chunks_per_call {
                on_chunk(AudioChunk {
                    samples: vec![0.0; samples_per_chunk],
                    sample_rate: 44100,
                    channels: 1,
                })?;
            }
            Ok(())
        }

        fn voices(&self) -> Vec<VoiceInfo> {
            self.voices.clone()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::FakeEngine;
    use super::*;

    #[test]
    fn voice_id_displays_its_inner_string() {
        let id = VoiceId::new("F5");
        assert_eq!(id.to_string(), "F5");
        assert_eq!(VoiceId::from("M3"), VoiceId::new("M3"));
    }

    #[test]
    fn fake_engine_streams_chunks_for_a_known_voice() {
        let engine = FakeEngine::new();
        let voice = engine.voices()[0].id.clone();

        let mut received = Vec::new();
        engine
            .speak_streaming("Hola.", &voice, &mut |chunk| {
                received.push(chunk);
                Ok(())
            })
            .expect("la voz existe, no debería fallar");

        assert_eq!(received.len(), 1);
        assert_eq!(engine.call_texts(), vec!["Hola.".to_string()]);
    }

    #[test]
    fn fake_engine_rejects_unknown_voice() {
        let engine = FakeEngine::new();
        let unknown = VoiceId::new("NO-EXISTE");

        let err = engine
            .speak_streaming("Hola.", &unknown, &mut |_| Ok(()))
            .expect_err("una voz inexistente debe fallar");

        assert!(matches!(err, TtsError::UnknownVoice(id) if id == unknown));
    }

    #[test]
    fn on_chunk_error_short_circuits_the_engine() {
        let engine = FakeEngine {
            chunks_per_call: 3,
            ..FakeEngine::new()
        };
        let voice = engine.voices()[0].id.clone();

        let mut seen = 0;
        let err = engine
            .speak_streaming("Frase larga de prueba.", &voice, &mut |_| {
                seen += 1;
                if seen == 1 {
                    Err(TtsError::Network("simulado".to_string()))
                } else {
                    Ok(())
                }
            })
            .expect_err("el callback debe cortar la síntesis");

        assert!(matches!(err, TtsError::Network(_)));
        // El motor no debe seguir invocando on_chunk después del error.
        assert_eq!(seen, 1);
    }

    #[test]
    fn tts_error_display_is_human_readable_spanish() {
        let err = TtsError::Network("timeout".to_string());
        assert_eq!(err.to_string(), "error de red: timeout");

        let err = TtsError::UnknownVoice(VoiceId::new("X9"));
        assert_eq!(err.to_string(), "voz desconocida: X9");
    }
}
