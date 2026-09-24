import DiloModes
import Foundation
import os
import Testing
@testable import Dilo

/// Pins the controller's impure half through its Dependencies seam: the
/// begin guards, the finish outcome routing, and the cancellation races
/// that the pure machine tests cannot reach.
@MainActor
struct DirectDictationControllerTests {
  /// Every MainActor boundary call the controller makes, in order, plus
  /// the arguments the routing decisions carry.
  /// One history write, as the dependency saw it.
  private struct HistoryEntry: Sendable {
    let text: String
    let translation: DictationHistoryStore.Translation?
    let source: String?
    let modo: String?
    /// Qué motor transcribió, tal como el controlador lo preguntó.
    let motor: String?
    let folder: URL
  }

  @MainActor
  private final class Recorder {
    var events: [String] = []
    var messages: [String] = []
    var listeningLatched: [Bool] = []
    var listeningTags: [String?] = []
    var insertedTexts: [String] = []
    var insertedDestinations: [InsertionDestination] = []
    var recordedSessions: [(wordCount: Int, speakingDuration: TimeInterval)] = []
    var accessibilityAlerts = 0
    var shapingNames: [String] = []
    var shapingChoiceLabels: [String?] = []
    /// Lo que la forma dijo al final de cada sesión (`EstadoDelNotch`).
    var resultados: [ResultadoDelNotch] = []
    var cycleCaptureStates: [Bool] = []

    func count(of event: String) -> Int {
      events.filter { $0 == event }.count
    }
  }

  private struct FinishError: LocalizedError {
    var errorDescription: String? { "finish failed" }
  }

  private func freshDefaults() -> UserDefaults {
    let name = "DirectDictationControllerTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  private static func makeTarget(
    isSecure: Bool = false,
    applicationName: String? = nil
  ) -> TextInsertionService.Target {
    TextInsertionService.Target(
      element: nil,
      processIdentifier: 1,
      isSecure: isSecure,
      displayID: nil,
      applicationName: applicationName
    )
  }

  /// Builds fake dependencies around the recorder. The Sendable speech
  /// closures report through lock-guarded counters because they cannot
  /// touch the MainActor recorder synchronously.
  private func makeDependencies(
    recorder: Recorder,
    prewarmed: OSAllocatedUnfairLock<Bool> = .init(initialState: false),
    startEntries: OSAllocatedUnfairLock<Int> = .init(initialState: 0),
    cancelCount: OSAllocatedUnfairLock<Int> = .init(initialState: 0),
    hasAccessibilityAccess: @escaping @MainActor () -> Bool = { true },
    captureFocusedTarget: @escaping @MainActor () -> TextInsertionService.Target?
      = { DirectDictationControllerTests.makeTarget() },
    startRecognitionBody: (@Sendable (Locale) async throws -> Void)? = nil,
    finishRecognition: @escaping @Sendable () async throws -> String = { "" },
    shutDownRecognition: @escaping @Sendable () async -> Void = {},
    historyEntries: OSAllocatedUnfairLock<[HistoryEntry]>
      = .init(initialState: []),
    translationAvailability: TranslationAvailability = .installed,
    translationReady: Bool = true,
    translationPrepareHangs: Bool = false,
    translateBody: (@Sendable (String) async throws -> String)? = nil,
    retainedPairs: OSAllocatedUnfairLock<[TranslationPair?]> = .init(initialState: []),
    transformar: @escaping @Sendable (
      String, Modo, ResolucionDeProveedor.DeSesion
    ) async -> TransformacionDeModo.Resultado = { texto, _, _ in .transformado(texto) },
    insertOutcome: TextInsertionService.InsertionOutcome = .inserted,
    notas: OSAllocatedUnfairLock<[String]> = .init(initialState: []),
    resultadoDeLaNota: ResultadoDeLaNota = .guardada
  ) -> DirectDictationController.Dependencies {
    DirectDictationController.Dependencies(
      setDownloadHandler: { _ in },
      resolveLocale: { _ in Locale(identifier: "en_US") },
      supportedLocale: { _ in nil },
      retainOnly: { _ in },
      prewarm: { _ in prewarmed.withLock { $0 = true } },
      startRecognition: { locale, _, _, _, _ in
        startEntries.withLock { $0 += 1 }
        try await startRecognitionBody?(locale)
      },
      finishRecognition: finishRecognition,
      cancelRecognition: { cancelCount.withLock { $0 += 1 } },
      shutDownRecognition: shutDownRecognition,
      // The real service over a faked framework, rather than a second set of
      // stubs: its rules are the ones a session depends on.
      translation: TranslationCoordinator(
        service: TranslationService(
          client: TranslationService.Client(
            availability: { _ in translationAvailability },
            prepare: { _ in
              if translationPrepareHangs { try await Task.sleep(for: .seconds(3600)) }
              guard translationReady else { throw TranslationFailure.unsupported }
            },
            translate: { _, text in
              if let translateBody { return try await translateBody(text) }
              return "translated: \(text)"
            },
            candidateTargets: { [] },
            retain: { pair in retainedPairs.withLock { $0.append(pair) } },
            shutDown: {}
          )
        )
      ),
      captureFocusedTarget: captureFocusedTarget,
      insertText: { text, _, destination in
        recorder.events.append("insertText")
        recorder.insertedTexts.append(text)
        recorder.insertedDestinations.append(destination)
        return insertOutcome
      },
      requestMicrophoneAccess: { true },
      requestSpeechAccess: { true },
      requestAccessibilityAccess: {},
      hasAccessibilityAccess: hasAccessibilityAccess,
      isPermissionAlertPresenting: { false },
      showAccessibilitySetupAlert: {
        recorder.events.append("showAccessibilitySetupAlert")
        recorder.accessibilityAlerts += 1
      },
      showRelaunchAlert: { recorder.events.append("showRelaunchAlert") },
      showListening: { _, isLatched, _, languageTag in
        recorder.events.append("showListening")
        recorder.listeningLatched.append(isLatched)
        recorder.listeningTags.append(languageTag)
      },
      showLatched: { recorder.events.append("showLatched") },
      showLiveText: { _, _ in recorder.events.append("showLiveText") },
      showFinalizing: { recorder.events.append("showFinalizing") },
      showShaping: { name in
        recorder.events.append("showShaping")
        recorder.shapingNames.append(name)
      },
      showShapingChoice: { label in
        recorder.events.append("showShapingChoice")
        recorder.shapingChoiceLabels.append(label)
      },
      showProcesando: { recorder.events.append("showProcesando") },
      showResultado: { resultado in
        recorder.events.append("showResultado")
        recorder.resultados.append(resultado)
      },
      showMessage: { message, _ in
        recorder.events.append("showMessage")
        recorder.messages.append(message)
      },
      showModelDownload: { _ in },
      showAudioLevel: { _ in },
      hideHUD: { recorder.events.append("hideHUD") },
      playPasteSound: { recorder.events.append("playPasteSound") },
      setShapingCycleCaptureEnabled: { enabled in
        recorder.events.append("cycleCapture:\(enabled)")
        recorder.cycleCaptureStates.append(enabled)
      },
      recordSession: { wordCount, speakingDuration in
        recorder.events.append("recordSession")
        recorder.recordedSessions.append((wordCount, speakingDuration))
      },
      recordHistory: { text, translation, source, modo, motor, folder in
        historyEntries.withLock {
          $0.append(HistoryEntry(
            text: text, translation: translation, source: source,
            modo: modo, motor: motor, folder: folder
          ))
        }
      },
      // El motor que escuchó de verdad. Fijo acá: lo que se afirma es que el
      // controlador lo pregunta y lo pasa al historial, no cuál contesta el
      // router.
      motorDelDictado: { "Parakeet v3" },
      guardarNota: { texto in
        notas.withLock { $0.append(texto) }
        return resultadoDeLaNota
      },
      transformar: transformar
    )
  }

  private func makeController(
    settings: AppSettings? = nil,
    dependencies: DirectDictationController.Dependencies
  ) -> DirectDictationController {
    DirectDictationController(
      settings: settings ?? AppSettings(defaults: freshDefaults()),
      dependencies: dependencies
    )
  }

  /// Un toque corto: apretar y soltar el gatillo de `slot`, que es lo que
  /// traba la sesión (`DictationSessionMachine.tapThreshold`).
  ///
  /// Los dos instantes son explícitos porque el umbral se mide **entre los
  /// eventos** y no entre las dos llamadas: arrancar la sesión ocurre entera
  /// dentro del apretón, y en un runner cargado esos milisegundos se comían
  /// los 250 del presupuesto. El toque se leía como un sostenido, la sesión
  /// no se trababa y la espera se iba a los 10 s. Acá el gesto dura 10 ms
  /// pase lo que pase en la máquina.
  private func toque(
    _ controller: DirectDictationController,
    _ slot: GlobalKeyEventMonitor.TriggerSlot
  ) {
    let inicio = ContinuousClock.now
    controller.handle(.triggerPressed(slot), at: inicio)
    controller.handle(.triggerReleased(slot), at: inicio + .milliseconds(10))
  }

  /// Espera a que la condición se cumpla, y recién se rinde a los 10 s de
  /// reloj. Los `sleep` le sueltan el main actor a las tareas del controlador.
  ///
  /// El presupuesto es tiempo y no vueltas. Contando vueltas —200 por 5 ms—
  /// esto decía "un segundo" sólo en una máquina ociosa: con la suite entera
  /// compartiendo el main actor, cada `sleep` de 5 ms vuelve en 11 y, peor,
  /// la tarea que se está esperando hace tres saltos de ejecutor y entra a una
  /// cola larguísima. El presupuesto se gastaba antes de que le tocara correr,
  /// y el test fallaba por la carga del runner y no por el código. Es lo mismo
  /// que ya dice `prepare` más abajo: se espera el estado, no una duración.
  private func waitUntil(
    _ comment: Comment,
    _ condition: @MainActor () -> Bool
  ) async {
    let limite = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < limite {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
    // Una última mirada: el sueño que gastó el plazo pudo ser justo el que
    // dejó correr la tarea que faltaba.
    if condition() { return }
    Issue.record(comment)
  }

  /// Prepares the controller through applyLanguages, then lets the
  /// preparation task run to completion past the prewarm it signals.
  private func prepare(
    _ controller: DirectDictationController,
    prewarmed: OSAllocatedUnfairLock<Bool>
  ) async {
    controller.applyLanguages()
    await waitUntil("Preparation never reached prewarm") {
      prewarmed.withLock { $0 }
    }
    // Wait for the state, not for a duration: preparation resolves and warms
    // a translation pair after the speech prewarm, and a fixed sleep that is
    // long enough on an idle machine is not long enough on a loaded one.
    await waitUntil("Preparation never finished") { controller.isPreparedForTesting }
  }

  /// Prepares, and waits for the translation pair to be ready too.
  private func prepareWithTranslation(
    _ controller: DirectDictationController,
    prewarmed: OSAllocatedUnfairLock<Bool>
  ) async {
    await prepare(controller, prewarmed: prewarmed)
    await waitUntil("Translation never became ready") {
      controller.isTranslationReadyForTesting
    }
  }

  @Test func triggerBeforePreparationShowsPreparingAndStaysIdle() {
    let recorder = Recorder()
    let startEntries = OSAllocatedUnfairLock(initialState: 0)
    let controller = makeController(
      dependencies: makeDependencies(recorder: recorder, startEntries: startEntries)
    )

    controller.handle(.triggerPressed(.primary))

    #expect(controller.sessionStateForTesting == .idle)
    #expect(recorder.messages == ["Preparando el reconocimiento…"])
    #expect(startEntries.withLock { $0 } == 0)
  }

  @Test func missingAccessibilityAccessShowsSetupAlertAndStaysIdle() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let controller = makeController(
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        hasAccessibilityAccess: { false }
      )
    )
    await prepare(controller, prewarmed: prewarmed)

    controller.toggleFromMenu()

    #expect(controller.sessionStateForTesting == .idle)
    #expect(recorder.accessibilityAlerts == 1)
    controller.stop()
  }

  @Test func secureFocusedFieldShowsSecureFieldAndStaysIdle() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let controller = makeController(
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        captureFocusedTarget: { Self.makeTarget(isSecure: true) }
      )
    )
    await prepare(controller, prewarmed: prewarmed)

    controller.toggleFromMenu()

    #expect(controller.sessionStateForTesting == .idle)
    #expect(recorder.messages == ["Campo protegido"])
    controller.stop()
  }

  @Test func approvedMenuToggleBeginsALatchedRecording() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let controller = makeController(
      dependencies: makeDependencies(recorder: recorder, prewarmed: prewarmed)
    )
    await prepare(controller, prewarmed: prewarmed)

    controller.toggleFromMenu()
    await waitUntil("Session never reached recording") {
      controller.sessionStateForTesting == .recording(.latched)
    }

    #expect(recorder.listeningLatched == [true])
    controller.stop()
  }

  @Test func insertedFinishPlaysPasteSoundAndRecordsUsage() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let controller = makeController(
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "hello world" }
      )
    )
    await prepare(controller, prewarmed: prewarmed)
    controller.toggleFromMenu()
    await waitUntil("Session never reached recording") {
      controller.sessionStateForTesting == .recording(.latched)
    }

    controller.toggleFromMenu()
    await waitUntil("Usage was never recorded") {
      recorder.recordedSessions.count == 1
    }

    #expect(controller.sessionStateForTesting == .idle)
    #expect(recorder.insertedTexts == ["hello world"])
    #expect(recorder.recordedSessions.first?.wordCount == 2)
    #expect((recorder.recordedSessions.first?.speakingDuration ?? -1) >= 0)
    // La forma ya no se va al terminar de escuchar: pasa a procesando antes
    // de la entrega y dice el resultado después (contrato del notch).
    let procesandoIndex = recorder.events.firstIndex(of: "showProcesando")
    let soundIndex = recorder.events.firstIndex(of: "playPasteSound")
    #expect(procesandoIndex != nil && soundIndex != nil)
    if let procesandoIndex, let soundIndex {
      #expect(procesandoIndex < soundIndex)
    }
    #expect(recorder.count(of: "hideHUD") == 0, "una sesión que entregó no se cancela")
    #expect(recorder.resultados == [.listo])
    controller.stop()
  }

  @Test func clipboardFallbackStillPlaysPasteSoundAndRecordsUsage() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let controller = makeController(
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "hello world" },
        insertOutcome: .copiedToClipboard
      )
    )
    await prepare(controller, prewarmed: prewarmed)
    controller.toggleFromMenu()
    await waitUntil("Session never reached recording") {
      controller.sessionStateForTesting == .recording(.latched)
    }

    controller.toggleFromMenu()
    await waitUntil("Usage was never recorded") {
      recorder.recordedSessions.count == 1
    }

    #expect(controller.sessionStateForTesting == .idle)
    #expect(recorder.count(of: "playPasteSound") == 1)
    controller.stop()
  }

  @Test func unavailableInsertionShowsMessageWithoutSoundOrUsage() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let controller = makeController(
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "hello world" },
        insertOutcome: .unavailable
      )
    )
    await prepare(controller, prewarmed: prewarmed)
    controller.toggleFromMenu()
    await waitUntil("Session never reached recording") {
      controller.sessionStateForTesting == .recording(.latched)
    }

    controller.toggleFromMenu()
    await waitUntil("Insertion failure message never shown") {
      recorder.messages.contains("No se pudo pegar el texto")
    }

    #expect(controller.sessionStateForTesting == .idle)
    #expect(recorder.count(of: "playPasteSound") == 0)
    #expect(recorder.recordedSessions.isEmpty)
    controller.stop()
  }

  @Test func finishFailureShowsTheErrorAndInsertsNothing() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let controller = makeController(
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { throw FinishError() }
      )
    )
    await prepare(controller, prewarmed: prewarmed)
    controller.toggleFromMenu()
    await waitUntil("Session never reached recording") {
      controller.sessionStateForTesting == .recording(.latched)
    }

    controller.toggleFromMenu()
    await waitUntil("Finish failure message never shown") {
      recorder.messages.contains("finish failed")
    }

    #expect(controller.sessionStateForTesting == .idle)
    #expect(recorder.insertedTexts.isEmpty)
    controller.stop()
  }

  @Test func escapeWhileStartingHidesTheHUDAndInsertsNothing() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let startEntries = OSAllocatedUnfairLock(initialState: 0)
    let controller = makeController(
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        startEntries: startEntries,
        startRecognitionBody: { _ in
          // Held open until the controller cancels the start task; the
          // CancellationError propagates as the torn-down start.
          try await Task.sleep(for: .seconds(10))
        }
      )
    )
    await prepare(controller, prewarmed: prewarmed)

    controller.toggleFromMenu()
    await waitUntil("Recognition start was never entered") {
      startEntries.withLock { $0 } >= 1
    }
    controller.handle(.cancelPressed)
    await waitUntil("Cancelled start never reset to idle") {
      controller.sessionStateForTesting == .idle
    }

    #expect(recorder.count(of: "hideHUD") == 1)
    #expect(recorder.insertedTexts.isEmpty)
    controller.stop()
  }

  @Test func escapeWhileRecordingCancelsRecognitionAndHidesTheHUD() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let cancelCount = OSAllocatedUnfairLock(initialState: 0)
    let controller = makeController(
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        cancelCount: cancelCount
      )
    )
    await prepare(controller, prewarmed: prewarmed)
    controller.toggleFromMenu()
    await waitUntil("Session never reached recording") {
      controller.sessionStateForTesting == .recording(.latched)
    }

    controller.handle(.cancelPressed)
    await waitUntil("Cancelled recording never reset to idle") {
      controller.sessionStateForTesting == .idle
    }

    #expect(cancelCount.withLock { $0 } >= 1)
    #expect(recorder.count(of: "hideHUD") == 1)
    #expect(recorder.insertedTexts.isEmpty)
    controller.stop()
  }

  @Test func emptyFinishTextStillRecordsAZeroWordSession() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let controller = makeController(
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "" }
      )
    )
    await prepare(controller, prewarmed: prewarmed)
    controller.toggleFromMenu()
    await waitUntil("Session never reached recording") {
      controller.sessionStateForTesting == .recording(.latched)
    }

    controller.toggleFromMenu()
    await waitUntil("Usage was never recorded") {
      recorder.recordedSessions.count == 1
    }

    #expect(controller.sessionStateForTesting == .idle)
    #expect(recorder.insertedTexts == [""])
    #expect(recorder.recordedSessions.first?.wordCount == 0)
    controller.stop()
  }

  /// stop() during an in-flight finish must wait for the finish before
  /// shutting the speech service down: shutting down beside it made a
  /// scheduler race decide whether the last words were inserted or dropped.
  @Test func stopDuringFinishInsertsTheTextBeforeShutDown() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let order = OSAllocatedUnfairLock<[String]>(initialState: [])
    let finishEntered = OSAllocatedUnfairLock(initialState: false)
    let finishReleased = OSAllocatedUnfairLock(initialState: false)
    let controller = makeController(
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: {
          finishEntered.withLock { $0 = true }
          while !finishReleased.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(5))
          }
          order.withLock { $0.append("finish") }
          return "held words"
        },
        shutDownRecognition: { order.withLock { $0.append("shutDown") } }
      )
    )
    await prepare(controller, prewarmed: prewarmed)

    controller.toggleFromMenu()
    await waitUntil("Session never reached recording") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.toggleFromMenu()
    await waitUntil("Finish never began") { finishEntered.withLock { $0 } }

    controller.stop()
    finishReleased.withLock { $0 = true }
    await waitUntil("Shut down never ran") {
      order.withLock { $0.contains("shutDown") }
    }

    #expect(recorder.insertedTexts == ["held words"])
    #expect(order.withLock { $0 } == ["finish", "shutDown"])
  }

  /// The destination rides in the session snapshot: a Settings change made
  /// mid-session must not redirect the finish already under way.
  @Test func finishDeliversWithTheDestinationCapturedAtSessionStart() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let settings = AppSettings(defaults: freshDefaults())
    settings.insertionDestination = .clipboardOnly
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "captured words" }
      )
    )
    await prepare(controller, prewarmed: prewarmed)

    controller.toggleFromMenu()
    await waitUntil("Session never reached recording") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    settings.insertionDestination = .both
    controller.toggleFromMenu()
    await waitUntil("Finish never delivered") {
      controller.sessionStateForTesting == .idle && !recorder.insertedTexts.isEmpty
    }

    #expect(recorder.insertedDestinations == [.clipboardOnly])
    controller.stop()
  }

  /// History off — the default — writes nothing, whatever the session says.
  @Test func finishWritesNoHistoryWhileTheSettingIsOff() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let historyEntries = OSAllocatedUnfairLock<[HistoryEntry]>(
      initialState: []
    )
    let controller = makeController(
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "spoken words" },
        historyEntries: historyEntries
      )
    )
    await prepare(controller, prewarmed: prewarmed)

    controller.toggleFromMenu()
    await waitUntil("Session never reached recording") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.toggleFromMenu()
    await waitUntil("Finish never delivered") { !recorder.insertedTexts.isEmpty }

    #expect(historyEntries.withLock { $0 }.isEmpty)
    controller.stop()
  }

  /// History on writes the finished text to the session's captured folder,
  /// before the insertion outcome can lose it.
  @Test func finishWritesHistoryToTheCapturedFolderWhileOn() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let historyEntries = OSAllocatedUnfairLock<[HistoryEntry]>(
      initialState: []
    )
    let folder = URL(filePath: "/tmp/DiloTests-history-\(UUID().uuidString)")
    let settings = AppSettings(defaults: freshDefaults())
    settings.dictationHistoryEnabled = true
    settings.dictationHistoryFolder = folder
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "spoken words" },
        historyEntries: historyEntries,
        insertOutcome: .unavailable
      )
    )
    await prepare(controller, prewarmed: prewarmed)

    controller.toggleFromMenu()
    await waitUntil("Session never reached recording") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.toggleFromMenu()
    await waitUntil("Finish never delivered") { !recorder.insertedTexts.isEmpty }

    let entries = historyEntries.withLock { $0 }
    #expect(entries.map(\.text) == ["spoken words"])
    #expect(entries.map(\.folder) == [folder])
    controller.stop()
  }

  /// The feature: a translate session inserts the translation, not the words.
  /// The target is the one thing the user cannot check anywhere else before
  /// speaking, and a wrong one only shows up after the text lands. With a
  /// single dictation language the HUD used to name nothing at all.
  @Test func aTranslateSessionNamesThePairInTheHUD() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let settings = AppSettings(defaults: freshDefaults())
    settings.translationTargetIdentifier = "es"
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(recorder: recorder, prewarmed: prewarmed)
    )
    await prepareWithTranslation(controller, prewarmed: prewarmed)

    controller.handle(.triggerPressed(.translate))
    await waitUntil("Never showed listening") {
      recorder.events.contains("showListening")
    }

    #expect(recorder.listeningTags == ["EN → ES"])
  }

  /// A plain session in the only configured language names nothing: there is
  /// no second language to tell it apart from.
  @Test func aPlainSingleLanguageSessionNamesNothing() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let controller = makeController(
      dependencies: makeDependencies(recorder: recorder, prewarmed: prewarmed)
    )
    await prepare(controller, prewarmed: prewarmed)

    controller.handle(.triggerPressed(.primary))
    await waitUntil("Never showed listening") {
      recorder.events.contains("showListening")
    }

    #expect(recorder.listeningTags == [nil])
  }

  @Test func aTranslateSessionInsertsTheTranslationRatherThanWhatWasSpoken() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let settings = AppSettings(defaults: freshDefaults())
    settings.translationTargetIdentifier = "es"
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "spoken words" }
      )
    )
    await prepareWithTranslation(controller, prewarmed: prewarmed)

    // Un toque corto traba la sesión y el siguiente apretón es el que la
    // termina. Trabar en vez de dormir más allá del umbral de 250 ms es lo
    // que deja a este test fuera del reloj.
    toque(controller, .translate)
    await waitUntil("Session never latched") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.handle(.triggerPressed(.translate))
    await waitUntil("Finish never delivered") { !recorder.insertedTexts.isEmpty }

    #expect(recorder.insertedTexts == ["translated: spoken words"])
    controller.stop()
  }

  /// A translation model that will not load must not hold plain dictation
  /// behind it. Preparation returning is what installs the event tap, so
  /// awaiting the model there disables the key the user actually pressed.
  @Test func aHangingTranslationModelStillLeavesDictationPrepared() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let settings = AppSettings(defaults: freshDefaults())
    settings.translationTargetIdentifier = "es"
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        translationPrepareHangs: true
      )
    )

    controller.applyLanguages()
    await waitUntil("Never prepared") { controller.isPreparedForTesting }

    #expect(!controller.isTranslationReadyForTesting)
    controller.stop()
  }

  /// A menu-started session owns the primary key, whatever the last session
  /// owned. Without that, a rebind during it pins the tap to a key the user
  /// cannot press while refusing the one they can.
  @Test func aMenuStartedSessionOwnsThePrimaryKey() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let settings = AppSettings(defaults: freshDefaults())
    settings.translationTargetIdentifier = "es"
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(recorder: recorder, prewarmed: prewarmed)
    )
    await prepareWithTranslation(controller, prewarmed: prewarmed)

    // A translate session first, so a stale binding exists to inherit.
    toque(controller, .translate)
    await waitUntil("Session never latched") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    #expect(controller.activeBindingForTesting == settings.translateTriggerBinding)
    controller.handle(.triggerPressed(.translate))
    await waitUntil("Session never ended") {
      controller.sessionStateForTesting == .idle
    }

    controller.toggleFromMenu()

    #expect(controller.activeBindingForTesting == settings.dictationTriggerBinding)
    controller.stop()
  }

  /// Changing a language drops the old pair before the reload is even
  /// scheduled. A translate key already queued on this actor would otherwise
  /// find the old pair ready and snapshot it, and insert the language the user
  /// just stopped choosing (ADR-0004).
  @Test func changingLanguagesDropsTheOldPairAtOnce() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let settings = AppSettings(defaults: freshDefaults())
    settings.translationTargetIdentifier = "es"
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(recorder: recorder, prewarmed: prewarmed)
    )
    await prepareWithTranslation(controller, prewarmed: prewarmed)
    #expect(controller.isTranslationReadyForTesting)

    // Synchronous: nothing is awaited between here and the assertion, so the
    // reload's own task cannot have run yet.
    controller.applyLanguages()

    #expect(!controller.isTranslationReadyForTesting)
    controller.stop()
  }

  /// A session keeps the key it started with. Rebinding mid-gesture would
  /// otherwise take that key away and the release would land on nothing: the
  /// session records until Escape (CONTEXT.md).
  @Test func aSessionsSlotKeepsTheKeyItStartedWith() {
    let settings = AppSettings(defaults: freshDefaults())
    settings.translationTargetIdentifier = "es"
    let started = settings.translateTriggerBinding
    settings.translateTriggerBinding = .optionEscape

    let bindings = DirectDictationController.triggerBindings(
      settings: settings,
      sessionSlot: .translate,
      sessionBinding: started
    )

    #expect(bindings.translate == started)
    // Only the busy slot is pinned; the rest follow the preferences.
    #expect(bindings.trigger == settings.dictationTriggerBinding)
  }

  /// Turning a language off mid-session cannot take its key either.
  @Test func aSessionsSlotSurvivesItsLanguageBeingTurnedOff() {
    let settings = AppSettings(defaults: freshDefaults())
    let started = settings.translateTriggerBinding

    let bindings = DirectDictationController.triggerBindings(
      settings: settings,
      sessionSlot: .translate,
      sessionBinding: started
    )

    #expect(!settings.isTranslationEnabled)
    #expect(bindings.translate == started)
  }

  /// With no session, every slot follows the preferences, and a slot with no
  /// language is not installed at all.
  @Test func anIdleTapFollowsThePreferences() {
    let settings = AppSettings(defaults: freshDefaults())

    let bindings = DirectDictationController.triggerBindings(
      settings: settings,
      sessionSlot: nil,
      sessionBinding: nil
    )

    #expect(bindings.trigger == settings.dictationTriggerBinding)
    #expect(bindings.secondary == nil)
    #expect(bindings.translate == nil)
  }

  /// El modo corre antes de la traducción. Un prompt está escrito en un
  /// idioma, con su ejemplo en ese idioma, así que darle una traducción es
  /// pedirle trabajar en uno para el que no se escribió.
  @Test func elModoVeLoDichoYLaTraduccionVeLoTransformado() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let shapedInput = OSAllocatedUnfairLock<String?>(initialState: nil)
    let translatedInput = OSAllocatedUnfairLock<String?>(initialState: nil)
    let settings = AppSettings(defaults: freshDefaults())
    settings.translationTargetIdentifier = "es"
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "um so ship it thursday" },
        translateBody: { text in
          translatedInput.withLock { $0 = text }
          return "envíalo el jueves"
        },
        transformar: { texto, _, _ in
          shapedInput.withLock { $0 = texto }
          return .transformado("Ship it on Thursday")
        }
      )
    )
    await prepareWithTranslation(controller, prewarmed: prewarmed)

    toque(controller, .translate)
    await waitUntil("Session never latched") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    // Una sesión de traducir no tiene tecla de modo, así que el modo se
    // elige con las flechas mientras habla: una flecha desde "sin modo" cae
    // en el primero de la lista.
    controller.handle(.shapingCycleRight)
    controller.handle(.triggerPressed(.translate))
    await waitUntil("Finish never delivered") { !recorder.insertedTexts.isEmpty }

    #expect(shapedInput.withLock { $0 } == "um so ship it thursday")
    #expect(translatedInput.withLock { $0 } == "Ship it on Thursday")
    #expect(recorder.insertedTexts == ["envíalo el jueves"])
    controller.stop()
  }

  /// History's delivered line is what landed. Written before shaping it
  /// recorded a translation nobody received, which only shows with both
  /// features on, because that line exists only for a translated session.
  @Test func historyRecordsTheTextThatWasActuallyInserted() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let historyEntries = OSAllocatedUnfairLock<[HistoryEntry]>(initialState: [])
    let settings = AppSettings(defaults: freshDefaults())
    settings.dictationHistoryEnabled = true
    settings.translationTargetIdentifier = "es"
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "um so ship it thursday" },
        historyEntries: historyEntries,
        translateBody: { _ in "envíalo el jueves" },
        transformar: { _, _, _ in .transformado("Ship it on Thursday") }
      )
    )
    await prepareWithTranslation(controller, prewarmed: prewarmed)

    toque(controller, .translate)
    await waitUntil("Session never latched") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.handle(.shapingCycleRight)
    controller.handle(.triggerPressed(.translate))
    await waitUntil("Finish never delivered") { !recorder.insertedTexts.isEmpty }

    let entries = historyEntries.withLock { $0 }
    // The spoken half is still the words as spoken, and the delivered half is
    // what the document received.
    #expect(entries.map(\.text) == ["um so ship it thursday"])
    #expect(entries.first?.translation?.text == recorder.insertedTexts.first)
    controller.stop()
  }

  /// The clipboard rescue can be refused too, while a read holds its lease.
  /// Saying only that the translation failed would promise words that are not
  /// anywhere the user can reach.
  @Test func aTranslationFailureSaysSoWhenTheClipboardRefusesAsWell() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let settings = AppSettings(defaults: freshDefaults())
    settings.translationTargetIdentifier = "es"
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "spoken words" },
        translateBody: { _ in throw TranslationFailure.timedOut },
        insertOutcome: .unavailable
      )
    )
    await prepareWithTranslation(controller, prewarmed: prewarmed)

    toque(controller, .translate)
    await waitUntil("Session never latched") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.handle(.triggerPressed(.translate))
    await waitUntil("Never reported") {
      recorder.messages.contains { $0.hasPrefix("No se pudo traducir") }
    }

    #expect(recorder.messages.contains("No se pudo traducir ni copiar"))
    controller.stop()
  }

  /// Insights counts the words that were spoken. Speaking duration is measured
  /// on the source side, so counting a translation's words against it would
  /// divide one language's count by another's minutes.
  @Test func aTranslatedSessionCountsTheWordsThatWereSpoken() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let settings = AppSettings(defaults: freshDefaults())
    settings.translationTargetIdentifier = "es"
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "one two three" },
        // Six words out for three words in, which is the whole point.
        translateBody: { _ in "uno dos tres cuatro cinco seis" }
      )
    )
    await prepareWithTranslation(controller, prewarmed: prewarmed)

    toque(controller, .translate)
    await waitUntil("Session never latched") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.handle(.triggerPressed(.translate))
    await waitUntil("Never recorded") { !recorder.recordedSessions.isEmpty }

    #expect(recorder.recordedSessions.map(\.0) == [3])
    controller.stop()
  }

  /// A translation that comes back unchanged still ran, so the entry still
  /// names both languages. Names, URLs and numbers translate to themselves.
  @Test func anUnchangedTranslationStillLabelsBothLanguages() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let historyEntries = OSAllocatedUnfairLock<[HistoryEntry]>(initialState: [])
    let settings = AppSettings(defaults: freshDefaults())
    settings.translationTargetIdentifier = "es"
    settings.dictationHistoryEnabled = true
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "Dilo" },
        historyEntries: historyEntries,
        translateBody: { $0 }
      )
    )
    await prepareWithTranslation(controller, prewarmed: prewarmed)

    toque(controller, .translate)
    await waitUntil("Session never latched") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.handle(.triggerPressed(.translate))
    await waitUntil("Finish never delivered") { !recorder.insertedTexts.isEmpty }

    let entries = historyEntries.withLock { $0 }
    #expect(entries.first?.translation?.spokenTag == "EN")
    #expect(entries.first?.translation?.text == "Dilo")
    controller.stop()
  }

  /// History keeps what was said, not only what was delivered: a failed
  /// insertion must not be able to lose the spoken half (ADR-0007), and it is
  /// the only half that cannot be produced again.
  @Test func aTranslatedSessionRecordsTheSpokenWordsAndTheTranslation() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let historyEntries = OSAllocatedUnfairLock<[HistoryEntry]>(initialState: [])
    let settings = AppSettings(defaults: freshDefaults())
    settings.translationTargetIdentifier = "es"
    settings.dictationHistoryEnabled = true
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "spoken words" },
        historyEntries: historyEntries
      )
    )
    await prepareWithTranslation(controller, prewarmed: prewarmed)

    toque(controller, .translate)
    await waitUntil("Session never latched") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.handle(.triggerPressed(.translate))
    await waitUntil("Finish never delivered") { !recorder.insertedTexts.isEmpty }

    let entries = historyEntries.withLock { $0 }
    #expect(entries.map(\.text) == ["spoken words"])
    #expect(entries.first?.translation?.text == "translated: spoken words")
    #expect(entries.first?.translation?.spokenTag == "EN")
    #expect(entries.first?.translation?.deliveredTag == "ES")
    controller.stop()
  }

  /// A failed translation delivers nothing and rescues the words to the
  /// clipboard: the wrong language in someone else's document is worse than a
  /// paste the user has to make themselves.
  @Test func aFailedTranslationInsertsNothingAndCopiesWhatWasSpoken() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let settings = AppSettings(defaults: freshDefaults())
    settings.translationTargetIdentifier = "es"
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "spoken words" },
        translateBody: { _ in throw TranslationFailure.timedOut }
      )
    )
    await prepareWithTranslation(controller, prewarmed: prewarmed)

    toque(controller, .translate)
    await waitUntil("Session never latched") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.handle(.triggerPressed(.translate))
    await waitUntil("Rescue never happened") { !recorder.insertedTexts.isEmpty }

    #expect(recorder.insertedTexts == ["spoken words"])
    #expect(recorder.insertedDestinations == [.clipboardOnly])
    #expect(recorder.messages.contains("No se pudo traducir"))
    // A rescue is not a delivery.
    #expect(recorder.count(of: "playPasteSound") == 0)
    #expect(recorder.recordedSessions.isEmpty)
    controller.stop()
  }

  /// The trap: routing the failure through fail() would drive the machine to
  /// cancelling and cancel a session that has already finished.
  @Test func aFailedTranslationEndsTheSessionRatherThanCancellingIt() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let cancelCount = OSAllocatedUnfairLock(initialState: 0)
    let settings = AppSettings(defaults: freshDefaults())
    settings.translationTargetIdentifier = "es"
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        cancelCount: cancelCount,
        finishRecognition: { "spoken words" },
        translateBody: { _ in throw TranslationFailure.timedOut }
      )
    )
    await prepareWithTranslation(controller, prewarmed: prewarmed)

    toque(controller, .translate)
    await waitUntil("Session never latched") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.handle(.triggerPressed(.translate))
    await waitUntil("Session never ended") { controller.sessionStateForTesting == .idle }

    #expect(cancelCount.withLock { $0 } == 0)
    controller.stop()
  }

  /// A plain trigger in the same app still inserts what was said.
  @Test func aPlainSessionIsUntouchedWhileTranslationIsConfigured() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let settings = AppSettings(defaults: freshDefaults())
    settings.translationTargetIdentifier = "es"
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "spoken words" }
      )
    )
    await prepare(controller, prewarmed: prewarmed)

    controller.toggleFromMenu()
    await waitUntil("Session never reached recording") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.toggleFromMenu()
    await waitUntil("Finish never delivered") { !recorder.insertedTexts.isEmpty }

    #expect(recorder.insertedTexts == ["spoken words"])
    controller.stop()
  }

  /// The rule that protects plain dictation: a translation model that will not
  /// load leaves dictation prepared and only the translate key refused.
  @Test func aTranslationPrewarmFailureStillLeavesDictationWorking() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let settings = AppSettings(defaults: freshDefaults())
    settings.translationTargetIdentifier = "es"
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "spoken words" },
        translationReady: false
      )
    )
    await prepare(controller, prewarmed: prewarmed)
    // Preparation does not wait for the translation model, so the pair may not
    // be resolved yet even though dictation is ready. Pressing before it is
    // dice "Elige un idioma para traducir", que es otra negativa.
    await waitUntil("Translation pair never resolved") {
      controller.translationPairForTesting != nil
    }

    controller.handle(.triggerPressed(.translate))
    #expect(controller.sessionStateForTesting == .idle)
    #expect(recorder.messages.contains("La traducción no está lista"))

    // And plain dictation still works.
    controller.toggleFromMenu()
    await waitUntil("Plain session never started") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.stop()
  }

  /// The regression: a target chosen after launch has to reach the pair.
  /// Preparation resolves it, so anything that changes the target must re-run
  /// preparation, or the trigger is installed with nothing to translate into
  /// y rechaza cada apretón con "Elige un idioma para traducir".
  @Test func aTargetChosenAfterLaunchResolvesOnceLanguagesAreReapplied() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let settings = AppSettings(defaults: freshDefaults())
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "spoken words" }
      )
    )
    // Prepared with translation off, exactly as a launch with no target.
    await prepare(controller, prewarmed: prewarmed)
    controller.handle(.triggerPressed(.translate))
    #expect(recorder.messages.contains("Elige un idioma para traducir"))

    // Now a target is chosen and the languages are reapplied.
    settings.translationTargetIdentifier = "es"
    await prepareWithTranslation(controller, prewarmed: prewarmed)

    toque(controller, .translate)
    await waitUntil("Session never latched") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.handle(.triggerPressed(.translate))
    await waitUntil("Finish never delivered") { !recorder.insertedTexts.isEmpty }

    #expect(recorder.insertedTexts == ["translated: spoken words"])
    controller.stop()
  }

  /// A day file that says only what you said is harder to use later than one
  /// that says where you were saying it, so the entry names the application
  /// that held focus when the session started.
  @Test func historyNamesTheApplicationTheTextWasAimedAt() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let historyEntries = OSAllocatedUnfairLock<[HistoryEntry]>(
      initialState: []
    )
    let settings = AppSettings(defaults: freshDefaults())
    settings.dictationHistoryEnabled = true
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        captureFocusedTarget: { Self.makeTarget(applicationName: "Ghostty") },
        finishRecognition: { "spoken words" },
        historyEntries: historyEntries
      )
    )
    await prepare(controller, prewarmed: prewarmed)

    controller.toggleFromMenu()
    await waitUntil("Session never reached recording") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.toggleFromMenu()
    await waitUntil("Finish never delivered") { !recorder.insertedTexts.isEmpty }

    #expect(historyEntries.withLock { $0 }.map(\.source) == ["Ghostty"])
    controller.stop()
  }

  /// Clipboard-only never aims at an application, so naming whichever one
  /// happened to hold focus would put a lie in the file.
  @Test func clipboardOnlyHistoryNamesTheClipboardRatherThanAnApplication() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let historyEntries = OSAllocatedUnfairLock<[HistoryEntry]>(
      initialState: []
    )
    let settings = AppSettings(defaults: freshDefaults())
    settings.dictationHistoryEnabled = true
    settings.insertionDestination = .clipboardOnly
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        captureFocusedTarget: { Self.makeTarget(applicationName: "Ghostty") },
        finishRecognition: { "spoken words" },
        historyEntries: historyEntries,
        insertOutcome: .copiedToClipboard
      )
    )
    await prepare(controller, prewarmed: prewarmed)

    controller.toggleFromMenu()
    await waitUntil("Session never reached recording") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.toggleFromMenu()
    await waitUntil("Finish never delivered") { !recorder.insertedTexts.isEmpty }

    #expect(historyEntries.withLock { $0 }.map(\.source) == ["Clipboard"])
    controller.stop()
  }


  /// El encargo entero, de punta a punta: apretar la tecla de un modo dicta y
  /// transforma **con ese modo**. Era justo lo que no pasaba — los modos se
  /// guardaban con su gatillo y el controlador seguía usando la otra
  /// biblioteca, así que de los cinco modos ninguno disparaba nada.
  @Test func laTeclaDeUnModoTerminaTransformandoConEseModo() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let historyEntries = OSAllocatedUnfairLock<[HistoryEntry]>(initialState: [])
    let modosUsados = OSAllocatedUnfairLock<[String]>(initialState: [])
    let settings = AppSettings(defaults: freshDefaults())
    settings.dictationHistoryEnabled = true
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "raw words" },
        historyEntries: historyEntries,
        transformar: { texto, modo, _ in
          modosUsados.withLock { $0.append(modo.id) }
          return .transformado("con \(modo.id): \(texto)")
        }
      )
    )
    await prepare(controller, prewarmed: prewarmed)

    toque(controller, .modo("correo"))
    await waitUntil("La sesión nunca se trabó") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.handle(.triggerPressed(.modo("correo")))
    await waitUntil("El final nunca entregó") { !recorder.insertedTexts.isEmpty }

    #expect(modosUsados.withLock { $0 } == ["correo"])
    #expect(recorder.insertedTexts == ["con correo: raw words"])
    #expect(recorder.shapingNames == ["Correo"])
    // El historial guarda el modo real, con su id: el nombre se edita, el id
    // no, y antes ahí iba el nombre de un prompt de la otra biblioteca.
    #expect(historyEntries.withLock { $0 }.map(\.modo) == ["Correo (correo)"])
    #expect(historyEntries.withLock { $0 }.map(\.text) == ["raw words"])
    controller.stop()
  }

  /// La tecla del dictado de siempre no pasa por ninguna IA. Es la promesa
  /// del producto y el default: sin modo elegido y con "Dilo decide" apagado,
  /// nadie transforma nada.
  @Test func elDictadoNormalNoPasaPorNingunModo() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let llamadas = OSAllocatedUnfairLock(initialState: 0)
    let controller = makeController(
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "raw words" },
        transformar: { texto, _, _ in
          llamadas.withLock { $0 += 1 }
          return .transformado("transformado \(texto)")
        }
      )
    )
    await prepare(controller, prewarmed: prewarmed)

    controller.toggleFromMenu()
    await waitUntil("La sesión nunca grabó") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.toggleFromMenu()
    await waitUntil("El final nunca entregó") { !recorder.insertedTexts.isEmpty }

    #expect(recorder.insertedTexts == ["raw words"])
    #expect(llamadas.withLock { $0 } == 0)
    controller.stop()
  }

  /// **Nunca un fallback silencioso.** Si el proveedor congelado falla, no se
  /// prueba otro: se dice qué pasó y las palabras salen tal como se dijeron.
  @Test func unProveedorQueFallaNoSeVaAOtroYLaPildoraLoDice() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let intentos = OSAllocatedUnfairLock(initialState: 0)
    let controller = makeController(
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "raw words" },
        transformar: { _, modo, _ in
          intentos.withLock { $0 += 1 }
          return .salioTalCual(
            aviso: "\(modo.nombre) no pudo reescribir: OpenAI no respondió."
          )
        }
      )
    )
    await prepare(controller, prewarmed: prewarmed)

    toque(controller, .modo("limpio"))
    await waitUntil("La sesión nunca se trabó") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.handle(.triggerPressed(.modo("limpio")))
    await waitUntil("El final nunca entregó") { !recorder.insertedTexts.isEmpty }

    // Un solo intento: no hay segundo proveedor.
    #expect(intentos.withLock { $0 } == 1)
    #expect(recorder.insertedTexts == ["raw words"])
    #expect(recorder.messages.last?.contains("no pudo reescribir") == true)
    // Y las palabras quedan recuperables desde el menú de la barra.
    #expect(controller.ultimoDictado?.texto(.original) == "raw words")
    controller.stop()
  }

  /// El proveedor se congela al empezar. Cambiar Ajustes mientras alguien
  /// habla aplica al dictado siguiente (ADR-0004), y acá eso es lo que impide
  /// que un modo que empezó local termine saliendo a una nube.
  @Test func cambiarAjustesAMitadDeDictadoNoCambiaElProveedorDeLaSesion() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let vistos = OSAllocatedUnfairLock<[String]>(initialState: [])
    let settings = AppSettings(defaults: freshDefaults())
    settings.proveedorGeneralID = "chip"
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "raw words" },
        transformar: { texto, _, proveedor in
          if case let .corre(resuelto) = proveedor {
            vistos.withLock { $0.append(resuelto.proveedor.id) }
          }
          return .transformado(texto)
        }
      )
    )
    await prepare(controller, prewarmed: prewarmed)

    toque(controller, .modo("limpio"))
    await waitUntil("La sesión nunca se trabó") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    // Mientras la persona habla, alguien cambia el proveedor general a una
    // nube y le pone modelo para que resuelva de verdad.
    settings.proveedorGeneralID = "openai"
    if let indice = settings.proveedores.firstIndex(where: { $0.id == "openai" }) {
      settings.proveedores[indice].modelo = "gpt-5"
    }
    controller.handle(.triggerPressed(.modo("limpio")))
    await waitUntil("El final nunca entregó") { !recorder.insertedTexts.isEmpty }

    #expect(vistos.withLock { $0 } == ["chip"])
    controller.stop()
  }

  /// "Un atajo, Dilo decide": con el interruptor prendido, el atajo de
  /// siempre resuelve el modo por reglas, y el historial guarda cuál ganó.
  @Test func conDiloDecidiendoElAtajoPrincipalEligeModoYElHistorialDiceporQue() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let historyEntries = OSAllocatedUnfairLock<[HistoryEntry]>(initialState: [])
    let modosUsados = OSAllocatedUnfairLock<[String]>(initialState: [])
    let settings = AppSettings(defaults: freshDefaults())
    settings.unAtajoDiloDecide = true
    settings.dictationHistoryEnabled = true
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        // Ghostty al frente: el modo Código lo lista, y la app al frente es
        // la señal que mide 100 % en el set de evaluación.
        captureFocusedTarget: { Self.makeTarget(applicationName: "Ghostty") },
        finishRecognition: { "raw words" },
        historyEntries: historyEntries,
        transformar: { texto, modo, _ in
          modosUsados.withLock { $0.append(modo.id) }
          return .transformado("con \(modo.id): \(texto)")
        }
      )
    )
    await prepare(controller, prewarmed: prewarmed)

    controller.toggleFromMenu()
    await waitUntil("La sesión nunca grabó") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.toggleFromMenu()
    await waitUntil("El final nunca entregó") { !recorder.insertedTexts.isEmpty }

    #expect(modosUsados.withLock { $0 } == ["codigo"])
    #expect(recorder.insertedTexts == ["con codigo: raw words"])
    let modoEnElHistorial = historyEntries.withLock { $0 }.first?.modo
    #expect(modoEnElHistorial?.contains("Código (codigo)") == true)
    #expect(modoEnElHistorial?.contains("la app al frente era Ghostty") == true)
    controller.stop()
  }

  /// La tecla le gana al decididor: lo que la persona dijo explícitamente no
  /// lo contradice ninguna regla.
  @Test func laTeclaDelModoLeGanaADiloDecide() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let modosUsados = OSAllocatedUnfairLock<[String]>(initialState: [])
    let settings = AppSettings(defaults: freshDefaults())
    settings.unAtajoDiloDecide = true
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        captureFocusedTarget: { Self.makeTarget(applicationName: "Ghostty") },
        finishRecognition: { "raw words" },
        transformar: { texto, modo, _ in
          modosUsados.withLock { $0.append(modo.id) }
          return .transformado(texto)
        }
      )
    )
    await prepare(controller, prewarmed: prewarmed)

    toque(controller, .modo("mensaje"))
    await waitUntil("La sesión nunca se trabó") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.handle(.triggerPressed(.modo("mensaje")))
    await waitUntil("El final nunca entregó") { !recorder.insertedTexts.isEmpty }

    #expect(modosUsados.withLock { $0 } == ["mensaje"])
    controller.stop()
  }

  /// El original y el resultado se guardan separados, en memoria de la
  /// sesión: es lo que "Copiar el último dictado" ofrece sin que nadie tenga
  /// que encender el historial, que escribe a disco y viene apagado.
  @Test func elUltimoDictadoGuardaLasDosMitades() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let avisados = OSAllocatedUnfairLock<[String]>(initialState: [])
    let settings = AppSettings(defaults: freshDefaults())
    // Historial apagado, que es el default: esto tiene que funcionar igual.
    #expect(!settings.dictationHistoryEnabled)
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "eh o sea mándale el correo" },
        transformar: { _, _, _ in .transformado("Estimado Juan:") }
      )
    )
    controller.onUltimoDictadoChange = { dictado in
      if let dictado { avisados.withLock { $0.append(dictado.texto(.entregado)) } }
    }
    await prepare(controller, prewarmed: prewarmed)

    toque(controller, .modo("correo"))
    await waitUntil("La sesión nunca se trabó") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.handle(.triggerPressed(.modo("correo")))
    await waitUntil("El final nunca entregó") { !recorder.insertedTexts.isEmpty }

    let ultimo = controller.ultimoDictado
    // El crudo es el de antes de limpiar muletillas: es lo único de todo
    // esto que no se puede reconstruir.
    #expect(ultimo?.texto(.original) == "eh o sea mándale el correo")
    #expect(ultimo?.texto(.entregado) == "Estimado Juan:")
    #expect(ultimo?.modo == "Correo")
    #expect(ultimo?.tieneDosMitades == true)
    #expect(avisados.withLock { $0 } == ["Estimado Juan:"])
    controller.stop()
  }

  /// El pegado que se cae al portapapeles ya lo hacía el camino heredado,
  /// pero callado: las palabras quedaban en otra parte y nadie lo decía.
  @Test func unPegadoQueSeCaeAlPortapapelesLoDiceEnLaPildora() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let controller = makeController(
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "raw words" },
        insertOutcome: .copiedToClipboard
      )
    )
    await prepare(controller, prewarmed: prewarmed)

    controller.toggleFromMenu()
    await waitUntil("La sesión nunca grabó") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.toggleFromMenu()
    await waitUntil("El final nunca entregó") { !recorder.insertedTexts.isEmpty }

    #expect(recorder.messages.last?.contains("te lo copié") == true)
    controller.stop()
  }

  /// Lo que las flechas recorren es [cada modo…, sin modo], dando la vuelta:
  /// un paso a la izquierda desde "sin modo" cae en el último de la lista.
  @Test func lasFlechasRecorrenLaListaYVuelvenASinModo() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let llamadas = OSAllocatedUnfairLock(initialState: 0)
    let settings = AppSettings(defaults: freshDefaults())
    let ultimo = settings.modos.last!
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "raw words" },
        transformar: { texto, _, _ in
          llamadas.withLock { $0 += 1 }
          return .transformado(texto)
        }
      )
    )
    await prepare(controller, prewarmed: prewarmed)

    controller.toggleFromMenu()
    await waitUntil("La sesión nunca grabó") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.handle(.shapingCycleLeft)
    #expect(recorder.shapingChoiceLabels.last == "\(ultimo.nombre)")
    controller.handle(.shapingCycleRight)
    // Nil, no «Sin modo»: sin modo no hay nada que nombrar y el chip no se
    // dibuja. El texto de relleno decía en la muesca abierta que no está
    // pasando nada, ocupando la franja del nombre del modo.
    #expect(recorder.shapingChoiceLabels.last == .some(nil))
    controller.toggleFromMenu()
    await waitUntil("El final nunca entregó") { !recorder.insertedTexts.isEmpty }

    // De vuelta en "sin modo": nada transforma y el HUD se va de inmediato,
    // igual que un dictado normal.
    #expect(recorder.insertedTexts == ["raw words"])
    #expect(llamadas.withLock { $0 } == 0)
    #expect(recorder.count(of: "showShaping") == 0)
    controller.stop()
  }

  /// Mover las flechas es elegir: desde ahí, "Dilo decide" ya no opina.
  @Test func elegirConLasFlechasLeGanaADiloDecide() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let llamadas = OSAllocatedUnfairLock(initialState: 0)
    let settings = AppSettings(defaults: freshDefaults())
    settings.unAtajoDiloDecide = true
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        captureFocusedTarget: { Self.makeTarget(applicationName: "Ghostty") },
        finishRecognition: { "raw words" },
        transformar: { texto, _, _ in
          llamadas.withLock { $0 += 1 }
          return .transformado(texto)
        }
      )
    )
    await prepare(controller, prewarmed: prewarmed)

    controller.toggleFromMenu()
    await waitUntil("La sesión nunca grabó") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    // Una flecha a la derecha y otra a la izquierda: vuelve a "sin modo",
    // pero ya fue una elección, así que las reglas se callan.
    controller.handle(.shapingCycleRight)
    controller.handle(.shapingCycleLeft)
    controller.toggleFromMenu()
    await waitUntil("El final nunca entregó") { !recorder.insertedTexts.isEmpty }

    #expect(llamadas.withLock { $0 } == 0)
    #expect(recorder.insertedTexts == ["raw words"])
    controller.stop()
  }

  /// Las flechas peladas se tragan exactamente mientras una sesión que puede
  /// elegir modo está grabando: se arman al empezar y se sueltan tanto en el
  /// final como en Escape.
  @Test func arrowCaptureFollowsRecordingThroughEndAndCancel() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let controller = makeController(
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "raw words" }
      )
    )
    await prepare(controller, prewarmed: prewarmed)

    controller.toggleFromMenu()
    await waitUntil("Session never reached recording") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    #expect(recorder.cycleCaptureStates == [true])
    controller.toggleFromMenu()
    await waitUntil("Finish never delivered") { !recorder.insertedTexts.isEmpty }
    #expect(recorder.cycleCaptureStates == [true, false])

    controller.toggleFromMenu()
    await waitUntil("Second session never reached recording") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    #expect(recorder.cycleCaptureStates == [true, false, true])
    controller.handle(.cancelPressed)
    await waitUntil("Cancelled session never reset to idle") {
      controller.sessionStateForTesting == .idle
    }
    #expect(recorder.cycleCaptureStates == [true, false, true, false])
    controller.stop()
  }

  /// Sin modos no hay nada que recorrer, así que las flechas nunca se tragan
  /// y no se muestra ninguna elección.
  @Test func arrowCaptureNeverArmsWithAnEmptyLibrary() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let settings = AppSettings(defaults: freshDefaults())
    settings.modos = []
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(recorder: recorder, prewarmed: prewarmed)
    )
    await prepare(controller, prewarmed: prewarmed)

    controller.toggleFromMenu()
    await waitUntil("Session never reached recording") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.toggleFromMenu()
    await waitUntil("Finish never delivered") { !recorder.insertedTexts.isEmpty }

    #expect(recorder.cycleCaptureStates.isEmpty)
    #expect(recorder.shapingChoiceLabels == [nil])
    controller.stop()
  }

  /// La fase visible: una sesión que va a transformar dice con qué modo, y lo
  /// dice antes de la inserción, en vez de esconder el HUD en silencio.
  @Test func unaSesionConModoLoNombraAntesDeInsertar() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let controller = makeController(
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "raw words" },
        transformar: { texto, _, _ in .transformado("transformado \(texto)") }
      )
    )
    await prepare(controller, prewarmed: prewarmed)

    toque(controller, .modo("limpio"))
    await waitUntil("La sesión nunca se trabó") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.handle(.triggerPressed(.modo("limpio")))
    await waitUntil("El final nunca entregó") { !recorder.insertedTexts.isEmpty }

    #expect(recorder.shapingNames == ["Limpio"])
    let shapingIndex = recorder.events.firstIndex(of: "showShaping")
    let procesandoIndex = recorder.events.firstIndex(of: "showProcesando")
    let insertIndex = recorder.events.firstIndex(of: "insertText")
    #expect(shapingIndex != nil && procesandoIndex != nil && insertIndex != nil)
    if let shapingIndex, let procesandoIndex, let insertIndex {
      #expect(shapingIndex < procesandoIndex)
      #expect(procesandoIndex < insertIndex)
    }
    controller.stop()
  }

  /// Una flecha en cola que llega fuera de la grabación está muerta: el final
  /// transforma con el modo de la tecla que abrió la sesión.
  @Test func cyclingWhileNotRecordingChangesNothing() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let modosUsados = OSAllocatedUnfairLock<[String]>(initialState: [])
    let controller = makeController(
      dependencies: makeDependencies(
        recorder: recorder,
        prewarmed: prewarmed,
        finishRecognition: { "raw words" },
        transformar: { texto, modo, _ in
          modosUsados.withLock { $0.append(modo.id) }
          return .transformado(texto)
        }
      )
    )
    await prepare(controller, prewarmed: prewarmed)

    controller.handle(.shapingCycleRight)
    #expect(recorder.shapingChoiceLabels.isEmpty)

    toque(controller, .modo("limpio"))
    await waitUntil("La sesión nunca se trabó") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.handle(.triggerPressed(.modo("limpio")))
    await waitUntil("El final nunca entregó") { !recorder.insertedTexts.isEmpty }

    #expect(modosUsados.withLock { $0 } == ["limpio"])
    controller.stop()
  }

  /// El tap tiene que recibir la tecla de cada modo. Sin esto —que es como
  /// estaba— el gatillo se guardaba en Ajustes y nunca llegaba al teclado.
  @Test func lasTeclasDeLosModosLleganAlTap() {
    let settings = AppSettings(defaults: freshDefaults())
    let bindings = DirectDictationController.triggerBindings(
      settings: settings, sessionSlot: nil, sessionBinding: nil
    )
    // De fábrica sólo Limpio trae tecla.
    #expect(bindings.modos.map(\.id) == ["limpio"])
    #expect(bindings.modos.first?.binding == .controlCommandL)

    settings.modos[1].gatillo = KeyBinding.optionEscape.gatillo
    let conDos = DirectDictationController.triggerBindings(
      settings: settings, sessionSlot: nil, sessionBinding: nil
    )
    #expect(conDos.modos.map(\.id) == ["limpio", settings.modos[1].id])
  }

  // MARK: Nota rápida (2026-09-24)

  /// Una nota se abre con un clic, se cierra con otro, y termina en Apple
  /// Notas: no se pega donde está el cursor.
  @Test func laNotaTerminaEnNotasYNoSePega() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let notas = OSAllocatedUnfairLock<[String]>(initialState: [])
    let controller = makeController(
      dependencies: makeDependencies(
        recorder: recorder, prewarmed: prewarmed,
        finishRecognition: { "comprar pan" }, notas: notas
      )
    )
    await prepare(controller, prewarmed: prewarmed)
    controller.dictarNota()
    await waitUntil("La nota nunca empezó a grabar") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    #expect(controller.sesionEsNota)
    controller.dictarNota()
    await waitUntil("La nota nunca terminó") { recorder.recordedSessions.count == 1 }

    #expect(notas.withLock { $0 } == ["comprar pan"])
    #expect(recorder.insertedTexts.isEmpty, "una nota no se pega")
    // Localizado: el runner de CI corre en inglés.
    #expect(recorder.messages.contains(String(localized: "Nota guardada en Notas, carpeta Dilo.")))
    #expect(controller.sessionStateForTesting == .idle)
    controller.stop()
  }

  /// Sin permiso para usar Notas, la nota queda en el portapapeles y la
  /// muesca dice por qué.
  @Test func sinPermisoLaNotaQuedaEnElPortapapeles() async {
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let controller = makeController(
      dependencies: makeDependencies(
        recorder: recorder, prewarmed: prewarmed,
        finishRecognition: { "comprar pan" }, resultadoDeLaNota: .sinPermiso
      )
    )
    await prepare(controller, prewarmed: prewarmed)
    controller.dictarNota()
    await waitUntil("La nota nunca empezó a grabar") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.dictarNota()
    await waitUntil("Nunca se avisó") { !recorder.messages.isEmpty }
    #expect(recorder.insertedDestinations == [.clipboardOnly])
    #expect(recorder.insertedTexts == ["comprar pan"])
    #expect(
      recorder.messages.last
        == String(localized: "Dilo no tiene permiso para usar Notas. Te copié la nota: pégala con ⌘V.")
    )
    controller.stop()
  }

  /// El modo elegido en el panel lo usa el atajo general, pero una nota sale
  /// como se dijo.
  @Test func elModoDelAtajoGeneralNoTocaLasNotas() async {
    let settings = AppSettings(defaults: freshDefaults())
    let modo = try? #require(settings.modos.first)
    settings.hudModoDelAtajoGeneral = modo?.id
    let recorder = Recorder()
    let prewarmed = OSAllocatedUnfairLock(initialState: false)
    let notas = OSAllocatedUnfairLock<[String]>(initialState: [])
    let controller = makeController(
      settings: settings,
      dependencies: makeDependencies(
        recorder: recorder, prewarmed: prewarmed,
        finishRecognition: { "hola" },
        transformar: { texto, _, _ in .transformado("MODO: \(texto)") },
        notas: notas
      )
    )
    await prepare(controller, prewarmed: prewarmed)

    // El atajo de siempre, con el modo del panel.
    controller.toggleFromMenu()
    await waitUntil("La sesión nunca empezó") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.toggleFromMenu()
    await waitUntil("La sesión nunca terminó") { recorder.recordedSessions.count == 1 }
    #expect(recorder.insertedTexts == ["MODO: hola"])

    // La nota, sin él.
    controller.dictarNota()
    await waitUntil("La nota nunca empezó") {
      controller.sessionStateForTesting == .recording(.latched)
    }
    controller.dictarNota()
    await waitUntil("La nota nunca terminó") { recorder.recordedSessions.count == 2 }
    #expect(notas.withLock { $0 } == ["hola"])
    controller.stop()
  }
}
