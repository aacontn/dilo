// Origen, una línea por pieza:
// - `jaroWinkler`: adaptado de Muesli CustomWordMatcher.swift:218-285
//   (3878028), © 2026 Pranav Hari, MIT. Cambios: nombres y premio por prefijo
//   sobre la clave fonética.
// - `sustituciones`: técnica de OpenWhispr correctionLearner.js (MIT) y
//   BetterWispr CorrectionLearner (Apache 2.0) —diff por palabras con la
//   subsecuencia común más larga, tramos de 1 a 3 palabras, más de la mitad
//   cambiada es reescritura—. La implementación es propia, sin su código.
// - `claveFonetica`, `CambioEnLoPegado`, los filtros de sentido y
//   `TusPalabrasAprendidas`: propios de Dilo.
import Foundation

/// Un par «oído → correcto» sacado de lo que la persona arregló a mano.
public struct ParDeCorreccion: Codable, Equatable, Hashable, Sendable {
  public var oido: String
  public var correcto: String

  public init(oido: String, correcto: String) {
    self.oido = oido
    self.correcto = correcto
  }
}

/// Qué palabras del dictado arregló la persona, y cuáles de esos arreglos
/// son vocabulario (un nombre, una marca, una sigla) y no una reescritura.
///
/// Es un valor puro: recibe lo pegado y lo que quedó en el campo, y contesta.
/// El diccionario de español entra como función para que esto se pruebe sin
/// AppKit (`NSSpellChecker` vive en la app).
public enum AprendizajeDeCorrecciones {
  /// Las más frecuentes del español escrito. Una corrección hacia una de
  /// éstas es gramática o estilo, nunca un nombre que el motor no conocía.
  static let palabrasComunes: Set<String> = [
    "a", "al", "algo", "asi", "bien", "como", "con", "cuando", "de", "del",
    "donde", "el", "ella", "en", "entre", "es", "esa", "ese", "eso", "esta",
    "este", "esto", "fue", "ha", "hay", "la", "las", "le", "les", "lo", "los",
    "mas", "me", "mi", "muy", "nada", "ni", "no", "nos", "o", "otro", "para",
    "pero", "por", "porque", "que", "se", "ser", "si", "sin", "sobre", "su",
    "sus", "tambien", "te", "todo", "tu", "un", "una", "uno", "y", "ya", "yo",
  ]

  /// Palabras que, si aparecen o desaparecen, cambian el sentido. Nunca se
  /// aprenden.
  static let negaciones: Set<String> = ["no", "nunca", "jamas", "tampoco", "ni", "nadie", "nada"]

  /// El parecido fonético mínimo, sobre la clave en español. Punto de
  /// partida (Muesli usa 0,64 sobre la escritura); se fija con pares reales.
  public static let parecidoMinimo = 0.72
  /// Lo más que se ofrece de un dictado. Más es una reescritura, no
  /// palabras que el motor no conocía.
  public static let maximoPorDictado = 3

  public static func pares(
    pegado original: String,
    editado: String,
    esPalabraConocida: (String) -> Bool = { _ in false }
  ) -> [ParDeCorreccion] {
    let antes = tokens(original)
    let despues = tokens(editado)
    guard !antes.isEmpty, !despues.isEmpty, antes != despues else { return [] }
    let cambios = sustituciones(antes, despues)
    // Cambiar más de la mitad es reescribir el mensaje, no corregir palabras.
    guard cambios.count <= max(1, antes.count / 2) else { return [] }
    var vistos = Set<String>()
    return cambios.filter { par in
      vistos.insert(llave(par.correcto)).inserted
        && esVocabulario(par, esPalabraConocida: esPalabraConocida)
    }
  }

  /// Sólo los errores del motor: lo «oído» tiene que estar, palabra por
  /// palabra, en lo que el motor escribió. Si no está, lo puso un modo o un
  /// reemplazo, y aprenderlo enseñaría al motor algo que nunca oyó.
  public static func soloDelMotor(_ pares: [ParDeCorreccion], crudo: String) -> [ParDeCorreccion] {
    let delMotor = tokens(crudo).map(llave)
    return pares.filter { par in
      let oido = tokens(par.oido).map(llave)
      guard !oido.isEmpty, oido.count <= delMotor.count else { return false }
      return (0 ... delMotor.count - oido.count).contains { Array(delMotor[$0 ..< $0 + oido.count]) == oido }
    }
  }

  static func esVocabulario(
    _ par: ParDeCorreccion,
    esPalabraConocida: (String) -> Bool
  ) -> Bool {
    let oido = llave(par.oido)
    let correcto = llave(par.correcto)
    guard par.correcto.contains(where: \.isLetter) else { return false }
    let tieneMayusculaInterior = par.correcto.dropFirst().contains(where: \.isUppercase)
    // Sólo tildes o mayúsculas: «esta» → «está» es ortografía y la arregla la
    // limpieza. Se salvan la marca con mayúscula adentro («posthog» →
    // «PostHog») y el nombre propio que el diccionario no conoce
    // («decamerón» → «Decameron»).
    if oido == correcto {
      let nombrePropio = par.correcto.first?.isUppercase == true
        && par.oido.first?.isLowercase == true && !esPalabraConocida(par.correcto)
      return tieneMayusculaInterior || nombrePropio
    }
    if par.correcto.count < 3, !par.correcto.contains(where: \.isUppercase) { return false }
    if palabrasComunes.contains(correcto) { return false }
    if cambiaElSentido(oido: oido, correcto: correcto) { return false }
    // Dos palabras que el diccionario conoce son un cambio de idea («lunes»
    // → «martes»), no un nombre mal oído. La marca con mayúscula interior
    // pasa.
    let sinEspacios = !par.correcto.contains(" ")
    if sinEspacios, !tieneMayusculaInterior,
      esPalabraConocida(par.oido), esPalabraConocida(par.correcto) {
      return false
    }
    return jaroWinkler(claveFonetica(oido), claveFonetica(correcto)) >= parecidoMinimo
  }

  /// Un número o una negación que aparece o desaparece cambia lo que se
  /// dijo.
  static func cambiaElSentido(oido: String, correcto: String) -> Bool {
    let cifrasOido = oido.filter(\.isNumber)
    let cifrasCorrecto = correcto.filter(\.isNumber)
    if cifrasOido != cifrasCorrecto { return true }
    let palabrasOido = Set(oido.split(separator: " ").map(String.init))
    let palabrasCorrecto = Set(correcto.split(separator: " ").map(String.init))
    return palabrasOido.intersection(negaciones) != palabrasCorrecto.intersection(negaciones)
  }

  /// Minúsculas, sin tildes, espacios simples.
  static func llave(_ texto: String) -> String {
    texto.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
      .split(separator: " ").joined(separator: " ")
  }

  /// Las palabras, sin la puntuación pegada a los bordes.
  static func tokens(_ texto: String) -> [String] {
    let bordes = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted
    return texto.split(whereSeparator: \.isWhitespace)
      .map { $0.trimmingCharacters(in: bordes) }
      .filter { !$0.isEmpty }
  }

  /// Diff por palabras con la subsecuencia común más larga. Cada tramo
  /// distinto de 1 a 3 palabras por lado es un candidato; uno más largo es
  /// una frase reescrita y no cuenta.
  ///
  /// La tabla se llena por prefijos y se recorre desde el final: cada vez que
  /// las dos palabras coinciden se cierra el tramo que se venía juntando.
  static func sustituciones(_ antes: [String], _ despues: [String]) -> [ParDeCorreccion] {
    // `largo[i][j]`: lo más que coinciden `antes[..<i]` y `despues[..<j]`.
    var largo = Array(repeating: Array(repeating: 0, count: despues.count + 1), count: antes.count + 1)
    for i in antes.indices {
      for j in despues.indices {
        largo[i + 1][j + 1] = antes[i] == despues[j]
          ? largo[i][j] + 1 : max(largo[i][j + 1], largo[i + 1][j])
      }
    }
    var tramos: [ParDeCorreccion] = []
    var sacadas: [String] = []
    var puestas: [String] = []
    func cerrar() {
      if (1 ... 3).contains(sacadas.count), (1 ... 3).contains(puestas.count) {
        tramos.append(ParDeCorreccion(
          oido: sacadas.reversed().joined(separator: " "),
          correcto: puestas.reversed().joined(separator: " ")
        ))
      }
      sacadas = []
      puestas = []
    }
    var i = antes.count, j = despues.count
    while i > 0 || j > 0 {
      if i > 0, j > 0, antes[i - 1] == despues[j - 1] {
        cerrar()
        i -= 1
        j -= 1
      } else if j > 0, i == 0 || largo[i][j - 1] >= largo[i - 1][j] {
        puestas.append(despues[j - 1])
        j -= 1
      } else {
        sacadas.append(antes[i - 1])
        i -= 1
      }
    }
    cerrar()
    return tramos.reversed()
  }

  /// Cómo suena una palabra en español, con una letra por sonido. El
  /// Soundex de `DiccionarioPersonal` es de oído inglés: «cuba netes» y
  /// «Kubernetes» le suenan distinto; con esta clave, casi igual.
  static func claveFonetica(_ texto: String) -> String {
    let letras = Array(llave(texto).filter(\.isLetter))
    var clave: [Character] = []
    var i = 0
    while i < letras.count {
      let actual = letras[i]
      let siguiente: Character? = i + 1 < letras.count ? letras[i + 1] : nil
      var sonido: Character? = actual
      switch actual {
      case "h": sonido = nil
      case "v": sonido = "b"
      case "w": sonido = "u"
      case "z": sonido = "s"
      case "q":
        sonido = "k"
        if siguiente == "u" { i += 1 }
      case "c":
        if siguiente == "h" {
          sonido = "x"
          i += 1
        } else if siguiente == "e" || siguiente == "i" {
          sonido = "s"
        } else {
          sonido = "k"
        }
      case "g":
        if siguiente == "e" || siguiente == "i" { sonido = "j" }
      case "l":
        if siguiente == "l" {
          sonido = "y"
          i += 1
        }
      default: break
      }
      if let sonido, clave.last != sonido { clave.append(sonido) }
      i += 1
    }
    return String(clave)
  }

  /// Jaro-Winkler entre 0 y 1, con el premio por prefijo común de hasta 4.
  static func jaroWinkler(_ a: String, _ b: String) -> Double {
    let x = Array(a), y = Array(b)
    if x.isEmpty || y.isEmpty { return x.isEmpty && y.isEmpty ? 1 : 0 }
    if x == y { return 1 }
    let ventana = max(0, max(x.count, y.count) / 2 - 1)
    var usadasX = [Bool](repeating: false, count: x.count)
    var usadasY = [Bool](repeating: false, count: y.count)
    var coincidencias = 0.0
    for i in x.indices {
      let desde = max(0, i - ventana), hasta = min(y.count - 1, i + ventana)
      guard desde <= hasta else { continue }
      for j in desde ... hasta where !usadasY[j] && x[i] == y[j] {
        usadasX[i] = true
        usadasY[j] = true
        coincidencias += 1
        break
      }
    }
    guard coincidencias > 0 else { return 0 }
    var k = 0, cruces = 0.0
    for i in x.indices where usadasX[i] {
      while !usadasY[k] { k += 1 }
      if x[i] != y[k] { cruces += 1 }
      k += 1
    }
    let jaro = (coincidencias / Double(x.count) + coincidencias / Double(y.count)
      + (coincidencias - cruces / 2) / coincidencias) / 3
    let prefijo = zip(x.prefix(4), y.prefix(4)).prefix { $0 == $1 }.count
    return jaro + Double(prefijo) * 0.1 * (1 - jaro)
  }
}

/// Qué quedó de lo pegado después de que la persona lo editó, o nil si el
/// cambio cayó fuera o lo desborda (entonces no se sabe qué corrigió).
///
/// Prefijo y sufijo comunes entre el campo de antes y el de ahora acotan el
/// tramo que cambió; si ese tramo cae dentro de lo pegado, lo pegado editado
/// es el mismo rango corrido por lo que creció o se achicó.
public enum CambioEnLoPegado {
  public static func editado(base: String, pegado: String, actual: String) -> String? {
    let base = normalizar(base), pegado = normalizar(pegado), actual = normalizar(actual)
    guard base != actual, !pegado.isEmpty,
      let rango = base.range(of: pegado, options: .backwards)
    else { return nil }
    let antes = Array(base), ahora = Array(actual)
    let inicio = base.distance(from: base.startIndex, to: rango.lowerBound)
    let fin = base.distance(from: base.startIndex, to: rango.upperBound)
    var prefijo = 0
    while prefijo < min(antes.count, ahora.count), antes[prefijo] == ahora[prefijo] {
      prefijo += 1
    }
    var sufijo = 0
    while sufijo < min(antes.count, ahora.count) - prefijo,
      antes[antes.count - 1 - sufijo] == ahora[ahora.count - 1 - sufijo] {
      sufijo += 1
    }
    // El tramo que cambió tiene que vivir dentro de lo pegado. Si empieza
    // antes o termina después, la persona editó otra cosa a la vez.
    guard prefijo >= inicio, antes.count - sufijo <= fin else { return nil }
    let finAhora = fin + (ahora.count - antes.count)
    guard finAhora >= inicio, finAhora <= ahora.count else { return nil }
    return String(ahora[inicio ..< finAhora]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Las apps devuelven el mismo texto con finales de línea y espacios
  /// distintos de los que pegamos; sin esto, todo parece editado.
  static func normalizar(_ texto: String) -> String {
    texto.precomposedStringWithCanonicalMapping
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\u{00A0}", with: " ")
      .replacingOccurrences(of: "\u{200B}", with: "")
      .replacingOccurrences(of: "\u{FEFF}", with: "")
  }
}

/// Lo que una sugerencia aceptada agregó a Tus palabras: exactamente lo que
/// «Deshacer» quita.
public struct LoAprendido: Equatable, Sendable {
  /// Términos que no estaban en Tus palabras.
  public var palabrasNuevas: [String] = []
  /// «Cuando digo… / Escríbelo así» que se agregaron.
  public var reemplazosNuevos: [Reemplazo] = []
  /// Los que había para la misma frase y se reemplazaron: vuelven al
  /// deshacer.
  public var reemplazosPisados: [Reemplazo] = []

  public init() {}

  public var estaVacio: Bool { palabrasNuevas.isEmpty && reemplazosNuevos.isEmpty }
}

/// Aprender un par es lo mismo que la persona haría a mano en Ajustes →
/// Palabras: el término va a **Tus palabras** (contexto del motor y
/// corrección por parecido) y lo oído a **Cuando digo…** (`Reemplazo`, que
/// gana aunque no se parezca). No hay una lista nueva ni una clave nueva:
/// todo lo aprendido se ve, se edita y se borra donde ya se veía.
public enum TusPalabrasAprendidas {
  /// Lo más que se aprende solo. Más que esto es ruido que nadie revisó.
  public static let tope = 200

  /// - Parameter soloTusPalabras: los que el revisor dijo que son un
  ///   término que Tus palabras arregla solo (`RevisionDeCorrecciones`): no
  ///   llevan regla en «Cuando digo…».
  public static func aprender(
    _ pares: [ParDeCorreccion], soloTusPalabras: Set<ParDeCorreccion> = [],
    palabras: inout [String], reemplazos: inout [Reemplazo]
  ) -> LoAprendido {
    var hecho = LoAprendido()
    for par in pares {
      let correcto = par.correcto.trimmingCharacters(in: .whitespacesAndNewlines)
      let oido = par.oido.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !correcto.isEmpty, !oido.isEmpty else { continue }
      if !palabras.contains(where: { $0.caseInsensitiveCompare(correcto) == .orderedSame }) {
        palabras.append(correcto)
        hecho.palabrasNuevas.append(correcto)
      }
      // Lo que se oyó escrito tal cual ya es lo correcto: basta Tus palabras.
      guard oido != correcto, !soloTusPalabras.contains(par) else { continue }
      let llave = Reemplazos.plegar(oido)
      if let i = reemplazos.firstIndex(where: { Reemplazos.plegar($0.dice) == llave }) {
        guard reemplazos[i].escribe != correcto else { continue }
        hecho.reemplazosPisados.append(reemplazos[i])
        reemplazos.remove(at: i)
      } else if reemplazos.filter(\.aprendido).count >= tope {
        continue
      }
      let nuevo = Reemplazo(dice: oido, escribe: correcto, aprendido: true)
      reemplazos.append(nuevo)
      hecho.reemplazosNuevos.append(nuevo)
    }
    return hecho
  }

  /// Si ya está en Tus palabras tal cual: ofrecerlo sería ruido.
  public static func yaSeSabe(
    _ par: ParDeCorreccion, palabras: [String], reemplazos: [Reemplazo]
  ) -> Bool {
    if par.oido == par.correcto {
      return palabras.contains { $0.caseInsensitiveCompare(par.correcto) == .orderedSame }
    }
    return reemplazos.contains {
      Reemplazos.plegar($0.dice) == Reemplazos.plegar(par.oido) && $0.escribe == par.correcto
    }
  }

  public static func deshacer(
    _ hecho: LoAprendido, palabras: inout [String], reemplazos: inout [Reemplazo]
  ) {
    palabras.removeAll { hecho.palabrasNuevas.contains($0) }
    reemplazos.removeAll { hecho.reemplazosNuevos.contains($0) }
    reemplazos.append(contentsOf: hecho.reemplazosPisados)
  }
}
