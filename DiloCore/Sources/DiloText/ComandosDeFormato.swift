import Foundation

// Idea (sin código) de BetterWispr y Scribe: separar los comandos que se
// aplican siempre de los que sólo valen en su lugar, y «borra eso» hasta la
// frase anterior. El escape «literal» es idea de FluidVoice (GPL, sin
// código). Las listas, las reglas y el código son de Dilo, para el español.

/// Lo que se dice para puntuar o editar, convertido en signos.
///
/// Corre en la capa de reglas, sin modelo y antes de cualquier modo: así el
/// dictado sin modo también sabe hacer un salto de línea, y el modelo de
/// texto recibe los signos ya puestos en vez de adivinarlos.
///
/// La dificultad es que «punto» y «coma» también son palabras. Lo
/// inequívoco («nueva línea», «signo de interrogación») vale siempre; lo
/// demás sólo en su lugar: «punto» al final o antes de un salto, nunca
/// después de un artículo o una preposición («llegamos al punto», «a las
/// cinco en punto»); «coma» salvo como verbo o sustantivo («que coma»,
/// «estuvo en coma»). Ante la duda, la palabra se queda.
public enum ComandosDeFormato {
  enum Accion: Equatable {
    /// Se pega a la palabra de la izquierda: . , ; : ? ! … ) ”
    case cierra(String)
    /// Se pega a la palabra de la derecha: ¿ ¡ ( “
    case abre(String)
    case salto(String)
    case puntoAparte
    case borraLaFrase
    case borraTodo
  }

  /// Nadie dice «nueva línea» queriendo escribirlo; para eso está «literal».
  static let siempre: [(frase: [String], accion: Accion)] = [
    (["nueva", "linea"], .salto("\n")),
    (["salto", "de", "linea"], .salto("\n")),
    (["nuevo", "parrafo"], .salto("\n\n")),
    (["punto", "aparte"], .puntoAparte),
    (["punto", "y", "aparte"], .puntoAparte),
    (["punto", "y", "seguido"], .cierra(".")),
    (["punto", "seguido"], .cierra(".")),
    (["punto", "y", "coma"], .cierra(";")),
    (["puntos", "suspensivos"], .cierra("…")),
    (["signo", "de", "interrogacion"], .cierra("?")),
    (["cierra", "interrogacion"], .cierra("?")),
    (["abre", "interrogacion"], .abre("¿")),
    (["signo", "de", "exclamacion"], .cierra("!")),
    (["cierra", "exclamacion"], .cierra("!")),
    (["abre", "exclamacion"], .abre("¡")),
    (["abre", "comillas"], .abre("“")),
    (["cierra", "comillas"], .cierra("”")),
    (["abre", "parentesis"], .abre("(")),
    (["cierra", "parentesis"], .cierra(")")),
  ]

  /// «Que coma», «se coma», «en coma»: ahí «coma» es verbo o sustantivo.
  static let antesDeComaQueNoEsComando: Set<String> = [
    "que", "no", "se", "lo", "la", "le", "les", "en", "un", "el", "me", "te", "nos",
  ]
  /// «Llegamos al punto», «en punto», «un punto»: un artículo, una
  /// preposición o un demostrativo antes dicen que «punto» es sustantivo.
  static let antesDePuntoQueNoEsComando: Set<String> = [
    "al", "el", "un", "en", "a", "de", "del", "ese", "este", "mi", "tu", "su", "otro", "cada",
  ]
  /// «Ganamos por dos puntos», «de los dos puntos»: ahí son puntos de un
  /// marcador, no el signo.
  static let antesDeDosPuntosQueNoEsComando: Set<String> = [
    "por", "de", "los", "las", "unos", "sus", "mis", "tus", "con", "en", "a", "y", "esos", "estos",
  ]
  /// «dilo punto cl» → «dilo.cl».
  static let dominios: Set<String> = [
    "cl", "com", "org", "net", "io", "app", "dev", "es", "ar", "ai", "pe", "mx", "co",
  ]
  /// Las palabras con que empieza algún comando. Si el dictado no trae
  /// ninguna, sale idéntico sin pasar por el resto.
  static let primeras: Set<String> = Set(siempre.map(\.frase[0])).union([
    "punto", "coma", "dos", "arroba", "borra", "borralo", "literal",
  ])

  public static func aplicar(_ texto: String) -> String {
    let crudas = texto.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    let claves = crudas.map(clave)
    guard claves.contains(where: primeras.contains) else { return texto }

    var armado = Armado()
    var i = 0
    while i < crudas.count {
      let previa = i > 0 ? claves[i - 1] : ""
      let siguiente = i + 1 < claves.count ? claves[i + 1] : ""

      // «literal nueva línea» escribe «nueva línea», tal cual se dijo.
      if claves[i] == "literal", let largo = largoDeComando(claves, desde: i + 1) {
        for k in i + 1 ... i + largo { armado.palabra(crudas[k]) }
        i += largo + 1
        continue
      }
      if let (frase, accion) = siempre.first(where: { calza($0.frase, claves, en: i) }) {
        armado.aplicar(accion)
        i += frase.count
        continue
      }
      switch claves[i] {
      case "coma" where i > 0 && esCifra(crudas[i - 1]) && esCifra(siguiente):
        // «2 coma 5» es un decimal: 2,5.
        armado.pegar(",")
        i += 1
      case "coma" where i > 0 && !antesDeComaQueNoEsComando.contains(previa)
        && !(esNumeroDicho(previa) && esNumeroDicho(siguiente)):
        armado.aplicar(.cierra(","))
        i += 1
      case "punto" where i > 0 && esCifra(crudas[i - 1]) && esCifra(siguiente):
        // «versión 1 punto 2» → «1.2».
        armado.pegar(".")
        i += 1
      case "punto" where i > 0 && dominios.contains(siguiente)
        && !antesDePuntoQueNoEsComando.contains(previa):
        armado.pegar("." + siguiente)
        i += 2
      case "punto" where i > 0 && !antesDePuntoQueNoEsComando.contains(previa)
        && (i + 1 == claves.count || empiezaUnSalto(claves, en: i + 1)):
        armado.aplicar(.cierra("."))
        i += 1
      case "dos" where siguiente == "puntos" && i > 0
        && !antesDeDosPuntosQueNoEsComando.contains(previa)
        && (i + 2 == claves.count || empiezaUnSalto(claves, en: i + 2)):
        armado.aplicar(.cierra(":"))
        i += 2
      case "arroba" where i > 0 && !siguiente.isEmpty:
        // «ana arroba dilo punto cl» → «ana@dilo.cl».
        armado.pegar("@")
        i += 1
      case "borra" where (siguiente == "eso" || siguiente == "todo") && apartado(crudas, i, 2):
        armado.aplicar(siguiente == "todo" ? .borraTodo : .borraLaFrase)
        i += 2
      case "borralo" where apartado(crudas, i, 1):
        armado.aplicar(.borraLaFrase)
        i += 1
      default:
        armado.palabra(crudas[i])
        i += 1
      }
    }
    return armado.texto.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
  }

  /// El texto que se va armando, con lo que el último comando dejó dicho
  /// para la palabra que viene.
  struct Armado {
    var texto = ""
    /// La que sigue va con mayúscula: la frase la abrió un comando.
    var mayuscula = false
    /// La que sigue va sin espacio: la anterior fue «¿», «(» o un salto.
    var pegado = false

    mutating func palabra(_ palabra: String) {
      var p = palabra
      if mayuscula, let primera = p.first { p = primera.uppercased() + p.dropFirst() }
      if !texto.isEmpty, !pegado { texto += " " }
      texto += p
      mayuscula = false
      pegado = false
    }

    /// Algo que va pegado a los dos lados: el «@», el «.» de un dominio.
    mutating func pegar(_ signos: String) {
      soltarCola(" ")
      texto += signos
      pegado = true
    }

    mutating func soltarCola(_ signos: String) {
      while let ultimo = texto.last, ultimo == " " || signos.contains(ultimo) {
        texto.removeLast()
      }
    }

    mutating func aplicar(_ accion: Accion) {
      switch accion {
      case let .cierra(signo):
        // La coma que el motor ya puso al lado de «coma» no se duplica.
        soltarCola(",;:.")
        if signo == "?" { abrir("¿") }
        if signo == "!" { abrir("¡") }
        texto += signo
        mayuscula = ".?!…".contains(signo)
        pegado = false
      case let .abre(signo):
        if !texto.isEmpty, texto.last != "\n", !pegado { texto += " " }
        texto += signo
        pegado = true
      case let .salto(salto):
        // Los dos puntos se quedan: «dos puntos, nueva línea» abre una lista.
        soltarCola(",;")
        texto += salto
        mayuscula = true
        pegado = true
      case .puntoAparte:
        soltarCola(",;:.")
        texto += ".\n\n"
        mayuscula = true
        pegado = true
      case .borraLaFrase:
        soltarCola(",;:")
        // Hasta el fin de la frase anterior; si era la única, todo.
        let fin = texto.dropLast().lastIndex { ".!?…\n".contains($0) }
        texto = fin.map { String(texto[...$0]) } ?? ""
        mayuscula = true
        pegado = texto.last == "\n"
      case .borraTodo:
        texto = ""
        mayuscula = true
        pegado = false
      }
    }

    /// Un «?» dictado pone su «¿» al comienzo de la frase, si no lo tenía.
    mutating func abrir(_ apertura: Character) {
      let inicio = texto.lastIndex { ".!?…\n".contains($0) }.map { texto.index(after: $0) }
        ?? texto.startIndex
      guard !texto[inicio...].contains(apertura) else { return }
      let primera = texto[inicio...].firstIndex { !$0.isWhitespace } ?? texto.endIndex
      texto.insert(apertura, at: primera)
    }
  }

  static func calza(_ frase: [String], _ claves: [String], en j: Int) -> Bool {
    j + frase.count <= claves.count && frase.indices.allSatisfy { claves[j + $0] == frase[$0] }
  }

  /// Cuántas palabras ocupa el comando que empieza en `j`, si empieza uno.
  static func largoDeComando(_ claves: [String], desde j: Int) -> Int? {
    if let comando = siempre.first(where: { calza($0.frase, claves, en: j) }) {
      return comando.frase.count
    }
    guard j < claves.count else { return nil }
    if ["punto", "coma", "arroba", "borralo"].contains(claves[j]) { return 1 }
    if calza(["dos", "puntos"], claves, en: j) || calza(["borra", "eso"], claves, en: j)
      || calza(["borra", "todo"], claves, en: j)
    {
      return 2
    }
    return nil
  }

  static func empiezaUnSalto(_ claves: [String], en j: Int) -> Bool {
    siempre.contains { calza($0.frase, claves, en: j) }
  }

  /// «Borra eso» es una orden sólo si va suelto: al final, o entre signos.
  /// «Borra eso del servidor» es texto.
  static func apartado(_ crudas: [String], _ i: Int, _ largo: Int) -> Bool {
    let alFinal = i + largo == crudas.count
    let antes = i == 0 || crudas[i - 1].last.map { ".,;!?".contains($0) } == true
    let despues = alFinal || crudas[i + largo - 1].last.map { ".,;".contains($0) } == true
    return despues && (antes || alFinal)
  }

  static func esCifra(_ palabra: String) -> Bool {
    !palabra.isEmpty && palabra.allSatisfy(\.isNumber)
  }

  static func esNumeroDicho(_ clave: String) -> Bool {
    esCifra(clave) || NumerosHablados.lexico[clave] != nil
  }

  /// La palabra para comparar: sin tildes, en minúsculas y sin la
  /// puntuación que el motor le haya pegado.
  static func clave(_ palabra: String) -> String {
    palabra.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_CL"))
      .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?¿¡…\"“”«»()"))
  }
}
