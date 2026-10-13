import Foundation

/// Lo que sale de un motor que se quedó pegado: puntuación sin palabras, la
/// misma letra mil veces, la misma frase dando vueltas.
///
/// `Muletillas` ya colapsa la palabra suelta repetida tres veces («no no
/// no»), que es habla. Esto atrapa lo que ningún humano dicta.
public enum DetectorDeBucles {
  public enum Motivo: Sendable, Equatable {
    /// Menos de la mitad son letras o números: «...!!!...».
    case puntuacion
    /// Tres caracteres distintos o menos en todo el texto: «aaaaaaaaaaaa».
    case repeticionDeCaracteres
    /// La mayoría del texto es una frase que se repite.
    case repeticionDePalabras
  }

  // Regla de caracteres: técnica observada en Ocelli (Ghidra, FUN_10010ca38: con 12
  // caracteres sin blancos o más, basura si menos del 50 % son alfanuméricos o si
  // hay 3 distintos o menos). Implementación propia.
  /// Desde cuántos caracteres sin blancos se mira la forma del texto. Ocelli.
  public static let caracteresMinimos = 12
  /// La fracción de letras y números bajo la cual el texto es puntuación. Ocelli.
  public static let fraccionAlfanumericaMinima = 0.5
  /// Cuántos caracteres distintos tiene, como mucho, un texto pegado. Ocelli.
  public static let caracteresDistintosMaximos = 3

  // Los n-gramas de palabras son propios: Ocelli no los tiene.
  /// Cuántas vueltas seguidas de la misma frase cuentan como bucle. Tres son
  /// habla («sí, sí, sí»); cuatro ya no.
  public static let vueltasMinimas = 4
  /// El largo máximo, en palabras, de la frase que da vueltas.
  public static let palabrasMaximasPorVuelta = 4
  /// Desde cuántas palabras se juzga el texto entero, y qué fracción tiene que
  /// irse en vueltas para que sea un bucle y no una frase con una repetición.
  public static let palabrasMinimas = 8
  public static let fraccionRepetidaMaxima = 0.6

  /// Por qué el texto entero es basura, o nil si no lo es.
  public static func motivo(_ texto: String) -> Motivo? {
    let sinBlancos = texto.filter { !$0.isWhitespace }
    if sinBlancos.count >= caracteresMinimos {
      let alfanumericos = sinBlancos.filter { $0.isLetter || $0.isNumber }.count
      if Double(alfanumericos) / Double(sinBlancos.count) < fraccionAlfanumericaMinima {
        return .puntuacion
      }
      if Set(sinBlancos.lowercased()).count <= caracteresDistintosMaximos {
        return .repeticionDeCaracteres
      }
    }
    let total = FrasesFantasma.normalizar(texto).count
    guard total >= palabrasMinimas else { return nil }
    let (_, quitadas) = colapsar(texto)
    return Double(quitadas) / Double(total) >= fraccionRepetidaMaxima ? .repeticionDePalabras : nil
  }

  /// Una frase de una a cuatro palabras que da cuatro vueltas o más seguidas
  /// queda en una sola. Devuelve el texto y cuántas palabras se fueron.
  ///
  /// Compara las palabras normalizadas —sin tildes, mayúsculas ni
  /// puntuación— y conserva la primera vuelta tal como vino: «Te lo mando, te
  /// lo mando, te lo mando, te lo mando.» queda en «Te lo mando,».
  public static func colapsar(_ texto: String) -> (String, Int) {
    var palabras = texto.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    var claves = palabras.map { FrasesFantasma.normalizar($0).joined() }
    var quitadas = 0
    for largo in stride(from: palabrasMaximasPorVuelta, through: 1, by: -1) {
      var i = 0
      while i + largo * vueltasMinimas <= palabras.count {
        let patron = Array(claves[i..<i + largo])
        // Una vuelta de puras llaves vacías es puntuación suelta, no una frase.
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
          quitadas += largo * (vueltas - 1)
        }
        i += 1
      }
    }
    return (quitadas == 0 ? texto : palabras.joined(separator: " "), quitadas)
  }
}
