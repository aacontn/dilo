import Foundation

// Técnica observada en Ocelli (Ghidra, FUN_1004a8abc / FUN_100497c10: el texto
// entero normalizado, de cinco palabras o menos, igual a una frase de la lista, y
// sólo con la toma bajo −48 dB). Implementación y listas propias, en español.
/// Lo que un motor dice cuando no hubo nadie hablando: la firma de los
/// subtítulos con que se entrenó, un «gracias», un «suscríbete».
///
/// Dos niveles, porque no todas cuestan lo mismo de equivocarse:
///
/// - **Nivel 1, siempre:** la firma de Amara y los créditos de subtítulos.
///   Nadie los dicta, y aparecen pegados al final de un dictado real.
/// - **Nivel 2, sólo con la toma casi muda y sólo si es el texto entero:**
///   «gracias», «chao», «suscríbete». Un «gracias» dictado de verdad sobre
///   una toma con voz nunca se borra.
public enum FrasesFantasma {
  /// Lo que se saca siempre, esté donde esté.
  private static let nivel1: [String] = [
    // «Subtítulos realizados por la comunidad de Amara.org» y lo que siga
    // hasta el final de la frase. Con «realizados» y no con cualquier «por»:
    // «activa los subtítulos por favor» es un dictado.
    #"(?i)subt[ií]tulos?\s+realizados?\s+por\s+(?:[^.!?\n]*?amara\s*\.\s*org|[^.!?\n]*)[.!?]?"#,
    // «Subtítulos por la comunidad de Amara.org», «subtitulado por Amara.org»:
    // sin «realizados», sólo cuando la firma está.
    #"(?i)(?:subt[ií]tulos?|subtitulado)\s+por\s+[^.!?\n]*?amara\s*\.\s*org[.!?]?"#,
    // La firma suelta.
    #"(?i)(?:www\.)?amara\s*\.\s*org\.?"#,
  ]

  /// Las frases que un motor inventa sobre silencio, ya normalizadas: sin
  /// tildes, sin puntuación, en minúsculas.
  public static let nivel2: Set<String> = [
    "gracias", "muchas gracias", "gracias por ver", "gracias por ver el video",
    "gracias por mirar", "gracias por su atencion", "gracias por tu atencion",
    "suscribete", "suscribete al canal", "suscribanse", "no olvides suscribirte",
    "dale like", "hasta luego", "hasta la proxima", "nos vemos",
    "nos vemos en el proximo video", "chao", "chau", "adios",
    "musica", "aplausos", "risas", "silencio", "subtitulos",
    // Por si el dictado es bilingüe: los mismos fantasmas en inglés.
    "you", "thank you", "thanks", "thanks for watching", "thank you for watching", "bye",
  ]

  /// Cuántas palabras puede tener un fantasma de nivel 2. Ocelli.
  public static let palabrasMaximasDeUnFantasma = 5

  /// Saca el nivel 1. Lo demás queda como estaba.
  public static func quitarSiempre(_ texto: String) -> String {
    var limpio = texto
    for patron in nivel1 {
      limpio = limpio.replacingOccurrences(of: patron, with: " ", options: .regularExpression)
    }
    return limpio == texto ? texto : FiltroDeArtefactos.normalizarHuecos(limpio)
  }

  /// Minúsculas, sin tildes ni puntuación, una palabra por elemento.
  public static func normalizar(_ texto: String) -> [String] {
    texto
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es"))
      .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
      .map(String.init)
  }

  /// Si el texto **entero** es una frase de nivel 2 y la toma estaba casi
  /// muda.
  public static func esFantasma(_ texto: String, tomaCasiMuda: Bool) -> Bool {
    guard tomaCasiMuda else { return false }
    let palabras = normalizar(texto)
    guard (1...palabrasMaximasDeUnFantasma).contains(palabras.count) else { return false }
    return nivel2.contains(palabras.joined(separator: " "))
  }
}
