import Foundation

// Idea de Tinycast («Adapt capitalization», AGPL-3: sin código). Propio de Dilo.

/// El dictado se adapta a lo que ya hay antes del cursor: a mitad de frase
/// entra con minúscula y con un espacio; después de un punto o al comienzo
/// del campo, con mayúscula.
///
/// Puro: recibe los últimos caracteres antes del cursor, leídos al **empezar**
/// el dictado, o nil si no se pudieron leer (sandbox, app sin Accesibilidad,
/// un editor web sin rango, o la lectura no llegó a tiempo), y entonces no
/// toca nada. Si una palabra es común o un nombre lo decide quien llama
/// (`esPalabraComun`; en la app, el corrector en español): «Quedó» baja a
/// «quedó», «Martina» se queda.
public enum AjusteAlCursor {
  /// Cuántos caracteres antes del cursor hacen falta para decidir.
  public static let caracteresQueMira = 3

  static let aperturas: Set<Character> = ["¿", "¡", "(", "[", "«", "“", "\"", "'", "/", "@", "#"]

  public static func ajustar(
    _ texto: String,
    antesDelCursor previo: String?,
    tusPalabras: Set<String> = [],
    esPalabraComun: (String) -> Bool
  ) -> String {
    guard let previo, !texto.isEmpty else { return texto }
    var ajustado = texto
    let ultimo = previo.last
    // Sin nada antes, o tras un fin de frase: mayúscula. Los espacios entre
    // el punto y el cursor no cambian eso.
    let finDeFrase = previo.trimmingCharacters(in: .whitespaces).last.map { ".!?…\n".contains($0) } ?? true

    if finDeFrase {
      ajustado = conPrimeraLetra(ajustado, mayuscula: true)
    } else if let primera = primeraPalabra(ajustado), !protegida(primera, tusPalabras: tusPalabras),
      esPalabraComun(primera.lowercased())
    {
      // A mitad de frase: «quedó listo» y no «Quedó listo». Se respetan
      // «API», «iPhone», lo que esté en Tus palabras y lo que no sea una
      // palabra común: «Martina» no es «martina».
      ajustado = conPrimeraLetra(ajustado, mayuscula: false)
    }

    // El espacio: hace falta si lo anterior es una palabra o un signo que
    // cierra, y no si el dictado empieza con puntuación.
    if let ultimo, !ultimo.isWhitespace, !aperturas.contains(ultimo),
      let primera = ajustado.first, !",.;:!?)]»”…".contains(primera)
    {
      ajustado = " " + ajustado
    }
    // Y si ya hay un espacio antes del cursor, el dictado no trae otro.
    if let ultimo, ultimo.isWhitespace {
      ajustado = String(ajustado.drop { $0 == " " })
    }
    return ajustado
  }

  static func primeraPalabra(_ texto: String) -> String? {
    texto.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map(String.init)
  }

  /// Una sigla o una marca con mayúsculas por dentro, o algo de Tus palabras.
  static func protegida(_ palabra: String, tusPalabras: Set<String>) -> Bool {
    (palabra.count > 1 && palabra.dropFirst().contains(where: \.isUppercase))
      || tusPalabras.contains(palabra)
  }

  static func conPrimeraLetra(_ texto: String, mayuscula: Bool) -> String {
    guard let indice = texto.firstIndex(where: \.isLetter) else { return texto }
    let letra = mayuscula ? texto[indice].uppercased() : texto[indice].lowercased()
    return texto.replacingCharacters(in: indice...indice, with: letra)
  }
}
