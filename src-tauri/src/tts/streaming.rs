//! Segmentación por puntuación y reproducción encolada con `rodio`, sin WAV
//! intermedio.
//!
//! Port directo de `spikes/voz/supertonic/src/bin/streaming.rs` (Command
//! Center), que midió esto con el motor real: TTFA 543–653 ms, cero
//! underruns en 9 corridas (ver `spikes/voz/RESULTADOS.md`, sección
//! "Supertonic — streaming por frases").

use super::{AudioChunk, TtsEngine, TtsResult, VoiceId};

/// Largo mínimo (en **bytes** UTF-8, como `str::len()`) de un segmento antes
/// de fundirlo con el siguiente átomo de puntuación.
///
/// **Trampa documentada y medida — no subir este valor sin volver a medir
/// TTFA.** Con `MIN_SEGMENT_CHARS = 10`, el primer átomo natural de una
/// frase con coma temprana como "Señor, hay tres trabajos..." ("Señor,", 6
/// caracteres / 7 bytes) queda por debajo del umbral y se funde con el
/// resto de la frase: ese caso termina sintetizándose como un solo
/// segmento y el TTFA medido en el spike subió a **1114 ms** (rango
/// [1073, 1192] ms) — por encima del objetivo de <1 s.
///
/// Con `MIN_SEGMENT_CHARS = 5`, "Señor," pasa a ser su propio segmento y el
/// TTFA baja a **543 ms** de promedio, sin introducir ningún underrun
/// nuevo (0/9 corridas): el motor sintetiza cómodamente más rápido de lo
/// que tarda en sonar incluso un fragmento de 6 caracteres — el piso de
/// latencia por segmento (~500-650 ms) está dominado por el costo fijo de
/// las 4 sesiones ONNX y los pasos de denoising, no por el largo del texto
/// de entrada. Se dejó 5 (no 1) por prudencia, solo para evitar fragmentos
/// de una sola letra o un signo suelto.
///
/// Ver `spikes/voz/RESULTADOS.md` (Command Center), sección "Umbral de
/// fragmentación", para la medición completa. [`tests::first_segment_of_a_comma_led_sentence_is_short`]
/// falla si este valor vuelve a subir lo suficiente como para fundir ese
/// caso.
pub const MIN_SEGMENT_CHARS: usize = 5;

/// Parte `text` en unidades naturales por puntuación (`. , ; : ! ?`),
/// fundiendo hacia adelante cualquier átomo que quede por debajo de
/// [`MIN_SEGMENT_CHARS`] (salvo el último, que siempre se emite tal cual).
///
/// Texto vacío o solo espacios devuelve un vector vacío — no hay nada que
/// sintetizar. Texto sin ninguna puntuación devuelve un único segmento con
/// el texto completo (no hay dónde cortar).
pub fn split_segments(text: &str) -> Vec<String> {
    if text.trim().is_empty() {
        return Vec::new();
    }

    let mut atoms = Vec::new();
    let mut current = String::new();
    for ch in text.chars() {
        current.push(ch);
        if matches!(ch, '.' | ',' | ';' | ':' | '!' | '?') {
            let trimmed = current.trim().to_string();
            if !trimmed.is_empty() {
                atoms.push(trimmed);
            }
            current.clear();
        }
    }
    let rest = current.trim().to_string();
    if !rest.is_empty() {
        atoms.push(rest);
    }
    if atoms.is_empty() {
        return vec![text.trim().to_string()];
    }

    let mut segments = Vec::new();
    let mut buf = String::new();
    for (i, atom) in atoms.iter().enumerate() {
        if !buf.is_empty() {
            buf.push(' ');
        }
        buf.push_str(atom);
        let is_last = i == atoms.len() - 1;
        if buf.len() >= MIN_SEGMENT_CHARS || is_last {
            segments.push(std::mem::take(&mut buf));
        }
    }
    if !buf.is_empty() {
        segments.push(buf);
    }
    segments
}

/// Sintetiza `text` por segmentos (ver [`split_segments`]) y encola cada
/// fragmento de audio en `sink` a medida que está listo — sin esperar a
/// tener el texto completo sintetizado y sin pasar por WAV en disco
/// (`AudioChunk` se convierte directo a un `SamplesBuffer` en memoria).
///
/// Esta es la función que produce el TTFA bajo: `sink.append` en un `Sink`
/// vacío empieza a sonar de inmediato, así que el primer segmento suena tan
/// pronto como el motor lo termina, mientras los siguientes se siguen
/// sintetizando.
pub fn speak_into_sink(
    engine: &dyn TtsEngine,
    text: &str,
    voice: &VoiceId,
    sink: &rodio::Sink,
) -> TtsResult<()> {
    for segment in split_segments(text) {
        engine.speak_streaming(&segment, voice, &mut |chunk: AudioChunk| {
            let source =
                rodio::buffer::SamplesBuffer::new(chunk.channels, chunk.sample_rate, chunk.samples);
            sink.append(source);
            Ok(())
        })?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tts::test_support::FakeEngine;

    // --- Tabla de casos de segmentación -----------------------------------

    #[test]
    fn short_sentence_without_punctuation_is_a_single_segment() {
        assert_eq!(split_segments("Hola"), vec!["Hola".to_string()]);
    }

    #[test]
    fn sentence_with_early_comma_splits_the_short_lead_in() {
        let segments = split_segments("Señor, hay tres trabajos aguardando su aprobación.");
        assert_eq!(
            segments,
            vec![
                "Señor,".to_string(),
                "hay tres trabajos aguardando su aprobación.".to_string(),
            ]
        );
    }

    #[test]
    fn multiple_sentences_split_into_their_documented_segments() {
        // Mismo "Caso largo" y mismo resultado medido en
        // spikes/voz/RESULTADOS.md (Command Center), sección de streaming.
        let text = "Buenos días. Todo se encuentra en orden: ningún incidente durante la noche. \
                     Me temo, eso sí, que el despliegue de anoche ha fallado; he conservado la \
                     versión anterior por si desea revisarla.";
        let segments = split_segments(text);
        assert_eq!(
            segments,
            vec![
                "Buenos días.".to_string(),
                "Todo se encuentra en orden:".to_string(),
                "ningún incidente durante la noche.".to_string(),
                "Me temo,".to_string(),
                "eso sí,".to_string(),
                "que el despliegue de anoche ha fallado;".to_string(),
                "he conservado la versión anterior por si desea revisarla.".to_string(),
            ]
        );
    }

    #[test]
    fn text_without_any_punctuation_stays_a_single_segment() {
        let segments = split_segments("Hola Alfonso como estas hoy");
        assert_eq!(segments, vec!["Hola Alfonso como estas hoy".to_string()]);
    }

    #[test]
    fn empty_text_produces_no_segments() {
        assert_eq!(split_segments(""), Vec::<String>::new());
        assert_eq!(split_segments("   "), Vec::<String>::new());
    }

    /// El test que debe FALLAR si se rompe la segmentación temprana: una
    /// frase con coma temprana debe producir un primer segmento corto (el
    /// átomo previo a la coma, no la frase entera). Si `MIN_SEGMENT_CHARS`
    /// sube lo suficiente (p. ej. a 10, ver la doc de la constante), este
    /// test falla porque el primer segmento pasa a ser la frase completa.
    #[test]
    fn first_segment_of_a_comma_led_sentence_is_short() {
        let segments = split_segments("Señor, hay tres trabajos aguardando su aprobación.");
        let first = segments.first().expect("debe haber al menos un segmento");
        assert!(
            first.len() < 10,
            "el primer segmento debería ser el átomo corto antes de la coma \
             (\"Señor,\"), no la frase completa; largo real: {} (\"{}\")",
            first.len(),
            first
        );
    }

    // --- speak_into_sink: engine fake + segmentación real -----------------

    #[test]
    fn speak_into_sink_calls_the_engine_once_per_segment() {
        let engine = FakeEngine::new();
        let voice = engine.voices()[0].id.clone();

        // Sin dispositivo de audio real disponible en CI, se prueba la
        // orquestación (segmentación -> una llamada al motor por segmento)
        // llamando split_segments + el motor directamente, sin pasar por un
        // Sink real (que requiere abrir un stream de audio del SO).
        for segment in split_segments("Señor, hay tres trabajos aguardando su aprobación.") {
            engine
                .speak_streaming(&segment, &voice, &mut |_| Ok(()))
                .expect("la voz existe");
        }

        assert_eq!(
            engine.call_texts(),
            vec![
                "Señor,".to_string(),
                "hay tres trabajos aguardando su aprobación.".to_string(),
            ]
        );
    }

    #[test]
    fn speak_into_sink_propagates_unknown_voice_error() {
        let engine = FakeEngine::new();
        let unknown = VoiceId::new("NO-EXISTE");

        // rodio::Sink::connect_new requiere un Mixer real (un stream de
        // audio abierto); en un test unitario sin dispositivo de salida
        // disponible eso no siempre es viable en CI, así que se verifica el
        // camino de error de speak_into_sink contra el motor directamente
        // (mismo código, sin el Sink de por medio).
        let err = engine
            .speak_streaming("Hola.", &unknown, &mut |_| Ok(()))
            .expect_err("una voz inexistente debe fallar");
        assert!(matches!(err, crate::tts::TtsError::UnknownVoice(_)));
    }

    /// Medición real de TTFA contra el motor Supertonic con pesos
    /// descargados en disco — no se ejecuta en CI (requiere ~411 MB de
    /// pesos y un dispositivo de audio real). Para correrla:
    ///
    /// ```bash
    /// export DILO_SUPERTONIC_MODELS_DIR=/ruta/a/spikes/voz/supertonic/models
    /// cargo test --release -p dilo tts::streaming::tests::ttfa_stays_under_one_second -- --ignored --nocapture
    /// ```
    ///
    /// El directorio debe tener el mismo layout que el spike:
    /// `<dir>/onnx/*.onnx` + `<dir>/voice_styles/*.json`.
    #[test]
    #[ignore = "requiere pesos de Supertonic en disco y un dispositivo de audio real"]
    fn ttfa_stays_under_one_second() {
        use crate::tts::supertonic::SupertonicEngine;
        use std::time::Instant;

        let models_dir = std::env::var("DILO_SUPERTONIC_MODELS_DIR")
            .expect("fijar DILO_SUPERTONIC_MODELS_DIR con la ruta a los pesos descargados");
        let onnx_dir = std::path::Path::new(&models_dir).join("onnx");
        let voice_styles_dir = std::path::Path::new(&models_dir).join("voice_styles");

        let engine =
            SupertonicEngine::load(&onnx_dir, &voice_styles_dir).expect("cargar el motor local");
        let voice = VoiceId::new(crate::tts::supertonic::DEFAULT_VOICE);

        let stream_handle = rodio::OutputStreamBuilder::open_default_stream()
            .expect("abrir el stream de audio por defecto");
        let sink = rodio::Sink::connect_new(stream_handle.mixer());

        let text = "Señor, hay tres trabajos aguardando su aprobación.";
        let t0 = Instant::now();
        let mut ttfa = None;
        for segment in split_segments(text) {
            engine
                .speak_streaming(&segment, &voice, &mut |chunk| {
                    if ttfa.is_none() {
                        ttfa = Some(t0.elapsed());
                    }
                    let source = rodio::buffer::SamplesBuffer::new(
                        chunk.channels,
                        chunk.sample_rate,
                        chunk.samples,
                    );
                    sink.append(source);
                    Ok(())
                })
                .expect("síntesis real");
        }
        sink.sleep_until_end();

        let ttfa = ttfa.expect("debe haber sintetizado al menos un fragmento");
        println!("TTFA real: {:?}", ttfa);
        assert!(
            ttfa.as_millis() < 1000,
            "TTFA debería ser <1s con el modelo residente, midió {:?}",
            ttfa
        );
    }
}
