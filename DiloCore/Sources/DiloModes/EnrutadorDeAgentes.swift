import Foundation

/// A qué **Agente** va lo que dijo la persona en la **Conversación**.
///
/// Se le habla a un agente por su nombre al principio de lo dicho —«Switchboard,
/// ¿qué tengo hoy?»—, y sin nombre lo dicho va al último agente de la llamada
/// y, si no hubo, a Dilo. «Revisa Claude Code», «abre Claude Code» o «pásame
/// con Switchboard» cambian de agente sin mandarle nada.
///
/// Compara plegado —sin tildes, sin mayúsculas, sin signos y sin espacios
/// entre las palabras del nombre— y por cómo suena (`ComoSuena`), porque el
/// **Motor de voz** pone tildes, comas y espacios a su criterio y escribe
/// «Cami» aunque el agente se guardó «Kami». Y conoce lo que Parakeet suele oír mal en
/// los nombres de fábrica («cloud code», «suichbord»): un nombre en inglés
/// dicho en una frase en español sale escrito como suena. Puro: entra lo
/// dicho, sale la ruta.
public struct EnrutadorDeAgentes: Sendable {
  public enum Ruta: Equatable, Sendable {
    /// Un **Turno** para un agente, con lo dicho sin su nombre adelante.
    case turno(TurnoDeLaPersona)
    /// Cambiar de agente sin decirle nada: «pásame con Switchboard».
    case cambiarA(Agente)
  }

  /// Lo que Parakeet escribe en vez del nombre, por nombre plegado y sin
  /// espacios. Sólo los de fábrica: un nombre que la persona inventa se
  /// reconoce por cómo suena, y si el motor lo oye mal lo agrega a Tus
  /// palabras.
  static let comoLoOyeElMotor: [String: [String]] = [
    "claudecode": [
      "cloud code", "clod code", "claud code", "clode code", "cloud cod", "clau code", "claude cod",
      "cloude code", "clow code", "claudio code", "claude codes", "cloud codes",
    ],
    "switchboard": [
      "suichbord", "suich bord", "suichboard", "switch bord", "switchbord", "suit board", "suitch board",
      "suich board", "swich board", "swichboard", "switch boar", "suichbor",
    ],
    "dilo": [],
  ]

  /// Lo que puede ir antes del nombre sin que deje de ser un llamado: «oye
  /// Dilo», «hola Switchboard».
  static let saludos: Set<String> = ["oye", "hola", "hey", "ey", "ok", "okay", "ya", "alo"]

  /// Los verbos que cambian de agente. Van seguidos del nombre y, a lo más, de
  /// cortesía: con algo más, ese algo es el turno para el agente nombrado.
  static let cambios: [[String]] = [
    ["revisa"], ["abre"], ["abreme"], ["pasame", "con"], ["pasame", "a"], ["paseme", "con"],
    ["ponme", "con"], ["habla", "con"], ["hablemos", "con"], ["hablar", "con"], ["quiero", "hablar", "con"],
    ["conectame", "con"], ["cambia", "a"], ["cambiate", "a"], ["llama", "a"], ["vamos", "con"],
    ["anda", "a"], ["ve", "a"],
  ]

  /// Lo que sobra después del nombre en un cambio sin mensaje.
  static let cortesia: Set<String> = ["por", "favor", "porfa", "porfavor", "ahora", "altiro", "gracias", "y"]

  public let agentes: [Agente]

  public init(agentes: [Agente]) {
    self.agentes = agentes
  }

  /// El agente al que va lo dicho y lo que se le dice.
  ///
  /// `ultimo` es el último agente al que se le habló en esta llamada: el que
  /// recibe lo dicho sin nombre. Sin último, Dilo; sin Dilo en la lista, el
  /// primero.
  public func enrutar(_ dicho: String, ultimo: Agente?) -> Ruta {
    let palabras = Self.palabras(de: dicho)
    var inicio = 0
    while inicio < palabras.count, Self.saludos.contains(palabras[inicio].plegada) { inicio += 1 }

    // Un verbo de cambio y un nombre: cambiar, y si sobra algo, decírselo.
    for verbo in Self.cambios where Self.empieza(palabras, en: inicio, con: verbo) {
      let tras = inicio + verbo.count
      guard let (agente, fin) = nombrado(palabras, desde: tras) else { continue }
      let resto = palabras[fin...].map(\.plegada)
      if resto.allSatisfy({ Self.cortesia.contains($0) }) { return .cambiarA(agente) }
      return .turno(TurnoDeLaPersona(agente: agente, texto: Self.resto(de: dicho, desde: palabras, indice: fin)))
    }

    // El nombre al principio: «Claude Code, revisa los tests».
    if let (agente, fin) = nombrado(palabras, desde: inicio) {
      let texto = Self.resto(de: dicho, desde: palabras, indice: fin)
      // Sólo el nombre es un llamado sin mensaje: «¿Switchboard?».
      if texto.isEmpty { return .cambiarA(agente) }
      return .turno(TurnoDeLaPersona(agente: agente, texto: texto))
    }

    let destino = ultimo ?? porDefecto
    return .turno(TurnoDeLaPersona(agente: destino, texto: dicho.trimmingCharacters(in: .whitespacesAndNewlines)))
  }

  /// Dilo, o el primero si la persona lo sacó de la lista.
  public var porDefecto: Agente {
    agentes.first { $0.tipo == .dilo } ?? agentes.first ?? Agente.deFabrica[0]
  }

  /// Las formas plegadas en que se reconoce el nombre de un agente: el nombre
  /// y lo que el motor suele oír en su lugar. Sirve también a la escucha de
  /// nombres, que busca las mismas palabras.
  public static func variantes(de agente: Agente) -> [String] {
    let nombre = SenalesDelTurno.plegar(agente.nombre)
    let junto = nombre.replacingOccurrences(of: " ", with: "")
    return [nombre] + (comoLoOyeElMotor[junto] ?? [])
  }

  /// El agente nombrado a partir de `desde` y dónde termina el nombre. Gana
  /// el nombre más largo: «Claude Code» antes que un agente «Claude».
  func nombrado(_ palabras: [Palabra], desde: Int) -> (Agente, Int)? {
    var mejor: (Agente, Int)?
    for agente in agentes {
      for variante in Self.variantes(de: agente) {
        let objetivo = ComoSuena.clave(variante.replacingOccurrences(of: " ", with: ""))
        guard !objetivo.isEmpty else { continue }
        var junto = ""
        var indice = desde
        while indice < palabras.count, junto.count < objetivo.count {
          junto += palabras[indice].clave
          indice += 1
          if junto == objetivo, indice > (mejor?.1 ?? -1) { mejor = (agente, indice) }
        }
      }
    }
    return mejor
  }

  /// Una palabra de lo dicho: plegada para comparar, y dónde termina en el
  /// original para devolver el resto tal como se dijo.
  struct Palabra: Equatable {
    let plegada: String
    let fin: String.Index
    var clave: String { ComoSuena.clave(plegada) }
  }

  static func palabras(de dicho: String) -> [Palabra] {
    var palabras: [Palabra] = []
    var actual = ""
    var indice = dicho.startIndex
    func cerrar(en fin: String.Index) {
      let plegada = SenalesDelTurno.plegar(actual).replacingOccurrences(of: " ", with: "")
      if !plegada.isEmpty { palabras.append(Palabra(plegada: plegada, fin: fin)) }
      actual = ""
    }
    while indice < dicho.endIndex {
      let caracter = dicho[indice]
      if caracter.isLetter || caracter.isNumber {
        actual.append(caracter)
      } else {
        cerrar(en: indice)
      }
      indice = dicho.index(after: indice)
    }
    cerrar(en: dicho.endIndex)
    return palabras
  }

  static func empieza(_ palabras: [Palabra], en inicio: Int, con secuencia: [String]) -> Bool {
    guard inicio + secuencia.count <= palabras.count else { return false }
    return zip(palabras[inicio...], secuencia).allSatisfy { $0.plegada == $1 }
  }

  /// Lo que se dijo después de la palabra `indice - 1`, como se dijo, sin la
  /// coma ni el «y» que lo pegaban al nombre.
  static func resto(de dicho: String, desde palabras: [Palabra], indice: Int) -> String {
    guard indice > 0 else { return dicho.trimmingCharacters(in: .whitespacesAndNewlines) }
    var resto = String(dicho[palabras[indice - 1].fin...])
    let separadores = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).subtracting(
      CharacterSet(charactersIn: "¿¡")
    )
    resto = String(resto.unicodeScalars.drop { separadores.contains($0) })
    if resto.lowercased().hasPrefix("y ") { resto = String(resto.dropFirst(2)) }
    resto = resto.trimmingCharacters(in: .whitespacesAndNewlines)
    // La mayúscula va en la primera letra, también detrás de «¿» o «¡».
    guard let letra = resto.firstIndex(where: \.isLetter) else { return resto }
    return resto[..<letra] + resto[letra].uppercased() + resto[resto.index(after: letra)...]
  }
}
