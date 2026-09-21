import Foundation

/// Las muletillas del español, fuera; el resto del español, intacto.
///
/// Las reglas vienen del Tauri (`audio_toolkit/text.rs`) y se reescriben acá
/// con los mismos casos, más los que el español de Chile necesita. La regla
/// de fondo no cambió y es la que hace difícil esto:
///
/// **Una muletilla que además es una palabra no se borra sin mirar el
/// contexto.** "Abre este archivo" no lleva muletilla; "este, abre el
/// archivo" sí, y es la misma palabra. Por eso hay dos listas: los sonidos de
/// duda, que no son palabras de nada y se borran donde aparezcan, y las
/// contextuales, que sólo se borran cuando vienen puntuadas como lo que son:
/// una pausa.
///
/// El voseo y los modismos se quedan enteros. "Cachái" se borra sólo como
/// coletilla —"dale, cachái"— nunca como verbo: "¿cachái lo que digo?" es una
/// pregunta, no ruido. "Po", "altiro", "bacán" y compañía no se tocan: son
/// como se habla acá, no un defecto del dictado.
public enum Muletillas {
  /// Sonidos de duda que no son palabra de nada en español. Se borran donde
  /// aparezcan. Nunca "um" ni "ha": el primero es portugués y el segundo es
  /// el verbo haber.
  public static let sonidosDeDuda: [String] = [
    "eh", "ehh", "ehhh", "ehm", "em", "emm", "eem", "mmm", "mm", "hmm", "hm",
  ]

  /// Muletillas que también son palabras legítimas. Sólo salen cuando están
  /// puntuadas como pausa: seguidas de coma, de puntos suspensivos, o solas
  /// al final de una frase.
  ///
  /// "Esto" no está y no va a estar: es pronombre mucho más seguido que
  /// muletilla, y borrarlo de "esto, la verdad, no sirve" deja una frase sin
  /// sujeto. Ante la duda, la palabra se queda.
  public static let contextuales: [String] = [
    "este", "o sea", "osea", "digamos", "a ver", "ya sabes",
    "cachái", "cachai", "cachay", "me entendís", "me entendí",
  ]

  /// Limpia el texto dictado.
  ///
  /// - Parameter propias: la lista de la persona. `nil` usa las de fábrica;
  ///   una lista vacía apaga la limpieza entera, que es la forma de decir
  ///   "no me toques nada".
  public static func limpiar(_ texto: String, propias: [String]? = nil) -> String {
    var resultado = texto

    if let propias {
      for palabra in propias where !palabra.isEmpty {
        resultado = borrarDondeSea(palabra, en: resultado)
      }
    } else {
      for sonido in sonidosDeDuda {
        resultado = borrarDondeSea(sonido, en: resultado)
      }
      for muletilla in contextuales {
        resultado = borrarCuandoEsPausa(muletilla, en: resultado)
      }
    }

    resultado = colapsarTartamudeos(resultado)
    return arreglarEspaciosYPuntuacion(resultado)
  }

  /// Borra la palabra donde aparezca, con la coma o el punto que la siga.
  /// Es lo que se puede hacer con un sonido que no significa nada.
  ///
  /// Salvo detrás de un número: "cinco mm" es una medida, no una duda.
  static func borrarDondeSea(_ palabra: String, en texto: String) -> String {
    reemplazar(
      "(?<![0-9] )\\b\(NSRegularExpression.escapedPattern(for: palabra))\\b[,.]?",
      en: texto
    )
  }

  /// Borra la muletilla sólo cuando está puntuada como pausa. Tres formas:
  /// seguida de coma o de suspensivos, encerrada entre comas al final, o
  /// suelta entre signos de pregunta ("¿cachái?").
  static func borrarCuandoEsPausa(_ muletilla: String, en texto: String) -> String {
    let m = NSRegularExpression.escapedPattern(for: muletilla)
    var resultado = texto
    // "o sea, necesito" → "necesito"
    resultado = reemplazar("\\b\(m)\\s*,\\s*", en: resultado)
    // "este... abre" → "abre"
    resultado = reemplazar("\\b\(m)\\s*(?:\\.\\.\\.|…)\\s*", en: resultado)
    // "dale, cachái." → "dale."
    resultado = reemplazar(",\\s*\(m)\\s*(?=[.!?]|$)", en: resultado)
    // "dale ¿cachái?" → "dale"
    resultado = reemplazar("¿?\\s*\\b\(m)\\b\\s*\\?", en: resultado)
    return resultado
  }

  private static func reemplazar(_ patron: String, en texto: String) -> String {
    guard let regex = try? NSRegularExpression(
      pattern: patron, options: [.caseInsensitive]
    ) else { return texto }
    return regex.stringByReplacingMatches(
      in: texto,
      range: NSRange(texto.startIndex ..< texto.endIndex, in: texto),
      withTemplate: ""
    )
  }

  /// Tres repeticiones seguidas o más se quedan en una: "el el el deploy" es
  /// el motor tropezando, no alguien insistiendo. Dos se respetan, porque
  /// "no no" es una frase.
  static func colapsarTartamudeos(_ texto: String) -> String {
    let palabras = texto.split(separator: " ", omittingEmptySubsequences: true)
    guard !palabras.isEmpty else { return texto }

    var resultado: [Substring] = []
    var i = 0
    while i < palabras.count {
      let palabra = palabras[i]
      guard palabra.allSatisfy(\.isLetter) else {
        resultado.append(palabra)
        i += 1
        continue
      }
      let minuscula = palabra.lowercased()
      var repeticiones = 1
      while i + repeticiones < palabras.count,
        palabras[i + repeticiones].lowercased() == minuscula {
        repeticiones += 1
      }
      resultado.append(palabra)
      i += repeticiones >= 3 ? repeticiones : 1
    }
    return resultado.joined(separator: " ")
  }

  /// Junta los espacios que dejó cada borrado y pega la puntuación que quedó
  /// colgando. Los saltos de línea se respetan: dictar código y dictar un
  /// correo comparten esta función, y ahí un salto es contenido.
  static func arreglarEspaciosYPuntuacion(_ texto: String) -> String {
    var resultado = texto
    resultado = reemplazarPor("[ \\t]{2,}", " ", en: resultado)
    resultado = reemplazarPor("\\s+([,.;:!?])", "$1", en: resultado)
    resultado = reemplazarPor("([¿¡]) +", "$1", en: resultado)
    // Una coma que se quedó sin lo que separaba: "ya, dale, ya" sin "ya" no
    // termina en "dale,".
    resultado = reemplazarPor("([,;:])\\s*(?=[,;:])", "", en: resultado)
    resultado = reemplazarPor("[ ,;:]+$", "", en: resultado)
    resultado = reemplazarPor("^[ ,;:]+", "", en: resultado)
    return resultado.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func reemplazarPor(
    _ patron: String, _ plantilla: String, en texto: String
  ) -> String {
    guard let regex = try? NSRegularExpression(pattern: patron) else { return texto }
    return regex.stringByReplacingMatches(
      in: texto,
      range: NSRange(texto.startIndex ..< texto.endIndex, in: texto),
      withTemplate: plantilla
    )
  }
}
