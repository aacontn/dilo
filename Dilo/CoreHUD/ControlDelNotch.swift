import Foundation

/// Corre `MaquinaDelNotch` y sus tiempos.
///
/// Separado de la máquina porque la máquina es pura y esto duerme: el
/// resultado se queda dos segundos y medio y después vuelve a reposo solo.
/// El reloj entra por parámetro (`DeadlineClock`, el mismo que usan las
/// esperas del pegado) para que un test adelante el tiempo en vez de
/// esperarlo — contra el reloj de pared, un test de tiempos afirma que el
/// runner fue rápido, no que el plazo se respetó (#82).
///
/// Sin AppKit ni SwiftUI: lo que sabe del HUD es que alguien quiere enterarse
/// cuando el estado cambia.
@MainActor
final class ControlDelNotch {
  private var maquina = MaquinaDelNotch()
  private let reloj: DeadlineClock
  private var vuelta: Task<Void, Never>?

  /// Se llama en cada cambio de estado, incluida la vuelta a reposo por
  /// tiempo cumplido.
  var alCambiar: ((EstadoDelNotch) -> Void)?

  var estado: EstadoDelNotch { maquina.estado }

  init(reloj: DeadlineClock = .continuous) {
    self.reloj = reloj
  }

  func recibir(_ evento: MaquinaDelNotch.Evento) {
    let anterior = maquina.estado
    let efectos = maquina.recibir(evento)
    for efecto in efectos {
      aplicar(efecto)
    }
    if maquina.estado != anterior {
      alCambiar?(maquina.estado)
    }
  }

  private func aplicar(_ efecto: MaquinaDelNotch.Efecto) {
    switch efecto {
    case .cancelarVuelta:
      vuelta?.cancel()
      vuelta = nil

    case let .programarVueltaAReposo(duracion, turno):
      vuelta?.cancel()
      vuelta = Task { [weak self, reloj] in
        try? await reloj.sleep(duracion)
        guard !Task.isCancelled else { return }
        self?.recibir(.expiroElResultado(turno: turno))
      }
    }
  }
}
