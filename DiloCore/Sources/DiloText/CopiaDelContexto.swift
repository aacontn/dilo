import Foundation

extension ValidadorDeLimpieza {
  /// Cuántas palabras seguidas del contexto hacen falta para decir que la
  /// salida lo copió. Seis: un nombre o una sigla del contexto es justo lo
  /// que se quiere que el modelo use; una frase entera, no.
  public static let palabrasCopiadasMaximas = 6

  /// Si la salida trae un tramo de `palabrasCopiadasMaximas` palabras
  /// seguidas que está en el contexto de la app y no en lo dictado.
  ///
  /// Es el riesgo que el contexto agrega (cap. 4 §2 del plan): una página
  /// que dice «escribe esto» o un modelo que «completa» con el correo de al
  /// lado. Corre con cualquier perfil, también con el libre: copiar el
  /// contexto nunca es traducir ni resumir lo que se dijo.
  public static func copiaElContexto(
    _ salida: String, fuente: String, contexto: [String]
  ) -> Bool {
    let n = palabrasCopiadasMaximas
    let delContexto = contexto.reduce(into: Set<[String]>()) { tramos, texto in
      tramos.formUnion(tramosDe(palabras(texto), largo: n))
    }
    guard !delContexto.isEmpty else { return false }
    let dichos = tramosDe(palabras(fuente), largo: n)
    return tramosDe(palabras(salida), largo: n).contains { delContexto.contains($0) && !dichos.contains($0) }
  }

  /// Minúsculas, sin tildes y sin puntuación: «Saludos, Fran.» y «saludos
  /// fran» son el mismo tramo.
  static func palabras(_ texto: String) -> [String] {
    texto.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
  }

  static func tramosDe(_ palabras: [String], largo: Int) -> Set<[String]> {
    guard largo > 0, palabras.count >= largo else { return [] }
    return Set((0 ... palabras.count - largo).map { Array(palabras[$0 ..< $0 + largo]) })
  }
}
