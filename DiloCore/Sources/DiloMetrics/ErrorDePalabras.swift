import Foundation

/// El WER de una transcripción contra su referencia: cuántas palabras hubo
/// que cambiar, quitar o poner, sobre cuántas tenía la referencia.
///
/// Es la vara del banco de comparación de motores (`scripts/comparar-motores.sh`)
/// y es pura para que la cuenta se pruebe sola: un WER mal contado hace ganar
/// al motor equivocado.
///
/// **Qué se normaliza y qué no.** Se ignoran mayúsculas, puntuación y
/// espacios, porque cada motor puntúa a su manera y Dilo los pule después.
/// Las tildes **cuentan**: «esta» por «está» es un error que la persona tiene
/// que corregir a mano. Los números no se reescriben: «tres» contra «3» cuenta
/// como error, y por eso la referencia se escribe como se quiere ver pegado.
public struct ErrorDePalabras: Sendable, Equatable {
  /// Sustituciones + borrados + inserciones.
  public let ediciones: Int
  /// Palabras de la referencia.
  public let palabras: Int

  public init(ediciones: Int, palabras: Int) {
    self.ediciones = ediciones
    self.palabras = palabras
  }

  /// La fracción, entre 0 y lo que dé (puede pasar de 1 si el motor inventa).
  /// Sin palabras en la referencia es 0 si tampoco hay en la hipótesis.
  public var tasa: Double {
    guard palabras > 0 else { return ediciones == 0 ? 0 : 1 }
    return Double(ediciones) / Double(palabras)
  }

  /// Sumar dos archivos da el WER del corpus —ediciones totales sobre
  /// palabras totales—, que no es el promedio de los WER: un archivo de tres
  /// palabras no pesa lo mismo que uno de trescientas.
  public static func + (a: ErrorDePalabras, b: ErrorDePalabras) -> ErrorDePalabras {
    ErrorDePalabras(ediciones: a.ediciones + b.ediciones, palabras: a.palabras + b.palabras)
  }

  public static let cero = ErrorDePalabras(ediciones: 0, palabras: 0)

  public static func medir(referencia: String, hipotesis: String) -> ErrorDePalabras {
    let ref = palabras(de: referencia)
    let hip = palabras(de: hipotesis)
    return ErrorDePalabras(ediciones: distancia(ref, hip), palabras: ref.count)
  }

  /// Las palabras como las cuenta el WER: minúsculas, sin puntuación, con
  /// tildes y eñes.
  public static func palabras(de texto: String) -> [String] {
    texto.lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
  }

  /// Levenshtein por palabras, con dos filas: un dictado de diez minutos son
  /// unas mil quinientas palabras y una matriz entera no hace falta.
  static func distancia(_ a: [String], _ b: [String]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var anterior = Array(0...b.count)
    var actual = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
      actual[0] = i
      for j in 1...b.count {
        let costo = a[i - 1] == b[j - 1] ? 0 : 1
        actual[j] = min(anterior[j] + 1, actual[j - 1] + 1, anterior[j - 1] + costo)
      }
      swap(&anterior, &actual)
    }
    return anterior[b.count]
  }
}
