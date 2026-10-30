import Foundation

/// Los tres modelos que la **Conversación** puede usar, del más barato al más
/// capaz, con lo que piensa cada uno.
///
/// Alfonso, 2026-10-29: «Haiku no sé si dé para todo; lo que podría ser
/// Sonnet, y si la tarea es muy simple sepa bajar a Haiku, o al revés, si es
/// muy compleja subir a Opus». El esfuerzo va acorde: `low` para Haiku —un
/// «gracias» no se piensa—, `medium` para Sonnet —el turno de todos los
/// días— y `high` para Opus, que está ahí justo para pensar.
public enum NivelDeModelo: String, CaseIterable, Comparable, Sendable {
  case haiku
  case sonnet
  case opus

  public var modelo: ModeloDeAnthropic {
    switch self {
    case .haiku: ModelosDeAnthropic.haiku
    case .sonnet: ModelosDeAnthropic.sonnet
    case .opus: ModelosDeAnthropic.opus
    }
  }

  public var esfuerzo: String {
    switch self {
    case .haiku: "low"
    case .sonnet: "medium"
    case .opus: "high"
    }
  }

  /// El techo de la respuesta. Lo que el modelo piensa cuenta contra este
  /// número, y Opus en `high` piensa bastante antes de una respuesta de
  /// cuatro oraciones: un techo justo cortaría la respuesta por la mitad.
  public var maximoDeTokens: Int {
    switch self {
    case .haiku: 2_000
    case .sonnet: 4_000
    case .opus: 8_000
    }
  }

  /// «Haiku», «Sonnet», «Opus»: lo que la barra de llamada dice al lado del
  /// turno. Nombres propios, no se traducen.
  public var nombreCorto: String {
    switch self {
    case .haiku: "Haiku"
    case .sonnet: "Sonnet"
    case .opus: "Opus"
    }
  }

  private var orden: Int {
    switch self {
    case .haiku: 0
    case .sonnet: 1
    case .opus: 2
    }
  }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.orden < rhs.orden }
}

/// Lo que se elige en Ajustes (y en la barra de llamada): que decida el
/// router, o un modelo fijo. Se guarda por `rawValue` en
/// `diloConversacionModelo`; no se renombra.
public enum EleccionDeModelo: String, CaseIterable, Sendable {
  case automatico
  case haiku
  case sonnet
  case opus

  /// El nivel fijado, o nil para automático.
  public var nivelFijo: NivelDeModelo? {
    switch self {
    case .automatico: nil
    case .haiku: .haiku
    case .sonnet: .sonnet
    case .opus: .opus
    }
  }
}

/// Qué modelo contesta cada **Turno** de la **Conversación**: una regla pura,
/// sin modelo, al estilo del `Decider` de `CONTEXT.md`.
///
/// Las reglas, decididas con Alfonso el 2026-10-29:
///
/// 1. **El primer turno va a Sonnet 5.5**, sin inferir nada. Sólo cambia si la
///    persona lo pide con todas sus letras —«piénsalo bien», «analiza a
///    fondo», «usa Opus» suben; «rápido», «corto», «usa Haiku» bajan—, y una
///    frase así cambia el modelo en cualquier turno.
/// 2. **Bajar a Haiku** se permite en cualquier turno, pero sólo para lo
///    claramente trivial: un saludo, «sí», «no», «gracias», «ok», «repite»,
///    confirmar algo ya dicho. Equivocarse ahí cuesta poco.
/// 3. **Subir a Opus por inferencia nunca en el primer turno**, y sólo con
///    evidencia acumulada: señales de complejidad (analizar, planificar,
///    comparar, código, varios pasos, un texto largo) en dos turnos del mismo
///    tema, o un turno muy largo y denso después del primero.
/// 4. **Histéresis**: arriba, el tema se queda arriba al menos
///    `turnosMinimosArriba` turnos o hasta que cambie el tema, sin saltar de
///    modelo cada turno. Un turno trivial en medio puede ir a Haiku sin bajar
///    el nivel del tema.
///
/// Un modelo fijado en Ajustes le gana a todo menos a lo pedido de viva voz:
/// si la persona dice «usa Opus», eso es más reciente que Ajustes.
///
/// El router vive lo que vive una conversación, en RAM. No ve el historial
/// entero, sólo lo que necesita: lo dicho en este turno y lo que anotó de los
/// anteriores (cuántos, el nivel del tema y su evidencia).
public struct RouterDeModelos: Equatable, Sendable {
  /// Por qué contestó ese modelo. Va al log de la conversación (nunca lo
  /// dicho) y es lo que los tests afirman.
  public enum Motivo: String, Equatable, Sendable {
    /// El primer turno, sin frase que lo cambie.
    case primerTurno
    /// El modelo de todos los días, sin evidencia para moverse.
    case base
    /// La persona lo pidió con una frase («piénsalo bien», «usa Haiku»).
    case pedidoDeViva
    /// Fijado a mano en Ajustes o en la barra de llamada.
    case fijado
    /// Un saludo, un «sí», un «gracias».
    case trivial
    /// Señales de complejidad en dos turnos del mismo tema.
    case evidencia
    /// Un turno muy largo y denso después del primero.
    case turnoLargo
    /// El tema ya estaba arriba y se queda (histéresis).
    case temaArriba
    /// El tema pasó sus turnos arriba sin más evidencia y volvió a la base.
    case vuelveALaBase
  }

  public struct Decision: Equatable, Sendable {
    public let nivel: NivelDeModelo
    public let motivo: Motivo

    public init(_ nivel: NivelDeModelo, _ motivo: Motivo) {
      self.nivel = nivel
      self.motivo = motivo
    }
  }

  /// Cuántos turnos se queda arriba un tema antes de poder bajar, contando
  /// el que lo subió. Los triviales de en medio no cuentan.
  public static let turnosMinimosArriba = 3
  /// Cuántos turnos con señales de complejidad, en el mismo tema, suben a
  /// Opus. Uno solo no: «compárame estos dos autos» es una pregunta que
  /// Sonnet contesta bien.
  public static let turnosComplejosParaSubir = 2
  /// Un turno de este largo, y denso, sube solo (nunca el primero). Noventa
  /// palabras son unos cuarenta segundos hablando: alguien que explica un
  /// problema entero, no alguien que charla.
  public static let palabrasDeUnTurnoLargo = 90
  /// Qué parte de las palabras tienen que ser de contenido —no artículos,
  /// preposiciones ni muletillas— para que un turno largo cuente como denso.
  /// Noventa palabras de «eh, o sea, como que» no piden Opus.
  public static let densidadMinima = 0.5
  /// Cuántas palabras puede tener, como mucho, un turno trivial.
  public static let palabrasDeUnTurnoTrivial = 6

  /// Cuántos turnos se decidieron en esta conversación.
  public private(set) var turnos = 0
  /// El nivel del tema en curso: la base o arriba.
  public private(set) var nivelDelTema = NivelDeModelo.sonnet
  /// Cuántos turnos no triviales lleva el tema en Opus, contando el que lo
  /// subió.
  public private(set) var turnosArriba = 0
  /// Cuántos turnos de este tema traían señales de complejidad.
  public private(set) var turnosComplejos = 0
  /// Un modelo pedido de viva voz («usa Sonnet»), que dura lo que el tema.
  public private(set) var pedidoDeViva: NivelDeModelo?

  public init() {}

  /// El modelo de este turno, y lo que el router anota para los siguientes.
  public mutating func decidir(
    _ dicho: String,
    eleccion: EleccionDeModelo = .automatico
  ) -> Decision {
    let senales = SenalesDelTurno(dicho)
    let esElPrimero = turnos == 0
    turnos += 1

    if senales.cambiaDeTema { cambiarDeTema() }

    // Lo dicho con todas sus letras le gana a todo, Ajustes incluido.
    if let nombrado = senales.nombraUnModelo {
      pedidoDeViva = nombrado
      if nombrado == .opus { subir() }
      return Decision(nombrado, .pedidoDeViva)
    }
    if senales.pideProfundidad {
      pedidoDeViva = nil
      subir()
      return Decision(.opus, .pedidoDeViva)
    }
    if senales.pideRapidez {
      // Sólo este turno: «rápido» es cómo contestar esto, no el resto.
      return Decision(.haiku, .pedidoDeViva)
    }

    if let fijo = eleccion.nivelFijo { return Decision(fijo, .fijado) }
    if let pedidoDeViva { return Decision(pedidoDeViva, .pedidoDeViva) }

    // Lo trivial baja sin tocar el nivel del tema ni contar como turno de él.
    if senales.esTrivial { return Decision(.haiku, .trivial) }

    if senales.esComplejo { turnosComplejos += 1 }

    // El primero se queda en la base. Su evidencia sí cuenta: si el segundo
    // también la trae, son dos turnos del mismo tema.
    if esElPrimero { return Decision(.sonnet, .primerTurno) }

    if nivelDelTema == .opus {
      turnosArriba += 1
      if turnosArriba <= Self.turnosMinimosArriba || senales.esComplejo || senales.esLargoYDenso {
        return Decision(.opus, .temaArriba)
      }
      cambiarDeTema()
      return Decision(.sonnet, .vuelveALaBase)
    }

    if turnosComplejos >= Self.turnosComplejosParaSubir {
      subir()
      return Decision(.opus, .evidencia)
    }
    if senales.esLargoYDenso {
      subir()
      return Decision(.opus, .turnoLargo)
    }
    return Decision(.sonnet, .base)
  }

  /// El tema sube a Opus y empieza a contar sus turnos arriba.
  private mutating func subir() {
    nivelDelTema = .opus
    turnosArriba = 1
  }

  private mutating func cambiarDeTema() {
    nivelDelTema = .sonnet
    turnosArriba = 0
    turnosComplejos = 0
    pedidoDeViva = nil
  }
}

/// Lo que el router lee de un turno, sin modelo: palabras, frases y largo.
///
/// Todo se compara plegado —sin tildes ni mayúsculas, sin signos—, porque
/// el motor de voz pone tildes y signos a su criterio: «piénsalo» y
/// «piensalo» tienen que ser lo mismo.
public struct SenalesDelTurno: Equatable, Sendable {
  public let palabras: [String]
  public let cambiaDeTema: Bool
  public let nombraUnModelo: NivelDeModelo?
  public let pideProfundidad: Bool
  public let pideRapidez: Bool
  public let esTrivial: Bool
  public let esComplejo: Bool
  public let esLargoYDenso: Bool

  public init(_ dicho: String) {
    let plegado = Self.plegar(dicho)
    let palabras = plegado.split(separator: " ").map(String.init)
    self.palabras = palabras
    let conBordes = " \(palabras.joined(separator: " ")) "

    func dice(_ frase: String) -> Bool { conBordes.contains(" \(frase) ") }

    cambiaDeTema = Self.frasesDeCambioDeTema.contains(where: dice)
    nombraUnModelo = Self.modeloNombrado(en: palabras)
    pideProfundidad = Self.frasesDeProfundidad.contains(where: dice)
    pideRapidez = !pideProfundidad && (
      Self.frasesDeRapidez.contains(where: dice) || Self.rapidezSuelta(en: dicho, palabras: palabras)
    )
    esTrivial = Self.esTrivial(palabras)
    esComplejo = Self.raicesDeComplejidad.contains { raiz in
      palabras.contains { $0.hasPrefix(raiz) }
    } || Self.frasesDeComplejidad.contains(where: dice)
      || dicho.filter({ $0 == "?" }).count >= 2
    esLargoYDenso = palabras.count >= RouterDeModelos.palabrasDeUnTurnoLargo
      && Self.densidad(palabras) >= RouterDeModelos.densidadMinima
  }

  /// Sin tildes, sin mayúsculas, sin signos: sólo palabras separadas por un
  /// espacio. La ñ queda como n, igual que en `EjecucionDeAtajos.plegar`.
  public static func plegar(_ texto: String) -> String {
    let sinTildes = texto.folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es")
    )
    let soloLetras = sinTildes.unicodeScalars.map { escalar -> Character in
      CharacterSet.alphanumerics.contains(escalar) ? Character(escalar) : " "
    }
    return String(soloLetras).split(separator: " ").joined(separator: " ")
  }

  /// «Rápido, ¿cuánto es…?», «Y ahora rápido, …» o «…, corto.»: la palabra
  /// sola, cerrada por su coma o su punto entre las primeras tres palabras,
  /// o abierta por uno al final. Sin el signo es parte de la frase —«me
  /// corté el pelo corto», «el auto más rápido»— y no un pedido.
  static func rapidezSuelta(en dicho: String, palabras: [String]) -> Bool {
    if palabras.count == 1 { return palabrasDeRapidez.contains(palabras[0]) }
    let conSignos = dicho.folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es")
    )
    let opciones = palabrasDeRapidez.joined(separator: "|")
    let alPrincipio = #"^\W*(\w+\s+){0,2}(\#(opciones))\s*[,.;:\u2014-]"#
    let alFinal = #"[,.;:\u2014-]\s*(\#(opciones))\W*$"#
    return conSignos.range(of: alPrincipio, options: .regularExpression) != nil
      || conSignos.range(of: alFinal, options: .regularExpression) != nil
  }

  /// La parte de las palabras que no son relleno.
  static func densidad(_ palabras: [String]) -> Double {
    guard !palabras.isEmpty else { return 0 }
    let contenido = palabras.filter { !palabrasVacias.contains($0) }
    return Double(contenido.count) / Double(palabras.count)
  }

  /// «Usa Opus», «con Sonnet», «pásate a Haiku».
  static func modeloNombrado(en palabras: [String]) -> NivelDeModelo? {
    for (i, palabra) in palabras.enumerated() {
      guard let nivel = NivelDeModelo(rawValue: palabra), i > 0 else { continue }
      let antes = palabras[i - 1]
      let dosAntes = i > 1 ? "\(palabras[i - 2]) \(antes)" : ""
      if verbosParaNombrar.contains(antes) || verbosParaNombrar.contains(dosAntes) { return nivel }
    }
    return nil
  }

  /// Si todo lo dicho, sin muletillas, se arma con frases triviales.
  ///
  /// Por frases y no por palabras sueltas a propósito: «qué es eso» son tres
  /// palabras que cada una podría ser trivial, y es una pregunta de verdad.
  static func esTrivial(_ palabras: [String]) -> Bool {
    let utiles = palabras.filter { !muletillas.contains($0) }
    // «Ya.», «Bueno.», «Oye»: sólo muletillas también es nada que pensar.
    if utiles.isEmpty { return !palabras.isEmpty && palabras.count <= RouterDeModelos.palabrasDeUnTurnoTrivial }
    guard utiles.count <= RouterDeModelos.palabrasDeUnTurnoTrivial else { return false }
    // Una sola palabra que pregunta qué se dijo.
    if utiles.count == 1, ["que", "como", "perdon"].contains(utiles[0]) { return true }
    var i = 0
    while i < utiles.count {
      let largo = (1...min(3, utiles.count - i)).reversed().first { n in
        frasesTriviales.contains(utiles[i..<(i + n)].joined(separator: " "))
      }
      guard let largo else { return false }
      i += largo
    }
    return true
  }

  static let frasesDeCambioDeTema = [
    "cambiando de tema", "otro tema", "otra cosa", "nada que ver", "olvida eso", "olvidalo",
    "pregunta aparte", "otra pregunta", "nuevo tema", "hablemos de otra",
  ]

  static let verbosParaNombrar: Set<String> = [
    "usa", "usar", "con", "ocupa", "pasate a", "cambia a", "pasa a", "contesta con", "responde con",
  ]

  static let frasesDeProfundidad = [
    "piensalo bien", "pensalo bien", "piensa bien", "piensalo harto", "analiza a fondo",
    "analizalo a fondo", "a fondo", "tomate tu tiempo", "con calma y en detalle", "razonalo bien",
  ]

  static let frasesDeRapidez = [
    "en corto", "respuesta corta", "se breve", "responde rapido", "contesta rapido", "rapidito",
    "corto y preciso", "en una frase", "en pocas palabras",
  ]

  /// Sueltas sólo cuentan como primera o última palabra: «rápido, ¿qué hora
  /// es?» es un pedido; «el auto más rápido» no.
  static let palabrasDeRapidez: Set<String> = ["rapido", "corto", "breve", "resumido"]

  static let muletillas: Set<String> = [
    "eh", "em", "mm", "este", "oye", "po", "pues", "bueno", "ah", "oh", "dilo", "ya", "mira",
  ]

  /// Lo que se puede decir sin que haya nada que pensar.
  static let frasesTriviales: Set<String> = [
    "hola", "holi", "buenas", "buenos dias", "buenas tardes", "buenas noches", "que tal",
    "como estas", "como estai", "como va", "si", "no", "ya", "ok", "okay", "oka", "dale", "listo",
    "perfecto", "bacan", "genial", "excelente", "gracias", "muchas gracias", "mil gracias",
    "de acuerdo", "correcto", "exacto", "claro", "obvio", "vale", "bueno", "entiendo",
    "entendido", "ya entiendo", "ah ya", "eso", "eso es", "eso mismo", "asi es", "repite",
    "repitelo", "repite eso", "repitemelo", "otra vez", "de nuevo", "que dijiste", "como dijiste",
    "no te escuche", "no te entendi", "confirmo", "confirmado", "chao", "adios", "nos vemos",
    "hasta luego", "por favor", "porfa", "si porfa", "esta bien", "todo bien", "super",
  ]

  /// Raíces que delatan una tarea de varios pasos. Plegadas: «diseña» queda
  /// «disena».
  static let raicesDeComplejidad = [
    "analiz", "planific", "compar", "estrategi", "arquitectur", "disena", "disenar", "codigo",
    "programa", "funcion", "script", "depur", "refactor", "algoritm", "optimiz", "evalua",
    "razona", "demuestr", "redacta", "redactar", "informe", "ensayo", "propuesta", "presupuest",
    "cronograma", "diagnostic", "investig",
  ]

  static let frasesDeComplejidad = [
    "paso a paso", "pros y contras", "ventajas y desventajas", "diferencia entre",
    "diferencias entre", "por que y como", "en detalle", "varios pasos", "un plan", "sql",
    "regex", "bug", "escribe un correo", "escribeme un correo", "escribe un texto",
  ]

  /// Lo que no carga contenido: artículos, preposiciones, pronombres,
  /// conjunciones y las muletillas del español hablado.
  static let palabrasVacias: Set<String> = muletillas.union([
    "el", "la", "los", "las", "un", "una", "unos", "unas", "lo", "le", "les", "de", "del", "a",
    "al", "en", "y", "o", "u", "e", "que", "se", "me", "te", "nos", "mi", "tu", "su", "es", "por",
    "para", "con", "sin", "pero", "como", "mas", "muy", "ya", "si", "no", "o sea", "sea", "cosa",
    "entonces", "osea", "tipo", "igual", "onda", "algo", "eso", "esto", "esa", "ese", "aca", "ahi",
  ])
}
