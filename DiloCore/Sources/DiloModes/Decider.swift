import Foundation

/// El contrato de decisión del spec §7.
///
/// Hay puntos de Dilo que son una **decisión**, no una generación: qué modo
/// aplica a este dictado, si esto es texto para pegar o una orden para Dilo,
/// si la frase de la reunión es un compromiso. Un `Decider` recibe texto más
/// contexto y una pregunta tipada, y devuelve la respuesta con su
/// probabilidad. Nada más: no genera, no oye audio, no conversa.
///
/// Tres implementaciones previstas, en este orden: reglas (la de acá, por
/// defecto y sin modelo), FoundationModels con generación guiada cuando las
/// reglas no alcancen, y una nube compatible con `/v1/systemone` si alguna
/// vez demuestra ser mejor en español. Laya quedó fuera el 2026-09-20: 65 %
/// contra el 100 % de la app al frente.
public protocol Decider: Sendable {
  func decidir(
    _ texto: String,
    _ pregunta: PreguntaTipada,
    en contexto: ContextoDeDecision
  ) async -> RespuestaTipada
}

/// Las tres formas de pregunta. Son las del formato que ya es estándar de
/// hecho entre los "System One": elegir una opción, puntuar, o sí/no.
public enum PreguntaTipada: Equatable, Sendable {
  /// Elegir una de hasta 255 opciones. La que usa Dilo para "¿qué modo?".
  case eleccion([String])
  /// Puntuar entre 2 y 10 niveles.
  case puntaje(ClosedRange<Int>)
  /// Sí o no. La que abrirá la puerta de comandos en v3: ¿esto es una orden
  /// para Dilo o es texto?
  case siNo

  public var opciones: [String] {
    switch self {
    case let .eleccion(opciones): opciones
    case let .puntaje(rango): rango.map(String.init)
    case .siNo: ["sí", "no"]
    }
  }
}

/// Lo que rodea al texto en el momento de decidir.
public struct ContextoDeDecision: Equatable, Sendable {
  /// La app al frente cuando empezó el dictado. Es la señal más fuerte que
  /// existe y la más barata: no cuesta ni un milisegundo.
  public var appAlFrente: String?
  public var modoActivo: String?
  public var ultimasLineas: [String]

  public init(
    appAlFrente: String? = nil,
    modoActivo: String? = nil,
    ultimasLineas: [String] = []
  ) {
    self.appAlFrente = appAlFrente
    self.modoActivo = modoActivo
    self.ultimasLineas = ultimasLineas
  }
}

public struct RespuestaTipada: Equatable, Sendable {
  public var valor: String
  /// Entre 0 y 1. Calibrada en el sentido modesto de que un empate resuelto a
  /// la fuerza vale menos que una app que coincide exacto: quien la lee puede
  /// decidir no hacerle caso.
  public var probabilidad: Double
  /// Qué señal ganó, en una frase corta. Va al historial cuando "un atajo,
  /// Dilo decide" eligió el modo: un modo que aparece sin que nadie apretara
  /// su tecla tiene que poder explicarse, o la próxima vez no se sabe si
  /// corregir el dictado o corregir la regla. Vacío es "no lo dice".
  public var porQue: String

  public init(valor: String, probabilidad: Double, porQue: String = "") {
    self.valor = valor
    self.probabilidad = probabilidad
    self.porQue = porQue
  }
}
