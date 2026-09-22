import AppKit

/// Dónde está el puntero cuando la ventana del HUD no lo recibe.
///
/// En reposo el panel pone `ignoresMouseEvents = true` para que los clics de
/// la barra de menús pasen de largo, y una ventana que ignora el mouse tampoco
/// recibe hover: sin esto no habría forma de enterarse de que el puntero llegó
/// a la silueta. Es lo mismo que hacen Boring Notch y Notch Buddy, y lo que
/// permite que la ventana sólo tome el mouse encima de la forma.
///
/// Dos piezas y no una:
///
/// - un **monitor global** de `.mouseMoved`, que ve los eventos que van a las
///   demás apps — es decir, justo los de mientras el HUD los ignora—, y
/// - un **sondeo** corto mientras el puntero está encima, porque desde que el
///   panel toma el mouse los eventos son nuestros y el monitor global deja de
///   verlos. Sin él, el puntero se iría de la silueta y la ventana se quedaría
///   tomando clics.
///
/// Un monitor global de eventos de mouse no pide permiso de accesibilidad
/// —sólo los de teclado lo piden—, así que esto no le agrega ningún diálogo a
/// nadie.
///
/// **Es la única fuente de «está encima / no está».** El `onHover` de SwiftUI
/// quedó afuera a propósito: la ventana ignora el mouse justo mientras el
/// puntero entra, así que nunca recibe el `mouseEntered` de esa entrada, y
/// cuando la ventana cambia de tamaño —que es lo que el hover hace— AppKit
/// rearma el área de seguimiento y manda un `mouseExited` que cerraba el panel
/// recién abierto. Dos fuentes peleándose por el mismo estado es lo que dejaba
/// el hover sin hacer nada.
@MainActor
final class MonitorDelPuntero {
  /// Cada cuánto se pregunta dónde está el puntero mientras está sobre la
  /// silueta. Doce veces por segundo alcanza para notar que se fue, y no es un
  /// temporizador corriendo en reposo: el sondeo se apaga en cuanto sale.
  static let cadenciaDelSondeo = Duration.milliseconds(80)

  /// Se llama con la posición del puntero en coordenadas de pantalla.
  var alMoverse: ((CGPoint) -> Void)?

  private var monitor: Any?
  private var sondeo: Task<Void, Never>?
  private var sondeando = false
  private let reloj: DeadlineClock
  /// Dónde está el puntero ahora mismo, en coordenadas de pantalla.
  /// Inyectable por el mismo motivo que el reloj: un test que lea el mouse de
  /// verdad afirma dónde quedó el cursor de quien corre los tests, no que la
  /// máquina del hover funcione.
  private let posicion: @MainActor () -> CGPoint

  init(
    reloj: DeadlineClock = .continuous,
    posicion: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation }
  ) {
    self.reloj = reloj
    self.posicion = posicion
  }

  func empezar() {
    guard monitor == nil else { return }
    monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
      MainActor.assumeIsolated {
        // La posición se lee aparte y no del evento: el evento trae
        // coordenadas de su ventana, y acá no hay ninguna.
        guard let self else { return }
        self.alMoverse?(self.posicion())
      }
    }
  }

  func detener() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    seguirDeCerca(false)
  }

  /// Enciende o apaga el sondeo. Idempotente a propósito: el llamador lo
  /// invoca en cada movimiento y volver a armar la tarea cada 80 ms sería un
  /// sondeo que nunca llega a sondear.
  func seguirDeCerca(_ encendido: Bool) {
    guard encendido != sondeando else { return }
    sondeando = encendido
    sondeo?.cancel()
    guard encendido else {
      sondeo = nil
      return
    }
    sondeo = Task { [weak self, reloj] in
      while !Task.isCancelled {
        try? await reloj.sleep(Self.cadenciaDelSondeo)
        guard !Task.isCancelled, let self else { return }
        self.alMoverse?(self.posicion())
      }
    }
  }
}
