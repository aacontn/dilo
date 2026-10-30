import Foundation

// Spoken Send: idea de FluidVoice (GPL-3; sin código). Propio de Dilo.

/// «…nos vemos mañana. Envía.» pega el texto y aprieta ↩. **Sólo al final y
/// sólo si va apartado por un signo**: en español «envía» es un verbo común,
/// y «dile que me envía el informe» no manda nada.
///
/// Puro: dice qué texto queda y si se pidió mandar. Si de verdad se manda lo
/// decide la app con `PoliticaDelEnvio` (nunca en una terminal, nunca en un
/// campo seguro, nunca si no se confirmó que el texto entró) y la tecla la
/// aprieta `AtajoSimulado`, que no lo hace con modificadores apretados.
///
/// Corre al final de la capa de reglas, **antes del modo**: la frase no llega
/// al modelo de texto ni a la traducción.
public enum EnvioHablado {
  public static let frasesDeFabrica = ["envía", "envíalo", "mándalo"]
  /// Dicho antes de la frase, la escribe y no manda: «literal envía».
  public static let escapeDeFabrica = "literal"

  public static func analizar(
    _ texto: String,
    frases: [String] = frasesDeFabrica,
    escape: String = escapeDeFabrica
  ) -> (texto: String, enviar: Bool) {
    let limpias = frases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    guard !limpias.isEmpty else { return (texto, false) }
    let alternativas = limpias.map(patronSinTildes).joined(separator: "|")
    // 1: el comienzo o el signo que la aparta. 2: el escape. 3: la frase,
    // repetida si se dijo dos veces («envía, envía»). Después, sólo espacios
    // y puntuación hasta el final.
    let patron = "(^|[.,;!?¿¡\\n]\\s*)(\(patronSinTildes(escape))\\s+)?((?:\(alternativas))(?:[\\s,]+(?:\(alternativas)))*)[\\s.,;:!?…]*$"
    guard let regex = try? NSRegularExpression(pattern: patron, options: [.caseInsensitive]),
      let m = regex.firstMatch(in: texto, range: NSRange(location: 0, length: (texto as NSString).length))
    else { return (texto, false) }
    let ns = texto as NSString
    if m.range(at: 2).location != NSNotFound {
      // «literal envía»: se escribe la palabra y no se manda nada.
      return (ns.replacingCharacters(in: m.range(at: 2), with: ""), false)
    }
    var antes = ns.substring(to: m.range.location) + ns.substring(with: m.range(at: 1))
    antes = antes.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n,;:-–"))
    // Lo que queda termina en un signo de cierre: la coma que apartaba la
    // frase no se queda colgando en el mensaje.
    if let ultimo = antes.last, !".?!…".contains(ultimo) { antes += "." }
    return (antes, true)
  }

  /// La frase como patrón que acepta las vocales con y sin tilde: el motor
  /// escribe «envia» o «envía» según cómo lo oyó.
  static func patronSinTildes(_ frase: String) -> String {
    let grupos: [Character: String] = [
      "a": "[aá]", "á": "[aá]", "e": "[eé]", "é": "[eé]", "i": "[ií]", "í": "[ií]",
      "o": "[oó]", "ó": "[oó]", "u": "[uúü]", "ú": "[uúü]", "ü": "[uúü]",
    ]
    return frase.lowercased().map { letra in
      if let grupo = grupos[letra] { return grupo }
      if letra.isWhitespace { return "\\s+" }
      return NSRegularExpression.escapedPattern(for: String(letra))
    }.joined()
  }
}
