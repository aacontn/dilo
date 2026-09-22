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

  init(reloj: DeadlineClock = .continuous) {
    self.reloj = reloj
  }

  func empezar() {
    guard monitor == nil else { return }
    monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
      MainActor.assumeIsolated {
        // La posición se lee de `NSEvent.mouseLocation` y no del evento: el
        // evento trae coordenadas de su ventana, y acá no hay ninguna.
        self?.alMoverse?(NSEvent.mouseLocation)
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
        alMoverse?(NSEvent.mouseLocation)
      }
    }
  }
}
