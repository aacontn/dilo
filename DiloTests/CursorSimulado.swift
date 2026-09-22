import CoreGraphics

/// Dónde está el puntero, para los tests que ejercitan el hover de la muesca.
///
/// Es la costura que `MonitorDelPuntero` abre con `posicion`, por el mismo
/// motivo que `DrivenClock` abre la del reloj: el monitor sondea la posición
/// cada 80 ms, así que un test que adelanta el reloj para pasar el retardo del
/// hover haría que el escenario leyera `NSEvent.mouseLocation` —el cursor de
/// verdad de quien corre los tests— y cerrara el hover que estaba afirmando.
/// Afirmaría dónde quedó el mouse, no que el hover funcione.
///
/// Empieza lejos de cualquier silueta: un test que no dice dónde está el
/// puntero está diciendo que está en otra parte.
@MainActor
final class CursorSimulado {
  var punto = CGPoint(x: -1_000, y: -1_000)

  init() {}
}
