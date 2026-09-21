import AppKit
import SwiftUI

/// Owns one fixed, borderless Settings surface for the app's lifetime.
///
/// La ventana en sí —sin barra de título, de tamaño fijo, centrada donde está
/// el puntero— la pone `VentanaSinBarra`, que Primeros pasos usa igual.
@MainActor
final class SettingsWindowController: NSWindowController {
  private static let windowSize = NSSize(width: 860, height: 600)

  convenience init(
    settings: AppSettings,
    sounds: HUDSounds,
    runtimeState: SettingsRuntimeState,
    usageTracker: UsageTracker,
    updater: SparkleUpdaterService,
    launchAtLogin: LaunchAtLoginService
  ) {
    let window = VentanaSinBarra(
      tamano: Self.windowSize,
      titulo: "Ajustes de Dilo",
      contenido: NSViewController()
    )
    window.contentViewController = NSHostingController(
      rootView: SettingsView(
        settings: settings,
        sounds: sounds,
        runtimeState: runtimeState,
        usageTracker: usageTracker,
        updater: updater,
        launchAtLogin: launchAtLogin,
        onClose: { [weak window] in window?.close() }
      )
    )
    window.setContentSize(Self.windowSize)
    self.init(window: window)
  }

  func show(reclamandoElFoco: Bool = false) {
    (window as? VentanaSinBarra)?.mostrar(reclamandoElFoco: reclamandoElFoco)
  }
}
