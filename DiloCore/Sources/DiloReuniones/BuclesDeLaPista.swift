import Foundation

/// Lo que Parakeet escribe cuando se queda pegado sobre una pista larga: la
/// misma sílaba o la misma frase corta, vuelta tras vuelta. En la reunión del
/// 2026-11-02 la pista `ellos` traía «pa» 21 veces seguidas.
///
/// Es la regla de `DetectorDeBucles.colapsar` del dictado, pero sobre las
/// palabras con tiempo de una pista: una frase de una a cuatro palabras que
/// da cuatro vueltas o más seguidas queda en su primera vuelta. Tres vueltas
/// son habla («no, no, no»); cuatro ya casi nunca.
public enum BuclesDeLaPista {
  public static let vueltasMinimas = 4
  public static let palabrasMaximasPorVuelta = 4

  public static func colapsar(_ palabras: [PalabraDeLaPista]) -> [PalabraDeLaPista] {
    var palabras = palabras
    var claves = palabras.map { clave($0.texto) }
    for largo in stride(from: palabrasMaximasPorVuelta, through: 1, by: -1) {
      var i = 0
      while i + largo * vueltasMinimas <= palabras.count {
        let patron = Array(claves[i..<i + largo])
        guard patron.contains(where: { !$0.isEmpty }) else {
          i += 1
          continue
        }
        var vueltas = 1
        while i + largo * (vueltas + 1) <= palabras.count,
          Array(claves[(i + largo * vueltas)..<(i + largo * (vueltas + 1))]) == patron
        {
          vueltas += 1
        }
        if vueltas >= vueltasMinimas {
          palabras.removeSubrange((i + largo)..<(i + largo * vueltas))
          claves.removeSubrange((i + largo)..<(i + largo * vueltas))
        }
        i += 1
      }
    }
    return palabras
  }

  /// La palabra sin mayúsculas, tildes ni puntuación: «Pa,» y «pa» son la
  /// misma vuelta.
  static func clave(_ texto: String) -> String {
    texto.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es"))
      .filter { $0.isLetter || $0.isNumber }
  }
}
