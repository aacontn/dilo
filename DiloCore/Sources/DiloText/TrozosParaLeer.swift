import Foundation

/// Lo que se va a leer, partido en trozos que una voz neural dice de una vez.
///
/// Tres razones para partir antes de sintetizar: PocketTTS se entrenó con
/// trozos cortos y con un párrafo entero se puede quedar hablando sin parar
/// (pide ≤ 50 tokens, unas treinta palabras); el primer audio llega cuando el
/// primer trozo está listo, no el texto entero; y detener entre un trozo y
/// otro es inmediato. Se corta por oración y, si una oración es muy larga,
/// por comas, punto y coma o dos puntos; sólo como último recurso entre dos
/// palabras.
public enum TrozosParaLeer {
  /// Unas treinta palabras del español son ~45 tokens del SentencePiece de
  /// PocketTTS: bajo los 50 que pide, con margen para los nombres raros.
  public static let palabrasPorTrozo = 30

  /// El primer trozo es más corto: el primer audio llega cuando ése está
  /// sintetizado, y una oración larga de entrada se oía recién al segundo.
  public static let palabrasDelPrimerTrozo = 14

  public static func partir(
    _ texto: String,
    maximo: Int = palabrasPorTrozo,
    primero: Int = palabrasDelPrimerTrozo
  ) -> [String] {
    var trozos: [String] = []
    for oracion in oraciones(texto) {
      let tope = trozos.isEmpty ? min(max(primero, 4), max(maximo, 4)) : max(maximo, 4)
      let partes = partirLarga(oracion, maximo: tope)
      trozos.append(partes[0])
      // Lo que queda de la primera oración ya va con el tope de siempre.
      if partes.count > 1 {
        let resto = partes.dropFirst().joined(separator: " ")
        trozos += partirLarga(resto, maximo: max(maximo, 4))
      }
    }
    return trozos
  }

  /// Las palabras que abren una frase nueva: sin coma a mano, cortar antes
  /// de una de éstas suena a pausa y no a corte («… vence el quince de marzo |
  /// y que el saldo …»), y no entre «tres coma cinco» y «u efe».
  static let abrenFrase: Set<String> = [
    "y", "e", "o", "u", "ni", "que", "pero", "porque", "pues", "aunque", "cuando",
    "donde", "mientras", "si", "sino", "como", "para", "desde", "hasta", "ante",
  ]

  /// Corta después de `.`, `!`, `?`, `…` o un salto de línea. El signo de
  /// apertura (`¿`, `¡`) queda con la oración que abre.
  static func oraciones(_ texto: String) -> [String] {
    var resultado: [String] = []
    var actual = ""
    let caracteres = Array(texto)
    var i = 0
    while i < caracteres.count {
      let c = caracteres[i]
      if c.isNewline {
        cerrar(&actual, en: &resultado)
        i += 1
        continue
      }
      actual.append(c)
      if ".!?…".contains(c) {
        // Los signos seguidos («?!», «...») van juntos.
        while i + 1 < caracteres.count, ".!?…\"»)".contains(caracteres[i + 1]) {
          i += 1
          actual.append(caracteres[i])
        }
        // Un punto pegado a la palabra siguiente no termina oración: «dilo.cl».
        if i + 1 == caracteres.count || caracteres[i + 1].isWhitespace {
          cerrar(&actual, en: &resultado)
        }
      }
      i += 1
    }
    cerrar(&actual, en: &resultado)
    return resultado
  }

  private static func cerrar(_ actual: inout String, en resultado: inout [String]) {
    let limpio = actual.trimmingCharacters(in: .whitespaces)
    if limpio.contains(where: { $0.isLetter || $0.isNumber }) { resultado.append(limpio) }
    actual = ""
  }

  static func partirLarga(_ oracion: String, maximo: Int) -> [String] {
    let palabras = oracion.split(whereSeparator: \.isWhitespace).map(String.init)
    guard palabras.count > maximo else { return [oracion] }

    var trozos: [String] = []
    var actual: [String] = []
    var i = 0
    while i < palabras.count {
      actual.append(palabras[i])
      let quedan = palabras.count - i - 1
      let pausa = palabras[i].last.map { ",;:".contains($0) } ?? false
      // En una pausa, si ya hay medio trozo y lo que queda no es una cola de
      // dos palabras sueltas.
      if pausa && actual.count >= maximo / 2 && quedan > 2 {
        trozos.append(actual.joined(separator: " "))
        actual = []
      } else if actual.count >= maximo {
        // Al tope sin pausa: se corta antes de la última palabra que abre
        // frase, si está en la segunda mitad; si no, ahí mismo.
        if var k = actual.indices.last(where: { $0 >= maximo / 2 && abrenFrase.contains(actual[$0].lowercased()) }) {
          // «y que» abre junto: el corte va antes de la primera.
          while k - 1 >= maximo / 2, abrenFrase.contains(actual[k - 1].lowercased()) { k -= 1 }
          trozos.append(actual[..<k].joined(separator: " "))
          actual = Array(actual[k...])
        } else {
          trozos.append(actual.joined(separator: " "))
          actual = []
        }
      }
      i += 1
    }
    if !actual.isEmpty {
      // Una cola cortita va con el trozo anterior si cabe.
      if actual.count <= 2, let ultimo = trozos.last,
        ultimo.split(separator: " ").count + actual.count <= maximo + 2
      {
        trozos[trozos.count - 1] = ultimo + " " + actual.joined(separator: " ")
      } else {
        trozos.append(actual.joined(separator: " "))
      }
    }
    return trozos
  }
}
