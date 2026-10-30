import Foundation

/// Cuándo la **escucha de nombres** tiene el micrófono abierto y cuándo no.
///
/// Prendida en Ajustes, escucha salvo que algo la pause: el dictado, la
/// conversación y la reunión ya usan el micrófono —y lo que se diga ahí no es
/// un llamado—, y con la pantalla bloqueada no hay nadie. Cada motivo se
/// prende y se apaga por separado, y escucha sólo cuando no queda ninguno.
/// Puro.
public struct PausasDeLaEscucha: Equatable, Sendable {
  public enum Motivo: String, CaseIterable, Sendable {
    case dictado
    case conversacion
    case reunion
    /// O el Mac durmiendo: tampoco hay nadie.
    case pantallaBloqueada
    /// No hay Parakeet en disco: la escucha transcribe con él y no hay con
    /// qué oír.
    case sinMotor
    /// El detector de voz no está y no se pudo bajar (sin red la primera
    /// vez).
    case sinDetector
    /// Ningún agente tiene «Se llama por nombre».
    case sinNombres
    /// No hay un micrófono que se pueda tener abierto: el único es un
    /// Bluetooth que nadie eligió (`PlanDeMicrofono.paraLaEscucha`), o el
    /// que hay no abrió.
    case sinMicrofono
  }

  public enum Estado: Equatable, Sendable {
    case apagada
    case pausada(Set<Motivo>)
    case escuchando
  }

  public var prendida: Bool
  public private(set) var motivos: Set<Motivo> = []

  public init(prendida: Bool = false) {
    self.prendida = prendida
  }

  public var estado: Estado {
    guard prendida else { return .apagada }
    return motivos.isEmpty ? .escuchando : .pausada(motivos)
  }

  /// Si el micrófono tiene que estar abierto ahora.
  public var abreElMicrofono: Bool { estado == .escuchando }

  /// Prende o apaga un motivo. Devuelve si cambió si el micrófono va
  /// abierto o no.
  @discardableResult
  public mutating func marcar(_ motivo: Motivo, _ presente: Bool) -> Bool {
    let antes = abreElMicrofono
    if presente { motivos.insert(motivo) } else { motivos.remove(motivo) }
    return antes != abreElMicrofono
  }

  /// El motivo que se dice en Ajustes debajo del interruptor: el primero
  /// que la persona puede arreglar. Nil si escucha o está apagada.
  public var motivoPrincipal: Motivo? {
    guard case let .pausada(motivos) = estado else { return nil }
    let orden: [Motivo] = [.sinMotor, .sinDetector, .sinNombres, .sinMicrofono, .dictado, .conversacion, .reunion, .pantallaBloqueada]
    return orden.first(where: motivos.contains)
  }
}
