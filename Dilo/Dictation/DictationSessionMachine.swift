import Foundation

/// The Direct Dictation session's state machine as a pure reducer: actions
/// in, state transition inside, effects out. No clocks (instants ride in on
/// actions), no services, no tasks — which is what makes the gesture and
/// race rules (quick-tap latching, finish-queued-while-starting,
/// cancel-while-starting, the no-speech policy) unit-testable
/// (DictationSessionMachineTests).
///
/// DirectDictationController owns the impure half: it translates monitor
/// events into actions, runs the begin guards, and executes the returned
/// effects against the speech service, HUD, and insertion. Async completions
/// come back as new actions. (ADR-0006: MV + local reducers.)
struct DictationSessionMachine {
  enum Gesture: Equatable {
    case held(startedAt: ContinuousClock.Instant)
    case latched

    var isLatched: Bool {
      if case .latched = self { return true }
      return false
    }
  }

  enum State: Equatable {
    case idle
    case starting(Gesture)
    case recording(Gesture)
    case finishing
    case cancelling
  }

  enum Action: Equatable {
    case triggerPressed(now: ContinuousClock.Instant)
    case triggerReleased(now: ContinuousClock.Instant)
    case menuToggled(now: ContinuousClock.Instant)
    case escapePressed
    case readAloudPressed
    /// The controller's begin guards (prepared, permissions, secure
    /// field) passed and the target is captured.
    case beginApproved
    case beginRejected
    case recognitionStarted(now: ContinuousClock.Instant)
    /// Recognition failed while starting, finishing, or mid-session.
    /// `wasCancelled` covers the torn-down start task.
    case recognitionFailed(wasCancelled: Bool)
    case updateReceived(hasVisibleText: Bool)
    case noSpeechTimedOut
    /// La toma llegó al tope de `PoliticaDeGrabacion` (cinco minutos): se
    /// termina como si la persona hubiera soltado, y lo dicho se pega.
    case limiteAlcanzado(now: ContinuousClock.Instant)
    /// «Reintentar» en el menú, con una toma guardada en RAM.
    case reintentoPedido
    /// The terminal reset after a finish inserted, a cancel completed,
    /// or a failure was shown.
    case sessionEnded
    /// La persona tocó «Deshacer» en la muesca dentro de la ventana
    /// (`GestoDelGatillo.ventanaParaDeshacer`).
    case deshacerCancelacion
    /// Venció la ventana, o lo retenido salió vacío: se suelta de la RAM.
    case retencionVencida
  }

  enum Effect: Equatable {
    /// Run the begin guards; feed back `beginApproved` or `beginRejected`.
    case checkAndBegin
    case beginRecognition
    case finishRecognition(speakingDuration: TimeInterval)
    case cancelRecognition
    case cancelStartTask
    case setEscapeCapture(Bool)
    case startNoSpeechTimer
    case stopNoSpeechTimer
    case showListening(latched: Bool)
    case showLatched
    case showLiveText
    case showFinalizing
    case hideHUD
    case notifyRecording(Bool)
    case triggerReadAloud
    /// Pasa la toma guardada por los motores otra vez; el final vuelve como
    /// `sessionEnded`, igual que el de un dictado.
    case reintentarTomaFallida
    /// En vez de tirar la sesión: terminar el reconocimiento en silencio y
    /// guardar el texto crudo en RAM, sin pegar ni ir al historial. El final
    /// vuelve como `sessionEnded`, con `retencionVencida` antes si no quedó
    /// nada que retener.
    case retenerParaDeshacer
    /// Correr la entrega de siempre con lo retenido.
    case entregarLoRetenido
    case descartarLoRetenido
  }

  /// Releasing the trigger before this counts as a quick tap and latches
  /// the session (CONTEXT.md). Es el de fábrica: el de cada sesión lo fija
  /// `fijarGesto` desde Ajustes.
  static let tapThreshold = Duration.milliseconds(GestoDelGatillo.umbralDeFabricaMs)

  private(set) var state = State.idle
  /// El umbral del toque corto y si un Esc se puede deshacer, de la sesión
  /// en curso. Se fijan en reposo y se quedan así hasta que termina: cambiar
  /// Ajustes a media sesión aplica a la siguiente (ADR-0004).
  private(set) var umbralDeToque = Self.tapThreshold
  private(set) var conDeshacer = false
  /// Hay un dictado cancelado esperando un «Deshacer». Sobrevive al reset de
  /// la sesión cancelada, que llega justo después de retener.
  private(set) var hayRetenido = false
  /// Pidieron deshacer mientras lo retenido todavía se estaba terminando de
  /// reconocer: se entrega en cuanto llegue.
  private var deshacerAlTerminar = false

  private var pendingGesture: Gesture?
  private var hasSpeech = false
  private var finishWhenStarted = false
  private var cancelWhenStarted = false
  private var recordingStartedAt: ContinuousClock.Instant?

  var isSessionActive: Bool {
    state != .idle
  }

  /// Fija el gesto de la sesión que viene. Sólo en reposo: con una sesión en
  /// curso no cambia nada.
  mutating func fijarGesto(umbral: Duration, conDeshacer: Bool) {
    guard state == .idle else { return }
    umbralDeToque = umbral
    self.conDeshacer = conDeshacer
  }

  mutating func reduce(_ action: Action) -> [Effect] {
    switch action {
    case let .triggerPressed(now):
      return triggerPressed(now: now)
    case let .triggerReleased(now):
      return triggerReleased(now: now)
    case let .menuToggled(now):
      return menuToggled(now: now)
    case .escapePressed:
      return cancel()
    case .readAloudPressed:
      return state == .idle ? [.triggerReadAloud] : []
    case .beginApproved:
      return beginApproved()
    case .beginRejected:
      pendingGesture = nil
      return []
    case let .recognitionStarted(now):
      return recognitionStarted(now: now)
    case let .recognitionFailed(wasCancelled):
      return recognitionFailed(wasCancelled: wasCancelled)
    case let .updateReceived(hasVisibleText):
      return updateReceived(hasVisibleText: hasVisibleText)
    case .noSpeechTimedOut:
      return hasSpeech ? [] : cancel()
    case let .limiteAlcanzado(now):
      return finish(now: now)
    case .reintentoPedido:
      // Sólo en reposo: un reintento nunca pisa un dictado en curso, y un
      // dictado nuevo nunca espera a que alguien decida qué hacer con la
      // toma —ése es el error de imnot que no se copia—. Mientras corre, la
      // sesión está en `finishing` y el gatillo no arranca otra.
      guard state == .idle else { return [] }
      state = .finishing
      return [.reintentarTomaFallida]
    case .sessionEnded:
      var efectos = reset()
      if deshacerAlTerminar, hayRetenido {
        efectos += deshacer()
      }
      return efectos
    case .deshacerCancelacion:
      guard hayRetenido else { return [] }
      // Todavía reconociendo lo retenido: se entrega al terminar.
      if state == .cancelling {
        deshacerAlTerminar = true
        return []
      }
      guard state == .idle else { return [] }
      return deshacer()
    case .retencionVencida:
      guard hayRetenido else { return [] }
      hayRetenido = false
      deshacerAlTerminar = false
      return [.descartarLoRetenido]
    }
  }

  private mutating func deshacer() -> [Effect] {
    hayRetenido = false
    deshacerAlTerminar = false
    state = .finishing
    return [.entregarLoRetenido]
  }

  /// Empezar otro dictado es la respuesta a «¿lo recupero?»: no. Lo retenido
  /// se suelta antes de que nada nuevo empiece.
  private mutating func soltarLoRetenido() -> [Effect] {
    guard hayRetenido else { return [] }
    hayRetenido = false
    deshacerAlTerminar = false
    return [.descartarLoRetenido]
  }

  private mutating func triggerPressed(now: ContinuousClock.Instant) -> [Effect] {
    switch state {
    case .idle:
      pendingGesture = .held(startedAt: now)
      return soltarLoRetenido() + [.checkAndBegin]
    case .starting(.latched):
      finishWhenStarted = true
      return []
    case .recording(.latched):
      return finish(now: now)
    case .starting(.held), .recording(.held), .finishing, .cancelling:
      return []
    }
  }

  private mutating func triggerReleased(now: ContinuousClock.Instant) -> [Effect] {
    switch state {
    case let .starting(.held(startedAt)):
      if startedAt.duration(to: now) < umbralDeToque {
        state = .starting(.latched)
        return [.showLatched]
      }
      finishWhenStarted = true
      return []
    case let .recording(.held(startedAt)):
      if startedAt.duration(to: now) < umbralDeToque {
        state = .recording(.latched)
        return [.showLatched]
      }
      return finish(now: now)
    case .idle, .starting(.latched), .recording(.latched), .finishing, .cancelling:
      return []
    }
  }

  private mutating func menuToggled(now: ContinuousClock.Instant) -> [Effect] {
    switch state {
    case .idle:
      pendingGesture = .latched
      return soltarLoRetenido() + [.checkAndBegin]
    case .starting:
      finishWhenStarted = true
      return []
    case .recording:
      return finish(now: now)
    case .finishing, .cancelling:
      return []
    }
  }

  private mutating func beginApproved() -> [Effect] {
    guard state == .idle, let gesture = pendingGesture else { return [] }
    pendingGesture = nil
    state = .starting(gesture)
    hasSpeech = false
    finishWhenStarted = false
    cancelWhenStarted = false
    recordingStartedAt = nil
    return [
      .setEscapeCapture(true),
      .showListening(latched: gesture.isLatched),
      .notifyRecording(true),
      .beginRecognition,
    ]
  }

  private mutating func recognitionStarted(now: ContinuousClock.Instant) -> [Effect] {
    if cancelWhenStarted {
      // Escape landed while the recognizer was still spinning up; the
      // session is already .cancelling and the HUD already hidden.
      return [.cancelRecognition]
    }

    switch state {
    case let .starting(gesture):
      state = .recording(gesture)
      recordingStartedAt = now
      var effects: [Effect] = [.startNoSpeechTimer]
      if finishWhenStarted {
        effects += finish(now: now)
      }
      return effects
    case .idle, .recording, .finishing, .cancelling:
      return []
    }
  }

  private mutating func recognitionFailed(wasCancelled: Bool) -> [Effect] {
    if wasCancelled || cancelWhenStarted {
      return reset()
    }
    guard isSessionActive else { return [] }
    state = .cancelling
    return [
      .stopNoSpeechTimer,
      .setEscapeCapture(false),
      .cancelRecognition,
    ]
  }

  private mutating func updateReceived(hasVisibleText: Bool) -> [Effect] {
    guard isSessionActive else { return [] }

    var effects: [Effect] = []
    if hasVisibleText {
      hasSpeech = true
      effects.append(.stopNoSpeechTimer)
    }

    // The recognizer emits its final results while the session finishes;
    // the band already says "Finalizing…" and must not flash the draft.
    if state == .finishing {
      return effects
    }
    effects.append(.showLiveText)
    return effects
  }

  private mutating func finish(now: ContinuousClock.Instant) -> [Effect] {
    guard case .recording = state else { return [] }
    let speakingDuration = recordingStartedAt.map {
      Self.timeInterval(for: $0.duration(to: now))
    } ?? 0
    state = .finishing
    return [
      .stopNoSpeechTimer,
      .setEscapeCapture(false),
      .showFinalizing,
      .finishRecognition(speakingDuration: speakingDuration),
    ]
  }

  private mutating func cancel() -> [Effect] {
    switch state {
    case .idle, .finishing, .cancelling:
      return []
    case .starting:
      // The start task tears itself down and reports back as a
      // cancelled recognition failure.
      cancelWhenStarted = true
      state = .cancelling
      return [.cancelStartTask, .stopNoSpeechTimer, .setEscapeCapture(false), .hideHUD]
    case .recording:
      state = .cancelling
      // Sin voz no hay nada que recuperar: se cancela como siempre.
      guard conDeshacer, hasSpeech else {
        return [.stopNoSpeechTimer, .setEscapeCapture(false), .hideHUD, .cancelRecognition]
      }
      hayRetenido = true
      return [.stopNoSpeechTimer, .setEscapeCapture(false), .retenerParaDeshacer]
    }
  }

  private mutating func reset() -> [Effect] {
    state = .idle
    pendingGesture = nil
    hasSpeech = false
    finishWhenStarted = false
    cancelWhenStarted = false
    recordingStartedAt = nil
    return [.stopNoSpeechTimer, .setEscapeCapture(false), .notifyRecording(false)]
  }

  private static func timeInterval(for duration: Duration) -> TimeInterval {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}
