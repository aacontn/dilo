import AppKit
import SwiftUI

/// The one shape, and who is holding it.
///
/// Dilo has a single HUD: one panel, one hosting view, one place on screen.
/// Two features want it — Direct Dictation and Drop Transcription — and they
/// must never both have it. This owns the window, the display choice, the
/// mounting, and the arbitration; the feature controllers own what their
/// surface says. Neither of them touches `NSPanel`.
///
/// It also owns the status message band, because "the HUD is the only surface
/// for status and error messages" (CONTEXT.md) is a property of the HUD, not of
/// either feature: a file that cannot be read says so in the same place a
/// secure field does.
@MainActor
final class HUDStage {
  /// How long the retract animation needs before the panel can order out.
  /// A perceptual duration rather than the spring's settling time, per
  /// WWDC23 "Animate with springs": don't wait for settling.
  /// Internal so a test can wait out the retract rather than guess at it.
  static let dismissDuration = Duration.milliseconds(350)
  private static let messageDuration = Duration.seconds(2)

  /// Who holds the shape. `message` is its own occupant rather than a mode of
  /// dictation: a message can interrupt either feature and outranks both.
  enum Occupant: Equatable {
    case none
    case dictation
    case message
    case drop
  }

  private(set) var occupant = Occupant.none

  /// El estado de sesión que el escenario está sosteniendo. Hoy siempre
  /// `dictando`: reunión y conversación están previstas y no se dibujan
  /// (`HUDSessionKind`, spec §5). Vive acá y no en el controlador de dictado
  /// porque el escenario es uno solo para los tres.
  private(set) var sessionKind = HUDSessionKind.dictando

  let dictationContent = DictationHUDContent()
  let dropContent = DropHUDContent()
  let sounds = HUDSounds()

  /// Forwarded to the drop surface, which is the only part of the HUD that
  /// takes input.
  var onDropReceived: ((Int) -> Void)?
  var onCardEvent: ((HUDCardEvent) -> Void)?

  private let settings: AppSettings
  private let panel: HUDPanel
  private let hostingView: NSHostingView<HUDRootView>
  private var renderedSettings: DictationSessionSettings
  private var orderOutTask: Task<Void, Never>?
  private var messageDismissTask: Task<Void, Never>?
  /// El observador de cambio de espacio. Se guarda y no se da de baja: el
  /// escenario vive lo que vive la app, y un `deinit` en un tipo aislado al
  /// actor principal no puede tocar sus propiedades.
  private var spaceObserver: (any NSObjectProtocol)?

  init(settings: AppSettings) {
    self.settings = settings
    renderedSettings = settings.sessionSettings
    let placeholder = HUDScreenSnapshot(
      id: 0,
      frame: .zero,
      safeAreaTop: 0,
      auxiliaryTopLeftArea: nil,
      auxiliaryTopRightArea: nil,
      menuBarHeight: 0
    )
    hostingView = NSHostingView(
      rootView: HUDRootView(
        screen: placeholder,
        settings: renderedSettings,
        content: dictationContent,
        drop: dropContent
      )
    )
    // The window size is this stage's decision, not the content's; without
    // this the hosting view imposes the shell's intrinsic size on the window
    // and collapses the fixed frame.
    hostingView.sizingOptions = []
    panel = HUDPanel(
      contentRect: CGRect(origin: .zero, size: CGSize(width: 1, height: 1)),
      contentView: hostingView
    )
    observeSpaceChanges()
  }

  /// Vuelve a poner la forma al frente cuando cambia el espacio activo.
  ///
  /// `canJoinAllSpaces` la lleva a todos los espacios, pero no arregla el
  /// orden: si el espacio nuevo es una app en pantalla completa nativa, su
  /// ventana se ordena al frente al entrar y la forma queda detrás —
  /// visible en el Escritorio, invisible en Keynote o en Safari en pantalla
  /// completa (issue #84 del árbol de origen). Reordenar al frente en cada cambio de
  /// espacio es lo que el overlay de Dilo-Tauri conseguía siendo un NSPanel
  /// `nonactivating` + `floating` que se muestra de nuevo en cada estado.
  ///
  /// Sólo mientras hay alguien en el escenario: sin sesión no hay ventana que
  /// ordenar y el observador no cuesta nada.
  private func observeSpaceChanges() {
    spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.occupant != .none else { return }
        self.panel.assertOverlayOrder()
      }
    }
  }

  /// Whether the shape currently takes the mouse. Only a drop surface does.
  var acceptsMouse: Bool {
    get { panel.acceptsMouse }
    set { panel.acceptsMouse = newValue }
  }

  /// The live sound preferences. A Drop Transcription has no session snapshot
  /// to capture — its moments are minutes apart — so it reads the current pick
  /// each time, where dictation uses the one it started with.
  var dropSoundSettings: DictationSoundSettings {
    settings.sessionSettings.sounds
  }

  /// The display this surface should open on: the one holding the focused
  /// input where that is known, else the pointer's, else the main one.
  func screen(preferring displayID: CGDirectDisplayID? = nil) -> HUDScreenSnapshot? {
    let screens = NSScreen.screens.compactMap { screen -> HUDScreenSnapshot? in
      guard let id = screen.cgDirectDisplayID else { return nil }
      return HUDScreenSnapshot(
        id: id,
        frame: screen.frame,
        safeAreaTop: screen.safeAreaInsets.top,
        auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
        auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
        menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY,
        estiloSinNotch: settings.hudEstiloSinNotch
      )
    }
    return HUDPlacement.selectDisplay(
      from: screens,
      targetDisplayID: displayID,
      pointerLocation: NSEvent.mouseLocation
    )
  }

  /// Hands the shape to `occupant` and puts it on `screen`.
  ///
  /// Taking it for dictation or a message evicts any drop surface: the file
  /// job keeps running with the status item carrying it, but the user is
  /// speaking now and that outranks a card (CONTEXT.md).
  func claim(
    _ occupant: Occupant,
    on screen: HUDScreenSnapshot,
    rendering settings: DictationSessionSettings? = nil,
    kind: HUDSessionKind = .dictando
  ) {
    // Un estado que todavía no dibuja nada no abre el escenario: una forma
    // negra vacía se lee como un cuelgue (`HUDSessionKind.isDrawn`).
    guard kind.isDrawn else { return }
    orderOutTask?.cancel()
    if occupant != .message { cancelMessageDismiss() }
    if occupant != .drop { evictDrop() }
    self.occupant = occupant
    sessionKind = kind
    renderedSettings = settings ?? self.settings.sessionSettings
    mount(on: screen)
  }

  /// Gives the shape up. The panel stays front while the retract plays, then
  /// orders out and the drop surface clears itself down.
  func retract() {
    guard occupant != .none else { return }
    acceptsMouse = false
    occupant = .none
    dictationContent.isRevealed = false
    dropContent.isRevealed = false

    orderOutTask?.cancel()
    orderOutTask = Task { [weak self] in
      try? await Task.sleep(for: Self.dismissDuration)
      guard !Task.isCancelled, let self, occupant == .none else { return }
      panel.orderOut(nil)
      // Only once it is off screen: clearing any of these earlier would show
      // through the retract.
      dictationContent.isDismissing = false
      dictationContent.text = ""
      dictationContent.volatileText = ""
      // The shaping caption outlived the shape: it is what decides whether
      // the label is mounted, and the label animates every frame while it is.
      dictationContent.shapingName = nil
      dictationContent.shapingChoiceLabel = nil
      dropContent.mode = .none
      dropContent.heldIcon = nil
      dropContent.transcript = nil
    }
  }

  /// Runs `work` after `delay` unless the shape has changed hands, for the
  /// self-dismissing states: a message, a notice, a card's deadline.
  func schedule(after delay: Duration, while occupant: Occupant, _ work: @escaping () -> Void) {
    orderOutTask?.cancel()
    orderOutTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self, self.occupant == occupant else { return }
      work()
    }
  }

  /// A status or error line, in the one place Dilo says anything.
  func showMessage(_ text: String, on displayID: CGDirectDisplayID? = nil) {
    guard let screen = screen(preferring: displayID) else { return }
    claim(.message, on: screen)
    // hide() pins these for the retract, and claim() cancels that order-out.
    // A message is a new occupant and must not inherit them.
    dictationContent.isDismissing = false
    dictationContent.shapingName = nil
    dictationContent.shapingChoiceLabel = nil
    dictationContent.showsVoiceVisual = false
    dictationContent.text = text
    dictationContent.volatileText = ""
    revealDictation()

    messageDismissTask?.cancel()
    messageDismissTask = Task { [weak self] in
      try? await Task.sleep(for: Self.messageDuration)
      guard !Task.isCancelled, let self, occupant == .message else { return }
      retract()
    }
  }

  func cancelMessageDismiss() {
    messageDismissTask?.cancel()
    messageDismissTask = nil
  }

  /// Reveals the dictation surface. It is always mounted — the root shows it
  /// whenever no drop state is up — so its reveal animates against a frame
  /// that already exists.
  func revealDictation() {
    guard !dictationContent.isRevealed else { return }
    commitParkedFrame()
    Task { @MainActor [dictationContent] in
      dictationContent.isRevealed = true
    }
  }

  /// Reveals a drop surface once its parked state has actually been drawn.
  ///
  /// The drop shape is inserted into the view tree at the same moment it is
  /// asked to open, and a view that has never rendered has no parked frame to
  /// spring from — both states collapse into one render and it appears already
  /// open. Forcing layout is not enough and there is no callback for "SwiftUI
  /// has drawn", so the flip waits one display cycle.
  func revealDrop() {
    guard !dropContent.isRevealed else { return }
    commitParkedFrame()
    Task { @MainActor [dropContent] in
      try? await Task.sleep(for: .milliseconds(20))
      dropContent.isRevealed = true
    }
  }

  /// Commits one frame in the parked state, so the reveal has something to
  /// animate from rather than drawing itself already open.
  private func commitParkedFrame() {
    hostingView.layoutSubtreeIfNeeded()
    panel.displayIfNeeded()
  }

  /// Rebuilds the root for this display and brings the window forward. The
  /// window's frame comes from the screen, never from the content.
  private func mount(on screen: HUDScreenSnapshot) {
    hostingView.rootView = HUDRootView(
      screen: screen,
      settings: renderedSettings,
      content: dictationContent,
      drop: dropContent,
      kind: sessionKind,
      onDrop: { [weak self] index in
        self?.onDropReceived?(index)
      },
      onCardEvent: { [weak self] event in
        self?.onCardEvent?(event)
      }
    )
    panel.setFrame(HUDNotchGeometry.windowFrame(for: screen), display: true)
    panel.assertOverlayOrder()
  }

  private func evictDrop() {
    acceptsMouse = false
    dropContent.mode = .none
  }
}
