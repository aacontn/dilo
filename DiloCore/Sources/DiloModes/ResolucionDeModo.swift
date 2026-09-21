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

    public init(modo: Modo?, razon: Razon) {
      self.modo = modo
      self.razon = razon
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
}
