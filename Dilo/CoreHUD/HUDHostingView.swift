import AppKit
import SwiftUI

/// La vista que hospeda el HUD, con el mouse acotado a la silueta.
///
/// La ventana anfitriona es más ancha que la forma —lleva holgura invisible
/// para la sombra y para el rebote de la revelación (ADR-0001)—, así que sólo
/// la silueta puede responderle al mouse: `hitTest` devuelve nil fuera de
/// `zonaInteractiva`.
///
/// **Y acá es donde el escenario se entera de que el puntero llegó.** La
/// ventana ya no ignora el mouse nunca (`HUDPanel`), así que un
/// `NSTrackingArea` `.activeAlways` sobre la vista entera ve entrar, moverse
/// y salir el puntero sin depender de que la app esté activa ni de que la
/// ventana sea key. Quién decide si ese punto cuenta como «encima de la
/// silueta» es `HUDStage`, con la misma geometría que arma `zonaInteractiva`:
/// acá sólo se reporta dónde está.
///
/// El área se arma con `.inVisibleRect` a propósito: sigue el tamaño de la
/// vista sola, y la vista cambia de tamaño cada vez que el hover abre la
/// forma. Un rect fijo habría que rearmarlo en cada cambio, que es el paso
/// que se olvida.
final class HUDHostingView<Content: View>: NSHostingView<Content>, HUDHostingViewProtocol {
  /// La franja que sí recibe el mouse, en coordenadas de esta vista. Nil
  /// mientras no hay ninguna, que es lo mismo que no recibir nada.
  var zonaInteractiva: CGRect?

  /// El puntero está en este punto, en coordenadas de pantalla.
  var alMoverseElPuntero: ((CGPoint) -> Void)?
  /// El puntero se fue de la ventana entera.
  var alSalirElPuntero: (() -> Void)?

  private var areaDeSeguimiento: NSTrackingArea?

  /// Fuera de la silueta devuelve nil, y AppKit sigue buscando: dentro de una
  /// jerarquía el evento pasa a la vista de atrás, y a nivel de ventana el
  /// punto queda sin vista que lo reclame sobre un panel transparente, que es
  /// lo que deja el clic en la app de abajo. Es lo que hacen NotchDrop y
  /// Boring Notch, y reemplaza al `ignoresMouseEvents` que se conmutaba a
  /// mano: una ventana que ignora el mouse tampoco recibe hover, así que el
  /// encendido llegaba tarde o nunca (tres intentos, 2026-09-22).
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let zonaInteractiva else { return nil }
    // `point` llega en coordenadas de la supervista, que es la vista de marco
    // de la ventana; la zona está en las de esta.
    let local = convert(point, from: superview)
    guard zonaInteractiva.contains(local) else { return nil }
    return super.hitTest(point)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let areaDeSeguimiento { removeTrackingArea(areaDeSeguimiento) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    areaDeSeguimiento = area
  }

  override func mouseEntered(with event: NSEvent) {
    reportar(event)
  }

  override func mouseMoved(with event: NSEvent) {
    reportar(event)
  }

  /// Una salida sólo cuenta si el puntero de verdad quedó fuera de la vista.
  ///
  /// El hover agranda la ventana, y AppKit rearma el área de seguimiento con
  /// el puntero adentro: si en ese rearme llega un `mouseExited`, cerrar sin
  /// mirar dónde está el puntero es exactamente lo que hacía el `onHover` de
  /// SwiftUI —abría el panel y lo cerraba en el mismo gesto—. Con el punto
  /// todavía adentro, es un movimiento más y el escenario decide.
  override func mouseExited(with event: NSEvent) {
    guard !bounds.contains(convert(event.locationInWindow, from: nil)) else {
      reportar(event)
      return
    }
    alSalirElPuntero?()
  }

  /// En coordenadas de pantalla y no de la vista: quien decide si el punto
  /// cae en la silueta es el escenario, que la mide contra la pantalla
  /// (`HUDNotchGeometry.siluetaEnPantalla`). Convertir en un solo lugar evita
  /// que los dos lados usen orígenes distintos.
  private func reportar(_ event: NSEvent) {
    guard let window else { return }
    alMoverseElPuntero?(window.convertPoint(toScreen: event.locationInWindow))
  }
}
