import AppKit

/// The setup conversation Dilo has to have with the user.
///
/// Accessibility is granted in System Settings, and macOS can hand the running
/// process a stale answer afterwards: the event tap keeps being refused until
/// the app is launched again. A transient HUD message is the wrong place to say
/// that, because it disappears while the user is still in System Settings. This
/// is a real dialog that waits, names the pane to open, and can relaunch Dilo.
@MainActor
enum PermissionAlert {
  /// True while a dialog is on screen, so a second trigger press cannot stack
  /// another one behind it.
  private(set) static var isPresenting = false

  /// Explains how to grant Accessibility after the system prompt was dismissed.
  static func requestAccessibilitySetup() {
    guard !isPresenting else { return }

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Dilo necesita Accesibilidad"
    alert.informativeText = """
      Activa Dilo en Ajustes del Sistema → Privacidad y seguridad → \
      Accesibilidad. Es lo que le deja poner tus palabras en la app donde estabas escribiendo.

      macOS sólo aplica este permiso cuando Dilo arranca, así que ábrelo de \
      nuevo una vez que lo hayas dado.
      """
    alert.addButton(withTitle: "Abrir Ajustes")
    alert.addButton(withTitle: "Cerrar y abrir de nuevo")
    alert.addButton(withTitle: "Después")

    switch run(alert) {
    case .alertFirstButtonReturn:
      openAccessibilitySettings()
    case .alertSecondButtonReturn:
      relaunch()
    default:
      break
    }
  }

  /// Shown once the permission reads as granted but the key still cannot be
  /// watched, which only a fresh launch clears.
  static func requestRelaunch() {
    guard !isPresenting else { return }

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Abre Dilo de nuevo para terminar"
    alert.informativeText = """
      El permiso ya está dado. macOS se lo aplica a Dilo sólo cuando la app \
      arranca, así que tu tecla de dictado no responde hasta que lo abras de nuevo.
      """
    alert.addButton(withTitle: "Cerrar y abrir de nuevo")
    alert.addButton(withTitle: "Después")

    if run(alert) == .alertFirstButtonReturn {
      relaunch()
    }
  }

  static func openAccessibilitySettings() {
    guard let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    ) else { return }
    NSWorkspace.shared.open(url)
  }

  /// Quits and comes back. `createsNewApplicationInstance` is required: without
  /// it macOS activates the copy that is still running instead of starting the
  /// replacement, and terminating only after the new instance is on its way
  /// keeps a gap from swallowing the relaunch.
  static func relaunch() {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true

    NSWorkspace.shared.openApplication(
      at: Bundle.main.bundleURL,
      configuration: configuration
    ) { _, _ in
      Task { @MainActor in
        NSApp.terminate(nil)
      }
    }
  }

  /// Dilo has no Dock icon, and an accessory app's alert opens behind
  /// whatever the user is looking at. The policy switches for as long as the
  /// dialog is up, the same trade the updater makes for its window.
  private static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
    isPresenting = true
    defer { isPresenting = false }

    let policy = NSApp.activationPolicy()
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    defer { NSApp.setActivationPolicy(policy) }

    return alert.runModal()
  }
}
