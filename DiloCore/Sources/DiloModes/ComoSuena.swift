import Foundation

/// Cómo suena una palabra ya plegada, para comparar nombres.
///
/// El **Motor de voz** escribe lo que oye, y un nombre que la persona inventa
/// se puede escribir de varias formas que suenan igual: quien guardó «Kami» y
/// dice su nombre recibe «Cami». En español esas formas son pocas y conocidas:
/// c, k y q; s y z; b y v; ll e y; la h muda y las letras dobles. Lo demás se
/// deja como está: cada regla de más es un nombre más que se confunde con otro.
public enum ComoSuena {
  /// `plegada` viene sin tildes ni mayúsculas (`SenalesDelTurno.plegar`).
  public static func clave(_ plegada: String) -> String {
    let letras = Array(plegada)
    let esVocal: (Character?) -> Bool = { $0.map("aeiou".contains) ?? false }
    var clave = ""
    var i = 0
    while i < letras.count {
      let letra = letras[i]
      let siguiente = i + 1 < letras.count ? letras[i + 1] : nil
      switch letra {
      case "c" where siguiente == "h":
        clave += "ch"
        i += 1
      case "c":
        clave.append(siguiente == "e" || siguiente == "i" ? "s" : "k")
      case "q":
        clave.append("k")
        if siguiente == "u", i + 2 < letras.count, "ei".contains(letras[i + 2]) { i += 1 }
      case "z":
        clave.append("s")
      case "v":
        clave.append("b")
      case "h":
        break
      case "l" where siguiente == "l":
        clave.append("y")
        i += 1
      case "y":
        clave.append(esVocal(siguiente) ? "y" : "i")
      default:
        clave.append(letra)
      }
      i += 1
    }
    return clave.reduce(into: "") { unica, letra in
      if unica.last != letra { unica.append(letra) }
    }
  }
}
