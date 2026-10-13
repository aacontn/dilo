import Foundation

// Idea (sin código) de BetterWispr: una sola expresión con todas las frases,
// las largas primero, con bordes de palabra Unicode y una sola pasada. El
// código y la comparación sin tildes son de Dilo.

/// «Cuando digo… / Escríbelo así». Lo que Tus palabras no alcanza por
/// parecido: «chat ge pe te» no se parece a «ChatGPT» en nada, pero es lo
/// que la persona quiere ver escrito.
///
/// El `Codable` es lo que se guarda en `diloReemplazos`: los nombres de los
/// campos no se renombran.
public struct Reemplazo: Codable, Equatable, Hashable, Sendable {
  public var dice: String
  public var escribe: String

  public init(dice: String, escribe: String) {
    self.dice = dice
    self.escribe = escribe
  }
}

public enum Reemplazos {
  /// Aplica la lista en una pasada, de izquierda a derecha: lo que un
  /// reemplazo escribió no lo vuelve a tocar otro, así que «A → B» y
  /// «B → C» no encadenan.
  ///
  /// El borde es «ni letra, ni marca, ni número, ni guion bajo» en Unicode:
  /// con `\b` de ASCII, «sap» calzaba adentro de «sapé». Las tildes no
  /// importan al comparar —«decamerón» calza con «decameron»— y la ñ sí:
  /// «año» y «ano» son palabras distintas.
  public static func aplicar(_ lista: [Reemplazo], a texto: String) -> String {
    let validas = lista
      .filter { !$0.dice.trimmingCharacters(in: .whitespaces).isEmpty }
      .sorted { $0.dice.count > $1.dice.count }
    guard !validas.isEmpty, !texto.isEmpty else { return texto }
    let alternativas = validas.map { patron($0.dice) }.joined(separator: "|")
    let borde = "[\\p{L}\\p{M}\\p{N}_]"
    guard let regex = try? NSRegularExpression(
      pattern: "(?<!\(borde))(?:\(alternativas))(?!\(borde))", options: [.caseInsensitive])
    else { return texto }

    let fuente = texto as NSString
    var salida = ""
    var desde = 0
    for calce in regex.matches(in: texto, range: NSRange(location: 0, length: fuente.length)) {
      let dicho = fuente.substring(with: calce.range)
      salida += fuente.substring(with: NSRange(location: desde, length: calce.range.location - desde))
      desde = NSMaxRange(calce.range)
      guard let entrada = validas.first(where: { plegar($0.dice) == plegar(dicho) }) else {
        salida += dicho
        continue
      }
      salida += conMayusculaSiAbreFrase(entrada.escribe, dicho: dicho, antes: salida)
    }
    salida += fuente.substring(from: desde)
    return salida
  }

  /// Al comienzo de una frase, una palabra guardada en minúscula («github»)
  /// sale con mayúscula si el motor la había escrito así. A mitad de frase,
  /// tal cual se guardó.
  static func conMayusculaSiAbreFrase(_ escribe: String, dicho: String, antes: String) -> String {
    guard dicho.first?.isUppercase == true, let primera = escribe.first, primera.isLowercase else {
      return escribe
    }
    let previo = antes.last { $0 != " " && $0 != "\t" }
    guard previo == nil || ".!?¿¡\n".contains(previo!) else { return escribe }
    return primera.uppercased() + escribe.dropFirst()
  }

  /// La frase como expresión: cada vocal acepta sus tildes y los espacios
  /// aceptan cualquier cantidad. La ñ queda como ñ.
  static func patron(_ frase: String) -> String {
    let vocales: [Character: String] = [
      "a": "[aáàäâ]", "e": "[eéèëê]", "i": "[iíìïî]", "o": "[oóòöô]", "u": "[uúùüû]",
    ]
    var resultado = ""
    var espacio = false
    for c in frase.trimmingCharacters(in: .whitespaces) {
      if c == " " || c == "\t" {
        if !espacio { resultado += "[ \\t]+" }
        espacio = true
        continue
      }
      espacio = false
      if c == "ñ" || c == "Ñ" {
        resultado += "ñ"
        continue
      }
      let base = String(c).folding(options: .diacriticInsensitive, locale: nil).lowercased()
      if base.count == 1, let clase = vocales[Character(base)] {
        resultado += clase
      } else {
        resultado += NSRegularExpression.escapedPattern(for: String(c))
      }
    }
    return resultado
  }

  /// Sin tildes y en minúsculas, salvo la ñ: plegarla juntaría «año» con
  /// «ano».
  static func plegar(_ s: String) -> String {
    s.lowercased()
      .map { $0 == "ñ" ? "ñ" : String($0).folding(options: .diacriticInsensitive, locale: nil) }
      .joined()
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
