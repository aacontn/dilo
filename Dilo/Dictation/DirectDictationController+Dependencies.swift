import AppKit
import DiloCapabilities
import DiloEngines
import DiloModes

/// Injectable speech, insertion, permission, HUD, and usage boundaries for
/// Direct Dictation, following the TextInsertionService.Dependencies
/// template: a struct of closures with a live default, so the controller's
/// begin guards, outcome routing, and cancellation races can run against
/// fakes instead of a live microphone, Accessibility, and pasteboard.
extension DirectDictationController {
  struct Dependencies {
    // Speech recognition, wrapping the SpeechRecognitionService actor.
    let setDownloadHandler: @Sendable (
      @escaping @Sendable (SpeechRecognitionService.ModelDownload) -> Void
    ) async -> Void
    let resolveLocale: @Sendable (String?) async throws -> Locale
    let supportedLocale: @Sendable (String) async -> Locale?
    let retainOnly: @Sendable ([Locale]) async -> Void
    let prewarm: @Sendable (Locale) async throws -> Void
    let startRecognition: @Sendable (
      Locale,
      _ updateHandler: @escaping @Sendable (SpeechRecognitionService.Update) -> Void,
      _ failureHandler: @escaping @Sendable (String) -> Void,
      _ levelHandler: @escaping @Sendable (Float) -> Void,
      /// El motor está cargando su modelo en la RAM mientras la persona ya
      /// habla, y después que terminó. No es una falla: el dictado espera.
      _ loadingHandler: @escaping @Sendable (Bool) -> Void
    ) async throws -> Void
    let finishRecognition: @Sendable () async throws -> String
    let cancelRecognition: @Sendable () async -> Void
    let shutDownRecognition: @Sendable () async -> Void

    /// Translation, whole. A collaborator rather than a seam: it has its own
    /// seam one layer down, and Settings talks to it directly.
    let translation: TranslationCoordinator

    // Text insertion.
    let captureFocusedTarget: @MainActor () -> TextInsertionService.Target?
    let insertText: @MainActor (
      String, TextInsertionService.Target?, InsertionDestination
    ) async -> ResultadoDeEntrega

    // Permissions and the dialogs that explain them.
    let requestMicrophoneAccess: @Sendable () async -> Bool
    let requestSpeechAccess: @Sendable () async -> Bool
    let requestAccessibilityAccess: @MainActor () -> Void
    let hasAccessibilityAccess: @MainActor () -> Bool
    let isPermissionAlertPresenting: @MainActor () -> Bool
    let showAccessibilitySetupAlert: @MainActor () -> Void
    let showRelaunchAlert: @MainActor () -> Void

    // The HUD surface dictation drives.
    let showListening: @MainActor (
      _ displayID: CGDirectDisplayID?,
      _ isLatched: Bool,
      _ settings: DictationSessionSettings,
      _ languageTag: String?
    ) -> Void
    let showLatched: @MainActor () -> Void
    let showLiveText: @MainActor (_ committed: String, _ volatile: String) -> Void
    let showFinalizing: @MainActor () -> Void
    /// La fase visible: el HUD se queda diciendo con qué modo está
    /// reescribiendo, en vez de irse en silencio.
    let showShaping: @MainActor (_ promptName: String) -> Void
    /// El cartel que, mientras grabas, nombra el modo de esta sesión; nil lo
    /// borra.
    let showShapingChoice: @MainActor (_ label: String?) -> Void
    /// Terminó de escuchar y lo grabado se está entregando o transformando.
    /// La forma se queda diciéndolo: irse acá es lo que hacía que el notch
    /// pareciera un aviso que pasó (contrato del notch, estado Procesando).
    let showProcesando: @MainActor () -> Void
    /// Lo entregado, por unos segundos, antes de volver a reposo.
    let showResultado: @MainActor (ResultadoDelNotch) -> Void
    let showMessage: @MainActor (String, CGDirectDisplayID?) -> Void
    let showModelDownload: @MainActor (String?) -> Void
    let showAudioLevel: @MainActor (Float) -> Void
    let hideHUD: @MainActor () -> Void
    let playPasteSound: @MainActor () -> Void

    /// Arms and disarms the tap's bare-arrow capture — las flechas peladas
    /// recorren los modos de la sesión. The live tap lives inside the
    /// controller, which drives it directly beside this call; the closure is
    /// the seam that lets tests see the toggling.
    let setShapingCycleCaptureEnabled: @MainActor (Bool) -> Void

    // Usage aggregation.
    let recordSession: @MainActor (
      _ wordCount: Int, _ speakingDuration: TimeInterval
    ) async -> Void

    // Transcription history, written only while its setting is on.
    let recordHistory: @Sendable (
      _ text: String,
      _ translation: DictationHistoryStore.Translation?,
      _ source: String?,
      _ modo: String?,
      _ motor: String?,
      _ folder: URL
    ) async -> Void

    /// Qué motor escuchó de verdad la sesión que acaba de terminar.
    ///
    /// Del router y no de Ajustes: son distintos justo cuando más importa
    /// —Parakeet elegido sin su modelo en disco dicta con Apple— y ésa es la
    /// pregunta que el historial no sabía contestar (2026-09-22). Trae un
    /// valor por defecto que devuelve nil para que los tests que arman estas
    /// dependencias a mano sigan compilando: una entrada sin motor es
    /// exactamente lo que ya sabe leer el historial viejo.
    var motorDelDictado: @Sendable () async -> String? = { nil }
    /// Guarda una nota rápida en Apple Notas. Con valor por defecto para que
    /// los tests que no la usan no tengan que armarla.
    var guardarNota: @Sendable (String) async -> ResultadoDeLaNota = { _ in .fallo }
    /// Si el notch dice que la sesión en curso es una nota.
    var mostrarQueEsNota: @MainActor (Bool) -> Void = { _ in }

    /// Las palabras propias que se le pasan al motor como contexto antes de
    /// reconocer. Trae un valor por defecto que no hace nada para que los
    /// tests que arman estas dependencias a mano sigan compilando sin
    /// enterarse: una costura nueva no tiene por qué costarle a nadie.
    var setPalabrasPropias: @Sendable ([String]) async -> Void = { _ in }

    /// La toma que quedó en RAM cuando el motor no sacó texto al soltar:
    /// pasarla otra vez, botarla, y enterarse de si hay una (con su
    /// duración). Con valores por defecto que no hacen nada para que los
    /// tests que no la usan no tengan que armarla.
    var reintentarToma: @Sendable () async throws -> String = { throw TomaSinTexto.sinToma }
    var descartarToma: @Sendable () async -> Void = {}
    var observarTomaFallida: @Sendable (
      @escaping @Sendable (TimeInterval?) -> Void
    ) async -> Void = { _ in }
    /// Le dice algo a VoiceOver sin mover el foco: la cuenta regresiva del
    /// tope no se ve si no miras la muesca.
    var anunciar: @MainActor (String) -> Void = { texto in
      NSAccessibility.post(
        element: NSApp as Any,
        notification: .announcementRequested,
        userInfo: [.announcement: texto, .priority: NSAccessibilityPriorityLevel.high.rawValue]
      )
    }
    /// El reloj del tope de cinco minutos. Inyectable para que una prueba no
    /// tenga que esperar cinco minutos de verdad.
    var relojDelTope: DeadlineClock = .continuous

    /// Los permisos y la entrada de audio, leídos al apretar el gatillo para
    /// decir qué falta antes de abrir el micrófono (`EstadoParaDictar`). Por
    /// defecto todo concedido: el host de los tests tiene su propio bundle id
    /// y ningún permiso, y leer el sistema de verdad ahí bloquearía toda la
    /// suite. `live` lee el sistema.
    var leerPermisos: @MainActor () -> PermisosLeidos = { .todosConcedidos }
    /// Un aviso que se arregla con un clic (`AvisoConAccion`). Por defecto
    /// cae al mensaje de siempre, para que una prueba que sólo mira los
    /// mensajes lo siga viendo.
    var mostrarAviso: (@MainActor (AvisoConAccion, CGDirectDisplayID?) -> Void)?

    /// La latencia por fase (`RelojDeFases`): lo que tardó la revisión de la
    /// toma, cuándo salió el ⌘V y dónde se guarda cada sesión medida. Por
    /// defecto no se mide nada ni se escribe nada: una prueba que no mira la
    /// latencia no tiene por qué tocar el disco.
    var duracionDeLaRevision: @Sendable () async -> Duration? = { nil }
    var instanteDelAtajo: @MainActor () -> ContinuousClock.Instant? = { nil }
    var registrarLatencia: @Sendable (MedicionDeSesion) async -> Void = { _ in }

    /// Correr un modo sobre lo dictado, con el proveedor que la sesión
    /// congeló al empezar. El proveedor entra como parámetro y no se lee de
    /// Ajustes acá adentro: eso es lo que hace que cambiar Ajustes a mitad de
    /// dictado no pueda mandar a una nube un texto que empezó siendo local.
    let transformar: @Sendable (
      _ texto: String,
      _ modo: Modo,
      _ proveedor: ResolucionDeProveedor.DeSesion
    ) async -> TransformacionDeModo.Resultado

    /// Builds the production boundaries around the live services the
    /// controller previously constructed itself.
    @MainActor
    static func live(
      settings: AppSettings,
      hudController: DictationHUDController,
      usageTracker: UsageTracker,
      textInsertionService: TextInsertionService
    ) -> Self {
      // La copia en RAM de cada dictado, que llenan los dos motores: sin
      // ella, un motor que se cae al soltar se lleva lo dicho.
      let grabadora = GrabadoraEnRAM()
      let speechService = SpeechRecognitionService(grabadora: grabadora)
      let historyStore = DictationHistoryStore()
      let latencias = AlmacenDeLatencias()
      // El motor doble. `speechService` sigue siendo el dueño de
      // SpeechAnalyzer, de las reservas de idioma y de las sesiones tibias:
      // el router sólo elige quién escucha. La sesión habla con el respaldo,
      // que es el mismo contrato con la toma guardada debajo.
      let (motores, respaldo) = DiloSpeechStack.armar(apple: speechService, grabadora: grabadora)
      // La elección se lee al arrancar cada dictado, no una vez: cambiarla en
      // Ajustes aplica al próximo dictado, como todo lo demás.
      let motorElegido: @Sendable () async -> SpeechEngineKind = {
        await MainActor.run { settings.motorDeVoz }
      }
      // Lo mismo con el reposo: cuánto aguanta el modelo en la RAM se lee al
      // empezar cada dictado, no una vez al arrancar.
      let reposoElegido: @Sendable () async -> Duration? = {
        await MainActor.run { settings.descargarModeloTras.intervalo }
      }

      return Self(
        setDownloadHandler: { await speechService.setDownloadHandler($0) },
        resolveLocale: { try await speechService.resolveLocale(identifier: $0) },
        supportedLocale: { await speechService.supportedLocale(identifier: $0) },
        retainOnly: { await speechService.retainOnly(locales: $0) },
        prewarm: { locale in
          await motores.elegir(await motorElegido())
          try await motores.prewarm(locale: locale)
        },
        startRecognition: { locale, updateHandler, failureHandler, levelHandler, loadingHandler in
          await motores.elegir(await motorElegido())
          await motores.configurarReposo(await reposoElegido())
          try await respaldo.start(
            locale: locale,
            handlers: EngineHandlers(
              parcial: { update in
                updateHandler(
                  SpeechRecognitionService.Update(
                    finalizedText: update.finalizado,
                    volatileText: update.volatil
                  )
                )
              },
              falla: failureHandler,
              nivel: levelHandler,
              cargando: loadingHandler
            )
          )
        },
        finishRecognition: { try await respaldo.finish() },
        cancelRecognition: { await respaldo.cancel() },
        shutDownRecognition: {
          await respaldo.cancel()
          await speechService.shutDown()
        },
        translation: TranslationCoordinator(
          service: TranslationService(client: .live)
        ),
        captureFocusedTarget: { textInsertionService.captureFocusedTarget() },
        insertText: { await textInsertionService.entregar($0, a: $1, segun: $2) },
        requestMicrophoneAccess: { await PermissionService.requestMicrophoneAccess() },
        requestSpeechAccess: { await PermissionService.requestSpeechAccess() },
        requestAccessibilityAccess: { PermissionService.requestAccessibilityAccess() },
        hasAccessibilityAccess: { PermissionService.hasAccessibilityAccess },
        isPermissionAlertPresenting: { PermissionAlert.isPresenting },
        showAccessibilitySetupAlert: { PermissionAlert.requestAccessibilitySetup() },
        showRelaunchAlert: { PermissionAlert.requestRelaunch() },
        showListening: { displayID, isLatched, settings, languageTag in
          hudController.showListening(
            on: displayID,
            isLatched: isLatched,
            settings: settings,
            languageTag: languageTag
          )
        },
        showLatched: { hudController.showLatched() },
        showLiveText: { hudController.showLiveText($0, volatile: $1) },
        showFinalizing: { hudController.showFinalizing() },
        showShaping: { hudController.showShaping(with: $0) },
        showShapingChoice: { hudController.showShapingChoice($0) },
        showProcesando: { hudController.showProcesando() },
        showResultado: { hudController.showResultado($0) },
        showMessage: { hudController.showMessage($0, on: $1) },
        showModelDownload: { hudController.showModelDownload($0) },
        showAudioLevel: { hudController.showAudioLevel($0) },
        hideHUD: { hudController.hide() },
        playPasteSound: { hudController.playPasteSound() },
        // The controller toggles its own tap; nothing else has to.
        setShapingCycleCaptureEnabled: { _ in },
        recordSession: {
          await usageTracker.recordSession(wordCount: $0, speakingDuration: $1)
        },
        recordHistory: { text, translation, source, modo, motor, folder in
          // A history write must never cost the session its insertion; a
          // full disk or revoked folder loses the entry, not the words.
          try? await historyStore.record(
            text,
            translation: translation,
            from: source,
            modo: modo,
            motor: motor,
            in: folder
          )
        },
        motorDelDictado: { await motores.motorDeLaUltimaSesion()?.title },
        guardarNota: { await NotasDeApple.guardar($0) },
        mostrarQueEsNota: { hudController.mostrarQueEsNota($0) },
        setPalabrasPropias: { await speechService.setPalabrasPropias($0) },
        reintentarToma: { try await respaldo.reintentar() },
        descartarToma: { await respaldo.descartarTomaFallida() },
        observarTomaFallida: { await respaldo.observarTomaFallida($0) },
        leerPermisos: { LecturaParaDictar.leer() },
        mostrarAviso: { hudController.mostrarAviso($0, on: $1) },
        duracionDeLaRevision: { await respaldo.duracionDeLaUltimaRevision() },
        instanteDelAtajo: { textInsertionService.ultimoAtajoEnviado },
        registrarLatencia: { await latencias.agregar($0) },
        transformar: { texto, modo, proveedor in
          await TransformacionDeModo().correr(texto, con: modo, deSesion: proveedor)
        }
      )
    }
  }
}
