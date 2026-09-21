import AppKit

/// La superficie sin barra de título que comparten Ajustes y Primeros pasos.
///
/// Las dos son lo mismo: una ventana de tamaño fijo, sin cromo del sistema,
/// que se puede hacer key, que se cierra con Escape y que aparece centrada en
/// la pantalla donde está el puntero. Estaba escrita una vez dentro del
/// controlador de Ajustes; el onboarding la necesitaba igual, y dos copias de
/// una ventana derivan en dos ventanas distintas.
@MainActor
final class VentanaSinBarra: NSWindow {
  private var yaSePosiciono = false

  init(tamano: NSSize, titulo: String, contenido: NSViewController) {
    super.init(
      contentRect: NSRect(origin: .zero, size: tamano),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    contentViewController = contenido
    title = titulo
    level = .normal
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isMovable = true
    // El arrastre lo hace el encabezado (SettingsWindowDragHandle); arrastrar
    // desde cualquier parte del fondo movería la ventana al elegir en una
    // lista.
    isMovableByWindowBackground = false
    isReleasedWhenClosed = false
    minSize = tamano
    maxSize = tamano
    setContentSize(tamano)
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func cancelOperation(_ sender: Any?) {
    close()
  }

  /// La trae al frente, y la primera vez la centra donde está el puntero. Las
  /// siguientes respeta dónde la dejó la persona.
  func mostrar() {
    if !yaSePosiciono {
      centrarEnLaPantallaDelPuntero()
      yaSePosiciono = true
    }
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
  }

  private func centrarEnLaPantallaDelPuntero() {
    let puntero = NSEvent.mouseLocation
    let pantalla = NSScreen.screens.first { $0.frame.contains(puntero) } ?? NSScreen.main
    guard let visible = pantalla?.visibleFrame else {
      center()
      return
    }
    setFrameOrigin(
      NSPoint(
        x: visible.midX - frame.width / 2,
        y: visible.midY - frame.height / 2
      )
    )
  }
}
