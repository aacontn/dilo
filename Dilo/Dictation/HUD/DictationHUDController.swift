import AppKit

/// What the HUD says during a Direct Dictation session: listening, the live
/// draft, finalizing.
///
/// It owns none of the window. `HUDStage` decides where the shape is and who
/// holds it; this decides what dictation puts in it.
///
/// Los sonidos de empezar y terminar tampoco son suyos: son de la transición
/// del contrato y los toca el escenario (`HUDStage.sonarPor`). Acá sólo queda
/// el de pegar, que no es un estado de la forma sino lo que pasó con el texto
/// en el documento de otra app.
@MainActor
final class DictationHUDController {
  /// Levels stopping for this long while listening means the microphone is
  /// dead, which must look different from silence (CONTEXT.md).
  private static let deadMicrophoneAfter = Duration.milliseconds(600)
  /// How long a session waits for its first buffer before calling the
  /// microphone dead.
  ///
  /// Opening the input makes a Bluetooth headset switch to its hands-free
  /// profile, which stops the audio engine and costs about 1.4 seconds before
  /// the first buffer arrives. Judging that by the 600ms that catches a
  /// microphone which stopped mid-sentence reported every Bluetooth session
  /// as broken for the second before it started working.
  private static let firstAudioAfter = Duration.milliseconds(2_500)

  private let stage: HUDStage
  private var sessionSettings: DictationSessionSettings
  /// Remembered so a download line can restore the right session text.
  private var sessionIsLatched = false
  /// True from the moment speech ends until the next session opens. The
  /// placeholder is a listening affordance, so nothing may write one after
  /// this — a finished model download restoring "Listening (latched)" under
  /// the shaping caption is the case that found it.
  private var hasStoppedListening = false
  private var lastLevelAt = ContinuousClock.now
  /// Whether this session has had a single buffer yet. Until it has, the
  /// input may simply still be opening rather than broken.
  private var hasHeardAudio = false
  private var micWatchdogTask: Task<Void, Never>?

  private var content: DictationHUDContent { stage.dictationContent }
  private var isListening: Bool { stage.occupant == .dictation }

  init(stage: HUDStage, settings: AppSettings) {
    self.stage = stage
    sessionSettings = settings.sessionSettings
  }

  /// Live microphone level, 0–1, ~46 Hz while listening. Smoothed with a
  /// fast attack and slow release, appended raw to the waveform history,
  /// and marks the microphone alive for the dead-mic watchdog.
  func showAudioLevel(_ level: Float) {
    guard content.showsVoiceVisual else { return }
    hasHeardAudio = true
    content.audioLevel = max(Double(level), content.audioLevel * 0.88)
    content.levelHistory.removeFirst()
    // Light EMA against the previous bar calms per-tick jitter without
    // dulling the speech rhythm.
    let lastBar = content.levelHistory.last ?? 0
    content.levelHistory.append(0.6 * level + 0.4 * lastBar)
    lastLevelAt = ContinuousClock.now
    content.isAudioAlive = true
  }

  /// Played when finalized text lands in the target, after a finished
  /// session's insertion.
  func playPasteSound() {
    stage.sounds.playPaste(using: sessionSettings.sounds)
  }

  func showMessage(_ text: String, on displayID: CGDirectDisplayID? = nil) {
    stopVoiceVisual()
    stage.showMessage(text, on: displayID)
  }

  /// La sesión está esperando algo antes de poder escuchar: el modelo, un
  /// permiso. Dice qué falta, sin onda ficticia (contrato del notch).
  func showPreparando(_ falta: FaltaDelNotch, on displayID: CGDirectDisplayID? = nil) {
    guard let screen = stage.screen(preferring: displayID) else { return }
    stage.claim(.dictation, on: screen, rendering: sessionSettings)
    stage.recibir(.preparar(falta))
    setDraft(falta.texto)
    stage.revealDictation()
  }

  /// Terminó el reconocimiento y lo grabado se está entregando o
  /// transformando. La forma **no se va**: irse acá es lo que hacía que el
  /// notch pareciera un aviso que pasó en vez del lugar donde el trabajo
  /// ocurre.
  func showProcesando() {
    guard isListening else { return }
    hasStoppedListening = true
    stopVoiceVisual()
    stage.recibir(.procesar)
    // Las palabras dichas se quedan mientras se entregan: son lo que la
    // persona está esperando ver. Si no se alcanzó a decir nada, la línea la
    // pone el estado.
    if content.text.isEmpty {
      setDraft(EstadoDelNotch.procesando.texto ?? "")
    }
  }

  /// Cómo terminó la sesión.
  ///
  /// El camino feliz no escribe nada: la muesca acusa con un check donde
  /// estaba la onda y se va (`ResultadoDelNotch.esAcuse`). Sólo el camino del
  /// error tiene una línea que poner.
  func showResultado(_ resultado: ResultadoDelNotch) {
    guard isListening else { return }
    stopVoiceVisual()
    content.shapingName = nil
    stage.recibir(.entregar(resultado))
    guard !resultado.esAcuse else { return }
    setDraft(resultado.texto)
  }

  func showListening(
    on displayID: CGDirectDisplayID?,
    isLatched: Bool,
    settings: DictationSessionSettings,
    languageTag: String? = nil
  ) {
    guard let screen = stage.screen(preferring: displayID) else { return }
    sessionSettings = settings
    hasStoppedListening = false
    content.languageTag = languageTag
    content.shapingName = nil
    content.shapingChoiceLabel = nil
    sessionIsLatched = isLatched
    // Dictation outranks a file job for the shape: the user is speaking now,
    // and the transcription keeps running with the status item carrying it.
    stage.claim(.dictation, on: screen, rendering: settings)
    stage.recibir(.escuchar)
    startVoiceVisual()
    setDraft(placeholder)
    stage.revealDictation()
  }

  func showLatched() {
    guard isListening else { return }
    sessionIsLatched = true
    setDraft(placeholder)
  }

  /// Exposed so the placeholder rules can be asserted without a window.
  var textForTesting: String { content.text + content.volatileText }

  /// Lo que la forma dice mientras escucha y todavía nadie habló: **nada**.
  ///
  /// Era «Te escucho…», y «Te escucho (trabado)» con el gatillo trabado.
  /// Veredicto del 2026-09-22: «encuentro que es una tontera, sácaselo, y así
  /// podemos achicar un poco el tamaño del notch cuando está activado». Tenía
  /// razón por los dos lados: la onda ya dice que el micrófono está abierto
  /// —esa es toda su función— y una frase de estado obliga a la muesca a
  /// medir lo que mida esa frase en el idioma más largo. Que el gatillo esté
  /// trabado lo dice la misma onda, que sigue viva sin que nadie sostenga
  /// nada.
  ///
  /// Queda como propiedad y no se borra la idea entera porque hay cuatro
  /// caminos que escriben el borrador y todos preguntan acá: es el único
  /// lugar donde este «nada» no se puede volver a llenar por descuido.
  private var placeholder: String { "" }

  /// A session waiting on its language model. The band says what it is waiting
  /// for instead of sitting on "Listening…" while nothing arrives; passing nil
  /// restores whatever the session was saying before.
  func showModelDownload(_ text: String?) {
    guard isListening else { return }
    // Esperar un modelo es «preparando», no «dictando»: el contrato pide que
    // el HUD diga qué falta y que no dibuje una onda que no viene de nadie.
    if let text {
      stage.recibir(.preparar(.aviso(text)))
    } else if case .preparando = stage.estado {
      stage.recibir(.escuchar)
    }
    setDraft(text ?? placeholder)
  }

  func showLiveText(_ committed: String, volatile: String = "") {
    guard isListening, !(committed + volatile).isEmpty else { return }
    setDraft(committed, volatile: volatile)
  }

  /// Speech has stopped but the recognized text has not arrived yet.
  ///
  /// Nothing is written and nothing resizes. The watchdog stops, because the
  /// silence that follows the last word is not a dead microphone, and the level
  /// settles to zero so the visual comes to rest instead of freezing mid-wobble.
  func showFinalizing() {
    guard isListening else { return }
    hasStoppedListening = true
    stopWatchdog()
    content.isAudioAlive = true
    content.audioLevel = 0
  }

  /// The shaping phase: recognition is finished and the chosen prompt is
  /// rewriting the words, so the shape stays up saying so instead of
  /// dismissing into silence. Speech has ended, so End plays here; the
  /// hide() that follows the rewrite must not replay it.
  func showShaping(with promptName: String) {
    guard isListening else { return }
    hasStoppedListening = true
    stopVoiceVisual()
    stage.recibir(.procesar)
    // The arrows are dead once the session finishes, so the pick leaves with
    // them and the caption names the prompt instead.
    content.shapingChoiceLabel = nil
    content.shapingName = promptName
  }

  private func setDraft(_ committed: String, volatile: String = "") {
    content.text = committed
    content.volatileText = volatile
  }

  /// The session's shaping pick by name; nil clears its tag. Cycling arrives
  /// mid-session, so this only speaks while the dictation session holds the
  /// shape.
  func showShapingChoice(_ label: String?) {
    // El modo activo sobrevive a la sesión: es lo que la muesca en reposo
    // puede decir si la persona lo pidió, y es el modo con el que el próximo
    // dictado arrancaría. Se escribe también cuando llega nil, porque recorrer
    // las flechas hasta «ningún modo» es una elección: guardando sólo los
    // nombres, la muesca seguía anunciando el modo que la persona acababa de
    // soltar.
    content.modoActivo = label.flatMap { $0.isEmpty ? nil : $0 }
    guard isListening else { return }
    content.shapingChoiceLabel = label
  }

  /// Si la sesión en curso es una nota rápida: la línea lo dice con un ícono.
  func mostrarQueEsNota(_ esNota: Bool) {
    content.esNota = esNota
  }

  func hide() {
    // The shape retracts exactly as it stands. The visual stops reacting so a
    // glow can play its drain, but the bands are pinned and the text is left
    // alone: resizing or relabelling a shape that is already sliding away is
    // the jolt this avoids.
    stopWatchdog()
    content.isDismissing = true
    content.showsVoiceVisual = false
    stage.retract()
  }

  /// Resets the visual to a live-and-silent baseline and arms the dead-mic
  /// watchdog.
  private func startVoiceVisual() {
    content.isDismissing = false
    content.sessionEpoch += 1
    content.showsVoiceVisual = true
    content.audioLevel = 0
    content.levelHistory = [Float](repeating: 0, count: HUDWaveformView.barCount)
    content.isAudioAlive = true
    lastLevelAt = ContinuousClock.now
    hasHeardAudio = false

    micWatchdogTask?.cancel()
    micWatchdogTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(300))
        guard let self, !Task.isCancelled else { return }
        if lastLevelAt.duration(to: .now) > Self.silenceBudget(hasHeardAudio: hasHeardAudio) {
          content.isAudioAlive = false
        }
      }
    }
  }

  /// How long the visual waits before calling the microphone dead: the short
  /// budget once audio has been heard, the long one while the input is still
  /// opening.
  static func silenceBudget(hasHeardAudio: Bool) -> Duration {
    hasHeardAudio ? deadMicrophoneAfter : firstAudioAfter
  }

  private func stopVoiceVisual() {
    stopWatchdog()
    content.showsVoiceVisual = false
  }

  private func stopWatchdog() {
    micWatchdogTask?.cancel()
    micWatchdogTask = nil
  }
}
