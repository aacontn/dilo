import AppKit
import SwiftUI

/// La vista que hospeda el HUD, con el mouse acotado a la silueta.
///
/// La ventana anfitriona es de tamaño fijo y mucho más ancha que la forma
/// —lleva holgura invisible para la sombra (ADR-0001)—. Mientras el HUD sólo
/// aparecía durante un dictado eso no importaba, porque la ventana no tomaba
/// el mouse nunca. Desde que el notch es un escenario permanente sí lo toma,
/// y una ventana de 628 puntos encima de la barra de menús que se traga cada
/// clic es exactamente el tipo de cosa que hace desinstalar una app.
///
/// `hitTest` devuelve nil fuera de `zonaInteractiva`, que es lo que hace que
/// el clic siga de largo hasta lo que haya debajo.
final class HUDHostingView<Content: View>: NSHostingView<Content>, HUDHostingViewProtocol {
  /// La franja que sí recibe el mouse, en coordenadas de esta vista. Nil
  /// mientras no hay ninguna, que es lo mismo que no recibir nada.
  var zonaInteractiva: CGRect?

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let zonaInteractiva else { return nil }
    // `point` llega en coordenadas de la supervista, que es la vista de marco
    // de la ventana; la zona está en las de esta.
    let local = convert(point, from: superview)
    guard zonaInteractiva.contains(local) else { return nil }
    return super.hitTest(point)
  }
}
