import AppKit
import DiloCapabilities
import DiloEngines
import DiloModes
import DiloText
import os

/// The impure half of Direct Dictation: owns the services, translates
/// trigger-monitor events into DictationSessionMachine actions, runs the
/// begin guards, and executes the machine's effects. Every state transition
/// lives in the machine; async completions come back to it as new actions.
@MainActor
final class DirectDictationController {
  /// Carries the session's captured settings while recording so the shell
  /// can mirror session-scoped looks (the status ghost's palette tint);
  /// nil when the session ends.
  var onRecordingStateChange: ((Bool, DictationSessionSettings?) -> Void)?
  /// Fired by the Read Aloud shortcut, only while no dictation session is
  /// active — speaking through the speaker path mid-dictation would feed
  /// the recognizer its own audio.
  var onReadAloudTriggered: (() -> Void)?
  /// La tecla de conversar, o cualquier gatillo mientras hay una
  /// Conversación: `true` al apretar y `false` al soltar. El dictado no la
  /// atiende; la reparte (`ControladorDeLaConversacion`).
  var onConversacion: ((Bool) -> Void)?
  /// Si hay una Conversación en curso. Mientras la hay, el gatillo del
  /// dictado le da el turno a la persona en vez de empezar un dictado: los
  /// dos usan el mismo motor de voz.
  var hayConversacion: () -> Bool = { false }
  /// El slot que la conversación tomó al apretar, para darle también el
  /// soltar.
  private var slotDeLaConversacion: GlobalKeyEventMonitor.TriggerSlot?
  /// El motor de voz prestado a la Conversación (`MotorParaConversar`).
  var motorParaConversar: MotorParaConversar? { dependencies.motorParaConversar }
  /// A language model downloading, as a locale identifier and progress (0…1),
  /// or nil progress once it finishes. Settings shows it on the language row.
  var onLanguageDownloadChange: ((String, Double?) -> Void)?

  private static let noSpeechTimeout = Duration.seconds(15)

  private let settings: AppSettings
  private let dependencies: Dependencies

  private var keyEventMonitor: GlobalKeyEventMonitor?
  private var machine = DictationSessionMachine()
  private let ducking = AudioDuckingSession()
  private let silenciador = SilenciadorDeLoQueSuena()
  /// Held for the length of a session. Without it, a Dilo that has sat
  /// idle for hours is napped, and the HUD's animation clock with it (#77).
  private let activity = ActivityAssertion(reason: "Direct Dictation session")
  private var focusedTarget: TextInsertionService.Target?
  private var noSpeechTask: Task<Void, Never>?
  private var permissionTask: Task<Void, Never>?
  private var permissionWatchTask: Task<Void, Never>?
  private var sessionStartTask: Task<Void, Never>?
  /// The finish in flight, carrying the session's last words to insertion.
  /// Tracked so teardown can wait for it instead of racing it.
  private var finishTask: Task<Void, Never>?
  private var isPrepared = false
  /// Por qué falló la última preparación, o nil si no falló. Tipado y no un
  /// string: si fue un permiso y la persona ya lo dio, el gatillo siguiente
  /// vuelve a preparar en vez de repetir que falta.
  private var fallaDePreparacion: BloqueoDelDictado?
  /// El idioma que se está bajando mientras se prepara, y cuánto va, para
  /// decir eso al apretar en vez de un «preparando» mudo.
  private var descargaDelModelo: (locale: Locale, fraccion: Double)?
  /// Los hitos de la sesión en curso (`DirectDictationController+Latencia`).
  var relojDeFases = RelojDeFases()
  /// Lo dicho antes de un Esc, mientras se puede deshacer.
  private var retenida: CancelacionRetenida?
  private var vigiaDeLaRetencion: Task<Void, Never>?
  private var currentSessionSettings: DictationSessionSettings?
  /// The languages behind the two trigger keys, resolved to locales Apple
  /// Speech supports. `secondary` is nil unless a second language is chosen.
  private var primaryLocale: Locale?
  private var secondaryLocale: Locale?
  /// Everything about translation, which this controller only asks two
  /// questions of. Settings drives it directly.
  var translation: TranslationCoordinator { dependencies.translation }
  /// Con qué traduce la sesión que se acaba de aprobar, resuelto al apretar
  /// la tecla (`estadoDeLaTraduccion`) y congelado en la sesión al empezar a
  /// escuchar.
  private var motorDeTraduccionAprobado: MotorDeTraduccion.Resuelto = .apple
  /// Which slot's key began the session in flight, so the session runs in
  /// the language of the key that started it even if Settings change.
  private var activeSlot: GlobalKeyEventMonitor.TriggerSlot = .primary
  /// The key that slot was bound to when the session began. A rebind while a
  /// gesture is running must not take the key the gesture is still using.
  private var activeBinding: KeyBinding?
  /// El modo con que esta sesión va a terminar, recorrido con las flechas
  /// peladas mientras grabas; nil es "sin modo", que pega las palabras tal
  /// como se dijeron. Vive sólo en la sesión: recorrer nunca escribe Ajustes.
  private var sessionModo: Modo?
  /// Verdadero cuando el modo lo nombró una persona —apretó su tecla o movió
  /// las flechas—. Es lo que impide que "un atajo, Dilo decide" contradiga
  /// una elección explícita, que es la regla de `ResolucionDeModo`.
  private var modoElegidoAMano = false
  /// El modo que se eligió en el panel del hover para el atajo general, si
  /// esta sesión lo usa. Aparte de la tecla porque una frase disparadora le
  /// gana (`ResolucionDeModo.alTerminar`).
  private var modoDelAtajoGeneral: Modo?
  /// Lo último que se dictó, entero y en sus dos mitades. En memoria y nada
  /// más: el historial viene apagado de fábrica y encenderlo para poder
  /// recuperar un dictado sería cambiar la privacidad por un rescate.
  private(set) var ultimoDictado: UltimoDictado?
  /// Avisa que hay algo nuevo que copiar, para que el menú de la barra
  /// aparezca y diga qué.
  var onUltimoDictadoChange: ((UltimoDictado?) -> Void)?
  /// Whether the tap is currently swallowing the bare arrows, so the toggle
  /// fires only on transitions.
  private var isShapingCycleCaptureEnabled = false
  /// La duración de la toma que quedó en RAM porque el motor no sacó texto,
  /// o nil si no hay ninguna. Avisa al menú de la barra, que es donde se
  /// reintenta.
  private(set) var duracionDeLaTomaFallida: TimeInterval?
  var onTomaFallidaChange: ((TimeInterval?) -> Void)?
  /// El reloj del tope de cinco minutos del dictado en curso.
  private var vigiaDelTope: Task<Void, Never>?
  /// Los segundos que quedan, mientras la muesca cuenta hacia atrás.
  private var cuentaRegresiva: Int?
  /// Lo último que la muesca mostró en vivo, para que la cuenta regresiva
  /// se escriba al lado sin borrarlo.
  private var ultimoEnVivo = (firme: "", volatil: "")
  /// Lo que rodeaba al dictado, leído en paralelo con el micrófono y
  /// recogido al soltar. Sólo RAM, sólo esta sesión.
  private let contextoDelDictado = CapturaDeContexto()
  /// Mirar el campo después de pegar y ofrecer aprender lo que la persona
  /// corrigió. `AppDelegate` lo conecta con la muesca.
  var correcciones: CorreccionesDelDictado

  convenience init(
    settings: AppSettings,
    hudController: DictationHUDController,
    usageTracker: UsageTracker,
    textInsertionService: TextInsertionService
  ) {
    self.init(
      settings: settings,
      dependencies: .live(
        settings: settings,
        hudController: hudController,
        usageTracker: usageTracker,
        textInsertionService: textInsertionService
      )
    )
  }

  init(settings: AppSettings, dependencies: Dependencies) {
    self.settings = settings
    self.dependencies = dependencies
    correcciones = CorreccionesDelDictado(settings: settings)
    keyEventMonitor = GlobalKeyEventMonitor { [weak self] event in
      // El instante se toma acá, en el tap, y no cuando el main actor llegue
      // a atender el evento. Arrancar una sesión —la assertion de actividad,
      // la foto de los ajustes, los primeros cuadros del HUD— ocupa el main
      // actor, y el evento de soltar espera en la cola detrás de eso. Con
      // `.now` leído al atenderlo, un toque corto de verdad se medía como
      // sostenido apenas el arranque pasaba de los 250 ms del umbral, y la
      // sesión no se trababa.
      let instante = ContinuousClock.now
      Task { @MainActor [weak self] in
        self?.handle(event, at: instante)
      }
    }
  }

  func start() {
    applyKeyBindings()
    observeModelDownloads()
    observarTomasFallidas()
    requestPermissionsAndPrepare()
  }

  /// Routes model downloads to both places they matter: the Language section,
  /// and the HUD when a session is already waiting on that very language.
  private func observeModelDownloads() {
    let handler: @Sendable (SpeechRecognitionService.ModelDownload) -> Void = { [weak self] download in
      Task { @MainActor in
        self?.receive(download)
      }
    }

    Task { [dependencies] in
      await dependencies.setDownloadHandler(handler)
    }
  }

  private func receive(_ download: SpeechRecognitionService.ModelDownload) {
    onLanguageDownloadChange?(download.locale.identifier, download.fraction)
    descargaDelModelo = download.fraction.map { (download.locale, $0) }

    // Only speak up in the HUD for the language this session is waiting on.
    guard machine.isSessionActive, locale(for: activeSlot) == download.locale else { return }

    guard let fraction = download.fraction else {
      dependencies.showModelDownload(nil)
      return
    }
    let name = SpeechLanguageCatalog.shortName(for: download.locale)
    dependencies.showModelDownload(
      String(localized: "Descargando \(name)… \(Int(fraction * 100))%")
    )
  }

  /// El motor está cargando su modelo en la RAM mientras la sesión ya graba.
  ///
  /// Se dice en la muesca con el mismo estado que una descarga de idioma: la
  /// línea nombra lo que está esperando en vez de quedarse muda mientras no
  /// llega nada. Las palabras no se pierden — al soltar, el buffer espera al
  /// modelo—, sólo tardan.
  private func showModelLoading(_ isLoading: Bool) {
    guard machine.isSessionActive else { return }
    dependencies.showModelDownload(isLoading ? "Cargando el modelo…" : nil)
  }

  /// Pushes the recorded Settings bindings into the event tap; called at
  /// start and whenever the Shortcuts section changes them.
  func applyKeyBindings() {
    let bindings = Self.triggerBindings(
      settings: settings,
      sessionSlot: machine.isSessionActive ? activeSlot : nil,
      sessionBinding: activeBinding
    )
    keyEventMonitor?.setBindings(
      trigger: bindings.trigger,
      secondaryTrigger: bindings.secondary,
      readAloud: bindings.readAloud,
      translateTrigger: bindings.translate,
      modos: bindings.modos,
      conversar: settings.conversacionGatillo
    )
    keyEventMonitor?.setEventHandlingSuspended(settings.isRecordingKeybind)
  }

  /// Which key each slot should hold, given the preferences and the session in
  /// flight.
  ///
  /// Pure, and static, because the tap it feeds is built in `init` and has no
  /// seam: this is the only place the rule can be pinned. And the rule needs
  /// pinning. The slot driving a session keeps its key exactly as it was when
  /// the session started, because turning a language off takes the binding
  /// away and rebinding replaces it — either one leaves a held release
  /// discarded and a latched session with nothing to finish it, so it records
  /// until Escape. A preference change applies to the next session
  /// (CONTEXT.md).
  static func triggerBindings(
    settings: AppSettings,
    sessionSlot: GlobalKeyEventMonitor.TriggerSlot?,
    sessionBinding: KeyBinding?
  ) -> (
    trigger: KeyBinding,
    secondary: KeyBinding?,
    readAloud: KeyBinding,
    translate: KeyBinding?,
    modos: [(id: String, binding: KeyBinding)]
  ) {
    func held(_ slot: GlobalKeyEventMonitor.TriggerSlot) -> KeyBinding? {
      sessionSlot == slot ? sessionBinding : nil
    }

    // La tecla de cada modo que tiene una. Es lo que faltaba: los modos se
    // guardaban con su gatillo y el tap nunca se enteraba, así que de los
    // cinco modos de Alfonso ninguno disparaba nada.
    let modos = settings.modos.compactMap { modo -> (id: String, binding: KeyBinding)? in
      let slot = GlobalKeyEventMonitor.TriggerSlot.modo(modo.id)
      guard let binding = held(slot) ?? modo.gatillo.flatMap(KeyBinding.init) else {
        return nil
      }
      return (modo.id, binding)
    }

    return (
      trigger: held(.primary) ?? settings.dictationTriggerBinding,
      secondary: settings.isSecondLanguageEnabled || sessionSlot == .secondary
        ? held(.secondary) ?? settings.secondaryTriggerBinding
        : nil,
      readAloud: settings.readAloudBinding,
      // Not installed until a target is chosen, so an unconfigured key
      // swallows nothing and behaves as if the feature were not there.
      translate: settings.isTranslationEnabled || sessionSlot == .translate
        ? held(.translate) ?? settings.translateTriggerBinding
        : nil,
      modos: modos
    )
  }

  /// Re-resolves both languages and warms them. Called whenever the Language
  /// section changes a pick, so the key you press next is already prepared
  /// rather than building its analyzer on the keypress.
  func applyLanguages() {
    // Synchronously, before the task: a translate key already queued on this
    // actor would otherwise still find the old pair ready and snapshot it, and
    // the session would insert the language the user just stopped choosing
    // (ADR-0004).
    let request = translation.invalidate()
    Task { [weak self] in
      guard let self else { return }
      do {
        try await prepareLanguages(request: request)
        isPrepared = true
        fallaDePreparacion = nil
      } catch {
        isPrepared = false
        preparationFailed(.motorFallo(error.localizedDescription))
      }
    }
  }

  /// Resolves both picks, drops anything no longer bound to a key, then warms
  /// the primary language. The second warms behind it and never throws: a
  /// model that still needs downloading must not delay the primary key.
  private func prepareLanguages(request: Int) async throws {
    let primary = try await dependencies.resolveLocale(
      settings.recognitionLocaleIdentifier
    )
    primaryLocale = primary

    // Resolved strictly: a stored pick this Mac cannot transcribe drops the
    // second language instead of quietly becoming the system default, which
    // would dictate in a language the user never chose.
    var secondary: Locale?
    if settings.isSecondLanguageEnabled {
      secondary = await dependencies.supportedLocale(
        settings.secondaryRecognitionLocaleIdentifier
      )
    }
    // A second language equal to the first is not a second language.
    secondaryLocale = secondary == primary ? nil : secondary

    let bound = [primary, secondaryLocale].compactMap(\.self)
    await dependencies.retainOnly(bound)
    try await dependencies.prewarm(primary)

    if let secondaryLocale {
      try? await dependencies.prewarm(secondaryLocale)
    }

    // Started, not awaited, which is what "never fatal" has to mean: this
    // returning is what sets isPrepared and installs the event tap, and a
    // translation model that will not load must not hold plain dictation
    // behind a feature the user may never press. A translate key pressed in
    // the gap is refused and retried, which the begin guard already does.
    let pair = settings.translationPair(from: primary)
    Task { [weak self] in
      await self?.translation.apply(pair, from: primary, request: request)
    }
  }

  /// Records which slot owns the session about to start, and the key it owns
  /// it with. Both together, always: a slot claimed without its key leaves the
  /// last session's key pinned, and the tap then holds one the user cannot
  /// press while refusing the one they can.
  private func claimSession(for slot: GlobalKeyEventMonitor.TriggerSlot) {
    activeSlot = slot
    // Una sesión nueva no es nota salvo que `dictarNota` diga lo contrario
    // justo después; lo mismo el «sin modo» de un atajo.
    sesionEsNota = false
    sesionSinModo = false
    if let rol = slot.bindingRole {
      activeBinding = settings.binding(for: rol)
    } else {
      // Un modo: su tecla vive dentro del modo. Que sea nil —el modo se
      // borró entre el apretón y esto— es el mismo caso que un rol cuya
      // tecla cambió: la sesión sigue y el tap ya tiene la suya.
      activeBinding = settings.modos.modo(slot.modoID)?.gatillo
        .flatMap(KeyBinding.init)
    }
  }

  private func locale(for slot: GlobalKeyEventMonitor.TriggerSlot) -> Locale? {
    switch slot {
    case .primary: primaryLocale
    case .secondary: secondaryLocale ?? primaryLocale
    // The source of a translation is always the primary language. The second
    // language exists so a different language can be dictated; translating
    // from it would put two settings behind one key.
    case .translate: primaryLocale
    // Un modo transforma lo dictado, no cambia de idioma: dicta en el
    // principal, como el atajo de siempre.
    case .modo: primaryLocale
    // La conversación no abre un dictado; si llegara acá, el principal.
    case .conversar: primaryLocale
    }
  }

  /// The HUD's language tag, shown only once a second language exists: with
  /// one language there is nothing to disambiguate.
  private var activeLanguageTag: String? {
    // A translate session names the pair whatever else is configured. The
    // target is the one thing the user cannot check anywhere else before
    // speaking, and a wrong one is only obvious after the text lands.
    if activeSlot == .translate { return translation.pair?.tag }
    guard secondaryLocale != nil, let locale = locale(for: activeSlot) else { return nil }
    return SpeechLanguageCatalog.tag(for: locale)
  }

  /// True while a released trigger is still being turned into inserted text.
  /// Termination waits on this rather than racing it.
  var isFinishing: Bool { finishTask != nil }

  /// How long a quit is held for a finish still in flight.
  ///
  /// Long enough for the longest bounded step a finish can be inside. A
  /// translating session waits out `TranslationService.defaultTimeout` before
  /// it writes history or reaches the clipboard, and killing the process in
  /// that window loses the words with nothing to recover them from. No longer
  /// than that: a wedged insertion must not hold the quit open forever.
  /// Con Claude, lo peor es su plazo entero y después el respaldo de Apple.
  static let finishGrace = TraductorConClaude.plazoPorDefecto
    + TranslationService.defaultTimeout
    + TransformacionDeModo.timeoutPorDefecto
    + .seconds(2)

  /// Waits for an in-flight finish to insert its text, giving up after
  /// `timeout` so a stuck insertion cannot hold the quit forever. Giving up
  /// only stops the waiting; the finish keeps running until the process goes.
  func waitForFinish(timeout: Duration = DirectDictationController.finishGrace) async {
    guard let finishTask else { return }
    await awaitValue(of: finishTask, orGiveUpAfter: timeout)
  }

  func stop() {
    // Before anything else: quitting mid-session must not leave the Mac quiet.
    ducking.restore()
    silenciador.devolver()
    noSpeechTask?.cancel()
    permissionTask?.cancel()
    permissionWatchTask?.cancel()
    sessionStartTask?.cancel()
    // The finish is deliberately not cancelled: it holds the user's last
    // words, and termination has already given it its window through
    // waitForFinish.
    keyEventMonitor?.stop()
    isPrepared = false

    // A finish still in flight holds the user's last words. Shutting the
    // speech service down beside it would cancel the very session the finish
    // is reading, and whichever task the scheduler ran first would decide
    // whether that text was inserted or dropped. Waiting first makes the
    // order a rule instead of a race.
    //
    // Bounded, because stop() is not only called on the way out: a wedged
    // insertion must not keep the speech service alive forever.
    Task { [dependencies, finishTask] in
      if let finishTask {
        await awaitValue(of: finishTask, orGiveUpAfter: Self.finishGrace)
      }
      await dependencies.shutDownRecognition()
      await translation.shutDown()
    }
  }

  /// Si la sesión en curso es una nota rápida: termina en Apple Notas y no
  /// pegada donde estaba el cursor.
  private(set) var sesionEsNota = false

  /// Empieza una nota rápida (el 7 de la lista del 2026-09-24): una sesión
  /// trabada del atajo de siempre, como la del menú, que al terminar guarda
  /// lo dicho en Apple Notas. Trabada porque la abre un clic y no una tecla
  /// sostenida; se termina con la tecla de dictado o con otro clic, y Esc la
  /// cancela, igual que cualquier otra.
  ///
  /// Del atajo de siempre y no una ranura propia: así la tecla que ya
  /// conoces la termina, sin aprender otra.
  func dictarNota() {
    guard !machine.isSessionActive else {
      // Un segundo clic con la nota abierta la termina.
      if sesionEsNota { send(.menuToggled(now: .now)) }
      return
    }
    claimSession(for: .primary)
    sesionEsNota = true
    send(.menuToggled(now: .now))
  }

  /// Empieza a dictar traduciendo, desde el panel del hover (2026-09-24): la
  /// misma sesión que la tecla de traducir, pero trabada, porque la abre un
  /// clic. Se termina con la tecla, con un clic en la muesca o con otro clic
  /// en el botón; Esc la cancela.
  func dictarTraduciendo() {
    guard !machine.isSessionActive else {
      terminarSesionTrabada()
      return
    }
    guard settings.isTranslationEnabled else { return }
    claimSession(for: .translate)
    send(.menuToggled(now: .now))
  }

  /// Termina el dictado trabado en curso, como volver a tocar su tecla. Lo
  /// usa el clic en la muesca (`HUDStage.clicDuranteLaSesionTrabada`).
  func terminarSesionTrabada() {
    guard machine.isSessionActive else { return }
    send(.menuToggled(now: .now))
  }

  /// Si la sesión en curso la abrió un atajo que pidió dictar **sin modo**:
  /// ni el modo elegido para el atajo general ni «Dilo decide», porque la
  /// persona dijo cuál quería.
  private(set) var sesionSinModo = false

  /// Qué modo pide un atajo de la app Atajos o Siri (`DictarIntent`).
  enum ModoPedido: Equatable, Sendable {
    /// Como el ítem del menú: el atajo general, con el modo que tenga
    /// elegido en el panel del hover.
    case elDelAtajoGeneral
    /// Las palabras como se dijeron, sin ninguna IA.
    case ninguno
    /// Un modo por su id, como si se hubiera apretado su tecla.
    case modo(String)
  }

  /// Lo que hizo un pedido de dictar desde afuera.
  enum RespuestaAlDictar: Equatable, Sendable {
    case empezo, termino
    /// El modo pedido ya no existe (se borró después de armar el atajo).
    case modoDesconocido
  }

  /// Empieza un dictado trabado desde Atajos o Siri, o termina el que está
  /// en curso, igual que el ítem del menú (fase 5, 2026-10-15). Trabado
  /// porque nadie sostiene una tecla; se termina con el gatillo, con un clic
  /// en la muesca o corriendo el atajo otra vez, y Esc lo cancela.
  @discardableResult
  func dictarDesdeUnAtajo(_ pedido: ModoPedido) -> RespuestaAlDictar {
    guard !machine.isSessionActive else {
      send(.menuToggled(now: .now))
      return .termino
    }
    switch pedido {
    case .elDelAtajoGeneral:
      claimSession(for: .primary)
    case .ninguno:
      claimSession(for: .primary)
      sesionSinModo = true
    case let .modo(id):
      guard settings.modos.modo(id) != nil else { return .modoDesconocido }
      claimSession(for: .modo(id))
    }
    send(.menuToggled(now: .now))
    return .empezo
  }

  func toggleFromMenu() {
    // The menu item has no language of its own, so it dictates in the first.
    if !machine.isSessionActive {
      claimSession(for: .primary)
    }
    send(.menuToggled(now: .now))
  }

  func requestPermissionsAndPrepare() {
    permissionTask?.cancel()
    isPrepared = false
    fallaDePreparacion = nil
    // Synchronously, for the same reason as applyLanguages: the work below is
    // a task, and nothing may translate against a pair it has not resolved.
    let request = translation.invalidate()

    permissionTask = Task { [weak self] in
      guard let self else { return }

      let microphoneGranted = await dependencies.requestMicrophoneAccess()
      guard !Task.isCancelled else { return }
      guard microphoneGranted else {
        preparationFailed(.microfonoDenegado)
        return
      }

      let speechGranted = await dependencies.requestSpeechAccess()
      guard !Task.isCancelled else { return }
      guard speechGranted else {
        preparationFailed(.reconocimientoDeVozDenegado)
        return
      }

      // Ask for one privacy permission at a time. Requesting Accessibility
      // beside the microphone prompt makes macOS stack or suppress dialogs.
      dependencies.requestAccessibilityAccess()

      do {
        try await prepareLanguages(request: request)
      } catch {
        guard !Task.isCancelled else { return }
        preparationFailed(.motorFallo(error.localizedDescription))
        return
      }

      isPrepared = true
      // La primera lectura de lo que impide dictar abre la conexión con
      // Core Audio y TCC —decenas de milisegundos de pared la primera vez,
      // décimas de milisegundo después—. Se paga acá, al preparar, y no en el
      // primer gatillo.
      _ = dependencies.leerPermisos()
      installTriggerMonitor()
    }
  }

  /// Watches for a permission the user is granting right now.
  ///
  /// Accessibility is granted in System Settings while Dilo is already
  /// running, and macOS tells the app nothing when it changes. Checking once at
  /// launch meant the trigger key stayed dead after the user had done everything
  /// right, with no hint that a relaunch was needed. This polls instead, and
  /// installs the tap the moment it is allowed to.
  private func startPermissionWatch() {
    guard permissionWatchTask == nil else { return }

    permissionWatchTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, let self else { return }
        // Never interrupt the dialog the user is reading.
        guard !dependencies.isPermissionAlertPresenting() else { continue }
        guard dependencies.hasAccessibilityAccess() else { continue }

        permissionWatchTask = nil
        if keyEventMonitor?.start() == true {
          dependencies.showMessage("Dilo está listo", nil)
        } else {
          dependencies.showRelaunchAlert()
        }
        return
      }
    }
  }

  /// The machine's current state, so tests can pin transitions the
  /// controller's effects produce.
  var sessionStateForTesting: DictationSessionMachine.State { machine.state }
  /// Si hay un Esc esperando su «Deshacer».
  var hayRetenidoForTesting: Bool { machine.hayRetenido }
  /// Whether preparation has finished, so a test can wait for the state it
  /// needs rather than for a duration. Preparation grew a translation tail,
  /// and a fixed sleep long enough on an idle machine is not long enough on a
  /// loaded one.
  var isPreparedForTesting: Bool { isPrepared }
  var isTranslationReadyForTesting: Bool { translation.isReady }
  /// The key the session in flight owns, for the rule that a rebind must not
  /// take it away.
  var activeBindingForTesting: KeyBinding? { activeBinding }
  /// The resolved pair. Preparation no longer waits for translation, so a test
  /// about a translate press has to wait for this rather than for isPrepared.
  var translationPairForTesting: TranslationPair? { translation.pair }
  /// Lo que la captura de contexto leyó hasta ahora, sin soltarlo: un test
  /// espera a que llegue antes de soltar, como lo haría quien habla.
  var contextoLeidoForTesting: ContextoCapturado { contextoDelDictado.leidoHastaAhora }

  /// Atiende un evento del monitor. `instante` es cuándo ocurrió, no cuándo
  /// se lo atiende: el umbral del toque corto se mide entre los dos eventos
  /// de la persona y no entre las dos veces que este método alcanzó a correr.
  func handle(
    _ event: GlobalKeyEventMonitor.Event,
    at instante: ContinuousClock.Instant = .now
  ) {
    switch event {
    case let .triggerPressed(slot)
      where slot == .conversar || (hayConversacion() && !machine.isSessionActive):
      slotDeLaConversacion = slot
      onConversacion?(true)
    case let .triggerReleased(slot) where slot == slotDeLaConversacion:
      slotDeLaConversacion = nil
      onConversacion?(false)
    case let .triggerPressed(slot):
      // While a session runs, only the key that started it controls it. The
      // other language's key is inert until this session ends, so a latched
      // German session cannot be stopped by the English key.
      if machine.isSessionActive {
        guard slot == activeSlot else { return }
      } else {
        claimSession(for: slot)
      }
      send(.triggerPressed(now: instante))
    case let .triggerReleased(slot):
      guard slot == activeSlot else { return }
      send(.triggerReleased(now: instante))
    case .cancelPressed:
      send(.escapePressed)
    case .readAloudPressed:
      send(.readAloudPressed)
    case .shapingCycleLeft:
      cycleShapingChoice(by: -1)
    case .shapingCycleRight:
      cycleShapingChoice(by: 1)
    }
  }

  private func send(_ action: DictationSessionMachine.Action) {
    let wasActive = machine.isSessionActive
    // El gesto de la sesión que viene, leído en reposo: con una sesión en
    // curso la máquina lo ignora y la sesión sigue con el suyo.
    if !wasActive {
      machine.fijarGesto(
        umbral: .milliseconds(settings.umbralDeToqueMs),
        conDeshacer: settings.deshacerCancelacion
      )
    }
    let effects = machine.reduce(action)
    anotarLatencia(action, efectos: effects)
    perform(effects)
    // A session keeps the key that started it even after Settings turns that
    // language off, so ending one is when the binding has to be given back.
    // Nothing else reapplies them, and a stale slot either swallows its key or
    // starts a session in a language nobody chose.
    if wasActive, !machine.isSessionActive {
      applyKeyBindings()
    }
    updateShapingCycleCapture()
    actualizarTope()
  }

  /// Arms the bare-arrow capture exactly while the machine is recording a
  /// session whose snapshot carries a library of modes. Derived from the state
  /// after every action rather than toggled on named paths, so no exit —
  /// finish, Escape, failure, timeout — can leave the arrows swallowed.
  private func updateShapingCycleCapture() {
    var shouldCapture = false
    if case .recording = machine.state,
       currentSessionSettings?.modos.isEmpty == false {
      shouldCapture = true
    }
    guard shouldCapture != isShapingCycleCaptureEnabled else { return }
    isShapingCycleCaptureEnabled = shouldCapture
    keyEventMonitor?.setShapingCycleCaptureEnabled(shouldCapture)
    dependencies.setShapingCycleCaptureEnabled(shouldCapture)
  }

  /// One arrow press: the next or previous entry in [library…, None],
  /// wrapping at the ends. Guarded on recording rather than on the capture
  /// flag, because a queued event can arrive after the session moved on.
  private func cycleShapingChoice(by delta: Int) {
    guard case .recording = machine.state,
       let biblioteca = currentSessionSettings?.modos,
       !biblioteca.isEmpty
    else { return }
    let optionCount = biblioteca.count + 1
    let current = sessionModo
      .flatMap { elegido in biblioteca.firstIndex { $0.id == elegido.id } }
      ?? biblioteca.count
    let next = (current + delta + optionCount) % optionCount
    sessionModo = next < biblioteca.count ? biblioteca[next] : nil
    // Mover las flechas es elegir: desde acá, "Dilo decide" ya no opina.
    modoElegidoAMano = true
    dependencies.showShapingChoice(shapingChoiceLabel)
  }

  /// El modo de la sesión por su nombre, o nil cuando no hay ninguno.
  ///
  /// Nil y no «Sin modo». Ese texto era relleno: la muesca abierta pasaba a
  /// decir que no está haciendo nada, ocupando la misma franja que el nombre
  /// del modo cuando sí lo hay —«el que diga *sin modo* me da igual: fuera»,
  /// el veredicto del 2026-09-21—. Sin modo no hay nada que nombrar, así que
  /// el chip no se dibuja (`DictationHUDShellView.chipDeModo`).
  ///
  /// El nombre pelado a propósito: la forma decide cómo se escribe, porque su
  /// ancho es una decisión de layout.
  private var shapingChoiceLabel: String? {
    guard currentSessionSettings?.modos.isEmpty == false else { return nil }
    return sessionModo?.nombre
  }

  private func perform(_ effects: [DictationSessionMachine.Effect]) {
    for effect in effects {
      perform(effect)
    }
  }

  private func perform(_ effect: DictationSessionMachine.Effect) {
    switch effect {
    case .checkAndBegin:
      checkAndBegin()
    case .beginRecognition:
      beginRecognition()
    case let .finishRecognition(speakingDuration):
      finishRecognition(speakingDuration: speakingDuration)
    case .cancelRecognition:
      Task { [weak self] in
        guard let self else { return }
        await dependencies.cancelRecognition()
        send(.sessionEnded)
      }
    case .cancelStartTask:
      sessionStartTask?.cancel()
    case let .setEscapeCapture(enabled):
      keyEventMonitor?.setEscapeCaptureEnabled(enabled)
    case .startNoSpeechTimer:
      startNoSpeechTimer()
    case .stopNoSpeechTimer:
      stopNoSpeechTimer()
    case let .showListening(latched):
      let session = DictationSessionSettings(
        settings: settings,
        translation: activeSlot == .translate ? translation.pair : nil,
        motorDeTraduccion: activeSlot == .translate ? motorDeTraduccionAprobado : .apple
      )
      currentSessionSettings = session
      // El modo de la sesión empieza en el de la tecla que la abrió. Si fue
      // el atajo de siempre, empieza sin ninguno: el dictado normal sale
      // limpio y no pasa por ninguna IA, salvo que "Dilo decide" opine al
      // final. Congelado acá y no leído después: cambiar Ajustes a mitad de
      // dictado aplica al siguiente (ADR-0004).
      let deLaTecla = session.modos.modo(activeSlot.modoID)
      // El atajo general usa el modo que se eligió en el panel del hover,
      // si se eligió uno; sin elección sigue siendo el dictado limpio.
      modoDelAtajoGeneral = activeSlot == .primary && !sesionEsNota && !sesionSinModo
        ? session.modos.modo(session.modoDelAtajoGeneralID) : nil
      sessionModo = deLaTecla ?? modoDelAtajoGeneral
      // Una nota sale como se dijo: ni el modo del atajo general —una nota no
      // es un correo— ni «Dilo decide», que opinaría por la app al frente,
      // que no es donde va a terminar. El del hover no es elegir a mano: una
      // frase disparadora le gana.
      modoElegidoAMano = deLaTecla != nil || sesionEsNota || sesionSinModo
      dependencies.mostrarQueEsNota(sesionEsNota)
      dependencies.showListening(
        focusedTarget?.displayID,
        latched,
        session,
        activeLanguageTag
      )
      dependencies.showShapingChoice(shapingChoiceLabel)
    case .showLatched:
      dependencies.showLatched()
    case .showLiveText:
      if let pendingLiveText {
        ultimoEnVivo = (pendingLiveText, pendingVolatileText)
        dependencies.showLiveText(
          pendingLiveText, conCuentaRegresiva(pendingLiveText, pendingVolatileText)
        )
      }
    case .showFinalizing:
      dependencies.showFinalizing()
    case .hideHUD:
      dependencies.hideHUD()
    case let .notifyRecording(isRecording):
      // Ducking rides this effect because it is the one signal that fires on
      // every terminal path — inserted, cancelled, failed, or timed out — so
      // the volume cannot be left down by a route nobody thought about.
      if isRecording {
        if currentSessionSettings?.ducksOtherAudio == true { ducking.duck() }
        if currentSessionSettings?.silenciaLoQueSuena == true { silenciador.callar() }
      } else {
        ducking.restore()
        silenciador.devolver()
        activity.release()
        contextoDelDictado.cancelar()
        registrarLatencia()
        focusedTarget = nil
        sessionStartTask = nil
        currentSessionSettings = nil
      }
      onRecordingStateChange?(isRecording, currentSessionSettings)
    case .triggerReadAloud:
      onReadAloudTriggered?()
    case .reintentarTomaFallida:
      ejecutarReintento()
    case .retenerParaDeshacer:
      retenerParaDeshacer()
    case .entregarLoRetenido:
      entregarLoRetenido()
    case .descartarLoRetenido:
      retenida = nil
      vigiaDeLaRetencion?.cancel()
      vigiaDeLaRetencion = nil
    }
  }

  /// «Deshacer» en la muesca, después de un Esc.
  func deshacerCancelacion() {
    send(.deshacerCancelacion)
  }

  /// El Esc de una sesión con voz: el reconocimiento termina en silencio y
  /// lo dicho queda en RAM la ventana para deshacer, sin pegarse ni ir al
  /// historial. La muesca lo ofrece con un clic.
  private func retenerParaDeshacer() {
    let segundosDeVoz = relojDeFases.instante(de: .microfonoAbierto)
      .map { Double(RelojDeFases.milisegundos($0.duration(to: .now))) / 1_000 } ?? 0
    // Todo lo que la entrega lee de la sesión, ahora: el reset que viene
    // detrás lo borra.
    var porRetener = CancelacionRetenida(
      crudo: "",
      destino: focusedTarget,
      sesion: currentSessionSettings ?? settings.sessionSettings,
      modo: sessionModo,
      modoElegidoAMano: modoElegidoAMano,
      esNota: sesionEsNota,
      ranura: activeSlot,
      tecla: activeBinding,
      segundosDeVoz: segundosDeVoz
    )
    dependencies.showResultado(
      .accionable(AvisoConAccion(
        texto: String(localized: "Cancelado · clic para deshacer"),
        accion: .deshacerCancelacion
      ))
    )
    vigiaDeLaRetencion?.cancel()
    let reloj = dependencies.relojDeLaRetencion
    vigiaDeLaRetencion = Task { [weak self] in
      do { try await reloj.sleep(GestoDelGatillo.ventanaParaDeshacer) } catch { return }
      self?.send(.retencionVencida)
    }
    Task { [weak self, dependencies] in
      var crudo = ""
      do {
        crudo = try await dependencies.finishRecognition()
      } catch TomaSinTexto.guardada {
        // El motor no sacó texto y guardó la toma para reintentar. Para un
        // Esc eso es ruido: la persona canceló, no hay nada que rescatar.
        await dependencies.descartarToma()
      } catch {}
      guard let self else { return }
      if crudo.isEmpty || !machine.hayRetenido {
        // Nada que deshacer: el aviso no puede ofrecer lo que no hay.
        send(.retencionVencida)
        dependencies.hideHUD()
      } else {
        porRetener.crudo = crudo
        retenida = porRetener
      }
      send(.sessionEnded)
    }
  }

  /// «Deshacer»: la entrega de siempre con lo retenido, como si se hubiera
  /// soltado en vez de apretar Esc.
  private func entregarLoRetenido() {
    vigiaDeLaRetencion?.cancel()
    vigiaDeLaRetencion = nil
    guard let lo = retenida else {
      send(.sessionEnded)
      return
    }
    retenida = nil
    focusedTarget = lo.destino
    currentSessionSettings = lo.sesion
    sessionModo = lo.modo
    modoElegidoAMano = lo.modoElegidoAMano
    sesionEsNota = lo.esNota
    activeSlot = lo.ranura
    activeBinding = lo.tecla
    dependencies.showProcesando()
    finishRecognition(speakingDuration: lo.segundosDeVoz, crudoRetenido: lo.crudo)
  }

  /// The text carried alongside the current `updateReceived` action; the
  /// machine decides whether it shows, the controller remembers what.
  private var pendingLiveText: String?
  private var pendingVolatileText = ""

  private func checkAndBegin() {
    // Held here rather than once recording starts: the first HUD frames are
    // what a napped process draws badly, and by then they have been drawn.
    // Every rejection below releases it, because .beginRejected produces no
    // effects and nothing downstream would.
    activity.hold()
    // Un dictado nuevo, aunque sea en el mismo campo, no es una corrección
    // del anterior: nunca dos vigías.
    correcciones.detener()

    // Todo lo que impide dictar se mira acá, antes de abrir el micrófono, y
    // se dice el primero (`EstadoParaDictar`). Antes un micrófono quitado o
    // un permiso sin contestar se descubría con el micrófono ya abierto y el
    // motor fallando a media frase.
    let accesibilidad = dependencies.hasAccessibilityAccess()
    // El foco sólo se puede leer con Accesibilidad; sin ella no hay campo
    // que mirar y el bloqueo ya lo dice.
    let target = accesibilidad ? dependencies.captureFocusedTarget() : nil
    let permisos = dependencies.leerPermisos()
    let (traduccion, motorDeTraduccion) = estadoDeLaTraduccion()
    motorDeTraduccionAprobado = motorDeTraduccion
    let estado = EstadoParaDictar(
      permisos: permisos,
      // La preparación de hoy pide este permiso con los dos motores
      // (`requestPermissionsAndPrepare`): sin él, tampoco Parakeet dicta.
      pideReconocimientoDeVoz: true,
      admitePegadoDirecto: Anfitrion.actual.admite(.pegadoDirecto),
      accesibilidad: accesibilidad,
      motor: estadoDelMotor(permisos),
      campoEsSeguro: target?.isSecure == true,
      traduccion: traduccion
    )

    guard let bloqueo = estado.primerBloqueo else {
      focusedTarget = target
      // En paralelo y nunca antes del micrófono: lo que no llegue al soltar no
      // existe (`CapturaDeContexto`).
      contextoDelDictado.empezar(
        destino: target,
        fuentes: settings.fuentesDeContexto,
        // El sitio también elige modo, pero sólo si nadie apretó la tecla de
        // uno y algún modo tiene sitios.
        sitioParaElegirModo: activeSlot.modoID == nil && settings.unAtajoDiloDecide
          && settings.modos.contains { !$0.sitios.isEmpty },
        leerAntesDelCursor: settings.mayusculaSegunElCursor,
        lectores: dependencies.lectoresDeContexto
      )
      // El corrector se despierta mientras la persona habla: consultarlo al
      // soltar tiene que costar un milisegundo, no un tercio de segundo.
      if settings.mayusculaSegunElCursor { dependencies.calentarCorrector() }
      send(.beginApproved)
      return
    }
    AppLog.session.notice("dictado bloqueado: \(bloqueo.nombreEnElLog, privacy: .public)")
    avisar(bloqueo, en: target?.displayID)
    switch bloqueo {
    case .sinAccesibilidad:
      // One dialog that explains it, not the system prompt again on every press.
      dependencies.showAccessibilitySetupAlert()
      startPermissionWatch()
    case .microfonoSinDecidir:
      // El aviso de macOS sólo sale cuando alguien lo pide: si la
      // preparación ya terminó, se vuelve a pedir; si sigue esperando la
      // respuesta, el aviso ya está en pantalla.
      if fallaDePreparacion != nil { requestPermissionsAndPrepare() }
    case .traduccionSinIdioma, .traduccionNoLista:
      translation.retry()
    default:
      break
    }
    activity.release()
    send(.beginRejected)
  }

  /// En qué está el motor, para `EstadoParaDictar`. Si la preparación paró en
  /// un permiso que ahora sí está, vuelve a preparar: dar el permiso y volver
  /// a apretar tiene que bastar, sin relanzar Dilo.
  private func estadoDelMotor(_ permisos: PermisosLeidos) -> EstadoParaDictar.Motor {
    if isPrepared { return .listo }
    switch fallaDePreparacion {
    case .microfonoDenegado?, .microfonoSinDecidir?, .reconocimientoDeVozDenegado?:
      guard permisos.microfono == .concedida, permisos.reconocimientoDeVoz == .concedida else {
        return .esperandoPermiso
      }
      requestPermissionsAndPrepare()
      return .preparando
    case let .motorFallo(porque)?:
      return .fallo(porque)
    default:
      guard let descargaDelModelo, descargaDelModelo.locale == primaryLocale else {
        return .preparando
      }
      return .bajandoModelo(
        idioma: SpeechLanguageCatalog.shortName(for: descargaDelModelo.locale),
        porcentaje: Int(descargaDelModelo.fraccion * 100)
      )
    }
  }

  /// Si la sesión que se va a abrir traduce, si puede, y con qué.
  ///
  /// El motor se resuelve acá, al apretar, y no al preparar los idiomas: la
  /// clave de Anthropic se pega en Ajustes en cualquier momento, y preguntar
  /// al Llavero al apretar es lo mismo que ya hacen los modos al empezar
  /// cada sesión. Sólo se pregunta con la tecla de traducir y sólo si la
  /// respuesta cambia algo (`MotorDeTraduccion.necesitaSaberSiHayClave`).
  /// Con Claude no hace falta que el modelo de Apple esté listo: ése es sólo
  /// el respaldo.
  private func estadoDeLaTraduccion() -> (EstadoParaDictar.Traduccion, MotorDeTraduccion.Resuelto) {
    guard activeSlot == .translate else { return (.noAplica, .apple) }
    guard let pair = translation.pair else { return (.sinIdioma, .apple) }
    let origen = pair.source.minimalIdentifier
    let destino = settings.translationTargetIdentifier
    let elegido = settings.motorDeTraduccion
    let hayClave = MotorDeTraduccion.necesitaSaberSiHayClave(
      elegido: elegido, origen: origen, destino: destino
    ) && dependencies.hayClaveDeAnthropic()
    let motor = MotorDeTraduccion.resolver(
      elegido: elegido, origen: origen, destino: destino, hayClave: hayClave
    )
    switch motor {
    case .claude: return (.lista, motor)
    case .faltaLaClave: return (.sinClave, motor)
    case .apple: return (translation.isReady ? .lista : .noLista, motor)
    }
  }

  /// Dice un bloqueo en la muesca: con su clic si se arregla en Ajustes del
  /// Sistema, como un mensaje si no.
  private func avisar(_ bloqueo: BloqueoDelDictado, en displayID: CGDirectDisplayID?) {
    if let aviso = bloqueo.avisoConAccion, let mostrarAviso = dependencies.mostrarAviso {
      mostrarAviso(aviso, displayID)
    } else {
      dependencies.showMessage(bloqueo.texto, displayID)
    }
  }

  private func beginRecognition() {
    guard let locale = locale(for: activeSlot) else {
      AppLog.session.error("no locale resolved for the trigger; refusing to begin")
      fail(message: "Preparando el reconocimiento…", wasCancelled: false)
      return
    }
    AppLog.session.info(
      "session began on \(String(describing: self.activeSlot), privacy: .public) in \(locale.identifier, privacy: .public)"
    )

    sessionStartTask = Task { [weak self] in
      guard let self else { return }
      do {
        // Tus palabras entran como contexto del motor antes de reconocer.
        // Es barato: sólo hace algo la primera vez después de que alguien
        // edite su diccionario, y esa vez paga rearmar la sesión preparada.
        await dependencies.setPalabrasPropias(settings.palabrasPropias)
        try await dependencies.startRecognition(
          locale,
          { [weak self] update in
            Task { @MainActor [weak self] in
              self?.receive(update)
            }
          },
          { [weak self] message in
            Task { @MainActor [weak self] in
              self?.fail(message: message, wasCancelled: false)
            }
          },
          { [weak self] level in
            Task { @MainActor [weak self] in
              self?.relojDeFases.marcar(.primerAudio)
              self?.dependencies.showAudioLevel(level)
            }
          },
          { [weak self] isLoading in
            Task { @MainActor [weak self] in
              self?.showModelLoading(isLoading)
            }
          }
        )
        guard !Task.isCancelled else {
          await dependencies.cancelRecognition()
          send(.sessionEnded)
          return
        }
        sessionStartTask = nil
        send(.recognitionStarted(now: .now))
      } catch {
        sessionStartTask = nil
        if Task.isCancelled {
          send(.recognitionFailed(wasCancelled: true))
        } else {
          fail(message: error.localizedDescription, wasCancelled: false)
        }
      }
    }
  }

  private func receive(_ update: SpeechRecognitionService.Update) {
    let displayText = update.displayText
    let hasVisibleText = !displayText
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty
    pendingLiveText = update.finalizedText
    // El HUD recibe los dos pedazos por separado y los dibuja distinto, así
    // que el espacio de la costura viaja con lo volátil: pegarlos a secas
    // dejaba la última palabra firme contra la primera que todavía tiembla.
    pendingVolatileText = Union.colaDe(update.finalizedText, update.volatileText)
    if hasVisibleText { relojDeFases.marcar(.primerParcial) }
    send(.updateReceived(hasVisibleText: hasVisibleText))
    pendingLiveText = nil
    pendingVolatileText = ""
  }

  /// Qué modo aplica a este dictado, y el texto sin la frase que lo eligió.
  ///
  /// La tecla siempre gana: es lo que la persona dijo explícitamente, y
  /// ningún decididor tiene derecho a contradecirla. Después, una frase
  /// disparadora; después el modo del hover; y sólo con "un atajo, Dilo
  /// decide" prendido, el sitio, la app y las palabras clave
  /// (`ResolucionDeModo.alTerminar`, con tests).
  private func resolverModo(
    texto: String,
    delaTecla: Modo?,
    elegidoAMano: Bool,
    delAtajoGeneral: Modo?,
    contexto: ContextoCapturado,
    session: DictationSessionSettings
  ) async -> (eleccion: ResolucionDeModo.Eleccion, texto: String) {
    await ResolucionDeModo.alTerminar(
      texto: texto,
      aLaMano: elegidoAMano ? .eligio(delaTecla) : .nadie,
      delAtajoGeneral: delAtajoGeneral,
      contexto: ContextoDeDecision(
        appAlFrente: contexto.nombreDeApp, bundleID: contexto.bundleID, sitio: contexto.sitio
      ),
      modos: session.modos,
      unAtajoDiloDecide: session.unAtajoDiloDecide,
      decider: DeciderPorReglas(modos: session.modos)
    )
  }

  /// Corre el modo con el contexto de la app cuando lo hay. Sin contexto, el
  /// camino de siempre.
  private func transformar(
    _ texto: String, _ modo: Modo, _ proveedor: ResolucionDeProveedor.DeSesion,
    contexto: SobreDelDictado.ContextoDeLaApp?, contextoEnLinea: Bool
  ) async -> TransformacionDeModo.Resultado {
    if let contexto, let conContexto = dependencies.transformarConContexto {
      return await conContexto(texto, modo, proveedor, contexto, contextoEnLinea)
    }
    return await dependencies.transformar(texto, modo, proveedor)
  }

  /// Lo que el historial guarda como modo: el nombre y el id, porque el
  /// nombre se edita y el id no, y —cuando lo eligió Dilo— la regla que ganó.
  /// Un modo que apareció sin que nadie apretara su tecla tiene que poder
  /// explicarse, o la próxima vez no se sabe si corregir el dictado o la regla.
  static func paraElHistorial(_ eleccion: ResolucionDeModo.Eleccion) -> String? {
    guard let modo = eleccion.modo else { return nil }
    let nombre = "\(modo.nombre) (\(modo.id))"
    guard let explicacion = eleccion.razon.explicacion else { return nombre }
    return "\(nombre) — \(explicacion)"
  }

  /// Guarda lo último que se dictó y avisa al menú de la barra. Sólo memoria:
  /// nada de esto toca el disco.
  private func recordar(_ dictado: UltimoDictado) {
    guard !dictado.texto(.entregado).isEmpty || !dictado.original.isEmpty else { return }
    ultimoDictado = dictado
    onUltimoDictadoChange?(dictado)
  }

  /// Writes the session's entry, after any translation and before the
  /// insertion: an entry names where the words were headed, and words the
  /// paste then loses are exactly the words history exists to keep.
  private func recordHistory(
    spoken: String,
    delivered: String?,
    modo: String? = nil,
    session: DictationSessionSettings
  ) async {
    guard session.historyEnabled, !spoken.isEmpty else { return }
    // The spoken words are the entry, always. A translation goes beside them
    // rather than instead of them: history exists so a failed insertion cannot
    // lose what was said (ADR-0007), and only the spoken half is unrecoverable.
    var translation: DictationHistoryStore.Translation?
    // Whatever it produced, including the same string back: a name, a URL or
    // a number translates to itself, and the entry still says which languages
    // the session ran between.
    if let pair = session.translation, let delivered {
      translation = DictationHistoryStore.Translation(
        spokenTag: pair.source.shortTag,
        deliveredTag: pair.target.shortTag,
        text: delivered
      )
    }
    await dependencies.recordHistory(
      spoken,
      translation,
      historySource(for: session.insertionDestination),
      modo,
      // Qué motor escuchó, y no cuál estaba elegido: la entrada tiene que
      // poder contestar «¿esto salió de Parakeet o de Apple?» para siempre.
      await dependencies.motorDelDictado(),
      session.historyFolder
    )
  }

  /// What the history entry names as this session's destination.
  ///
  /// Clipboard-only never aims at an application, so naming the one that
  /// happened to hold focus would be a lie. Everything else names where the
  /// words were headed when they were spoken.
  private func historySource(for destination: InsertionDestination) -> String? {
    guard destination != .clipboardOnly else { return "Clipboard" }
    return focusedTarget?.applicationName
  }

  /// Finishes recognition and routes the insertion outcome to its terminal UI.
  ///
  /// - Parameter speakingDuration: The completed session's measured speech time.
  private func finishRecognition(speakingDuration: TimeInterval, crudoRetenido: String? = nil) {
    // Lo que la persona eligió en el momento en que soltó, no lo que Ajustes
    // diga después. Se lee antes de la tarea para que el sembrado de la
    // sesión siguiente no le gane la carrera a este final.
    let modoDeLaTecla = sessionModo
    let elegidoAMano = modoElegidoAMano
    let delAtajoGeneral = modoDelAtajoGeneral
    let esNota = sesionEsNota
    let (contexto, fuentes) = contextoDelDictado.recoger()
    // El campo para el vigía de correcciones, ahora: el `sessionEnded` que
    // sigue al pegado deja `focusedTarget` en nil.
    let anclaParaVigilar = focusedTarget?.ancla
    finishTask = Task { [weak self] in
      guard let self else { return }
      defer { finishTask = nil }
      do {
        // Delivery follows the session snapshot, so a Settings change
        // mid-session applies to the next session (ADR-0004).
        let session = currentSessionSettings ?? settings.sessionSettings
        // El crudo se guarda antes de tocarlo: es lo único de todo esto que
        // no se puede reconstruir (punto 4 del encargo).
        // Lo retenido de un Esc deshecho ya pasó por el motor y la revisión.
        let crudo: String
        if let crudoRetenido {
          crudo = crudoRetenido
        } else {
          crudo = try await dependencies.finishRecognition()
          anotarRevisado()
        }
        // La costura de español de Dilo: todo lo reconocido pasa por DiloText
        // antes de que nadie más lo toque — espacios, muletillas y tus
        // palabras, en ese orden. Las preferencias son las que la sesión
        // capturó al empezar.
        let reglas = DiloText.limpiar(crudo, con: session.textoPreferencias)
        relojDeFases.marcar(.limpio)
        // «…nos vemos mañana. Envía.»: la frase se va acá, al final de las
        // reglas, y no llega al modo ni a la traducción. Si de verdad se
        // manda lo decide `PoliticaDelEnvio` después de pegar.
        let (limpio, pidioEnviar) = session.frasesDeEnvio.map {
          EnvioHablado.analizar(reglas, frases: $0)
        } ?? (reglas, false)

        // Qué modo aplica. La tecla siempre gana; las reglas sólo opinan
        // cuando nadie eligió y la persona lo pidió (spec §7). Una frase
        // disparadora se va del texto: desde acá lo dicho es sin ella.
        let (eleccion, spoken) = await resolverModo(
          texto: limpio,
          delaTecla: modoDeLaTecla,
          elegidoAMano: elegidoAMano,
          delAtajoGeneral: delAtajoGeneral,
          contexto: contexto,
          session: session
        )
        let modo = eleccion.modo

        // A session about to shape keeps the HUD up saying so; every other
        // session dismisses here exactly as before.
        let willShape = modo != nil && !spoken.isEmpty
        if let modo, willShape {
          // Si lo eligió Dilo, también por qué: «Correo · lo dijiste».
          dependencies.showShaping(eleccion.enLaMuesca ?? modo.nombre)
        } else {
          // Antes acá se escondía el HUD y el resultado aterrizaba con la
          // forma ya fuera de pantalla. Ahora se queda: procesando primero,
          // resultado después, reposo al final.
          dependencies.showProcesando()
        }

        // The one place between recognition and insertion where the words may
        // change. A transform that fails delivers nothing: the trigger
        // promised a translation, and pasting the untranslated words instead
        // lands the wrong language in someone else's document.
        var text = spoken
        var transformado: String?
        var avisoDelModo: String?
        var propuestaRechazada: String?
        // El modo primero, la traducción después. Un prompt está escrito en
        // un idioma, con su ejemplo en ese idioma, así que darle una
        // traducción es pedirle trabajar en uno para el que no se escribió.
        if let modo, willShape {
          switch await transformar(
            text, modo, session.proveedorDeSesion(para: modo),
            contexto: contexto.paraElSobre(fuentes), contextoEnLinea: fuentes.tambienEnLinea
          ) {
          case let .transformado(reescrito):
            text = reescrito
            transformado = reescrito
          case let .salioTalCual(aviso):
            // Nunca un segundo proveedor. Se dice qué pasó y las palabras
            // quedan enteras en "Copiar el último dictado".
            avisoDelModo = aviso
          case let .rechazado(propuesta, motivo):
            // Lo que devolvió cambiaba el sentido: va la capa de reglas,
            // que es lo que se pega sin modo, y la propuesta queda en el
            // menú por si el validador se equivocó.
            avisoDelModo = motivo.aviso(modo: modo.nombre)
            propuestaRechazada = propuesta
          case .sinModo:
            break
          }
          relojDeFases.marcar(.modo)
          relojDeFases.conModo = true
        }
        // Shaped or passed through, the phase is over — pero la entrega
        // todavía no, así que la forma pasa a procesando y no a reposo.
        if willShape { dependencies.showProcesando() }

        recordar(
          UltimoDictado(
            original: crudo,
            limpio: spoken,
            transformado: transformado,
            modo: transformado == nil ? nil : modo?.nombre,
            propuestaRechazada: propuestaRechazada
          )
        )

        var avisoDeLaTraduccion: String?
        if let pair = session.translation, !text.isEmpty {
          do {
            let traducido = try await translation.traducir(
              text, with: pair, motor: session.motorDeTraduccion
            )
            text = traducido.texto
            // Claude falló y tradujo Apple: se pega, y se dice.
            avisoDeLaTraduccion = traducido.respaldoPor?.avisoConApple
            relojDeFases.marcar(.traducido)
            relojDeFases.traducido = true
          } catch {
            // El rescate son las palabras como se dijeron, no como las dejó
            // el modo: el modo es una comodidad y lo crudo es lo que tiene
            // que sobrevivir.
            await recordHistory(
              spoken: spoken, delivered: nil,
              modo: Self.paraElHistorial(eleccion), session: session
            )
            // Clipboard-only whatever the session's destination: nothing is
            // pasted, and the words survive where the user can reach them.
            let rescue = await dependencies.insertText(spoken, nil, .clipboardOnly)
            // Ended, not failed: a failure action would drive the machine to
            // cancelling and cancel a session that has already finished.
            send(.sessionEnded)
            // The clipboard can refuse too, while a read still holds its
            // lease. Reporting only the translation would promise words that
            // are not anywhere the user can reach (CONTEXT.md).
            // Si fue Claude, por qué: una clave mala no se arregla igual que
            // un Anthropic saturado.
            let porque = (error as? FallaDeTraduccion)?.aviso
            dependencies.showMessage(
              !rescue.llego ? "No se pudo traducir ni copiar" : porque ?? "No se pudo traducir",
              nil
            )
            return
          }
        }

        // Last before insertion, so the delivered line is what actually
        // lands: written earlier it recorded a translation nobody received,
        // because the mode had not run yet. Still before insertion, so a
        // failed paste cannot lose the words (ADR-0007).
        await recordHistory(
          spoken: spoken, delivered: text,
          modo: Self.paraElHistorial(eleccion), session: session
        )

        if esNota {
          await guardarNota(text, spoken: spoken, speakingDuration: speakingDuration)
          return
        }

        // Lo último antes de pegar: la mayúscula y el espacio según lo que
        // había antes del cursor al empezar. Sólo si se va a pegar, y sólo si
        // la lectura llegó: sin ella no se toca nada.
        if session.ajustarAlCursor, session.insertionDestination != .clipboardOnly {
          text = AjusteAlCursor.ajustar(
            text,
            antesDelCursor: contexto.antesDelCursor,
            tusPalabras: Set(session.textoPreferencias.palabrasPropias),
            esPalabraComun: dependencies.esPalabraComun
          )
        }

        let entrega = await dependencies.insertText(
          text, focusedTarget, session.insertionDestination
        )
        anotarEntrega(entrega, atajo: dependencies.instanteDelAtajo())
        anotarRevision(await dependencies.duracionDeLaRevision())
        AppLog.delivery.info(
          "session ended: \(entrega.nombreEnElLog, privacy: .public), \(UsageMetrics.wordCount(in: spoken), privacy: .public) words in \(speakingDuration, format: .fixed(precision: 1), privacy: .public)s"
        )
        if entrega.llego { dependencies.playPasteSound() }
        // El ↩ de «envía», antes de soltar la sesión: el foco que se usa es
        // el de este dictado, y `sessionEnded` lo deja en nil.
        let envio = PoliticaDelEnvio.decidir(
          pidio: pidioEnviar,
          entrega: entrega,
          textoVacio: text.isEmpty,
          clase: ClaseDeDestino.de(bundleID: focusedTarget?.bundleID),
          campoSeguro: focusedTarget?.isSecure ?? true,
          modoSinTerminar: avisoDelModo != nil,
          admitePegadoDirecto: Anfitrion.actual.admite(.pegadoDirecto)
            && session.insertionDestination != .clipboardOnly
        )
        var avisoDelEnvio = envio.aviso
        if envio == .enviar {
          let mandado = await dependencies.pulsarIntro(focusedTarget)
          AppLog.delivery.info("envía: \(mandado ? "mandado" : "no mandado: teclas apretadas", privacy: .public)")
          if !mandado { avisoDelEnvio = PoliticaDelEnvio.avisoConTeclasApretadas }
        }
        send(.sessionEnded)
        // Qué se acusa y qué se dice lo decide `ResultadoDelNotch.tras`. Lo
        // que no se pegó manda sobre el aviso del modo: las palabras sin
        // destino son lo que no se puede perder en silencio.
        let resultado = ResultadoDelNotch.tras(entrega, texto: text)
        dependencies.showResultado(resultado)
        // Lo que entró se mira un rato por si la persona lo corrige. Una
        // traducción no: lo oído está en otro idioma que lo pegado.
        switch entrega {
        case .pegado, .pegadoSinConfirmar:
          if let anclaParaVigilar, session.translation == nil {
            correcciones.vigilar(
              pegado: text, crudo: crudo, ancla: anclaParaVigilar,
              leer: dependencies.leerCampoParaAprender
            )
          }
        default:
          break
        }
        // Uno solo cabe. Que tradujo Apple va primero: es sobre el idioma
        // que acaba de aterrizar en el documento.
        if resultado.esAcuse || resultado == .copiado,
          let aviso = avisoDelEnvio ?? avisoDeLaTraduccion ?? avisoDelModo
        {
          dependencies.showMessage("\(aviso)", nil)
        }
        if entrega.llego {
          // The words that were spoken, not the words inserted. Speaking
          // duration is measured on the source side, so counting a
          // translation's words against it would divide one language's count
          // by another's minutes.
          await dependencies.recordSession(UsageMetrics.wordCount(in: spoken), speakingDuration)
        }
      } catch {
        AppLog.delivery.error(
          "session failed: \(error.localizedDescription, privacy: .public)"
        )
        fail(message: error.localizedDescription, wasCancelled: false)
      }
      finishTask = nil
    }
  }

  /// El final de una nota rápida: a Apple Notas, y si no se puede, al
  /// portapapeles con el porqué. Las palabras nunca se pierden: el historial
  /// ya las guardó antes de llegar acá (ADR-0007).
  private func guardarNota(_ texto: String, spoken: String, speakingDuration: TimeInterval) async {
    let resultado = await dependencies.guardarNota(texto)
    if resultado == .guardada {
      dependencies.playPasteSound()
      send(.sessionEnded)
      dependencies.showMessage(String(localized: "Nota guardada en Notas, carpeta Dilo."), nil)
      await dependencies.recordSession(UsageMetrics.wordCount(in: spoken), speakingDuration)
      return
    }
    let rescate = await dependencies.insertText(texto, nil, .clipboardOnly)
    send(.sessionEnded)
    let mensaje: String
    switch (resultado, rescate) {
    case (_, .retenido):
      mensaje = String(localized: "No pude guardar la nota en Notas ni copiarla.")
    case (.sinPermiso, _):
      mensaje = String(localized: "Dilo no tiene permiso para usar Notas. Te copié la nota: pégala con ⌘V.")
    default:
      mensaje = String(localized: "No pude guardar la nota en Notas. Te la copié: pégala con ⌘V.")
    }
    dependencies.showMessage(mensaje, nil)
  }

  /// A failure path always ends with the message shown after the reset —
  /// the machine handles the transition, the controller the message.
  private func fail(message: String, wasCancelled: Bool) {
    let effects = machine.reduce(.recognitionFailed(wasCancelled: wasCancelled))
    // The reduce above bypasses send(), so the capture rule re-derives here:
    // a failure must not leave the arrows swallowed.
    updateShapingCycleCapture()
    actualizarTope()
    guard !effects.isEmpty else { return }

    if effects.contains(.cancelRecognition) {
      // Active failure: cancel recognition, reset, then show why.
      for effect in effects where effect != .cancelRecognition {
        perform(effect)
      }
      Task { [weak self] in
        guard let self else { return }
        await dependencies.cancelRecognition()
        send(.sessionEnded)
        dependencies.showMessage(message, nil)
      }
    } else {
      perform(effects)
    }
  }

  private func startNoSpeechTimer() {
    noSpeechTask?.cancel()
    noSpeechTask = Task { [weak self] in
      try? await Task.sleep(for: Self.noSpeechTimeout)
      guard !Task.isCancelled, let self else { return }
      // Con el micrófono entregando ceros el corte dice por qué; sin eso la
      // forma se escondía igual que tras un silencio de verdad. El
      // temporizador se apaga con la primera palabra, así que acá no hay
      // dictado que perder.
      if dependencies.microfonoMudo() {
        fail(message: AvisoDelMicrofono.cortadoSinSonido, wasCancelled: false)
      } else {
        send(.noSpeechTimedOut)
      }
    }
  }

  private func stopNoSpeechTimer() {
    noSpeechTask?.cancel()
    noSpeechTask = nil
  }

  /// Reintenta la toma que quedó en RAM, desde el menú de la barra. Nunca con
  /// un dictado andando: la máquina lo rechaza, y un dictado nuevo nunca
  /// espera por una toma vieja.
  func reintentarTomaFallida() {
    send(.reintentoPedido)
  }

  /// La persona no quiere la toma: se va de la RAM al tiro.
  func descartarTomaFallida() {
    Task { [dependencies] in await dependencies.descartarToma() }
  }

  /// El menú de la barra se entera de si hay una toma guardada, y de cuánto
  /// dura, cada vez que cambia: al fallar un dictado, al reintentar, al
  /// descartarla y cuando vence sola a los diez minutos. Lo llama `start()`;
  /// no es privado para que una prueba lo llame sin levantar el tap.
  func observarTomasFallidas() {
    let handler: @Sendable (TimeInterval?) -> Void = { [weak self] duracion in
      Task { @MainActor [weak self] in
        self?.duracionDeLaTomaFallida = duracion
        self?.onTomaFallidaChange?(duracion)
      }
    }
    Task { [dependencies] in await dependencies.observarTomaFallida(handler) }
  }

  /// El efecto `.reintentarTomaFallida`. El texto va al portapapeles y no a
  /// donde estaba el cursor: el foco de entonces ya no existe, y pegar en lo
  /// que sea que esté al frente ahora es pegar donde nadie pidió. Corre como
  /// `finishTask` para que salir de la app espere a que termine.
  private func ejecutarReintento() {
    finishTask = Task { [weak self] in
      guard let self else { return }
      defer { finishTask = nil }
      let session = settings.sessionSettings
      let crudo: String
      do {
        crudo = try await dependencies.reintentarToma()
      } catch {
        send(.sessionEnded)
        dependencies.showMessage(error.localizedDescription, nil)
        return
      }
      let limpio = DiloText.limpiar(crudo, con: session.textoPreferencias)
      recordar(UltimoDictado(original: crudo, limpio: limpio))
      await recordHistory(spoken: limpio, delivered: limpio, session: session)
      let copia = await dependencies.insertText(limpio, nil, .clipboardOnly)
      send(.sessionEnded)
      dependencies.showMessage(
        !copia.llego
          ? String(localized: "Salió, pero no pude copiarlo. Está en «Copiar el último dictado».")
          : String(localized: "Listo: te lo copié. Pégalo con ⌘V."),
        nil
      )
    }
  }

  /// Arma el tope de cinco minutos mientras se graba, y lo desarma en
  /// cualquier otro estado. Se deriva del estado después de cada acción, como
  /// la captura de las flechas: así ninguna salida —soltar, Esc, una falla—
  /// puede dejar un reloj corriendo que termine el dictado siguiente.
  private func actualizarTope() {
    if case .recording = machine.state {
      if vigiaDelTope == nil { armarTope() }
      return
    }
    vigiaDelTope?.cancel()
    vigiaDelTope = nil
    cuentaRegresiva = nil
    ultimoEnVivo = ("", "")
  }

  /// Una sola tarea que duerme hasta quince segundos antes del tope y desde
  /// ahí late una vez por segundo: en un dictado normal no cuesta nada. El
  /// tope existe porque la toma vive en RAM (`PoliticaDeGrabacion`), y al
  /// llegar termina como si la persona hubiera soltado: lo dicho se pega.
  private func armarTope() {
    let reloj = dependencies.relojDelTope
    let inicio = reloj.now()
    vigiaDelTope = Task { [weak self] in
      do {
        try await reloj.sleep(PoliticaDeGrabacion.duracionMaxima - PoliticaDeGrabacion.avisoAntesDelTope)
        while true {
          guard let self else { return }
          switch PoliticaDeGrabacion.fase(transcurrido: reloj.now() - inicio) {
          case .normal:
            break
          case let .terminaEn(segundos):
            mostrarCuentaRegresiva(segundos)
          case .tope:
            send(.limiteAlcanzado(now: .now))
            return
          }
          try await reloj.sleep(.seconds(1))
        }
      } catch {
        // Cancelado: el dictado terminó antes del tope.
      }
    }
  }

  /// La cuenta regresiva va en la misma línea del dictado, al final —que es
  /// lo que la muesca nunca recorta—, y VoiceOver la anuncia una sola vez.
  private func mostrarCuentaRegresiva(_ segundos: Int) {
    if cuentaRegresiva == nil {
      dependencies.anunciar(
        String(localized: "Quedan \(segundos) segundos. El dictado termina solo y se pega.")
      )
    }
    cuentaRegresiva = segundos
    dependencies.showLiveText(
      ultimoEnVivo.firme, conCuentaRegresiva(ultimoEnVivo.firme, ultimoEnVivo.volatil)
    )
  }

  /// Lo volátil con la cuenta pegada al final. El espacio lo pone `Union`,
  /// como en cualquier otra costura del dictado.
  private func conCuentaRegresiva(_ firme: String, _ volatil: String) -> String {
    guard let cuentaRegresiva else { return volatil }
    let cola = Union.unir(volatil, String(localized: "· termino en \(cuentaRegresiva) s"))
    return Union.colaDe(firme, cola)
  }

  private func installTriggerMonitor() {
    guard dependencies.hasAccessibilityAccess() else {
      dependencies.requestAccessibilityAccess()
      startPermissionWatch()
      return
    }

    // Granted, but macOS decides what this process may do when it launches, so
    // the tap can still be refused. Only a fresh launch clears that, and saying
    // so is the whole point of the dialog.
    guard keyEventMonitor?.start() == true else {
      dependencies.showRelaunchAlert()
      return
    }
  }

  /// Guarda lo medido de la sesión que terminó. Fuera del main actor: el
  /// archivo se escribe en su actor, y el motor que escuchó lo dice el
  /// router. Nada de esto toca el texto dictado.
  private func registrarLatencia() {
    guard let reloj = cerrarLaMedicion() else { return }
    Task { [dependencies] in
      let motor = await dependencies.motorDelDictado() ?? "?"
      await dependencies.registrarLatencia(reloj.medicion(motor: motor))
    }
  }

  private func preparationFailed(_ bloqueo: BloqueoDelDictado) {
    fallaDePreparacion = bloqueo
    avisar(bloqueo, en: nil)
  }
}
