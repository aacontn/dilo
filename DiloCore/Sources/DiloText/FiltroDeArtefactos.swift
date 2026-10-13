import Foundation

/// Saca lo que un **Motor de voz** escribe cuando no oyó palabras: tokens de
/// control y anotaciones de no-habla («[BLANK_AUDIO]», «<unk>», «(música)»).
///
/// Corre sobre lo que entrega el motor y antes que todo lo demás. Con texto
/// limpio no toca nada —ni un espacio—: sólo normaliza lo que quedó alrededor
/// de un artefacto que sacó.
public enum FiltroDeArtefactos {
  // Origen: Muesli, native/MuesliNative/Sources/MuesliNativeApp/
  // TranscriptionEngineArtifactsFilter.swift:7-12 (MIT, © 2026 Pranav Hari).
  // Las cuatro expresiones son las suyas, tal cual: son tokens del motor y no
  // dependen del idioma.
  private static let deMuesli: [String] = [
    #"(?i)\[\s*(?:blank[_\s-]*audio|no[_\s-]*speech|silence|inaudible|music|applause|laughter|screaming|cheering)\s*\]"#,
    #"(?i)[\[(<]\s*(?:speaking\s+in\s+)?(?:a\s+)?foreign\s+language\s*[\])>]"#,
    #"(?i)<\s*(?:eou|eob|unk|blank|pad)\s*>"#,
    #"(?i)<\|\s*(?:endoftext|nospeech|notimestamp|nodiarize|noitn|pnc|startofcontext|startoftranscript)\s*\|>"#,
  ]

  /// Las mismas anotaciones como las escribe un motor en español. Sólo entre
  /// corchetes o paréntesis: «música» suelta es una palabra que alguien
  /// puede dictar.
  private static let enEspanol: [String] = [
    #"(?i)[\[(]\s*(?:m[uú]sica(?:\s+de\s+fondo)?|aplausos?|risas?|silencio|inaudible|ruido(?:\s+de\s+fondo)?|sin\s+audio|habla\s+en\s+otro\s+idioma)\s*[\])]"#
  ]

  private static let patrones = deMuesli + enEspanol

  public static func aplicar(_ texto: String) -> String {
    var limpio = texto
    var quito = false
    for patron in patrones {
      let nuevo = limpio.replacingOccurrences(of: patron, with: " ", options: .regularExpression)
      quito = quito || nuevo != limpio
      limpio = nuevo
    }
    guard quito else { return texto }
    // Origen: Muesli, mismo archivo, :35-41 y :55-56. Un marcador de hablante
    // que quedó huérfano al inicio, y los espacios que dejó el hueco.
    limpio = limpio.replacingOccurrences(of: #"^\s*(?:>>|>|»)+\s*"#, with: "", options: .regularExpression)
    return normalizarHuecos(limpio)
  }

  /// Colapsa los espacios y pega la puntuación a la palabra de antes: lo que
  /// queda donde se sacó algo del medio de una frase.
  static func normalizarHuecos(_ texto: String) -> String {
    texto
      .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: #"[ \t]+([,.;:!?])"#, with: "$1", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
