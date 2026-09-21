import AppKit
import SwiftUI

/// La ventana de Primeros pasos: una sola, viva mientras dure la app.
///
/// Comparte superficie con Ajustes (`VentanaSinBarra`) porque es la misma
/// ventana con otro contenido: el mismo encabezado, el mismo cromo y el mismo
/// Escape para cerrar.
@MainActor
final class OnboardingWindowController: NSWindowController {
  private static let tamano = NSSize(width: 720, height: 560)

  convenience init(settings: AppSettings, permisos: EstadoDePermisos) {
    let ventana = VentanaSinBarra(
      tamano: Self.tamano,
      titulo: "Primeros pasos con Dilo",
      contenido: NSViewController()
    )
    ventana.contentViewController = NSHostingController(
      rootView: OnboardingView(
        settings: settings,
        permisos: permisos,
        onClose: { [weak ventana] in ventana?.close() }
      )
    )
    ventana.setContentSize(Self.tamano)
    self.init(window: ventana)
  }

  func mostrar() {
    (window as? VentanaSinBarra)?.mostrar()
  }
}
