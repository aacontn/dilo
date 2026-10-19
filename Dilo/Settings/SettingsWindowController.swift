import AppKit
import DiloModes
import SwiftUI

/// Owns one fixed, borderless Settings surface for the app's lifetime.
///
/// La ventana en sí —sin barra de título, de tamaño fijo, centrada donde está
/// el puntero— la pone `VentanaSinBarra`, que Primeros pasos usa igual.
@MainActor
final class SettingsWindowController: NSWindowController {
  private static let windowSize = NSSize(
    width: SettingsView.tamano.width, height: SettingsView.tamano.height
  )

  private var runtimeState: SettingsRuntimeState?
  private weak var settings: AppSettings?
  #if DEBUG
    private var vigia: VigiaDeCuelgues?
  #endif

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
    self.runtimeState = runtimeState
    self.settings = settings
    window.alCerrar = { [weak self] in self?.alCerrar() }
  }

  /// Abrir es también volver a preguntar por las claves (una lectura, fuera
  /// del hilo principal): pudieron cambiar por fuera mientras estaba cerrada.
  func show(reclamandoElFoco: Bool = false) {
    if let runtimeState, !runtimeState.ventanaAbierta {
      if let settings {
        runtimeState.seccionPedida = SeccionAlAbrir.decidir(
          pedida: runtimeState.seccionPedida,
          ultima: settings.ultimaSeccionDeAjustes,
          cerradaEn: settings.ajustesCerradosEn,
          ahora: .now
        )
      }
      runtimeState.claves.olvidar()
      runtimeState.ventanaAbierta = true
      #if DEBUG
        let vigia = VigiaDeCuelgues { [weak runtimeState] in
          runtimeState?.seccionActual?.rawValue ?? "?"
        }
        vigia.empezar()
        self.vigia = vigia
      #endif
    }
    (window as? VentanaSinBarra)?.mostrar(reclamandoElFoco: reclamandoElFoco)
  }

  private func alCerrar() {
    runtimeState?.ventanaAbierta = false
    if let settings, let seccion = runtimeState?.seccionActual {
      settings.ultimaSeccionDeAjustes = seccion.rawValue
      settings.ajustesCerradosEn = .now
    }
    #if DEBUG
      vigia?.parar()
      vigia = nil
    #endif
  }
}
