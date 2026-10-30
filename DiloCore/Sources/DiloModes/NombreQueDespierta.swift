import Foundation

/// Si lo que oyó la **escucha de nombres** empieza con el nombre de un
/// **Agente** que se llama por nombre, y qué se dijo después.
///
/// La escucha transcribe con el **Motor de voz** el principio de cada tramo
/// con voz (`VentanaDeEscucha`) y le pregunta acá. Sólo cuenta el nombre **al
/// principio**: «Dilo, ¿qué tengo hoy?» llama; «la app se llama Dilo» no.
///
/// «Dilo» es además un verbo («dilo otra vez»). Para no despertar con el
/// verbo, el nombre tiene que ir **apartado**: solo, o seguido de un signo
/// que el motor pone cuando hay pausa («Dilo, …», «Dilo. …», «Dilo ¿…?»).
/// Medido en la espiga del 2026-10-30
/// (`/Volumes/SSD 1/Dilo/taller/escucha/README.md`): Parakeet pone la coma
/// en casi todos los llamados y no la pone en el verbo.
///
/// Compara plegado —sin tildes, mayúsculas ni signos— y por cómo suena
/// (`ComoSuena`), porque el motor pone tildes y mayúsculas a su criterio y
/// escribe «Cami» aunque el agente se guardó «Kami». Un nombre de varias
/// palabras se compara junto («Claude Code» = «claudecode»). Puro.
public struct NombreQueDespierta: Sendable {
  /// Un llamado: a quién, y lo que siguió al nombre si hubo algo.
  public struct Llamado: Equatable, Sendable {
    public let agente: Agente
    /// Lo dicho después del nombre, como se dijo y sin la coma que lo pegaba
    /// al nombre. `nil` si sólo se dijo el nombre.
    public let primerTurno: String?

    public init(agente: Agente, primerTurno: String?) {
      self.agente = agente
      self.primerTurno = primerTurno
    }
  }

  /// Lo que Parakeet escribe en vez de «Dilo» al principio de un llamado,
  /// medido en la espiga del 2026-10-30 sobre 200 llamados de `say`: «Dilo»
  /// sale bien en el 43 % y el resto es casi siempre una de éstas. Ninguna
  /// despierta sin el signo que la aparta («Digo que no» no llama; «Digo, …»
  /// sí), y por eso se pueden aceptar: en la prosa medida ninguna apareció así
  /// al principio de un tramo. «Milo» y «vivo» no están a propósito: «Milo,
  /// ven acá» es un llamado a otro.
  public static let comoLoOyeElMotor: [String: [String]] = [
    "dilo": ["di lo", "digo", "dimo", "divo", "dino", "lilo", "nilo", "dio", "delo", "limo"]
  ]

  /// El nombre plegado y lo que el motor suele escribir en su lugar.
  public static func variantes(de agente: Agente) -> [String] {
    let nombre = SenalesDelTurno.plegar(agente.nombre)
    return [nombre] + (comoLoOyeElMotor[nombre.replacingOccurrences(of: " ", with: "")] ?? [])
  }

  /// Lo que puede ir antes del nombre sin que deje de ser un llamado: «oye
  /// Dilo», «hola Dilo». Una sola palabra: con dos ya es una frase que nombra
  /// a Dilo, no un llamado.
  static let saludos: Set<String> = ["oye", "hola", "hey", "ey", "ok", "okay", "alo"]

  /// Los signos que dicen que el nombre quedó apartado del resto. El motor
  /// los pone cuando hay una pausa después del nombre.
  static let apartan: Set<Character> = [",", ".", "!", "?", "¿", "¡", ":", ";", "…", "—"]

  /// Los agentes que la escucha puede despertar, con las formas plegadas en
  /// que se reconoce cada uno. El más largo gana: «Claude Code» antes que un
  /// agente «Claude».
  public let candidatos: [(agente: Agente, variantes: [String])]

  /// - Parameters:
  ///   - agentes: todos; sólo cuentan los que tienen `seLlamaPorNombre`.
  ///   - variantes: las formas en que el motor escribe cada nombre. Por
  ///     defecto, el nombre plegado y `comoLoOyeElMotor`.
  public init(
    agentes: [Agente],
    variantes: (Agente) -> [String] = NombreQueDespierta.variantes(de:)
  ) {
    candidatos = agentes.filter(\.seLlamaPorNombre).map { agente in
      let formas = variantes(agente).map {
        ComoSuena.clave(SenalesDelTurno.plegar($0).replacingOccurrences(of: " ", with: ""))
      }.filter { !$0.isEmpty }
      return (agente, Array(Set(formas)).sorted { $0.count > $1.count })
    }
  }

  /// Si hay alguien a quien escuchar: sin agentes que se llamen por nombre,
  /// la escucha no tiene para qué abrir el micrófono.
  public var hayNombres: Bool { !candidatos.isEmpty }

  /// El llamado que hay en lo oído, o nil.
  ///
  /// - Parameter exigirApartado: false cuando el nombre ya se oyó en el
  ///   principio del tramo y esto es el tramo entero: con más contexto el
  ///   motor a veces pega el nombre al resto («Di lo que hay de nuevo») y no
  ///   por eso deja de ser un llamado.
  public func oir(_ dicho: String, exigirApartado: Bool = true) -> Llamado? {
    let palabras = Self.palabras(de: dicho)
    guard !palabras.isEmpty else { return nil }
    var inicio = 0
    if palabras.count > 1, Self.saludos.contains(palabras[0].plegada) { inicio = 1 }

    var mejor: (agente: Agente, fin: Int, largo: Int)?
    for (agente, variantes) in candidatos {
      for objetivo in variantes {
        var junto = ""
        var indice = inicio
        while indice < palabras.count, junto.count < objetivo.count {
          junto += palabras[indice].clave
          indice += 1
        }
        guard junto == objetivo, objetivo.count > (mejor?.largo ?? 0) else { continue }
        mejor = (agente, indice, objetivo.count)
      }
    }
    guard let mejor else { return nil }

    let ultima = palabras[mejor.fin - 1]
    let resto = String(dicho[ultima.fin...])
    let primerTurno = Self.limpiar(resto)
    // Sólo el nombre: un llamado sin nada más.
    guard let primerTurno else { return Llamado(agente: mejor.agente, primerTurno: nil) }
    // Con algo después, el nombre tiene que ir apartado por un signo; si no,
    // es una frase que empieza con la palabra («Dilo otra vez»).
    if exigirApartado {
      guard let signo = resto.first(where: { !$0.isWhitespace }), Self.apartan.contains(signo) else {
        return nil
      }
    }
    return Llamado(agente: mejor.agente, primerTurno: primerTurno)
  }

  /// Una palabra de lo dicho: plegada para comparar y dónde termina en el
  /// original, para devolver el resto tal como se dijo.
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

  /// Lo que siguió al nombre sin los signos que lo pegaban, con mayúscula en
  /// la primera letra (también detrás de «¿» o «¡»). Nil si no queda ninguna
  /// letra ni número.
  public static func limpiar(_ resto: String) -> String? {
    let separadores = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
      .subtracting(CharacterSet(charactersIn: "¿¡"))
    var limpio = String(resto.unicodeScalars.drop { separadores.contains($0) })
    limpio = limpio.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let letra = limpio.firstIndex(where: { $0.isLetter || $0.isNumber }) else { return nil }
    return limpio[..<letra] + limpio[letra].uppercased() + limpio[limpio.index(after: letra)...]
  }
}
