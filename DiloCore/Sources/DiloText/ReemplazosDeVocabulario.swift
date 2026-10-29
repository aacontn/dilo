import Foundation

/// Los reemplazos que la segunda pasada de **Tus palabras** encontró en el
/// audio («de camerún» → «Decameron»), aplicados sobre el texto que Dilo ya
/// cosió.
///
/// No se usa el texto que devuelve FluidAudio: viene rearmado desde los
/// tiempos de cada palabra y traería de vuelta las palabras pegadas que
/// `CosturaDeTrozos` separa. Se aplica sólo lo reemplazado, en orden, cada
/// par una vez y siempre más adelante que el anterior, con bordes Unicode
/// para que «año» no calce dentro de «años».
public enum ReemplazosDeVocabulario {
  public static func aplicar(_ pares: [(original: String, nuevo: String)], a texto: String) -> String {
    var resultado = texto
    // Hasta dónde ya se reemplazó, contado en caracteres: los índices no
    // sobreviven a un reemplazo.
    var desde = 0
    for (original, nuevo) in pares where !original.isEmpty {
      let patron = #"(?<![\p{L}\p{M}\p{N}_])"# + NSRegularExpression.escapedPattern(for: original)
        + #"(?![\p{L}\p{M}\p{N}_])"#
      let inicio = resultado.index(resultado.startIndex, offsetBy: min(desde, resultado.count))
      guard let rango = resultado.range(
        of: patron, options: [.regularExpression, .caseInsensitive], range: inicio..<resultado.endIndex
      ) else { continue }
      let antes = resultado.distance(from: resultado.startIndex, to: rango.lowerBound)
      resultado.replaceSubrange(rango, with: nuevo)
      desde = antes + nuevo.count
    }
    return resultado
  }
}
