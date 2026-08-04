//! Alineador de tokens con hablantes — Task 4 del plan "reuniones en
//! streaming" (`.superpowers/sdd/2026-08-04-reuniones-en-streaming/`).
//!
//! Pega cada [`TimedToken`] (Task 3, transcripción con marcas de tiempo
//! reales) al [`SpeakerSpan`] (Task 2, diarización en streaming) con el que
//! más se solapa en el tiempo, y agrupa los tokens consecutivos que
//! comparten hablante en una [`AttributedRun`] — la unidad que la UI puede
//! pintar como "una intervención de un hablante".
//!
//! Es lógica pura: sin ONNX, sin estado, sin async. Reemplaza el troceo por
//! turnos que Dilo usaba hasta ahora, cuyo problema motivó todo el plan:
//! una interrupción corta (media palabra de otro hablante pisando al que
//! tenía la palabra) no cabía en un turno y se perdía, fundida en el turno
//! de al lado o descartada por mezclada. Aquí cada token se resuelve por su
//! propio solape temporal, así que una interrupción de un solo token
//! sobrevive como su propia intervención (ver el test
//! `una_interrupcion_corta_sobrevive_como_intervencion_propia`).
//!
//! ## Regla dura: nunca adivinar
//!
//! Un token que no cae dentro de ningún [`SpeakerSpan`] (o cuando no hay
//! tramos en absoluto, por ejemplo si la diarización falló) queda con
//! `speaker: None`. Es la misma regla que ya rige el motor de diarización
//! no-streaming (ver `flatten_overlaps` en el módulo padre): es preferible
//! decir "sin identificar" que atribuirle a alguien algo que no dijo.

use crate::managers::diarization::sortformer::SpeakerSpan;
use crate::managers::transcription::TimedToken;

/// Una intervención atribuida: texto de uno o más tokens consecutivos que
/// comparten el mismo hablante (o la misma ausencia de hablante).
#[derive(Debug, Clone, PartialEq)]
pub struct AttributedRun {
    pub text: String,
    /// `None` cuando ningún tramo de hablante cubre estos tokens — nunca se
    /// adivina un hablante para rellenar este campo.
    pub speaker: Option<u8>,
    pub start_ms: u64,
    pub end_ms: u64,
}

/// Solape en milisegundos entre `[a_start, a_end)` y `[b_start, b_end)`, o 0
/// si no se tocan.
fn overlap_ms(a_start: u64, a_end: u64, b_start: u64, b_end: u64) -> u64 {
    let start = a_start.max(b_start);
    let end = a_end.min(b_end);
    end.saturating_sub(start)
}

/// Para un token, el hablante del tramo con mayor solape temporal, o `None`
/// si ningún tramo lo cubre (nunca se adivina).
fn speaker_for_token(token: &TimedToken, spans: &[SpeakerSpan]) -> Option<u8> {
    spans
        .iter()
        .map(|span| {
            (
                overlap_ms(token.start_ms, token.end_ms, span.start_ms, span.end_ms),
                span.speaker,
            )
        })
        .filter(|(overlap, _)| *overlap > 0)
        .max_by_key(|(overlap, _)| *overlap)
        .map(|(_, speaker)| speaker)
}

/// Pega cada token al hablante del tramo con mayor solape temporal y agrupa
/// los tokens consecutivos que comparten hablante en intervenciones.
///
/// Un token sin tramo que lo cubra queda con `speaker: None` — nunca se
/// adivina. Sin tokens, no hay intervenciones. Sin tramos, todo el texto
/// sale igual, sólo que sin hablante identificado (degradación honesta si
/// la diarización falla).
pub fn attribute(tokens: &[TimedToken], spans: &[SpeakerSpan]) -> Vec<AttributedRun> {
    let mut runs: Vec<AttributedRun> = Vec::new();

    for token in tokens {
        let speaker = speaker_for_token(token, spans);

        match runs.last_mut() {
            Some(run) if run.speaker == speaker => {
                run.text.push_str(&token.text);
                run.end_ms = token.end_ms;
            }
            _ => runs.push(AttributedRun {
                text: token.text.clone(),
                speaker,
                start_ms: token.start_ms,
                end_ms: token.end_ms,
            }),
        }
    }

    runs
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tok(text: &str, start_ms: u64, end_ms: u64) -> TimedToken {
        TimedToken {
            text: text.into(),
            start_ms,
            end_ms,
        }
    }

    fn span(start_ms: u64, end_ms: u64, speaker: u8) -> SpeakerSpan {
        SpeakerSpan {
            start_ms,
            end_ms,
            speaker,
        }
    }

    #[test]
    fn tokens_del_mismo_hablante_se_agrupan_en_una_intervencion() {
        let tokens = vec![
            tok("hola", 0, 300),
            tok(" que", 300, 600),
            tok(" tal", 600, 900),
        ];
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
            tok(" no", 450, 600), // interrupción
            tok(" diciendo", 650, 1000),
        ];
        let spans = vec![span(0, 430, 0), span(430, 620, 1), span(620, 1000, 0)];
        let runs = attribute(&tokens, &spans);
        assert_eq!(
            runs.len(),
            3,
            "la interrupción no puede fundirse con lo de al lado"
        );
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
