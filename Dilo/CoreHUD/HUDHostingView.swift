import AppKit
import SwiftUI

/// La vista que hospeda el HUD, con el mouse acotado a la silueta.
///
/// La ventana anfitriona es más ancha que la forma —lleva holgura invisible
/// para la sombra y para el rebote de la revelación (ADR-0001)—, así que
/// mientras toma el mouse sólo la silueta puede responderle: `hitTest`
/// devuelve nil fuera de `zonaInteractiva`.
///
/// **Esto acota, no libera.** Un `hitTest` nil hace que el clic se pierda, no
/// que llegue a la ventana de abajo: eso es cosa de `ignoresMouseEvents`, que
/// `HUDStage` conmuta con `MonitorDelPuntero`, y del tamaño de la ventana en
/// reposo (`HUDNotchGeometry.EncuadreDeLaVentana`). Los ~190 puntos muertos
/// bajo la muesca que Alfonso reportó el 2026-09-22 salían justo de confiar
/// sólo en esto.
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
