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

  /// El retardo del hover de fábrica, en segundos.
  ///
  /// Medio segundo, el punto medio de lo que hacen las apps de notch que
  /// Alfonso pasó de referencia (0,4–0,6 s). La tolerancia es lo que separa
  /// «me acerqué a mirar» de «pasé el mouse camino al menú»: sin ella,
  /// cruzar la pantalla abre y cierra la muesca tres veces. Cuánto es lo
  /// justo depende de cómo mueve el mouse cada persona, así que es un ajuste
  /// (`AppSettings.hudRetardoDeHover`) y esto es sólo su valor inicial.
  static let retardoDeHoverDeFabrica = 0.5

  /// El de fábrica como `Duration`, que es lo que un test quiere adelantar
  /// cuando no cambió el ajuste.
  static var toleranciaDelHover: Duration {
    .milliseconds(Int(retardoDeHoverDeFabrica * 1000))
  }

  /// Cuánto se queda abierto el contexto como mucho.
  ///
  /// Red de seguridad y no diseño: la ventana deja de recibir el mouse en
  /// cuanto el puntero sale de la silueta (`HUDHostingView.hitTest`), así que
  /// la salida puede no llegar nunca. Sin esto, un contexto abierto se queda
  /// abierto para siempre.
  static let contextoMaximo = Duration.seconds(4)

  /// El estado del contrato que el escenario está sosteniendo.
  var estado: EstadoDelNotch { dictationContent.estado }

  /// La máquina del contrato del notch y sus tiempos. Vive acá y no en el
  /// controlador de dictado porque el escenario es uno solo: un mensaje de
  /// Drop Transcription y un resultado de dictado se turnan la misma forma, y
  /// con una máquina por feature se pisan los temporizadores.
  let control: ControlDelNotch

  /// Un clic en la silueta en reposo: abre el menú de acciones, el mismo del
  /// status item. Lo cablea `AppDelegate`, que es quien tiene el menú.
  var alPedirAcciones: (() -> Void)?
  /// Un clic en la silueta mostrando un resultado: copia lo último dictado.
  var alPedirCopiar: (() -> Void)?

  private let settings: AppSettings
  private let panel: HUDPanel
  private let hostingView: HUDHostingView<HUDRootView>
  /// La pantalla donde está puesta la forma. El reposo se queda donde quedó
  /// la última sesión —seguir al puntero pediría sondearlo, y una forma que
  /// salta de monitor sola es peor que una que espera—.
  private var pantallaActual: HUDScreenSnapshot?
  private var hoverTask: Task<Void, Never>?
  /// El reloj de los plazos del escenario. Inyectable por el mismo motivo
  /// que el del pegado (#82): contra el reloj de pared, un test de tiempos
  /// afirma que el runner fue rápido, no que el plazo se respetó.
  private let reloj: DeadlineClock
  private var renderedSettings: DictationSessionSettings
  private var orderOutTask: Task<Void, Never>?
  /// El observador de cambio de espacio. Se guarda y no se da de baja: el
  /// escenario vive lo que vive la app, y un `deinit` en un tipo aislado al
  /// actor principal no puede tocar sus propiedades.
  private var spaceObserver: (any NSObjectProtocol)?

  init(settings: AppSettings, reloj: DeadlineClock = .continuous) {
    self.settings = settings
    self.reloj = reloj
    control = ControlDelNotch(reloj: reloj)
    renderedSettings = settings.sessionSettings
    let placeholder = HUDScreenSnapshot(
      id: 0,
      frame: .zero,
      safeAreaTop: 0,
      auxiliaryTopLeftArea: nil,
      auxiliaryTopRightArea: nil,
      menuBarHeight: 0
    )
    hostingView = HUDHostingView(
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
    observarCambiosDePantallas()
    control.alCambiar = { [weak self] estado in
      guard let self else { return }
      aplicar(estado)
      // La vuelta a reposo puede venir del temporizador del resultado, y
      // entonces nadie más soltó la forma.
      if estado == .reposo { retract() }
    }
    dictationContent.alEntrarElPuntero = { [weak self] dentro in
      self?.punteroEncima(dentro)
    }
    dictationContent.alHacerClic = { [weak self] in
      self?.clicEnLaSilueta()
    }
  }

  /// Pone la forma en pantalla en reposo y la deja ahí.
  ///
  /// El notch de Dilo no aparece al dictar: está. Esto se llama una vez al
  /// arrancar, y después la forma sólo cambia de tamaño. Que la ventana viva
  /// montada no cuesta: en reposo nada anima (`EstadoDelNotch.anima`), que es
  /// el número que el spec §3 pide cuidar.
  func despertar() {
    guard let screen = screen() else { return }
    dictationContent.isRevealed = false
    mount(on: screen)
    aplicar(.reposo)
  }

  /// Mueve la máquina del contrato. Es la única puerta: el estado no se
  /// escribe a mano desde ninguna parte.
  func recibir(_ evento: MaquinaDelNotch.Evento) {
    control.recibir(evento)
  }

  /// Anota en qué estado está el escenario y ajusta lo que depende de él: si
  /// la forma toma el mouse y qué franja de la ventana lo recibe.
  private func aplicar(_ estado: EstadoDelNotch) {
    dictationContent.estado = estado
    if !estado.tomaElMouse {
      cancelarHover()
      dictationContent.punteroEncima = false
    }
    // Un arrastre en curso manda: la superficie de Drop Transcription pide el
    // mouse por su cuenta y no se lo quita un cambio de estado del dictado.
    if occupant != .drop {
      acceptsMouse = estado.tomaElMouse
      panel.tomaElTeclado = false
    }
    actualizarPresencia()
    actualizarZonaInteractiva()
  }

  /// Si la forma está escondida ahora mismo: sólo el reposo, y sólo donde no
  /// hay barra de menús de la que colgar (`HUDNotchGeometry.reposoSeEsconde`).
  var escondido: Bool {
    guard let pantallaActual else { return false }
    return estado.esCompacto && HUDNotchGeometry.reposoSeEsconde(for: pantallaActual)
  }

  /// Esconde o muestra la forma sin sacarla de pantalla.
  ///
  /// `alphaValue` y no `orderOut`: la ventana se queda montada en todos los
  /// espacios, así que volver de una app en pantalla completa no pide
  /// recolocarla ni pelear otra vez por el orden. Lo que sí hay que soltar es
  /// el mouse, porque una ventana invisible que se traga clics es peor que
  /// una visible que los toma.
  private func actualizarPresencia() {
    panel.alphaValue = escondido ? 0 : 1
  }

  /// Vuelve a colocar la forma cuando cambia la configuración de pantallas:
  /// enchufar un monitor, cambiar la resolución o el modo escalado mueve
  /// dónde está el centro de la barra de menús.
  private func observarCambiosDePantallas() {
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let screen = self.screen() else { return }
        self.mount(on: screen)
      }
    }
  }

  /// La franja de la ventana que recibe el mouse: la silueta, no la ventana.
  ///
  /// En reposo es la silueta compacta; abierta, lo más ancho que la forma
  /// puede llegar a ser con los ajustes de esta sesión. Generoso a propósito
  /// en los estados abiertos: sólo duran lo que dura una sesión, y errar por
  /// unos puntos ahí vale menos que perder un clic en Copiar.
  private func actualizarZonaInteractiva() {
    guard let pantallaActual, estado.tomaElMouse, !escondido else {
      panel.zonaInteractiva = nil
      return
    }
    let tamaño: CGSize
    if estado.esCompacto {
      let reposo = HUDNotchGeometry.reposoSize(for: pantallaActual)
      // Con el contexto abierto la silueta crece; la zona crece con ella.
      tamaño = CGSize(
        width: reposo.width * (dictationContent.contextoVisible == nil ? 1 : 3.5),
        height: reposo.height + (dictationContent.contextoVisible == nil ? 0 : 22)
      )
    } else {
      let ventana = HUDNotchGeometry.windowSize(for: pantallaActual)
      tamaño = CGSize(
        width: min(renderedSettings.hudMetrics.contentWidth, ventana.width),
        height: ventana.height - HUDNotchGeometry.shadowPadding
      )
    }
    panel.zonaInteractiva = HUDNotchGeometry.zonaInteractiva(
      for: pantallaActual,
      tamaño: tamaño
    )
  }

  /// El puntero entró o salió de la silueta. La tolerancia va acá y no en la
  /// vista porque es tiempo, y el tiempo del escenario lo lleva el escenario.
  private func punteroEncima(_ dentro: Bool) {
    hoverTask?.cancel()
    let retardo = Duration.milliseconds(
      Int((max(0, settings.hudRetardoDeHover) * 1000).rounded())
    )
    hoverTask = Task { [weak self, reloj] in
      try? await reloj.sleep(retardo)
      guard !Task.isCancelled, let self else { return }
      // Un hover jamás arranca una captura: lo único que toca es qué se
      // dibuja (contrato del notch).
      dictationContent.punteroEncima = dentro && estado.tomaElMouse
      actualizarZonaInteractiva()
      guard dictationContent.punteroEncima else { return }

      try? await reloj.sleep(Self.contextoMaximo)
      guard !Task.isCancelled else { return }
      dictationContent.punteroEncima = false
      actualizarZonaInteractiva()
    }
  }

  private func cancelarHover() {
    hoverTask?.cancel()
    hoverTask = nil
  }

  /// Dónde abrir el menú de acciones: justo debajo de la silueta, en
  /// coordenadas de pantalla.
  var puntoDeAcciones: NSPoint? {
    guard let pantallaActual else { return nil }
    let ventana = HUDNotchGeometry.windowFrame(for: pantallaActual)
    let reposo = HUDNotchGeometry.reposoSize(for: pantallaActual)
    return NSPoint(x: ventana.midX, y: ventana.maxY - reposo.height)
  }

  private func clicEnLaSilueta() {
    switch estado {
    case .reposo: alPedirAcciones?()
    case .resultado: alPedirCopiar?()
    case .preparando, .dictando, .procesando: break
    }
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
        guard let self else { return }
        // Siempre, no sólo con sesión: desde que el escenario es permanente,
        // la forma en reposo también tiene que sobrevivir al cambio de
        // espacio.
        self.panel.assertOverlayOrder()
        // Y volver a medir: entrar a una app en pantalla completa autooculta
        // la barra de menús, que es de donde sale el alto de la muesca y
        // también la señal de que el reposo tiene que esconderse.
        if let screen = self.screen() { self.mount(on: screen) }
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
        estiloSinNotch: settings.hudEstiloSinNotch,
        nombre: screen.localizedName
      )
    }
    return HUDPlacement.selectDisplay(
      from: screens,
      targetDisplayID: displayID,
      pointerLocation: NSEvent.mouseLocation,
      pantallaElegida: settings.hudPantalla
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

  /// Suelta la forma: se encoge hasta el reposo y se queda ahí.
  ///
  /// **La ventana no se va de la pantalla.** Antes se ordenaba fuera y el
  /// notch desaparecía al terminar de dictar, que es lo que lo volvía una
  /// notificación en vez de un lugar. Ahora el escenario es permanente y lo
  /// que cambia es el tamaño de la silueta.
  func retract() {
    guard occupant != .none else { return }
    // Idempotente: si la máquina ya está en reposo —porque venció el
    // resultado— esto no mueve nada y no vuelve a llamar acá.
    control.recibir(.cancelar)
    occupant = .none
    dictationContent.isRevealed = false
    dropContent.isRevealed = false

    orderOutTask?.cancel()
    orderOutTask = Task { [weak self, reloj] in
      try? await reloj.sleep(Self.dismissDuration)
      guard !Task.isCancelled, let self, occupant == .none else { return }
      // Sólo cuando la forma ya se encogió: limpiar antes se vería durante
      // el encogimiento.
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
      aplicar(.reposo)
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
  ///
  /// Un mensaje es un resultado del contrato: dice qué pasó y se va solo. El
  /// plazo lo lleva la máquina y no un temporizador aparte — dos relojes
  /// sobre la misma forma terminan uno tapando al otro.
  func showMessage(_ text: String, on displayID: CGDirectDisplayID? = nil) {
    guard let screen = screen(preferring: displayID) else { return }
    claim(.message, on: screen)
    recibir(.entregar(.aviso(text)))
    // hide() pins these for the retract, and claim() cancels that order-out.
    // A message is a new occupant and must not inherit them.
    dictationContent.isDismissing = false
    dictationContent.shapingName = nil
    dictationContent.shapingChoiceLabel = nil
    dictationContent.showsVoiceVisual = false
    dictationContent.text = text
    dictationContent.volatileText = ""
    revealDictation()
  }

  /// Ya no hay un temporizador de mensajes aparte: el plazo es el del
  /// resultado del contrato, y lo cancela el evento que abra la sesión
  /// siguiente.
  func cancelMessageDismiss() {}

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
    pantallaActual = screen
    panel.setFrame(HUDNotchGeometry.windowFrame(for: screen), display: true)
    panel.assertOverlayOrder()
    actualizarPresencia()
    actualizarZonaInteractiva()
  }

  private func evictDrop() {
    acceptsMouse = false
    dropContent.mode = .none
  }
}
