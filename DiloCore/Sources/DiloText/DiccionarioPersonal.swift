import Foundation

/// Tus palabras: nombres, proyectos, siglas y términos técnicos que el motor
/// no conoce y escribe como suenan.
///
/// Se aplica de dos formas, y las dos hacen falta:
///
/// - **Como contexto del motor**, antes de reconocer. SpeechAnalyzer lo
///   acepta (`AnalysisContext.contextualStrings`), y así "Decameron" sale
///   bien de entrada en vez de salir "de camerún" y corregirse después.
/// - **Como post-corrección**, después. Porque el contexto es una ayuda, no
///   una garantía, y porque el motor que venga mañana puede no tenerlo.
///
/// La corrección es difusa a propósito: compara por distancia de edición y
/// por cómo suena, y prueba grupos de hasta tres palabras, porque el dictado
/// parte los nombres ("Charge B" por "ChargeBee", "Espacio Digital" en dos).
public enum DiccionarioPersonal {
  /// Las palabras tal como se le pasan al motor. Sin vacías y sin repetidas:
  /// una lista con basura adentro empeora el reconocimiento en vez de
  /// ayudarlo.
  public static func terminosParaElMotor(_ palabras: [String]) -> [String] {
    var vistas = Set<String>()
    return palabras.compactMap { palabra in
      let limpia = palabra.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !limpia.isEmpty, vistas.insert(limpia.lowercased()).inserted else {
        return nil
      }
      return limpia
    }
  }

  /// El umbral de fábrica. Más alto corrige más y se equivoca más; es el
  /// mismo número con que el Tauri llevaba meses andando.
  public static let umbralDeFabrica = 0.28

  public static func aplicar(
    _ texto: String, palabras: [String], umbral: Double = umbralDeFabrica
  ) -> String {
    let propias = terminosParaElMotor(palabras)
    guard !propias.isEmpty else { return texto }

    let llaves = propias.enumerated().flatMap { indice, palabra in
      llavesDeComparacion(palabra, indice: indice)
    }
    let tokens = texto.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    var resultado: [String] = []
    var i = 0

    while i < tokens.count {
      // Se prueban los grupos de una, dos y tres palabras y gana el que mejor
      // calza. Cuando dos calzan casi igual gana el **más corto**: comerse una
      // palabra de más es un error caro y silencioso —"de decamerón" se
      // convierte en "Decameron" y la frase pierde la preposición— mientras
      // que quedarse corto sólo deja el dictado como salió.
      var mejorN: Int?
      var mejorReemplazo: String?
      var mejorPuntaje = Double.greatestFiniteMagnitude

      for n in 1 ... 3 {
        guard i + n <= tokens.count else { break }
        let grupo = Array(tokens[i ..< (i + n)])
        guard n == 1 || !esPalabraDeFuncion(grupo[0]) else { continue }
        let candidato = grupo.map(llaveDe).joined()
        guard let (reemplazo, puntaje) = mejorCoincidencia(
          candidato, propias: propias, llaves: llaves, umbral: umbral
        ) else { continue }
        // El margen es lo que hace que "más corto" no sea "peor": un grupo
        // largo tiene que ganar por diferencia, no por decimales.
        if puntaje < mejorPuntaje - 0.05 || mejorN == nil {
          mejorPuntaje = puntaje
          mejorN = n
          mejorReemplazo = reemplazo
        }
      }

      if let n = mejorN, let reemplazo = mejorReemplazo {
        let grupo = Array(tokens[i ..< (i + n)])
        let (prefijo, _) = puntuacion(de: grupo[0])
        let (_, sufijo) = puntuacion(de: grupo[n - 1])
        let corregido = conservarMayusculas(de: grupo[0], en: reemplazo)
        resultado.append("\(prefijo)\(corregido)\(sufijo)")
        i += n
      } else {
        resultado.append(tokens[i])
        i += 1
      }
    }
    return resultado.joined(separator: " ")
  }

  struct Llave {
    let indice: Int
    let texto: String
  }

  /// La forma comparable de una palabra: sólo letras y números, en
  /// minúsculas y sin tildes. "Decamerón", "decameron" y "DECAMERON" son la
  /// misma cosa para comparar, y distintas para escribir.
  static func llaveDe(_ palabra: String) -> String {
    palabra
      .folding(options: .diacriticInsensitive, locale: nil)
      .lowercased()
      .filter { $0.isLetter || $0.isNumber }
  }

  static func llavesDeComparacion(_ palabra: String, indice: Int) -> [Llave] {
    var llaves: [Llave] = []
    let principal = llaveDe(palabra)
    if !principal.isEmpty { llaves.append(Llave(indice: indice, texto: principal)) }

    // "R&D" se dicta "R y D" acá y "R and D" en inglés: las dos formas tienen
    // que llegar a la misma palabra.
    if palabra.contains("&") {
      for union in [" y ", " and "] {
        let expandida = llaveDe(palabra.replacingOccurrences(of: "&", with: union))
        if !expandida.isEmpty, !llaves.contains(where: { $0.texto == expandida }) {
          llaves.append(Llave(indice: indice, texto: expandida))
        }
      }
    }
    return llaves
  }

  /// Las palabras con que el español pega las cosas. Un nombre propio no
  /// empieza en "de" ni en "la": si el grupo empieza por una de éstas, el
  /// nombre empieza en la siguiente, y juntarlas produce "Decameron" donde
  /// decías "de Decameron".
  static let palabrasDeFuncion: Set<String> = [
    "a", "al", "ante", "con", "contra", "de", "del", "desde", "el", "en",
    "entre", "es", "hacia", "hasta", "la", "las", "le", "les", "lo", "los",
    "mi", "no", "o", "para", "por", "que", "se", "si", "sin", "sobre", "su",
    "sus", "tras", "tu", "un", "una", "unos", "unas", "y", "ya",
  ]

  static func esPalabraDeFuncion(_ token: String) -> Bool {
    palabrasDeFuncion.contains(llaveDe(token))
  }

  static func mejorCoincidencia(
    _ candidato: String, propias: [String], llaves: [Llave], umbral: Double
  ) -> (String, Double)? {
    guard !candidato.isEmpty, candidato.count <= 50 else { return nil }

    var mejor: String?
    var mejorPuntaje = Double.greatestFiniteMagnitude

    for llave in llaves {
      // La primera letra tiene que calzar. Corregir cambiando el principio de
      // la palabra convierte cualquier cosa en cualquier cosa, y es lo que
      // hacía que "hace Charge B" terminara entero en "ChargeBee".
      guard candidato.first == llave.texto.first else { continue }
      // Largos muy distintos no se comparan: sin esto, un grupo de tres
      // palabras se "corrige" a una palabra corta que no tiene nada que ver.
      let diferencia = abs(Double(candidato.count - llave.texto.count))
      let mayor = Double(max(candidato.count, llave.texto.count))
      guard diferencia <= max(mayor * 0.25, 2) else { continue }

      let distancia = Double(levenshtein(candidato, llave.texto))
      let porLetras = mayor > 0 ? distancia / mayor : 1
      // Sonar parecido pesa mucho más que escribirse parecido: el dictado se
      // equivoca de oído, no de dedo.
      let puntaje = suenanIgual(candidato, llave.texto) ? porLetras * 0.3 : porLetras

      if puntaje < umbral, puntaje < mejorPuntaje {
        mejor = propias[llave.indice]
        mejorPuntaje = puntaje
      }
    }
    guard let mejor else { return nil }
    return (mejor, mejorPuntaje)
  }

  static func conservarMayusculas(de original: String, en reemplazo: String) -> String {
    let letras = original.filter(\.isLetter)
    if !letras.isEmpty, letras.allSatisfy(\.isUppercase) { return reemplazo.uppercased() }
    if let primera = original.first, primera.isUppercase {
      return reemplazo.prefix(1).uppercased() + reemplazo.dropFirst()
    }
    return reemplazo
  }

  /// Lo que envuelve a la palabra —comillas, paréntesis, la coma del final—
  /// se conserva tal cual. Corregir un nombre no es motivo para comerse la
  /// puntuación de alrededor.
  static func puntuacion(de palabra: String) -> (String, String) {
    let prefijo = palabra.prefix { !$0.isLetter && !$0.isNumber }
    let resto = palabra.dropFirst(prefijo.count)
    let sufijo = resto.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed()
    return (String(prefijo), String(sufijo))
  }

  static func levenshtein(_ a: String, _ b: String) -> Int {
    let x = Array(a), y = Array(b)
    if x.isEmpty { return y.count }
    if y.isEmpty { return x.count }
    var fila = Array(0 ... y.count)
    for i in 1 ... x.count {
      var anterior = fila[0]
      fila[0] = i
      for j in 1 ... y.count {
        let guardado = fila[j]
        fila[j] = x[i - 1] == y[j - 1]
          ? anterior
          : min(anterior, fila[j], fila[j - 1]) + 1
        anterior = guardado
      }
    }
    return fila[y.count]
  }

  /// Soundex: el mismo código fonético que usaba el Tauri. Es de oído inglés
  /// y eso se nota con las palabras en español, pero por eso nunca decide
  /// solo: sólo le baja el puntaje a una candidata que ya se parecía escrita.
  static func suenanIgual(_ a: String, _ b: String) -> Bool {
    let codigoA = soundex(a), codigoB = soundex(b)
    return !codigoA.isEmpty && codigoA == codigoB
  }

  static func soundex(_ palabra: String) -> String {
    let letras = Array(palabra.uppercased().filter(\.isLetter))
    guard let primera = letras.first else { return "" }

    func codigo(_ letra: Character) -> Character? {
      switch letra {
      case "B", "F", "P", "V": "1"
      case "C", "G", "J", "K", "Q", "S", "X", "Z": "2"
      case "D", "T": "3"
      case "L": "4"
      case "M", "N": "5"
      case "R": "6"
      default: nil
      }
    }

    var resultado = String(primera)
    var anterior = codigo(primera)
    for letra in letras.dropFirst() {
      let actual = codigo(letra)
      if let actual, actual != anterior { resultado.append(actual) }
      // H y W no cortan la repetición; una vocal sí.
      if letra != "H", letra != "W" { anterior = actual }
      if resultado.count == 4 { break }
    }
    return resultado.padding(toLength: 4, withPad: "0", startingAt: 0)
  }
}
