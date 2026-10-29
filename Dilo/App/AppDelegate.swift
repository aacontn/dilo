import AppIntents
import AppKit
import DiloCapabilities
import DiloEngines
import DiloModes
import os

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var settings: AppSettings?
  private var statusItemController: StatusItemController?
  private var hudStage: HUDStage?
  private var hudController: DictationHUDController?
  private var dropTranscriptionController: DropTranscriptionController?
  private var dictationController: DirectDictationController?
  private var readAloudController: ReadAloudController?
  private var settingsWindowController: SettingsWindowController?
  private var onboardingWindowController: OnboardingWindowController?
  private var estadoDePermisos: EstadoDePermisos?
  private var usageTracker: UsageTracker?
  /// Guardado para el cierre: un dictado prometido en el portapapeles muere
  /// con Dilo si nadie lo vuelve texto antes.
  private var textInsertionService: TextInsertionService?
  private let settingsRuntimeState = SettingsRuntimeState()
  private let updaterService = SparkleUpdaterService()
  private let launchAtLoginService = LaunchAtLoginService()
  /// Los agentes de código que avisan por su *hook* (`dilo://agente?…`).
  private var agentes: AgentesEnLaMuesca?
  /// Lo que los App Intents llaman; `PuenteDeAtajos` lo guarda débil, así
  /// que vive acá.
  private var accionesDeAtajos: AccionesDeDiloEnVivo?
  private var avisoDeAtajo: AvisoDeAtajoEnLaMuesca?
  /// Ordena Tus palabras con Claude de vez en cuando.
  private var ordenador: OrdenadorDelDiccionario?
  /// La Conversación: hablarle a Dilo y que conteste en voz alta.
  private var conversacion: ControladorDeLaConversacion?
  /// Las URL que llegan antes de que la app termine de arrancar: abrir
  /// `dilo://` con Dilo cerrado lo lanza, y AppKit entrega la URL antes de
  /// `applicationDidFinishLaunching`.
  private var urlsPendientes: [URL] = []
  #if DEBUG
    /// El arnés de la muesca: dibuja cada estado a pedido, sin dictar
    /// (`EscenaDeMuestra`, `scripts/muesca.sh`). No existe en Release.
    private let receptorDeMuestras = ReceptorDeMuestras()
    /// La puerta de `scripts/metrics.sh` para dictar sin el menú de la barra
    /// (`DisparadorDeMetricas`). Sólo escucha con `DILO_METRICS_WAV` puesto.
    private let disparadorDeMetricas = DisparadorDeMetricas()
  #endif

  static func main() {
    // Antes que nada de AppKit: con `--mcp` o como `dilo` este mismo binario
    // es el servidor MCP o el CLI, sin ventanas ni ícono, y no vuelve de acá.
    ArranqueParaAgentes.correrSinVentanasSiCorresponde()
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
  }
 

  /// True while this process hosts the test suite rather than a user.
  ///
  /// The live launch path requests microphone and speech permissions and
  /// installs the event tap, which pops system permission dialogs over every
  /// automated test run on a machine that has not granted them. Hosting
  /// tests skips the launch entirely: tests build the objects they exercise,
  /// and a test that means to see a permission prompt drives
  /// PermissionService itself, on purpose.
  private static var isHostingTests: Bool {
    let environment = ProcessInfo.processInfo.environment
    return environment["XCTestSessionIdentifier"] != nil
      || environment["XCTestConfigurationFilePath"] != nil
      || environment["XCTestBundlePath"] != nil
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard !Self.isHostingTests else { return }

    // Una línea, al arrancar: de qué lado de la capa de capacidades corre
    // esta copia. Sin esto, "en App Store no me aparece Leer en voz alta" es
    // una hora de mirar código en vez de un `log show`.
    AppLog.capacidades.notice(
      "Anfitrión \(Anfitrion.actual.nombre, privacy: .public); escondidas: \(Capacidad.allCases.filter { !Anfitrion.actual.admite($0) }.map(\.rawValue).joined(separator: ", "), privacy: .public)"
    )

    // Before anything can be staged: a crash or a force-quit while a
    // transcript card was on screen leaves the user's speech in cleartext
    // under $TMPDIR, and nothing else ever removes it.
    StagedTranscript.sweep()

    let settings = AppSettings()
    self.settings = settings
    // Con clave de Anthropic y el general todavía en el de fábrica, los modos
    // pasan a Claude Haiku 5.5, una vez (`MigracionDeProveedores`).
    settings.pasarElGeneralAClaudeSiCorresponde(claves: Llavero())
    // Antes de que nada se dibuje: la muesca en reposo ya pinta su punto.
    PaletaActiva.compartida.elegir(settings.paleta)
    // One shape, two features. The stage owns the window and hands it out;
    // each feature's HUD controller only decides what its surface says.
    let stage = HUDStage(settings: settings)
    self.hudStage = stage
    let hudController = DictationHUDController(stage: stage, settings: settings)
    let usageTracker = UsageTracker()
    // One insertion service for the whole app. Its clipboard read lease is per
    // instance, so a second one would let a dictation insertion and a Read
    // Aloud copy work the pasteboard at the same time.
    let textInsertionService = TextInsertionService()
    self.textInsertionService = textInsertionService
    let dictationController = DirectDictationController(
      settings: settings,
      hudController: hudController,
      usageTracker: usageTracker,
      textInsertionService: textInsertionService
    )
    self.hudController = hudController
    self.dictationController = dictationController
    self.usageTracker = usageTracker

    let readAloudController = ReadAloudController(
      settings: settings,
      hudController: hudController,
      translation: dictationController.translation,
      textInsertion: textInsertionService
    )
    self.readAloudController = readAloudController

    let dropTranscriptionController = DropTranscriptionController(
      settings: settings,
      hud: DropHUDController(stage: stage)
    )
    self.dropTranscriptionController = dropTranscriptionController
    dropTranscriptionController.start()
    dropTranscriptionController.onProgressChange = { [weak self, weak settings] fraction in
      self?.statusItemController?.setTranscriptionProgress(
        fraction,
        // Sin el Llavero: es un color, y esto corre en cada avance.
        accent: settings?.sessionSettingsParaDibujar.dropAccent ?? SettingsTheme.accentColor
      )
    }

    let statusItemController = StatusItemController(
      toggleDictation: { dictationController.toggleFromMenu() },
      toggleReadAloud: { readAloudController.toggle() },
      transcribeFile: { dropTranscriptionController.pickFile() },
      // El clic izquierdo en el ícono y «Abrir» del panel: la ventana de la
      // app, que en Dilo es Ajustes.
      openSettings: { [weak self] in self?.showSettings() },
      openOnboarding: { [weak self] in self?.mostrarPrimerosPasos() },
      openNovedades: { [weak self] in self?.showSettings(seccion: .novedades) },
      checkForUpdates: { [weak self] in self?.updaterService.checkForUpdates() }
    )
    self.statusItemController = statusItemController
    statusItemController.dictarNota = { dictationController.dictarNota() }
    // El panel de la barra ofrece el mismo modo del atajo general que el
    // panel de la muesca, y lleva vidrio con el mismo interruptor.
    statusItemController.leerModos = { [weak settings] in
      guard let settings else { return ([], nil) }
      return (
        settings.modos.map { PanelDeLaBarra.Modo(id: $0.id, nombre: $0.nombre) },
        settings.hudModoDelAtajoGeneral
      )
    }
    statusItemController.alElegirModo = { [weak settings] id in
      settings?.hudModoDelAtajoGeneral = id
    }
    statusItemController.leerVidrio = { [weak settings] in settings?.hudPanelDeVidrio ?? true }
    statusItemController.tomaFallida.reintentar = { dictationController.reintentarTomaFallida() }
    statusItemController.tomaFallida.descartar = { dictationController.descartarTomaFallida() }
    dictationController.onTomaFallidaChange = { [weak statusItemController, weak stage] duracion in
      statusItemController?.tomaFallida.mostrar(duracion)
      // Y en una píldora al costado de la muesca, que es donde se mira
      // cuando un dictado no salió; un clic la reintenta, como el panel de
      // la barra.
      stage?.mostrarTomaGuardada(duracion)
    }
    stage.alPedirReintento = { dictationController.reintentarTomaFallida() }
    // Aprender de una corrección: la oferta vive en un segmento de la muesca
    // y el clic vuelve al controlador, que es quien sabe qué se aprendió.
    dictationController.correcciones.alCambiarLaOferta = { [weak stage] oferta in
      stage?.mostrarOfertaDeAprendizaje(oferta)
    }
    stage.alTocarAprendizaje = { dictationController.correcciones.tocar() }
    // Aprender con Claude: Haiku 5.5 revisa cada corrección antes de la
    // oferta, y Sonnet 5.5 ordena Tus palabras en segundo plano, nunca
    // durante un dictado (`OrdenadorDelDiccionario`).
    dictationController.correcciones.revisar = { candidatos, modelo in
      await AprendizajeConClaude.revisar(candidatos, modelo: modelo)
    }
    let ordenador = OrdenadorDelDiccionario(settings: settings)
    self.ordenador = ordenador
    ordenador.hayDictadoEnCurso = { [weak settingsRuntimeState] in
      settingsRuntimeState?.isDictating ?? false
    }
    settingsRuntimeState.ordenador = ordenador
    dictationController.correcciones.alAprender = { [weak ordenador] in ordenador?.revisarSiToca() }
    ordenador.empezar()
    // La Conversación usa el motor de voz del dictado, así que se turnan: con
    // una llamada en curso el gatillo le da el turno a la persona, y un
    // dictado que empieza por el menú o un atajo cuelga la llamada.
    let conversacion = ControladorDeLaConversacion(
      settings: settings, stage: stage, motor: dictationController.motorParaConversar
    )
    self.conversacion = conversacion
    conversacion.hayDictado = { [weak settingsRuntimeState] in settingsRuntimeState?.isDictating ?? false }
    conversacion.alCambiar = { [weak statusItemController] conversando in
      statusItemController?.setConversando(conversando)
    }
    dictationController.hayConversacion = { [weak conversacion] in conversacion?.enCurso ?? false }
    dictationController.onConversacion = { [weak conversacion] apretado in
      conversacion?.gatillo(apretado: apretado)
    }
    statusItemController.conversar = { [weak conversacion] in conversacion?.alternar() }
    stage.dictationContent.alDictarNota = { dictationController.dictarNota() }
    stage.dictationContent.alTerminarSesionTrabada = { dictationController.terminarSesionTrabada() }
    stage.dictationContent.alDictarTraduciendo = { dictationController.dictarTraduciendo() }
    stage.dictationContent.alElegirIdiomaDeTraduccion = { [weak self] in
      self?.showSettings(seccion: .dictation, reclamandoElFoco: true)
    }

    // El notch como escenario permanente: la forma se pone en pantalla acá y
    // no se va más; lo que cambia después es su tamaño y su estado
    // (`EstadoDelNotch`).
    stage.despertar()
    stage.alPedirAcciones = { [weak statusItemController, weak stage] in
      guard let silueta = stage?.siluetaDeAcciones else { return }
      statusItemController?.mostrarAcciones(bajo: silueta)
    }
    statusItemController.alCambiarElPanel = { [weak stage] abierto in
      stage?.panelDeLaBarraAbierto = abierto
    }
    stage.alPedirCopiar = { [weak statusItemController] in
      statusItemController?.copiarLoUltimo()
    }
    stage.alPedirAccion = { accion in
      switch accion {
      case let .abrirAjustes(panel):
        if let url = URL(string: panel) { NSWorkspace.shared.open(url) }
      case .deshacerCancelacion:
        dictationController.deshacerCancelacion()
      }
    }
    // Lo que llega de afuera y pide un segmento al costado: los agentes de
    // código por su *hook* y «Mostrar en la muesca» de Atajos. El escenario
    // sólo los sienta y los dibuja; el clic vuelve a quien los publicó.
    let agentes = AgentesEnLaMuesca(
      settings: settings,
      publicar: { [weak stage] actividad, contenido in stage?.publicarDeAfuera(actividad, contenido: contenido) },
      retirar: { [weak stage] id in stage?.retirarDeAfuera(id: id) }
    )
    self.agentes = agentes
    let avisoDeAtajo = AvisoDeAtajoEnLaMuesca(
      publicar: { [weak stage] actividad, contenido in stage?.publicarDeAfuera(actividad, contenido: contenido) },
      retirar: { [weak stage] id in stage?.retirarDeAfuera(id: id) }
    )
    self.avisoDeAtajo = avisoDeAtajo
    stage.alTocarSegmentoDeAfuera = { [weak agentes, weak avisoDeAtajo] id in
      if id == AvisoDeAtajoEnLaMuesca.actividad.id {
        avisoDeAtajo?.quitar()
      } else {
        agentes?.tocar(id: id)
      }
    }
    settingsRuntimeState.probarAgente = { [weak agentes] in agentes?.probar() }

    // Los App Intents (Atajos, Spotlight, Siri) llaman a lo mismo que el
    // menú de la barra y el panel del hover.
    let accionesDeAtajos = AccionesDeDiloEnVivo(
      settings: settings,
      dictado: dictationController,
      conversacion: conversacion,
      copiarAlPortapapeles: { [weak statusItemController] texto in
        statusItemController?.copiarAlPortapapeles(texto)
      },
      aviso: avisoDeAtajo
    )
    self.accionesDeAtajos = accionesDeAtajos
    PuenteDeAtajos.actual = accionesDeAtajos
    AtajosDeDilo.updateAppShortcutParameters()

    #if DEBUG
      receptorDeMuestras.alDibujar = { [weak stage] escena, texto in
        stage?.mostrarMuestra(escena, texto: texto)
      }
      receptorDeMuestras.alSoltar = { [weak stage] in stage?.soltarMuestra() }
      stage.alInterrumpirLaMuestra = { [weak receptorDeMuestras] in receptorDeMuestras?.olvidar() }
      receptorDeMuestras.escuchar()
      disparadorDeMetricas.alternar = { dictationController.toggleFromMenu() }
      disparadorDeMetricas.escuchar()
    #endif

    dictationController.onRecordingStateChange = {
      [weak self, weak statusItemController, weak settingsRuntimeState] isRecording, session in
      let accent = session.flatMap {
        $0.voiceVisual.usesEdgeGlow ? $0.glowPalette.statusAccent : nil
      }
      statusItemController?.setRecording(isRecording, accent: accent)
      settingsRuntimeState?.isDictating = isRecording
      if isRecording { self?.conversacion?.colgar() }
    }
    #if DEBUG
      // Y al archivo que mira `scripts/metrics.sh`, sin tocar lo de arriba.
      let anotarElEstado = dictationController.onRecordingStateChange
      dictationController.onRecordingStateChange = { [disparadorDeMetricas] isRecording, session in
        anotarElEstado?(isRecording, session)
        disparadorDeMetricas.anotar(dictando: isRecording)
      }
    #endif
    // Settings drives translation directly. Routing it through the dictation
    // controller would only make that controller forward three things it has
    // no opinion about.
    let translation = dictationController.translation
    settingsRuntimeState.installTranslationModel = { [weak translation] pair in
      await translation?.install(pair) ?? .unavailable
    }
    settingsRuntimeState.stopInstallingTranslationModel = { [weak translation] in
      translation?.stopInstalling()
    }
    translation.onTargetsChange = { [weak settingsRuntimeState] targets, source in
      settingsRuntimeState?.translationTargets = targets
      settingsRuntimeState?.translationSource = source
    }
    translation.onStateChange = { [weak settingsRuntimeState] state in
      settingsRuntimeState?.translationModelState = state
    }
    // Lo último que se dictó llega al panel de la barra, que es donde alguien
    // lo va a buscar cuando el pegado no aterrizó donde esperaba.
    dictationController.onUltimoDictadoChange = {
      [weak statusItemController, weak stage, weak settingsRuntimeState] dictado in
      statusItemController?.setUltimoDictado(dictado)
      // Y a Inicio, en Ajustes, con su «Copiar». Sólo en RAM.
      settingsRuntimeState?.ultimoDictado = dictado
      // Lo que el hover sobre el notch en reposo revela: lo último que
      // dictaste, que es lo que alguien va a buscar ahí.
      stage?.dictationContent.contexto = dictado?.vistazo(.entregado)
      // Y a los recientes del panel, donde se puede volver a copiar.
      if let dictado {
        stage?.dictationContent.agregarReciente(dictado.texto(.entregado), origen: .dictado)
      }
    }
    dictationController.onLanguageDownloadChange = {
      [weak settingsRuntimeState] identifier, fraction in
      settingsRuntimeState?.setDownload(identifier: identifier, fraction: fraction)
    }
    readAloudController.onSpeakingStateChange = {
      [weak statusItemController] isSpeaking in
      statusItemController?.setSpeaking(isSpeaking)
    }
    // Option+Escape toggles Read Aloud; the dictation controller owns
    // the event tap and fires this only while no session is active.
    dictationController.onReadAloudTriggered = { [weak readAloudController] in
      readAloudController?.toggle()
    }

    // Compiles the HUD's shaders now, so the cost does not land on the first
    // frames of the first dictation.
    HUDShaderWarmUp.start()

    // Requests permissions and prepares the selected Speech Model
    // shortly after launch (CONTEXT.md).
    dictationController.start()

    applyKeyBindings()
    observeKeyBindings()
    observeLanguages()

    // A background check is postponed while a session is running, so an update
    // window can never take focus mid-dictation and move the insertion target.
    updaterService.isBusy = { [weak settingsRuntimeState] in
      settingsRuntimeState?.isDictating ?? false
    }

    // Last: a scheduled check can show a window, and it must never land
    // before the status item and dictation are wired.
    updaterService.start()

    saludar(settings)

    for url in urlsPendientes { agentes.abrir(url) }
    urlsPendientes = []
  }

  /// `dilo://…` (`CFBundleURLTypes` de `Info.plist`). Hoy sólo
  /// `dilo://agente?…`; qué se acepta y por qué no más lo dice
  /// `EnlaceDeDilo`.
  func application(_ application: NSApplication, open urls: [URL]) {
    guard !Self.isHostingTests else { return }
    guard let agentes else {
      urlsPendientes.append(contentsOf: urls.prefix(16))
      return
    }
    for url in urls { agentes.abrir(url) }
  }

  /// Rebinding in Settings updates the event tap and the bar panel's
  /// hints immediately; Observation re-arms after every change. The same
  /// loop pauses trigger handling while a key recorder is armed.
  private func observeKeyBindings() {
    guard let settings else { return }
    withObservationTracking {
      _ = settings.dictationTriggerBinding
      _ = settings.secondaryTriggerBinding
      _ = settings.readAloudBinding
      _ = settings.translateTriggerBinding
      _ = settings.conversacionGatillo
      _ = settings.isRecordingKeybind
      // Cada modo trae su propia tecla, así que la lista entra en este bucle:
      // sin esto, asignarle una tecla a un modo la guardaba y el tap no se
      // enteraba hasta el próximo arranque.
      _ = settings.modos
      // The second trigger is only installed once a second language exists,
      // so the pick that enables it belongs in this loop too.
      _ = settings.secondaryRecognitionLocaleIdentifier
      // The target is what installs the translate trigger, the same reason the
      // second language's pick belongs in this loop.
      _ = settings.translationTargetIdentifier
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.applyKeyBindings()
        self?.observeKeyBindings()
      }
    }
  }

  /// Changing a language in Settings re-resolves and re-warms both, so the
  /// next keypress meets a prepared analyzer rather than a cold one.
  private func observeLanguages() {
    guard let settings else { return }
    withObservationTracking {
      _ = settings.recognitionLocaleIdentifier
      _ = settings.secondaryRecognitionLocaleIdentifier
      // The translation target belongs here as well as in the key-binding
      // loop: that one installs the trigger, this one resolves and warms the
      // pair the trigger will use. Without it a changed target reinstalled a
      // trigger that had nothing to translate into.
      _ = settings.translationTargetIdentifier
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.dictationController?.applyLanguages()
        self?.observeLanguages()
      }
    }
  }

  private func applyKeyBindings() {
    guard let settings else { return }
    dictationController?.applyKeyBindings()
    statusItemController?.setKeyBindings(
      trigger: settings.dictationTriggerBinding,
      readAloud: settings.readAloudBinding,
      conversar: settings.conversacionGatillo
    )
  }

  /// A released trigger whose text has not landed yet is the one thing worth
  /// delaying a quit for: the user spoke it and expects to see it. AppKit's
  /// deferred termination is the only way to wait, because
  /// `applicationWillTerminate` is synchronous and the finish needs the main
  /// actor to make progress.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let dictationController, dictationController.isFinishing else {
      return .terminateNow
    }
    Task { @MainActor in
      await dictationController.waitForFinish()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  func applicationWillTerminate(_ notification: Notification) {
    conversacion?.colgar()
    dictationController?.stop()
    textInsertionService?.alCerrar()
    // A transcript the HUD is still offering only exists in its staging folder,
    // so quitting writes it out rather than losing it.
    dropTranscriptionController?.commitOfferedTranscript()
  }

  /// Qué ve la persona al arrancar, según qué copia de Dilo es ésta.
  ///
  /// Instalación nueva: los Primeros pasos, que es donde se explican los
  /// permisos antes de pedirlos. Copia que acaba de actualizarse: las
  /// Novedades de la versión, que es lo que Dilo ya hacía en su versión Tauri.
  /// Copia que ya venía al día: nada, que es lo que corresponde en una app que
  /// vive en la barra de menús.
  private func saludar(_ settings: AppSettings) {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""

    if !settings.onboardingVisto {
      settings.versionVista = version
      mostrarPrimerosPasos(reclamandoElFoco: true)
      return
    }

    // La versión vista vacía es una copia anterior a que esto existiera: se
    // anota y no se le abre nada, porque no actualizó a nada todavía.
    if !settings.versionVista.isEmpty, settings.versionVista != version {
      settings.versionVista = version
      showSettings(seccion: .novedades, reclamandoElFoco: true)
      return
    }
    settings.versionVista = version
  }

  private func mostrarPrimerosPasos(reclamandoElFoco: Bool = false) {
    guard let settings else { return }
    settings.onboardingVisto = true

    if onboardingWindowController == nil {
      let permisos = EstadoDePermisos(motorEsApple: settings.motorDeVoz == .apple)
      estadoDePermisos = permisos
      onboardingWindowController = OnboardingWindowController(
        settings: settings,
        permisos: permisos
      )
    }
    estadoDePermisos?.refrescar()
    onboardingWindowController?.mostrar(reclamandoElFoco: reclamandoElFoco)
  }

  private func showSettings(seccion: SettingsSection? = nil, reclamandoElFoco: Bool = false) {
    guard let settings, let usageTracker else { return }
    if let seccion { settingsRuntimeState.seccionPedida = seccion }
    if settingsWindowController == nil {
      settingsWindowController = SettingsWindowController(
        settings: settings,
        sounds: HUDSounds(),
        runtimeState: settingsRuntimeState,
        usageTracker: usageTracker,
        updater: updaterService,
        launchAtLogin: launchAtLoginService
      )
    }
    settingsWindowController?.show(reclamandoElFoco: reclamandoElFoco)
  }
}
