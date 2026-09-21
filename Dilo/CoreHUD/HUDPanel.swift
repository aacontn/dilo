import AppKit

/// The window that hosts the HUD.
///
/// Sits at `mainMenu + 3` — enough to own the notch strip above the menu bar
/// and full-screen apps without private-API window code (ADR-0001).
///
/// Sobrevivir a una app en pantalla completa nativa cuesta cuatro cosas a la
/// vez, y con tres no alcanza (issue #84 del árbol de origen): el nivel sobre la barra
/// de menús, `canJoinAllSpaces` para ir a todos los espacios,
/// `fullScreenAuxiliary` para que el espacio de pantalla completa la acepte, y
/// `nonactivatingPanel` + `isFloatingPanel` para que flote sin robarle el foco
/// a nadie. Es el mismo juego que el overlay del Dilo congelado armaba en
/// Tauri (`app/src-tauri/src/overlay.rs`: `PanelLevel::Status`,
/// `borderless().nonactivating_panel()`, `can_join_all_spaces()` +
/// `full_screen_auxiliary()`).
///
/// Lo que falta después de eso es el **orden**: al entrar a un espacio de
/// pantalla completa su ventana se ordena al frente, y una forma que ya
/// estaba mostrada queda detrás. Por eso `assertOverlayOrder()` y el
/// observador de cambio de espacio de `HUDStage`.
final class HUDPanel: NSPanel {
  init(contentRect: NSRect, contentView: NSView) {
    super.init(
      contentRect: contentRect,
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered,
      defer: false
    )

    // Flota sobre todo sin activar la app ni aparecer en el conmutador de
    // ventanas. Nunca se vuelve key salvo mientras sostiene un arrastre.
    //
    // Va **antes** del nivel a propósito: `isFloatingPanel = true` le pone
    // `.floating` (3) a la ventana de paso, y hacerlo después dejaría el HUD
    // debajo de la barra de menús y de cualquier app en pantalla completa.
    isFloatingPanel = true
    becomesKeyOnlyIfNeeded = true
    level = Self.overlayLevel
    // Sin la animación de aparición de AppKit: el resorte de la revelación es
    // el de la forma, y dos curvas encima se ven como un tropiezo.
    animationBehavior = .none
    isOpaque = false
    backgroundColor = .clear
    // The shell draws the design's shadow itself, so window shadow would
    // double it.
    hasShadow = false
    isMovable = false
    isMovableByWindowBackground = false
    // Display-only during dictation: clicks pass through everywhere and it
    // never takes focus. Drop Transcription flips this on while the shape is a
    // drop target or holding a transcript, and off again afterwards.
    ignoresMouseEvents = true
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    collectionBehavior = Self.overlayCollectionBehavior
    self.contentView = contentView
  }

  /// Sobre la barra de menús y sobre la ventana de una app en pantalla
  /// completa, sin APIs privadas (ADR-0001). No sube más: por encima de esto
  /// viven las alertas del sistema y el salvapantallas, y el HUD de un
  /// dictado no le gana a ninguno de los dos.
  static let overlayLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

  /// `canJoinAllSpaces` la lleva a cada espacio; `fullScreenAuxiliary` es lo
  /// que hace que un espacio de pantalla completa la acepte en vez de
  /// esconderla; `stationary` la deja quieta en Mission Control, e
  /// `ignoresCycle` la saca de ⌘Tab.
  static let overlayCollectionBehavior: NSWindow.CollectionBehavior =
    [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

  /// Reafirma nivel, comportamiento y orden, y muestra la ventana.
  ///
  /// Los tres se reponen juntos a propósito: AppKit baja el nivel efectivo de
  /// una ventana que entra a un espacio de pantalla completa, y reordenarla
  /// sin reponer el nivel la deja al frente del espacio equivocado. Se llama
  /// en cada `mount` y en cada cambio de espacio activo.
  func assertOverlayOrder() {
    level = Self.overlayLevel
    collectionBehavior = Self.overlayCollectionBehavior
    orderFrontRegardless()
  }

  /// Whether the shape currently receives the mouse. Kept as a named property
  /// rather than callers setting `ignoresMouseEvents` directly, so the one
  /// place this is allowed to change stays greppable.
  var acceptsMouse: Bool {
    get { !ignoresMouseEvents }
    set { ignoresMouseEvents = !newValue }
  }

  /// Key only while the shape is a drop target or holding a transcript, which
  /// is the only time it wants the mouse at all.
  ///
  /// NotchDrop's window can become key and its drops land instantly; a window
  /// that can never become key is a slower path for the dragging source. The
  /// panel is still `.nonactivatingPanel`, so this never activates Dilo or
  /// takes the frontmost app's focus — and during dictation, when the focused
  /// control is the whole point, `acceptsMouse` is false and this is false
  /// with it.
  override var canBecomeKey: Bool { acceptsMouse }

  /// The frame is computed from the screen, not proposed by AppKit; without
  /// this the window gets pushed below the menu bar strip it exists to cover.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}
