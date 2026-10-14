import Foundation

/// Qué modo aplica a este dictado.
///
/// Dos caminos, en este orden: la tecla que apretaste, y —sólo si lo pediste—
/// las reglas. La tecla siempre gana: es lo que la persona dijo explícitamente
/// y ningún decididor tiene derecho a contradecirla.
public enum ResolucionDeModo {
  public enum Razon: Equatable, Sendable {
    case atajo
    /// `porQue` es la regla que ganó, en las palabras que ve la persona y que
    /// el historial guarda. Un modo que se aplicó sin que nadie apretara su
    /// tecla tiene que poder explicarse.
    case reglas(probabilidad: Double, porQue: String)
    case ninguna

    /// Cómo se cuenta esta elección en el historial. Nil cuando no hay nada
    /// que contar: la tecla que se apretó ya lo dice todo.
    public var explicacion: String? {
      switch self {
      case .atajo, .ninguna: nil
      case let .reglas(_, porQue):
        porQue.isEmpty ? "Dilo lo eligió" : "Dilo lo eligió: \(porQue)"
      }
    }
  }

  public struct Eleccion: Equatable, Sendable {
    public var modo: Modo?
    public var razon: Razon
    /// Qué señal eligió el modo cuando no lo eligió una tecla. Es lo que la
    /// muesca dice al lado del nombre (`EleccionAutomatica.enLaMuesca`).
    public var senal: EleccionAutomatica.Senal?

    public init(modo: Modo?, razon: Razon, senal: EleccionAutomatica.Senal? = nil) {
      self.modo = modo
      self.razon = razon
      self.senal = senal
    }

    /// El nombre del modo y, si lo eligió Dilo, por qué: «Correo · lo
    /// dijiste». Nil sin modo.
    public var enLaMuesca: String? {
      guard let modo else { return nil }
      guard let senal else { return modo.nombre }
      return "\(modo.nombre) · \(EleccionAutomatica.enLaMuesca(senal))"
    }
  }

  /// El modo cuya tecla es ésta, o nil. Una tecla que no es de ningún modo no
  /// es un error: es el dictado normal, que sale limpio sin pasar por un LLM.
  public static func porAtajo(_ gatillo: Gatillo, entre modos: [Modo]) -> Modo? {
    modos.first { $0.gatillo?.disparaLoMismoQue(gatillo) ?? false }
  }

  /// El modo que las reglas eligen para este texto en esta app.
  ///
  /// Devuelve nil cuando el decididor no se la juega. El umbral existe porque
  /// pegar un correo reescrito donde alguien dictó un comando es peor que no
  /// reescribir nada: ante la duda, el dictado sale como salió.
  public static func porReglas(
    texto: String,
    contexto: ContextoDeDecision,
    modos: [Modo],
    decider: some Decider,
    umbral: Double = 0.5
  ) async -> Eleccion {
    guard !modos.isEmpty else { return Eleccion(modo: nil, razon: .ninguna) }
    let respuesta = await decider.decidir(
      texto, .eleccion(modos.map(\.id)), en: contexto
    )
    guard respuesta.probabilidad >= umbral, let modo = modos.modo(respuesta.valor) else {
      return Eleccion(modo: nil, razon: .ninguna)
    }
    return Eleccion(
      modo: modo,
      razon: .reglas(probabilidad: respuesta.probabilidad, porQue: respuesta.porQue)
    )
  }

  /// El camino completo, tal como lo usa la app al terminar un dictado.
  ///
  /// - Parameter unAtajoDiloDecide: la opción del spec §7 ("primer uso, v1.5").
  ///   **Apagada de fábrica**: quien no la prende tiene exactamente el
  ///   comportamiento de siempre, una tecla por modo y nada más.
  public static func resolver(
    gatillo: Gatillo?,
    texto: String,
    contexto: ContextoDeDecision,
    modos: [Modo],
    unAtajoDiloDecide: Bool,
    decider: some Decider,
    umbral: Double = 0.5
  ) async -> Eleccion {
    if let gatillo, let modo = porAtajo(gatillo, entre: modos) {
      return Eleccion(modo: modo, razon: .atajo)
    }
    guard unAtajoDiloDecide else { return Eleccion(modo: nil, razon: .ninguna) }
    return await porReglas(
      texto: texto, contexto: contexto, modos: modos,
      decider: decider, umbral: umbral
    )
  }

  /// Lo que la persona eligió para este dictado, si eligió algo.
  public enum ALaMano: Equatable, Sendable {
    /// Nadie eligió: deciden las señales.
    case nadie
    /// La tecla de un modo, las flechas o una nota: gana siempre, y nil es
    /// «sin modo» dicho a propósito.
    case eligio(Modo?)
  }

  /// El camino completo al terminar un dictado, en el orden de la fase 4:
  /// tecla o flechas > **palabra disparadora** > modo del atajo general (el
  /// del panel del hover) > **sitio** > **app** > palabras clave.
  ///
  /// La disparadora va por encima del hover porque se dijo para este
  /// dictado; el hover es una preferencia que queda. Funciona aunque «Dilo
  /// decide» esté apagado: es explícita. Sitio, app y palabras clave sólo con
  /// «Dilo decide» prendido, como siempre.
  ///
  /// - Returns: la elección y el texto que sigue, sin la disparadora si la
  ///   hubo.
  public static func alTerminar(
    texto: String,
    aLaMano: ALaMano,
    delAtajoGeneral: Modo?,
    contexto: ContextoDeDecision,
    modos: [Modo],
    unAtajoDiloDecide: Bool,
    decider: some Decider,
    umbral: Double = 0.5
  ) async -> (eleccion: Eleccion, texto: String) {
    if case let .eligio(modo) = aLaMano {
      return (Eleccion(modo: modo, razon: modo == nil ? .ninguna : .atajo), texto)
    }
    if let hallazgo = PalabraDisparadora.buscar(en: texto, modos: modos),
      let modo = modos.modo(hallazgo.modoID) {
      let eleccion = Eleccion(
        modo: modo,
        razon: .reglas(probabilidad: 1, porQue: "dijiste «\(hallazgo.disparadora)»"),
        senal: .palabra(hallazgo.disparadora)
      )
      return (eleccion, hallazgo.textoSinElla)
    }
    if let delAtajoGeneral {
      return (Eleccion(modo: delAtajoGeneral, razon: .atajo), texto)
    }
    guard unAtajoDiloDecide, !modos.isEmpty else {
      return (Eleccion(modo: nil, razon: .ninguna), texto)
    }
    if let sitio = contexto.sitio, let modo = EleccionAutomatica.porSitio(sitio, modos: modos) {
      let eleccion = Eleccion(
        modo: modo,
        razon: .reglas(probabilidad: 0.95, porQue: "estabas en \(sitio)"),
        senal: .sitio(sitio)
      )
      return (eleccion, texto)
    }
    var eleccion = await porReglas(
      texto: texto, contexto: contexto, modos: modos, decider: decider, umbral: umbral
    )
    if eleccion.modo != nil, case let .reglas(probabilidad, _) = eleccion.razon {
      // 0,95 es la app; lo demás, las palabras clave (`DeciderPorReglas`).
      eleccion.senal = probabilidad >= 0.95
        ? .app(contexto.appAlFrente ?? contexto.bundleID ?? "") : .palabrasClave
    }
    return (eleccion, texto)
  }
}
