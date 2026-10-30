import Foundation

/// Corta el texto que llega en streaming en oraciones para la voz.
///
/// La voz empieza a hablar con la **primera oración completa** y no con la
/// respuesta entera: eso es lo que hace que la conversación se sienta como
/// una llamada y no como esperar un correo. Una oración termina en `.`, `!`,
/// `?`, `…`, `:` o `;` seguidos de un espacio, o en un salto de línea. Lo
/// primero de la respuesta sale antes: también con una coma, si ya lleva
/// `palabrasParaLaPrimeraComa` palabras.
///
/// Lo que no corta: un punto entre dígitos («3.5»), una abreviatura conocida
/// («Sr.», «etc.», «EE. UU.») y un trozo de una sola letra. Puro: entra
/// texto, salen oraciones.
public struct TrozosParaDecir: Sendable {
  private var pendiente = ""
  private var yaSalioAlgo = false

  /// Lo más corto que se manda solo. Una oración de una letra («a.») es casi
  /// siempre un pedazo de una sigla, no algo que decir.
  public static let largoMinimo = 2

  /// Cuántas palabras tiene que llevar lo primero para cortar en una coma:
  /// con menos («Sí, …», «Hola, Alfonso, …») la pausa queda rara.
  public static let palabrasParaLaPrimeraComa = 4

  static let abreviaturas: Set<String> = [
    "sr", "sra", "srta", "dr", "dra", "etc", "ej", "p", "pag", "aprox", "av", "depto", "n", "nro",
    "ee", "uu", "vs", "min", "max", "tel", "ud", "uds", "art", "prof", "ing", "lic",
  ]

  public init() {}

  /// Suma un pedazo y devuelve las oraciones que quedaron completas, ya
  /// limpias para decir.
  public mutating func agregar(_ pedazo: String) -> [String] {
    pendiente += pedazo
    var oraciones: [String] = []
    while let corte = siguienteCorte() {
      let oracion = String(pendiente[..<corte])
      pendiente = String(pendiente[corte...])
      let limpia = Self.paraDecir(oracion)
      if limpia.count >= Self.largoMinimo {
        oraciones.append(limpia)
        yaSalioAlgo = true
      }
    }
    return oraciones
  }

  /// Lo que quedó sin terminar cuando la respuesta se acabó, o nil si no
  /// queda nada que decir.
  public mutating func terminar() -> String? {
    let resto = Self.paraDecir(pendiente)
    pendiente = ""
    return resto.isEmpty ? nil : resto
  }

  /// Dónde termina la primera oración completa, contando el espacio que la
  /// cierra; nil si todavía no hay ninguna.
  private func siguienteCorte() -> String.Index? {
    var i = pendiente.startIndex
    while i < pendiente.endIndex {
      let c = pendiente[i]
      let siguiente = pendiente.index(after: i)
      if c == "\n" {
        return siguiente
      }
      if c == ",", !yaSalioAlgo {
        let siguienteEsEspacio = siguiente < pendiente.endIndex && pendiente[siguiente].isWhitespace
        let palabras = pendiente[..<i].split(whereSeparator: \.isWhitespace).count
        if siguienteEsEspacio, palabras >= Self.palabrasParaLaPrimeraComa {
          return pendiente.index(after: siguiente)
        }
      }
      if ".!?…:;".contains(c) {
        // Hace falta ver qué viene después: sin eso no se sabe si «3.» es
        // el final o «3.5».
        guard siguiente < pendiente.endIndex else { return nil }
        let despues = pendiente[siguiente]
        if despues.isWhitespace, !esAbreviatura(antesDe: i, signo: c) {
          return pendiente.index(after: siguiente)
        }
      }
      i = siguiente
    }
    return nil
  }

  private func esAbreviatura(antesDe punto: String.Index, signo: Character) -> Bool {
    guard signo == "." else { return false }
    let antes = pendiente[..<punto]
    let palabra = antes.reversed().prefix { $0.isLetter }
    let plegada = String(palabra.reversed()).folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es")
    )
    // Una sola letra mayúscula («J. Pérez») tampoco termina nada.
    if palabra.count == 1, palabra.first?.isUppercase == true { return true }
    return Self.abreviaturas.contains(plegada)
  }

  /// El texto como se dice: sin markdown, sin viñetas, sin espacios de más.
  /// El prompt pide no usar markdown; esto es para cuando igual llega.
  public static func paraDecir(_ texto: String) -> String {
    var limpio = texto
    for marca in ["**", "__", "`", "~~"] {
      limpio = limpio.replacingOccurrences(of: marca, with: "")
    }
    let lineas = limpio.split(separator: "\n", omittingEmptySubsequences: false).map { linea -> String in
      var linea = linea.trimmingCharacters(in: .whitespaces)
      while let primero = linea.first, "#>".contains(primero) {
        linea = String(linea.dropFirst()).trimmingCharacters(in: .whitespaces)
      }
      if linea.hasPrefix("- ") || linea.hasPrefix("* ") || linea.hasPrefix("• ") {
        linea = String(linea.dropFirst(2))
      }
      return linea
    }
    limpio = lineas.joined(separator: " ")
    limpio = limpio.replacingOccurrences(of: "*", with: "")
    return limpio.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
