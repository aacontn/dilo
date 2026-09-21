import AppKit

/// La superficie sin barra de título que comparten Ajustes y Primeros pasos.
///
/// Las dos son lo mismo: una ventana de tamaño fijo, sin cromo del sistema,
/// que se puede hacer key, que se cierra con Escape y que aparece centrada en
/// la pantalla donde está el puntero. Estaba escrita una vez dentro del
/// controlador de Ajustes; el onboarding la necesitaba igual, y dos copias de
/// una ventana derivan en dos ventanas distintas.
@MainActor
final class VentanaSinBarra: NSWindow, NSWindowDelegate {
  private var yaSePosiciono = false
  /// La política a la que hay que volver cuando esta ventana se cierre, si es
  /// que hubo que cambiarla para traerla al frente.
  private var politicaADevolver: NSApplication.ActivationPolicy?

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
    delegate = self
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func cancelOperation(_ sender: Any?) {
    close()
  }

  /// La trae al frente, y la primera vez la centra donde está el puntero. Las
  /// siguientes respeta dónde la dejó la persona.
  ///
  /// - Parameter reclamandoElFoco: para las ventanas que aparecen **sin que
  ///   nadie las pida** —los Primeros pasos al instalar, las Novedades al
  ///   actualizar—. Dilo vive en la barra de menús, y una app accesoria que
  ///   ordena al frente sin que nadie la haya activado deja su ventana detrás
  ///   de lo que la persona esté mirando. Se pasa a app normal mientras la
  ///   ventana esté abierta y se vuelve a accesoria al cerrarla, que es el
  ///   mismo trato que ya hacen el updater y los diálogos de permisos.
  func mostrar(reclamandoElFoco: Bool = false) {
    if !yaSePosiciono {
      centrarEnLaPantallaDelPuntero()
      yaSePosiciono = true
    }
    if reclamandoElFoco, NSApp.activationPolicy() != .regular {
      politicaADevolver = NSApp.activationPolicy()
      NSApp.setActivationPolicy(.regular)
    }
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    guard let politica = politicaADevolver else { return }
    politicaADevolver = nil
    NSApp.setActivationPolicy(politica)
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
