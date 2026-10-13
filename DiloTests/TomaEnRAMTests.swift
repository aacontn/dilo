import DiloCapabilities
import DiloEngines
import DiloModes
import Foundation
import Testing
import os

@testable import Dilo

/// El tope de cinco minutos y el reintento de una toma guardada, en la
/// máquina pura.
struct TopeYReintentoEnLaMaquinaTests {
  private let t0 = ContinuousClock.now

  private func grabando() -> DictationSessionMachine {
    var maquina = DictationSessionMachine()
    _ = maquina.reduce(.menuToggled(now: t0))
    _ = maquina.reduce(.beginApproved)
    _ = maquina.reduce(.recognitionStarted(now: t0))
    return maquina
  }

  @Test func elTopeTerminaComoSoltar() {
    var maquina = grabando()
    let efectos = maquina.reduce(.limiteAlcanzado(now: t0.advanced(by: .seconds(300))))
    #expect(maquina.state == .finishing)
    #expect(efectos.contains(.finishRecognition(speakingDuration: 300)))
  }

  /// Un tope que llega tarde —el dictado ya se soltó— no hace nada.
  @Test func elTopeDespuesDeSoltarNoHaceNada() {
    var maquina = grabando()
    _ = maquina.reduce(.menuToggled(now: t0.advanced(by: .seconds(10))))
    #expect(maquina.reduce(.limiteAlcanzado(now: t0.advanced(by: .seconds(300)))).isEmpty)
  }

  @Test func elReintentoSoloArrancaEnReposo() {
    var maquina = DictationSessionMachine()
    #expect(maquina.reduce(.reintentoPedido) == [.reintentarTomaFallida])
    #expect(maquina.state == .finishing)
    // Mientras corre, ni otro reintento ni un gatillo arrancan nada.
    #expect(maquina.reduce(.reintentoPedido).isEmpty)
    #expect(maquina.reduce(.triggerPressed(now: t0)).isEmpty)
    _ = maquina.reduce(.sessionEnded)
    #expect(maquina.state == .idle)
  }

  @Test func unReintentoNoInterrumpeUnDictado() {
    var maquina = grabando()
    #expect(maquina.reduce(.reintentoPedido).isEmpty)
    #expect(maquina.state == .recording(.latched))
  }
}

/// Lo mismo, del lado del controlador: a dónde va el texto de un reintento,
/// qué se dice cuando no sale, y la cuenta regresiva del tope.
@MainActor
struct TomaEnRAMEnElControladorTests {
  @MainActor
  private final class Registro {
    var mensajes: [String] = []
    var pegados: [(texto: String, destino: InsertionDestination)] = []
    var enVivo: [String] = []
    var anuncios: [String] = []
    var finales = 0
  }

  private func dependencias(
    _ registro: Registro,
    preparado: OSAllocatedUnfairLock<Bool>,
    finales: OSAllocatedUnfairLock<Int> = .init(initialState: 0),
    reintentar: @escaping @Sendable () async throws -> String = { "" },
    observar: @escaping @Sendable (@escaping @Sendable (TimeInterval?) -> Void) async -> Void = { _ in },
    reloj: DeadlineClock = .continuous
  ) -> DirectDictationController.Dependencies {
    var dependencias = DirectDictationController.Dependencies(
      setDownloadHandler: { _ in },
      resolveLocale: { _ in Locale(identifier: "es_CL") },
      supportedLocale: { _ in nil },
      retainOnly: { _ in },
      prewarm: { _ in preparado.withLock { $0 = true } },
      startRecognition: { _, _, _, _, _ in },
      finishRecognition: {
        finales.withLock { $0 += 1 }
        return ""
      },
      cancelRecognition: {},
      shutDownRecognition: {},
      translation: TranslationCoordinator(
        service: TranslationService(
          client: TranslationService.Client(
            availability: { _ in .installed },
            prepare: { _ in },
            translate: { _, texto in texto },
            candidateTargets: { [] },
            retain: { _ in },
            shutDown: {}
          )
        )
      ),
      captureFocusedTarget: {
        TextInsertionService.Target(
          element: nil, processIdentifier: 1, isSecure: false, displayID: nil, applicationName: nil)
      },
      insertText: { texto, _, destino in
        registro.pegados.append((texto, destino))
        return .copiado
      },
      requestMicrophoneAccess: { true },
      requestSpeechAccess: { true },
      requestAccessibilityAccess: {},
      hasAccessibilityAccess: { true },
      isPermissionAlertPresenting: { false },
      showAccessibilitySetupAlert: {},
      showRelaunchAlert: {},
      showListening: { _, _, _, _ in },
      showLatched: {},
      showLiveText: { firme, volatil in registro.enVivo.append(firme + volatil) },
      showFinalizing: {},
      showShaping: { _ in },
      showShapingChoice: { _ in },
      showProcesando: {},
      showResultado: { _ in },
      showMessage: { mensaje, _ in registro.mensajes.append(mensaje) },
      showModelDownload: { _ in },
      showAudioLevel: { _ in },
      hideHUD: {},
      playPasteSound: {},
      setShapingCycleCaptureEnabled: { _ in },
      recordSession: { _, _ in },
      recordHistory: { _, _, _, _, _, _ in },
      transformar: { texto, _, _ in .transformado(texto) }
    )
    dependencias.reintentarToma = reintentar
    dependencias.observarTomaFallida = observar
    dependencias.anunciar = { registro.anuncios.append($0) }
    dependencias.relojDelTope = reloj
    return dependencias
  }

  private func controlador(_ dependencias: DirectDictationController.Dependencies) -> DirectDictationController {
    let nombre = "TomaEnRAMTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: nombre)!
    defaults.removePersistentDomain(forName: nombre)
    return DirectDictationController(settings: AppSettings(defaults: defaults), dependencies: dependencias)
  }

  /// Espera el estado y no una duración (la razón está en
  /// `DirectDictationControllerTests.waitUntil`).
  private func hasta(_ comentario: Comment, _ condicion: @MainActor () -> Bool) async {
    let limite = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < limite {
      if condicion() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
    if condicion() { return }
    Issue.record(comentario)
  }

  @Test func unReintentoQueSaleVaAlPortapapelesYLoDice() async {
    let registro = Registro()
    let control = controlador(
      dependencias(registro, preparado: .init(initialState: false), reintentar: { "hola mundo" }))

    control.reintentarTomaFallida()
    await hasta("el reintento no terminó") { control.sessionStateForTesting == .idle && !registro.mensajes.isEmpty }

    #expect(registro.pegados.map(\.texto) == ["hola mundo"])
    #expect(registro.pegados.map(\.destino) == [.clipboardOnly])
    #expect(registro.mensajes == [String(localized: "Listo: te lo copié. Pégalo con ⌘V.")])
    #expect(control.ultimoDictado?.original == "hola mundo")
  }

  @Test func unReintentoQueNoSaleDiceQuePaso() async {
    let registro = Registro()
    let control = controlador(
      dependencias(registro, preparado: .init(initialState: false), reintentar: { throw TomaSinTexto.tampocoSalio }))

    control.reintentarTomaFallida()
    await hasta("el reintento no terminó") { !registro.mensajes.isEmpty }

    #expect(registro.pegados.isEmpty)
    #expect(registro.mensajes == [TomaSinTexto.tampocoSalio.localizedDescription])
    #expect(control.sessionStateForTesting == .idle)
  }

  @Test func elMenuSeEnteraDeLaTomaGuardada() async {
    let registro = Registro()
    let avisos = OSAllocatedUnfairLock<(@Sendable (TimeInterval?) -> Void)?>(initialState: nil)
    let control = controlador(
      dependencias(registro, preparado: .init(initialState: false), observar: { handler in
        avisos.withLock { $0 = handler }
      }))
    var vistos: [TimeInterval?] = []
    control.onTomaFallidaChange = { vistos.append($0) }
    control.observarTomasFallidas()
    await hasta("nadie se suscribió") { avisos.withLock { $0 } != nil }

    avisos.withLock { $0 }?(42)
    await hasta("el menú no se enteró") { vistos == [42] }
    #expect(control.duracionDeLaTomaFallida == 42)
  }

  /// Cinco minutos de dictado trabado: a los 4:45 la muesca cuenta hacia
  /// atrás y VoiceOver lo anuncia una vez; a los 5:00 termina sola, como si
  /// la persona hubiera soltado.
  @Test func elTopeCuentaHaciaAtrasYTerminaSolo() async {
    let registro = Registro()
    let preparado = OSAllocatedUnfairLock(initialState: false)
    let finales = OSAllocatedUnfairLock(initialState: 0)
    let reloj = DrivenClock()
    let control = controlador(
      dependencias(registro, preparado: preparado, finales: finales, reloj: reloj.deadlineClock))
    control.applyLanguages()
    await hasta("no se preparó") { control.isPreparedForTesting }

    control.toggleFromMenu()
    await hasta("no empezó a grabar") {
      if case .recording = control.sessionStateForTesting { return true }
      return false
    }
    await reloj.waitForSleeper()
    reloj.advance(by: .seconds(285))
    await hasta("no avisó") { !registro.anuncios.isEmpty }
    #expect(registro.anuncios.count == 1)
    #expect(registro.enVivo.last?.contains("15") == true)

    await reloj.waitForSleeper()
    reloj.advance(by: .seconds(1))
    await hasta("no siguió contando") { registro.enVivo.last?.contains("14") == true }
    #expect(registro.anuncios.count == 1)

    for _ in 0..<14 {
      await reloj.waitForSleeper()
      reloj.advance(by: .seconds(1))
    }
    await hasta("el tope no terminó el dictado") { finales.withLock { $0 } == 1 }
  }

  /// Soltar antes del tope apaga el reloj: no queda nada corriendo que
  /// termine el dictado siguiente.
  @Test func soltarAntesDelTopeApagaElReloj() async {
    let registro = Registro()
    let preparado = OSAllocatedUnfairLock(initialState: false)
    let finales = OSAllocatedUnfairLock(initialState: 0)
    let reloj = DrivenClock()
    let control = controlador(
      dependencias(registro, preparado: preparado, finales: finales, reloj: reloj.deadlineClock))
    control.applyLanguages()
    await hasta("no se preparó") { control.isPreparedForTesting }

    control.toggleFromMenu()
    await reloj.waitForSleeper()
    control.toggleFromMenu()
    await hasta("no terminó") { control.sessionStateForTesting == .idle }
    await hasta("el reloj del tope sigue armado") { !reloj.hasSleeper }
  }
}
