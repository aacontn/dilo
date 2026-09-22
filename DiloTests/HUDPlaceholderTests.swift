import CoreGraphics
import Testing

@testable import Dilo

/// La muesca no escribe palabras que nadie dijo.
///
/// Era «Te escucho…», y «Te escucho (trabado)» con el gatillo trabado.
/// Veredicto del 2026-09-22: «encuentro que es una tontera, sácaselo, y así
/// podemos achicar un poco el tamaño del notch cuando está activado». La onda
/// ya dice que el micrófono está abierto, y una frase de estado obliga a la
/// muesca a medir lo que mida esa frase en el idioma más largo.
///
/// Esta suite existía para perseguir esa frase por los cuatro caminos que
/// escriben el borrador —abrir, trabar, volver de una descarga de modelo y la
/// fase de transformación—, porque arreglar uno solo dejaba los otros tres
/// escribiéndola. Ahora lo que se afirma es que ninguno de los cuatro escribe
/// nada.
@MainActor
@Suite("El borrador de la muesca")
struct HUDPlaceholderTests {
  private func controller(_ visual: HUDVoiceVisualStyle) -> DictationHUDController {
    let store = AppSettings.previewStore()
    store.voiceVisual = visual
    return DictationHUDController(stage: HUDStage(settings: store), settings: store)
  }

  private func session(_ store: AppSettings) -> DictationSessionSettings {
    store.sessionSettings
  }

  private func recentDraft(_ stage: HUDStage, visual: HUDVoiceVisualStyle) -> Bool {
    DictationHUDShellView.showsRecentDraft(
      visual: visual,
      listening: stage.dictationContent.showsVoiceVisual,
      dismissing: stage.dictationContent.isDismissing,
      shaping: stage.dictationContent.shapingName != nil,
      reduceMotion: false
    )
  }

  /// Los cuatro caminos, con los cuatro visuales, y ninguno escribe nada.
  @Test(arguments: [
    HUDVoiceVisualStyle.compact, .glowDraft, .waveform, .glow,
  ])
  func ningunCaminoEscribeLoQueNadieDijo(visual: HUDVoiceVisualStyle) {
    let store = AppSettings.previewStore()
    store.voiceVisual = visual
    let hud = DictationHUDController(stage: HUDStage(settings: store), settings: store)

    hud.showListening(on: CGDirectDisplayID?.none, isLatched: false, settings: session(store))
    #expect(hud.textForTesting.isEmpty, "abrir")

    hud.showLatched()
    #expect(hud.textForTesting.isEmpty, "trabar")

    hud.showModelDownload(nil)
    #expect(hud.textForTesting.isEmpty, "volver de una descarga")

    hud.showShaping(with: "Tighten grammar")
    #expect(hud.textForTesting.isEmpty, "transformar")
  }

  /// Trabado tampoco se dice con palabras: lo dice la onda, que sigue viva sin
  /// que nadie sostenga nada.
  @Test(arguments: [HUDVoiceVisualStyle.waveform, .glow])
  func trabarNoEscribeNada(visual: HUDVoiceVisualStyle) {
    let store = AppSettings.previewStore()
    store.voiceVisual = visual
    let hud = DictationHUDController(stage: HUDStage(settings: store), settings: store)

    hud.showListening(on: CGDirectDisplayID?.none, isLatched: true, settings: session(store))
    #expect(hud.textForTesting.isEmpty)
    hud.showLatched()
    #expect(hud.textForTesting.isEmpty)
  }

  /// Lo que sí se dice sigue diciéndose: esperar un modelo no es escuchar, y
  /// la línea nombra lo que falta.
  @Test func esperarUnModeloSiSeDice() {
    let store = AppSettings.previewStore()
    store.voiceVisual = .waveform
    let hud = DictationHUDController(stage: HUDStage(settings: store), settings: store)

    hud.showListening(on: CGDirectDisplayID?.none, isLatched: false, settings: session(store))
    hud.showModelDownload("Cargando el modelo…")
    #expect(hud.textForTesting == "Cargando el modelo…")

    hud.showModelDownload(nil)
    #expect(hud.textForTesting.isEmpty)
  }

  /// Y las palabras dichas de verdad se quedan mientras se entregan.
  @Test func loDichoSeQuedaMientrasSeEntrega() {
    let store = AppSettings.previewStore()
    store.voiceVisual = .waveform
    let hud = DictationHUDController(stage: HUDStage(settings: store), settings: store)

    hud.showListening(on: CGDirectDisplayID?.none, isLatched: false, settings: session(store))
    hud.showLiveText("quedamos el martes")
    #expect(hud.textForTesting == "quedamos el martes")
    hud.showShaping(with: "Correo")
    #expect(hud.textForTesting == "quedamos el martes")
  }

  /// A Bluetooth headset costs about 1.4 seconds before its first buffer,
  /// because opening the input switches its profile and restarts the engine.
  /// The budget that catches a microphone dying mid-sentence is 600ms, and
  /// judging the opening by it called every Bluetooth session broken.
  @Test func theMicrophoneIsNotCalledDeadWhileTheInputIsStillOpening() {
    #expect(
      DictationHUDController.silenceBudget(hasHeardAudio: false) > .milliseconds(1_400),
      "a cold Bluetooth session would be reported as a dead microphone"
    )
    #expect(
      DictationHUDController.silenceBudget(hasHeardAudio: true) == .milliseconds(600),
      "a microphone that stops mid-sentence still has to show up quickly"
    )
    #expect(
      DictationHUDController.silenceBudget(hasHeardAudio: true)
        < DictationHUDController.silenceBudget(hasHeardAudio: false)
    )
  }

  /// The shaping caption decides whether the HUD mounts a label that
  /// animates every frame, so state left behind after the shape retracts
  /// costs about 20% of a CPU for as long as the app stays open.
  @Test func retractingClearsTheShapingCaption() async throws {
    let store = AppSettings.previewStore()
    store.voiceVisual = .waveform
    let stage = HUDStage(settings: store)
    let hud = DictationHUDController(stage: stage, settings: store)

    hud.showListening(on: CGDirectDisplayID?.none, isLatched: false, settings: session(store))
    hud.showLiveText("some words")
    hud.showShaping(with: "Tighten grammar")
    #expect(stage.dictationContent.shapingName != nil)

    hud.hide()
    // An event wait, not a time bound. Sleeping for the retract plus a margin
    // passed alone and failed under a parallel run, which is the flake #82 and
    // #116 were about; this budget only spends itself on a broken run.
    for _ in 0..<400 where stage.dictationContent.shapingName != nil {
      try await Task.sleep(for: .milliseconds(5))
    }

    #expect(stage.dictationContent.shapingName == nil, "the caption outlived the shape")
    #expect(stage.dictationContent.shapingChoiceLabel == nil)
  }

  /// The words being rewritten are not a placeholder, so the shaping phase
  /// leaves them where they are.
  @Test func theShapingPhaseKeepsARealDraft() {
    let store = AppSettings.previewStore()
    store.voiceVisual = .waveform
    let hud = DictationHUDController(stage: HUDStage(settings: store), settings: store)

    hud.showListening(on: CGDirectDisplayID?.none, isLatched: false, settings: session(store))
    hud.showLiveText("the words it is rewriting")
    hud.showShaping(with: "Tighten grammar")
    #expect(hud.textForTesting == "the words it is rewriting")
  }

  /// A real draft always shows, whichever visual is selected.
  @Test func aLiveDraftIsNeverSuppressed() {
    let store = AppSettings.previewStore()
    store.voiceVisual = .compact
    let hud = DictationHUDController(stage: HUDStage(settings: store), settings: store)

    hud.showListening(on: CGDirectDisplayID?.none, isLatched: false, settings: session(store))
    hud.showLiveText("hello there")
    #expect(hud.textForTesting == "hello there")
  }

  @Test func aVolatileGuessShowsBeforeItCommits() {
    let store = AppSettings.previewStore()
    store.voiceVisual = .glowDraft
    let hud = DictationHUDController(stage: HUDStage(settings: store), settings: store)

    hud.showListening(on: CGDirectDisplayID?.none, isLatched: false, settings: session(store))
    hud.showLiveText("hello ", volatile: "ther")
    #expect(hud.textForTesting == "hello ther")
  }

  @Test func aStatusMessageDoesNotKeepThePreviousGuess() {
    let store = AppSettings.previewStore()
    store.voiceVisual = .glowDraft
    let hud = DictationHUDController(stage: HUDStage(settings: store), settings: store)

    hud.showListening(on: CGDirectDisplayID?.none, isLatched: false, settings: session(store))
    hud.showLiveText("hello ", volatile: "ther")
    hud.showMessage("Couldn't insert text")
    #expect(hud.textForTesting == "Couldn't insert text")
  }

  /// hide() pins the layout for the retract, then an insert failure claims
  /// the shape for a message. That message is a new occupant: the recent
  /// draft stays through shaping and the retract, and leaves with the
  /// status line.
  @Test func aStatusMessageDoesNotKeepTheRecentDraft() {
    let store = AppSettings.previewStore()
    store.voiceVisual = .glowDraft
    let stage = HUDStage(settings: store)
    let hud = DictationHUDController(stage: stage, settings: store)

    hud.showListening(on: CGDirectDisplayID?.none, isLatched: false, settings: session(store))
    hud.showLiveText("the words it is rewriting")
    hud.showShaping(with: "Tighten grammar")
    #expect(recentDraft(stage, visual: .glowDraft))

    hud.hide()
    #expect(stage.dictationContent.isDismissing)
    #expect(recentDraft(stage, visual: .glowDraft))

    hud.showMessage("Couldn't insert text")
    #expect(!stage.dictationContent.isDismissing)
    #expect(stage.dictationContent.shapingName == nil)
    #expect(!recentDraft(stage, visual: .glowDraft))
    #expect(hud.textForTesting == "Couldn't insert text")
  }
}
