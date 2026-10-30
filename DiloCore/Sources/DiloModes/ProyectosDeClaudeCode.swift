import Foundation

/// Un proyecto al que se le puede hablar por nombre: «Claude Code, en Dilo,
/// revisa los tests» abre una sesión en su carpeta.
public struct ProyectoDeClaudeCode: Codable, Equatable, Hashable, Sendable, Identifiable {
  /// Cómo se dice. «andes-flags-plataforma» se dice «andes flags».
  public var nombre: String
  public var carpeta: String

  public var id: String { carpeta }

  public init(nombre: String, carpeta: String) {
    self.nombre = nombre
    self.carpeta = carpeta
  }
}

/// Los proyectos que se conocen por nombre: los escritos en Ajustes y, de
/// fábrica, cada carpeta de `~/Developer`, que son enlaces a los repos
/// reales. Uno escrito en Ajustes le gana a uno de `~/Developer` con el mismo
/// nombre: así se cambia a dónde apunta «Dilo» sin tocar los enlaces.
public enum CatalogoDeProyectos {
  public static func todos(
    propios: [ProyectoDeClaudeCode],
    deDeveloper: [ProyectoDeClaudeCode]
  ) -> [ProyectoDeClaudeCode] {
    let nombresPropios = Set(propios.map { NombreHablado.normalizado($0.nombre) })
    let deFabrica = deDeveloper.filter { !nombresPropios.contains(NombreHablado.normalizado($0.nombre)) }
    return (propios + deFabrica).filter { !NombreHablado.normalizado($0.nombre).isEmpty }
  }

  /// Las entradas de `~/Developer` que sirven de proyecto: ni ocultas ni
  /// archivos sueltos (eso lo filtra quien lista el disco).
  public static func deDeveloper(carpetas: [String], raiz: String) -> [ProyectoDeClaudeCode] {
    carpetas
      .filter { !$0.hasPrefix(".") }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
      .map { ProyectoDeClaudeCode(nombre: $0, carpeta: (raiz as NSString).appendingPathComponent($0)) }
  }
}

/// Un nombre como se oye: sin tildes ni mayúsculas, con guiones, puntos y
/// guiones bajos como espacios.
public enum NombreHablado {
  public static func normalizado(_ texto: String) -> String {
    palabras(texto).joined(separator: " ")
  }

  public static func palabras(_ texto: String) -> [String] {
    texto
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_CL"))
      .lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
  }
}

/// Lo que se entendió de un turno para Claude Code: a qué proyecto va, si es
/// para retomar la última sesión y qué hay que mandarle.
public struct PedidoAClaudeCode: Equatable, Sendable {
  public var proyecto: ProyectoDeClaudeCode?
  /// «Retoma la sesión de Dilo», «revisa Claude Code»: abrir la más reciente
  /// del proyecto en vez de una nueva.
  public var retomar: Bool
  /// Lo que se le manda a Claude Code, tal como se dijo. Vacío si el turno
  /// sólo nombró el proyecto o pidió retomar.
  public var tarea: String

  public init(proyecto: ProyectoDeClaudeCode? = nil, retomar: Bool = false, tarea: String) {
    self.proyecto = proyecto
    self.retomar = retomar
    self.tarea = tarea
  }

  /// Entiende lo dicho. `esperandoProyecto` es que Dilo acaba de preguntar
  /// «¿en qué proyecto?»: ahí «Dilo» a secas es la respuesta.
  public static func entender(
    _ texto: String,
    proyectos: [ProyectoDeClaudeCode],
    esperandoProyecto: Bool = false
  ) -> PedidoAClaudeCode {
    let fichas = Ficha.de(texto)
    var i = 0
    var pedido = PedidoAClaudeCode(tarea: texto.trimmingCharacters(in: .whitespacesAndNewlines))

    // «Retoma (la sesión) (de|del|en) (el proyecto) X», «revisa Claude Code».
    if let largo = frase(deRetomar: fichas) {
      pedido.retomar = true
      i = largo
      if i < fichas.count, ["de", "del", "en"].contains(fichas[i].palabra), !fichas[i - 1].cierra {
        let antes = i
        i += 1
        i = saltar(["el", "proyecto"], en: fichas, desde: i)
        if let (proyecto, fin) = proyecto(en: fichas, desde: i, entre: proyectos) {
          pedido.proyecto = proyecto
          i = fin
        } else {
          i = antes
        }
      }
    } else {
      // «En (el proyecto) X, …», «proyecto X: …» o, si Dilo preguntó, «X».
      var j = 0
      if j < fichas.count, fichas[j].palabra == "en" { j += 1 }
      j = saltar(["el", "proyecto"], en: fichas, desde: j)
      let nombroAlgo = j > 0 || esperandoProyecto
      // No se exige la coma después del nombre: Parakeet no siempre la pone.
      // «En general, …» no es un proyecto porque «general» no está en la
      // lista, y un proyecto sólo se nombra al principio.
      if nombroAlgo, let (proyecto, fin) = proyecto(en: fichas, desde: j, entre: proyectos) {
        pedido.proyecto = proyecto
        i = fin
      }
    }

    if i > 0 {
      pedido.tarea = resto(texto, desde: i, fichas: fichas)
    }
    return pedido
  }

  /// Las frases que piden retomar, como palabras normalizadas.
  static let frasesDeRetomar: [[String]] = [
    ["retoma", "la", "sesion"], ["retomar", "la", "sesion"], ["retoma"], ["retomar"], ["retomemos"],
    ["sigue", "con", "la", "sesion"], ["continua", "la", "sesion"], ["vuelve", "a", "la", "sesion"],
    ["revisa", "claude", "code"], ["abre", "claude", "code"], ["revisa", "cloud", "code"], ["abre", "cloud", "code"],
  ]

  private static func frase(deRetomar fichas: [Ficha]) -> Int? {
    let palabras = fichas.map(\.palabra)
    let largos = frasesDeRetomar
      .filter { palabras.starts(with: $0) }
      .map(\.count)
    return largos.max()
  }

  private static func saltar(_ relleno: [String], en fichas: [Ficha], desde inicio: Int) -> Int {
    var i = inicio
    while i < fichas.count, relleno.contains(fichas[i].palabra), !fichas[i].cierra { i += 1 }
    return i
  }

  /// El proyecto que se nombra desde `inicio`: el nombre entero más largo, o
  /// el principio de un solo nombre («andes flags» por
  /// «andes-flags-plataforma», «switchboard» por «switchboard-os»).
  static func proyecto(
    en fichas: [Ficha],
    desde inicio: Int,
    entre proyectos: [ProyectoDeClaudeCode]
  ) -> (ProyectoDeClaudeCode, fin: Int)? {
    guard inicio < fichas.count else { return nil }
    // Las palabras dichas hasta el primer signo que cierra.
    var dichas: [String] = []
    var k = inicio
    while k < fichas.count {
      dichas.append(fichas[k].palabra)
      if fichas[k].cierra { break }
      k += 1
    }
    let conPalabras = proyectos.map { ($0, NombreHablado.palabras($0.nombre)) }.filter { !$0.1.isEmpty }

    let enteros = conPalabras.filter { dichas.starts(with: $0.1) }
    if let mejor = enteros.max(by: { $0.1.count < $1.1.count }) {
      return (mejor.0, inicio + mejor.1.count)
    }
    // El principio de un nombre: tantas palabras dichas como calcen, y que
    // calcen con uno solo.
    for largo in stride(from: min(dichas.count, 4), through: 1, by: -1) {
      let cabeza = Array(dichas.prefix(largo))
      let calzan = conPalabras.filter { $0.1.count > largo && $0.1.starts(with: cabeza) }
      if calzan.count == 1 { return (calzan[0].0, inicio + largo) }
      if calzan.count > 1 { return nil }
    }
    return nil
  }

  /// Lo dicho desde la ficha `desde`, tal cual, sin el «y» ni los signos con
  /// que se unía a lo anterior.
  private static func resto(_ texto: String, desde i: Int, fichas: [Ficha]) -> String {
    guard i < fichas.count else { return "" }
    var resto = String(texto[fichas[i].rango.lowerBound...])
    if fichas[i].palabra == "y" {
      resto = i + 1 < fichas.count ? String(texto[fichas[i + 1].rango.lowerBound...]) : ""
    }
    resto = resto.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.-—").union(.whitespacesAndNewlines))
    guard let primera = resto.first else { return "" }
    return primera.uppercased() + resto.dropFirst()
  }

  /// Una palabra dicha, con dónde está en el texto original y si la cierra
  /// un signo («Dilo,»).
  struct Ficha {
    var palabra: String
    var rango: Range<String.Index>
    var cierra: Bool

    static func de(_ texto: String) -> [Ficha] {
      var fichas: [Ficha] = []
      var i = texto.startIndex
      while i < texto.endIndex {
        guard texto[i].isLetter || texto[i].isNumber else {
          if !fichas.isEmpty, ",;:.?!".contains(texto[i]) { fichas[fichas.count - 1].cierra = true }
          i = texto.index(after: i)
          continue
        }
        var fin = i
        // Un guion entre letras es parte del nombre («dilo-landing»).
        while fin < texto.endIndex,
          texto[fin].isLetter || texto[fin].isNumber
            || ("-_".contains(texto[fin]) && texto.index(after: fin) < texto.endIndex
              && (texto[texto.index(after: fin)].isLetter || texto[texto.index(after: fin)].isNumber))
        {
          fin = texto.index(after: fin)
        }
        for (n, palabra) in NombreHablado.palabras(String(texto[i..<fin])).enumerated() {
          // Las partes de «dilo-landing» comparten el rango de la palabra.
          fichas.append(Ficha(palabra: palabra, rango: n == 0 ? i..<fin : fin..<fin, cierra: false))
        }
        i = fin
      }
      return fichas
    }
  }
}

/// La pregunta cuando no se nombró proyecto y no hay uno usado antes.
public enum PreguntaDeProyecto {
  public static func texto(proyectos: [ProyectoDeClaudeCode]) -> String {
    let ejemplos = proyectos.prefix(3).map(\.nombre).map(NombreHablado.normalizado)
    switch ejemplos.count {
    case 0:
      return "No tengo proyectos para Claude Code. Agrégalos en Ajustes, en Claude."
    case 1:
      return "¿En qué proyecto? Por ejemplo, \(ejemplos[0])."
    default:
      let primeros = ejemplos.dropLast().joined(separator: ", ")
      return "¿En qué proyecto? Por ejemplo, \(primeros) o \(ejemplos.last!)."
    }
  }

  public static func listo(en proyecto: ProyectoDeClaudeCode) -> String {
    "Listo, estoy en \(NombreHablado.normalizado(proyecto.nombre)). ¿Qué hago?"
  }
}
