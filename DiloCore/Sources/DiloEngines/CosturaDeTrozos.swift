import DiloText
import Foundation

/// Un token del motor, visto desde acá: el pedazo de texto que emitió y
/// cuándo sonó.
///
/// Es un tipo propio y no el de FluidAudio para poder probar la costura con
/// `swift test`, sin modelo, sin Core ML y sin 469 MB en disco.
public struct TokenDeVoz: Sendable, Equatable {
  /// El texto tal cual, **con su espacio adelante si abre palabra**. Es la
  /// marca de SentencePiece ya traducida: un token que continúa la palabra
  /// anterior llega sin espacio.
  public let texto: String
  public let inicio: TimeInterval
  public let fin: TimeInterval

  public init(texto: String, inicio: TimeInterval, fin: TimeInterval) {
    self.texto = texto
    self.inicio = inicio
    self.fin = fin
  }
}

/// **Dónde se rompe el texto que devuelve Parakeet, y por qué.**
///
/// Parakeet no transcribe el buffer de una: lo parte en ventanas y después
/// cose los tokens de todas. En esa costura, cada cierto trecho, el primer
/// token de la ventana siguiente llega **sin** la marca de palabra nueva, y
/// las dos palabras salen pegadas: «Igual se ve que es rápidoAhora habría que
/// ver qué tan». El motor además escribe con mayúscula el comienzo de cada
/// ventana, así que lo pegado se lee como dos frases sin separar.
///
/// El texto ya armado no dice dónde estuvo la costura, pero los tiempos de
/// cada token sí: dentro de una palabra los tokens van seguidos —fracciones
/// de una décima— y en una costura hay silencio de por medio. Sobre esa
/// evidencia se corta, y sólo sobre ella.
///
/// **Tres condiciones a la vez, y son a propósito conservadoras.** Se corta
/// cuando el token continúa la palabra anterior, empieza con mayúscula y
/// entre los dos pasó más de `silencioMinimo`. Con menos de eso no se toca
/// nada: "iPhone" y "macOS" salen del modelo con sus tokens pegados en el
/// tiempo y se quedan enteros. Ante la duda, la palabra se queda como vino —
/// la misma regla que el resto del español de Dilo.
public enum CosturaDeTrozos {
  /// Cuánto silencio delata una costura. Una ventana del encoder dura unos
  /// 80 ms, así que dos décimas son más que cualquier hueco dentro de una
  /// palabra dicha de corrido.
  public static let silencioMinimo: TimeInterval = 0.2

  /// El texto del motor, con los espacios que la costura se comió.
  public static func texto(de tokens: [TokenDeVoz]) -> String {
    Union.unir(segmentos(de: tokens))
  }

  /// Los trozos en que se parte lo que entregó el motor. Sin costuras a la
  /// vista es uno solo.
  static func segmentos(de tokens: [TokenDeVoz]) -> [String] {
    var segmentos: [String] = []
    var actual = ""
    var finAnterior: TimeInterval?

    for token in tokens {
      if let finAnterior, rompeAca(token, finAnterior: finAnterior), !actual.isEmpty {
        segmentos.append(actual)
        actual = ""
      }
      actual += token.texto
      finAnterior = token.fin
    }
    if !actual.isEmpty { segmentos.append(actual) }
    return segmentos
  }

  private static func rompeAca(_ token: TokenDeVoz, finAnterior: TimeInterval) -> Bool {
    guard let primera = token.texto.first else { return false }
    // Con espacio adelante el motor ya dijo que es palabra nueva: no hay nada
    // que arreglar.
    guard !primera.isWhitespace else { return false }
    guard primera.isUppercase else { return false }
    return token.inicio - finAnterior >= silencioMinimo
  }
}
