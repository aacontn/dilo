import AppKit
import ApplicationServices
import DiloCapabilities
import os

@MainActor
final class TextInsertionService {
  /// Runs the sole leased pasteboard read away from the main actor.
  ///
  /// Apple documents no thread-safety contract for `NSPasteboard`. Background
  /// use is accepted only to keep promised-data resolution from blocking the
  /// main actor. The serial queue and read lease prevent same-instance overlap.
  let clipboardReaderQueue = DispatchQueue(
    label: "cl.espaciodigital.dilo.clipboard-snapshot",
    qos: .userInitiated
  )

  /// True from before a read is enqueued until its closure actually returns.
  ///
  /// A timeout never clears this lease: while AppKit remains inside a promised
  /// data read, every later read and every write must remain excluded.
  let clipboardReadLease = OSAllocatedUnfairLock(initialState: false)

  struct Target {
    fileprivate let element: AXUIElement?
    let processIdentifier: pid_t

    let isSecure: Bool
    let displayID: CGDirectDisplayID?
    /// The application that held focus when the session began, for the
    /// history entry to name. Resolved at capture time rather than at write
    /// time, because by then the application may be gone.
    let applicationName: String?
    /// Para elegir la `PoliticaDeEntrega`: una terminal no se teclea y un
    /// escritorio remoto recibe el ⌘V por el HID.
    let bundleID: String?
    /// El campo y el cursor al empezar, sin leer el texto. Nil en el sandbox,
    /// sin campo editable o sin un cursor quieto.
    let ancla: AnclaDelFoco?

    init(
      element: AXUIElement?,
      processIdentifier: pid_t,
      isSecure: Bool,
      displayID: CGDirectDisplayID?,
      applicationName: String? = nil,
      bundleID: String? = nil,
      ancla: AnclaDelFoco? = nil
    ) {
      self.element = element
      self.processIdentifier = processIdentifier
      self.isSecure = isSecure
      self.displayID = displayID
      self.applicationName = applicationName
      self.bundleID = bundleID
      self.ancla = ancla
    }
  }

  /// Injectable pasteboard, focus, event, and timing boundaries for insertion.
  struct Dependencies {
    let pasteboard: NSPasteboard
    /// Reads every pasteboard item into values that can cross back to the main actor.
    ///
    /// The service invokes this closure only on its serial reader queue while
    /// holding the read lease. `nil` means the read was incomplete or failed.
    let readClipboardItems: @Sendable () -> [ClipboardItemSnapshot]?
    /// The total acquisition deadline shared by the first read and one reread.
    let snapshotTimeout: Duration
    let focusedElement: @MainActor () -> AXUIElement?
    let frontmostApplication: @MainActor () -> NSRunningApplication?
    let isProcessRunning: @MainActor (pid_t) -> Bool
    let isTargetFocused: @MainActor (Target) -> Bool
    /// Lo que se mira del teclado antes de pegar: entrada segura y teclas
    /// sostenidas. Va antes del atajo para que los tests lo pongan junto a él.
    var teclado: LecturasDelTeclado = .delSistema
    /// Aprieta ⌘V por el canal que dice la política del destino.
    let postPasteShortcut: @MainActor (CanalDelAtajo) -> Bool
    /// Presses Copy in the focused application, for reading a selection
    /// Accessibility will not answer for.
    ///
    /// Defaulted, unlike the fields above it, so the insertion tests that
    /// never copy keep their call sites: refusing to copy is what they expect
    /// and the safe answer besides.
    var postCopyShortcut: @MainActor () -> Bool = { false }
    /// How long a copy is given to reach the pasteboard. Long enough for a
    /// browser to answer, short enough that a key press does not feel stuck.
    var copyTimeout: Duration = .milliseconds(400)
    /// Cómo se entrega a este destino. Con valor por defecto porque sale del
    /// destino mismo y del anfitrión: un test sólo lo cambia para fingir otra
    /// clase de app.
    var politica: @MainActor (Target) -> PoliticaDeEntrega = { destino in
      PoliticaDeEntrega.para(
        ClaseDeDestino.de(bundleID: destino.bundleID),
        alProcesoSePuede: Anfitrion.actual.admite(.atajoAlProceso)
      )
    }
    /// El campo con el foco en esa app y su cursor, al empezar el dictado.
    var anclaDelFoco: @MainActor (pid_t) -> AnclaDelFoco? = { Anfitrion.actual.anclaDelFoco(en: $0) }
    /// Si el foco y el cursor siguen donde dice el ancla.
    var anclaSigueIgual: @MainActor (AnclaDelFoco) -> Bool = { Anfitrion.actual.anclaSigueIgual($0) }
    /// Lo que se lee del campo, fuera del actor principal: una app lenta en
    /// contestar no traba la muesca.
    var fotoDelCampo: @Sendable (AnclaDelFoco) async -> FotoDelCampo = { ancla in
      await Task.detached { Anfitrion.actual.fotoDelCampo(ancla) }.value
    }
    /// Teclea el dictado, para el reintento cuando el ⌘V no entró.
    var teclear: @MainActor ([TecleoDelDictado.Pedazo], CanalDelAtajo) async -> Bool = {
      await TecleoSimulado.teclear($0, por: $1)
    }
    /// Si la persona tecleó o hizo clic en los últimos `hace`: entonces un
    /// campo que no cambió puede ser obra suya y no prueba nada.
    var huboEntradaDeLaPersona: @MainActor (_ hace: Duration) -> Bool = { hace in
      let segundos = Double(hace.components.seconds) + Double(hace.components.attoseconds) / 1e18
      let tecla = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
      let clic = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .leftMouseDown)
      return min(tecla, clic) < segundos
    }
    /// The time source behind the snapshot and copy deadlines. Injectable so
    /// a test drives time instead of betting the runner beats a real
    /// deadline, which is the bet that flaked on loaded CI machines (#82).
    var clock: DeadlineClock = .continuous

    /// Builds the production boundaries around the shared general pasteboard.
    static var live: Self {
      let pasteboard = NSPasteboard.general
      // Apple documents no NSPasteboard thread-safety contract. This background
      // read is deliberate: promised data wedged the main actor in __dataForType
      // -> CFPasteboardCopyData -> mach_msg, while same-instance overlap was
      // proven to raise NSException "value not absent" in pasteboardItems. The
      // serial reader queue and lease exclude every write until the read returns.
      nonisolated(unsafe) let backgroundPasteboard = pasteboard

      return Self(
        pasteboard: pasteboard,
        readClipboardItems: {
          TextInsertionService.foto(de: backgroundPasteboard).items
        },
        snapshotTimeout: .milliseconds(600),
        focusedElement: TextInsertionService.focusedElement,
        frontmostApplication: { NSWorkspace.shared.frontmostApplication },
        isProcessRunning: { processIdentifier in
          guard let application = NSRunningApplication(
            processIdentifier: processIdentifier
          ) else {
            return false
          }
          return !application.isTerminated
        },
        isTargetFocused: TextInsertionService.isStillFocused,
        teclado: .delSistema,
        postPasteShortcut: TextInsertionService.postPasteShortcut,
        postCopyShortcut: TextInsertionService.postCopyShortcut,
        copyTimeout: .milliseconds(400),
        clock: .continuous
      )
    }
  }

  let dependencies: Dependencies
  /// El dictado que está en el portapapeles esperando volver. Uno a la vez:
  /// el siguiente lo hereda.
  var pegadoPendiente: PegadoPendiente?
  /// La devolución del portapapeles, que sigue corriendo después de que
  /// `entregar` ya contestó.
  var tareaDeDevolucion: Task<Void, Never>?
  /// Cuándo salió el último ⌘V. Lo lee la latencia por fase del dictado para
  /// partir la entrega en preparar el pegado y esperar el acuse.
  var ultimoAtajoEnviado: ContinuousClock.Instant?

  init(dependencies: Dependencies = .live) {
    self.dependencies = dependencies
  }

  func captureFocusedTarget() -> Target? {
    if let element = dependencies.focusedElement() {
      let processIdentifier = Anfitrion.actual.pid(de: element)

      let application = NSRunningApplication(processIdentifier: processIdentifier)
      return Target(
        element: element,
        processIdentifier: processIdentifier,
        isSecure: isSecureTextField(element),
        displayID: displayID(for: element),
        applicationName: application?.localizedName,
        bundleID: application?.bundleIdentifier,
        ancla: dependencies.anclaDelFoco(processIdentifier)
      )
    }

    // Some apps expose no focused AX element even while an editor has focus.
    // Keep the application as the safest available focus boundary.
    guard let application = dependencies.frontmostApplication() else { return nil }
    return Target(
      element: nil,
      processIdentifier: application.processIdentifier,
      isSecure: false,
      displayID: nil,
      applicationName: application.localizedName,
      bundleID: application.bundleIdentifier
    )
  }

  /// Un atributo de Accesibilidad leído como elemento. Lo contesta el
  /// anfitrión: en sandbox mirar dentro de otra app no se puede, así que la
  /// respuesta es nil y el pegado cae solo a la app al frente.
  private static func element(
    _ owner: AXUIElement,
    _ attribute: String
  ) -> AXUIElement? {
    Anfitrion.actual.elemento(owner, atributo: attribute)
  }

  private static func focusedElement() -> AXUIElement? {
    Anfitrion.actual.elementoEnfocado()
  }

  /// Ojo: `false` puede significar "no es un campo de contraseña" o "no se
  /// pudo saber". Quien apoye una decisión en esto mira antes
  /// `Anfitrion.actual.admite(.focoAntesDePegar)`.
  private func isSecureTextField(_ element: AXUIElement) -> Bool {
    Anfitrion.actual.esCampoSeguro(element)
  }

  private func displayID(for element: AXUIElement) -> CGDirectDisplayID? {
    let frameElement = window(for: element) ?? element
    guard let frame = frame(of: frameElement) else { return nil }

    let displays = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, CGRect)? in
      guard let displayID = screen.cgDirectDisplayID else { return nil }
      return (displayID, CGDisplayBounds(displayID))
    }

    let center = CGPoint(x: frame.midX, y: frame.midY)
    if let containingDisplay = displays.first(where: { $0.1.contains(center) }) {
      return containingDisplay.0
    }

    return displays.max { lhs, rhs in
      lhs.1.intersection(frame).area < rhs.1.intersection(frame).area
    }?.0
  }

  private func window(for element: AXUIElement) -> AXUIElement? {
    Self.element(element, kAXWindowAttribute)
  }

  private func frame(of element: AXUIElement) -> CGRect? {
    Anfitrion.actual.marco(de: element)
  }

  private static func isStillFocused(_ target: Target) -> Bool {
    Anfitrion.actual.sigueSiendoElFoco(
      elemento: target.element,
      pid: target.processIdentifier
    )
  }

  /// Copies the focused application's selection and hands it back, leaving
  /// the clipboard as it was.
  ///
  /// For the applications Accessibility cannot answer for. Measured on macOS
  /// 26, Chromium browsers report no focused element at all and Safari reports
  /// a web area with no selected text, so a read-only reader finds nothing on
  /// any web page. Copy works wherever Copy works.
  ///
  /// - Returns: the copied text, or nil when there was nothing to copy. That
  ///   is known rather than guessed: a copy that found nothing leaves the
  ///   pasteboard's change count where it was.
  func copySelection() async -> String? {
    // Un dictado todavía prometido no se fotografía: leerlo dispararía la
    // promesa, y guardarlo lo haría pasar por lo de la persona.
    devolverElPendienteAhora()
    // The snapshot comes first because it is the permission to proceed: a
    // clipboard that cannot be captured cannot be put back, and taking
    // someone's clipboard to read a tweet is not a trade to make.
    guard case let .accepted(items, changeCount) = await snapshotClipboardItems() else {
      return nil
    }
    guard dependencies.postCopyShortcut() else { return nil }
    guard let copiedCount = await waitForCopy(after: changeCount) else {
      return nil
    }

    let copied = dependencies.pasteboard.string(forType: .string)
    restoreClipboard(items, ifUnchangedSince: copiedCount)
    return copied
  }

  /// Waits for the copy to land, and reports the count it landed at.
  ///
  /// - Returns: the new change count, or nil if the count never moved, which
  ///   is what nothing being selected looks like.
  private func waitForCopy(after changeCount: Int) async -> Int? {
    let clock = dependencies.clock
    let deadline = clock.now() + dependencies.copyTimeout
    while clock.now() < deadline {
      let current = dependencies.pasteboard.changeCount
      if current != changeCount { return current }
      do {
        try await clock.sleep(.milliseconds(10))
      } catch {
        return nil
      }
    }
    return nil
  }

  /// ⌘C al HID: lo pide Leer en voz alta para la app al frente, sin un
  /// destino capturado al que mandárselo.
  private static func postCopyShortcut() -> Bool {
    postShortcut(virtualKey: TeclaDelAtajo.resolver("c"))
  }

  private static func postPasteShortcut(_ canal: CanalDelAtajo) -> Bool {
    postShortcut(virtualKey: TeclaDelAtajo.resolver("v"), publicar: canal.publicar)
  }

  /// El canal del ⌘V para este destino, según su política.
  func canal(para target: Target) -> CanalDelAtajo {
    CanalDelAtajo.para(
      pid: target.processIdentifier,
      alProceso: dependencies.politica(target).alProceso
    )
  }

  /// Aprieta ⌘ + la tecla con la secuencia entera de `AtajoSimulado`.
  ///
  /// `apretadas`, `crear` y `publicar` son la costura de los tests: con ellas
  /// la secuencia se captura en vez de llegarle al sistema. Sin `crear`, los
  /// eventos salen de la fuente del teclado físico.
  static func postShortcut(
    virtualKey: CGKeyCode,
    apretadas: AtajoSimulado.TeclasApretadas = .delTeclado(),
    crear: ((AtajoSimulado.Pulsacion) -> CGEvent?)? = nil,
    publicar: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
  ) -> Bool {
    let crear = crear ?? { [fuente = CGEventSource(stateID: .hidSystemState)] pulsacion in
      guard let fuente else { return nil }
      return AtajoSimulado.evento(pulsacion, fuente: fuente)
    }
    return AtajoSimulado.publicar(
      AtajoSimulado.pulsaciones(de: virtualKey, con: apretadas),
      crear: crear,
      publicar: publicar
    )
  }
}

private extension CGRect {
  var area: CGFloat {
    guard !isNull else { return 0 }
    return width * height
  }
}
