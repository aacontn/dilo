import AVFAudio
import Accelerate
import DiloEngines
import Speech
import os

final class MicrophoneInput: @unchecked Sendable {
  enum InputError: LocalizedError, Sendable {
    case unavailable
    case converterCreationFailed
    case conversionFailed(String)
    case analyzerBackpressure

    var errorDescription: String? {
      switch self {
      case .unavailable:
        "No microphone input is available."
      case .converterCreationFailed:
        "The microphone audio format is unsupported."
      case let .conversionFailed(message):
        "Microphone conversion failed: \(message)"
      case .analyzerBackpressure:
        "Speech analysis could not keep up with microphone input."
      }
    }
  }

  /// The converter into the analyzer's format, rebuilt whenever the tap
  /// starts delivering a different one.
  ///
  /// The input format is not fixed for the life of a session: a Bluetooth
  /// headset switches from A2DP to its 16 kHz hands-free profile the moment
  /// something opens the microphone, so the first buffers after a route
  /// change arrive in a format the session did not start with. One box per
  /// tap, so the audio thread is the only thread that touches it.
  final class ConverterBox: @unchecked Sendable {
    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init(outputFormat: AVAudioFormat) {
      self.outputFormat = outputFormat
    }

    func converter(for format: AVAudioFormat) throws -> AVAudioConverter {
      if let converter, inputFormat == format { return converter }
      guard let made = AVAudioConverter(from: format, to: outputFormat) else {
        throw InputError.converterCreationFailed
      }
      converter = made
      inputFormat = format
      return made
    }
  }

  private final class InputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
      self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
      lock.withLock {
        guard !supplied else {
          status.pointee = .noDataNow
          return nil
        }

        supplied = true
        status.pointee = .haveData
        return buffer
      }
    }
  }

  /// Replaced rather than restarted when the audio route changes: the old
  /// engine's input chain cannot re-initialise across a Bluetooth profile
  /// switch, which fails with -10868.
  private var audioEngine = AVAudioEngine()
  /// Serialises route recovery off the notification thread.
  private let recoveryQueue = DispatchQueue(label: "cl.espaciodigital.dilo.mic-recovery")
  private var configurationObserver: (any NSObjectProtocol)?
  private var analyzerFormat: AVAudioFormat?
  private var recovering = false
  /// A route change that arrived while recovering. Dropping it would leave a
  /// dead engine behind, and a headset settling its profile can post more
  /// than one.
  private var recoveryPending = false
  /// Dónde aterriza cada buffer ya convertido. Devuelve `false` cuando el
  /// consumidor no da abasto, que es la contrapresión que antes venía del
  /// `YieldResult` del stream.
  ///
  /// Es un closure y no la continuación del analizador porque el motor
  /// Parakeet necesita exactamente esta captura —con la recuperación de
  /// cambio de ruta de los audífonos Bluetooth, que costó cara— pero no pasa
  /// por SpeechAnalyzer. La inicialización de siempre sigue existiendo, más
  /// abajo, y hace justo lo que hacía.
  private let sink: @Sendable (AVAudioPCMBuffer) -> Bool
  /// Se llama cuando la captura se muere y no viene nada más.
  private let onEnd: @Sendable () -> Void
  private let failureHandler: @Sendable (InputError) -> Void
  /// Normalized microphone level (0–1) per tap buffer, for the HUD's
  /// voice-reactive visual. Called on the audio thread.
  private let levelHandler: (@Sendable (Float) -> Void)?
  /// La copia en RAM de lo que se oye, a 16 kHz mono, para reintentar un
  /// dictado cuyo motor se cayó sin volver a hablar. Nil donde nadie la
  /// pide (transcribir un archivo).
  private let grabadora: GrabadoraEnRAM?
  /// Lo que este dictado comparte con quien lo armó: a quién avisarle que el
  /// micrófono entrega ceros. Nil donde nadie lo pide.
  private let microfono: MicrofonoDeLaSesion?
  /// Cuenta los ceros exactos del hardware. Sólo lo toca el hilo de audio
  /// (y una reapertura arma otro tap que sigue contando con el mismo).
  private var detector = DetectorDeMicMuerto()
  /// El micrófono al que quedó fijado el motor, para volver a fijar el que
  /// arma una reconstrucción. Nil sigue la entrada del sistema.
  private var entradaFijada: EntradaDeAudio?
  /// Con qué dispositivo y formato arrancó el motor que corre, para
  /// reconocer el aviso de cambio de ruta que sigue a nuestro propio fijado.
  private var huellaAlArrancar: GuardiaDeReconstruccion.Huella?
  /// El tope de reconstrucciones: si el motor entra en bucle igual, se deja
  /// de fijar el micrófono y se sigue con la entrada del sistema.
  private var guardia = GuardiaDeReconstruccion()
  /// Para el registro de gatillo → primer búfer, con y sin motor tibio: es
  /// la medida que decide si el motor tibio se prende de fábrica.
  private var abiertoEn: ContinuousClock.Instant?
  private var motorEraTibio = false
  private let stateLock = NSLock()

  private var running = false
  private var reportedFailure = false
#if DEBUG
  /// Gancho de medición de la Tarea 7, sólo en Debug: ver
  /// `MicrophoneInput+MetricasWAV.swift`. Nil en cuanto la variable de entorno
  /// no está, que es siempre salvo cuando corre `scripts/metrics.sh`.
  private var wavDeMetricas: EntradaWAVDeMetricas?
#endif

  init(
    sink: @escaping @Sendable (AVAudioPCMBuffer) -> Bool,
    onEnd: @escaping @Sendable () -> Void,
    failureHandler: @escaping @Sendable (InputError) -> Void,
    levelHandler: (@Sendable (Float) -> Void)? = nil,
    grabadora: GrabadoraEnRAM? = nil,
    microfono: MicrofonoDeLaSesion? = nil
  ) {
    self.sink = sink
    self.onEnd = onEnd
    self.failureHandler = failureHandler
    self.levelHandler = levelHandler
    self.grabadora = grabadora
    self.microfono = microfono
  }

  convenience init(
    analyzerContinuation: AsyncStream<AnalyzerInput>.Continuation,
    failureHandler: @escaping @Sendable (InputError) -> Void,
    levelHandler: (@Sendable (Float) -> Void)? = nil,
    grabadora: GrabadoraEnRAM? = nil,
    microfono: MicrofonoDeLaSesion? = nil
  ) {
    self.init(
      sink: { buffer in
        if case .dropped = analyzerContinuation.yield(AnalyzerInput(buffer: buffer)) {
          return false
        }
        return true
      },
      onEnd: { analyzerContinuation.finish() },
      failureHandler: failureHandler,
      levelHandler: levelHandler,
      grabadora: grabadora,
      microfono: microfono
    )
  }

  func start(outputFormat: AVAudioFormat) throws {
#if DEBUG
    if let ruta = ProcessInfo.processInfo.environment[EntradaWAVDeMetricas.variable],
      !ruta.isEmpty {
      // El WAV también pasa por la grabadora: la medición de soltar→texto
      // tiene que pagar lo mismo que un dictado de verdad.
      let copia = copiaBox(para: outputFormat)
      let sink = self.sink
      let entrada = try EntradaWAVDeMetricas(
        ruta: ruta,
        formatoDelAnalizador: outputFormat,
        sink: { [weak self] buffer in
          self?.guardarEnRAM(buffer, copiaBox: copia)
          return sink(buffer)
        },
        nivel: levelHandler
      )
      stateLock.withLock {
        wavDeMetricas = entrada
        running = true
      }
      entrada.empezar()
      return
    }
#endif
    // El micrófono de este dictado, fijado sólo en el motor de Dilo y antes
    // de leer el formato del bus: la entrada del sistema no se toca.
    if let entrada = microfono?.entrada {
      if let tibio = microfono?.motorTibio(para: entrada) {
        stateLock.withLock {
          audioEngine = tibio
          entradaFijada = entrada
          motorEraTibio = true
        }
      } else {
        fijar(audioEngine, a: entrada)
      }
    }
    stateLock.withLock { abiertoEn = .now }
    let hardwareFormat = audioEngine.inputNode.inputFormat(forBus: 0)
    guard Self.hasUsableHardwareInput(hardwareFormat) else {
      throw InputError.unavailable
    }

    stateLock.withLock { analyzerFormat = outputFormat }
    observeConfigurationChanges(of: audioEngine)
    do {
      try startCapturing(on: audioEngine, into: outputFormat)
    } catch {
      stopObservingConfigurationChanges()
      AppLog.audio.error(
        "engine failed to start: \(error.localizedDescription, privacy: .public)"
      )
      throw error
    }
    stateLock.withLock { running = true }
    AppLog.audio.info(
      "capturing at \(self.audioEngine.inputNode.outputFormat(forBus: 0).sampleRate, privacy: .public) Hz"
    )
  }

  /// Installs the tap and starts the engine.
  ///
  /// The tap takes no format. Handing it one captured moments earlier throws
  /// an Objective-C exception the moment the hardware has moved on ("Failed
  /// to create tap due to format mismatch"), which Swift cannot catch, so the
  /// app would die rather than recover. Nil means the bus's live format.
  private func startCapturing(on engine: AVAudioEngine, into outputFormat: AVAudioFormat) throws {
    let inputNode = engine.inputNode
    inputNode.removeTap(onBus: 0)

    let converterBox = ConverterBox(outputFormat: outputFormat)
    let copia = copiaBox(para: outputFormat)
    inputNode.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
      self?.receive(buffer, converterBox: converterBox, copiaBox: copia)
    }

    engine.prepare()
    // Antes de `start()` y no después: el aviso que sigue al fijado puede
    // llegar, en otro hilo, antes de que `start()` vuelva.
    let huella = Self.huella(de: engine)
    stateLock.withLock { huellaAlArrancar = huella }
    do {
      try engine.start()
    } catch {
      inputNode.removeTap(onBus: 0)
      throw error
    }
  }

  /// En qué dispositivo y con qué formato está la entrada del motor ahora.
  private static func huella(de engine: AVAudioEngine) -> GuardiaDeReconstruccion.Huella {
    let formato = engine.inputNode.inputFormat(forBus: 0)
    return GuardiaDeReconstruccion.Huella(
      dispositivo: engine.inputNode.auAudioUnit.deviceID,
      tasa: formato.sampleRate,
      canales: formato.channelCount
    )
  }

  private func observeConfigurationChanges(of engine: AVAudioEngine) {
    stopObservingConfigurationChanges()
    let observer = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: nil
    ) { [weak self, weak engine] _ in
      guard let self else { return }
      // Fijar un motor nuevo y arrancarlo hace que ese mismo motor avise un
      // cambio de ruta sin haberse detenido. Reconstruir por eso fijaba otro
      // motor, que volvía a avisar: el bucle de la webcam en la 0.4.4.
      if let engine {
        let alArrancar = self.stateLock.withLock { self.huellaAlArrancar }
        let ahora = Self.huella(de: engine)
        guard GuardiaDeReconstruccion.hayQueReconstruir(
          corriendo: engine.isRunning, alArrancar: alArrancar, ahora: ahora
        ) else {
          AppLog.audio.info(
            "aviso de cambio de ruta con el motor andando en el mismo micrófono (\(ahora.tasa, privacy: .public) Hz): no reconstruyo"
          )
          return
        }
      }
      AppLog.audio.notice("audio route changed; the engine has stopped itself")
      self.recoverFromRouteChange()
    }
    stateLock.withLock { configurationObserver = observer }
  }

  private func stopObservingConfigurationChanges() {
    let observer = stateLock.withLock { () -> (any NSObjectProtocol)? in
      defer { configurationObserver = nil }
      return configurationObserver
    }
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  /// AVAudioEngine stops itself when the audio hardware changes underneath it
  /// and says so through this notification. Nothing else restarts it, so
  /// without this a session that began just as a headset switched profile
  /// listens to an engine that is no longer running: no levels, no words, and
  /// no error to show for it.
  private func recoverFromRouteChange() {
    let shouldRecover = stateLock.withLock { () -> Bool in
      guard running else { return false }
      guard !recovering else {
        recoveryPending = true
        return false
      }
      recovering = true
      return true
    }
    guard shouldRecover else { return }
    scheduleRecovery()
  }

  private func scheduleRecovery() {
    // Off the notification thread. No settle delay: a fresh engine starts
    // cleanly straight away, and the -10868 that looked like it needed one
    // came from restarting the old engine rather than from being early.
    recoveryQueue.async { [weak self] in
      guard let self else { return }
      rebuildEngine()

      // A change that arrived mid-rebuild describes hardware the new engine
      // never saw, so it gets its own pass rather than being dropped.
      let again = stateLock.withLock { () -> Bool in
        guard running, recoveryPending else {
          recovering = false
          recoveryPending = false
          return false
        }
        recoveryPending = false
        return true
      }
      if again { scheduleRecovery() }
    }
  }

  private func rebuildEngine() {
    let outputFormat = stateLock.withLock { () -> AVAudioFormat? in
      guard running else { return nil }
      return analyzerFormat
    }
    guard let outputFormat else { return }

    let previous = stateLock.withLock { audioEngine }
    previous.stop()
    previous.inputNode.removeTap(onBus: 0)

    let engine = AVAudioEngine()
    // Más de `maximo` reconstrucciones en la ventana es un bucle, lo cause
    // quien lo cause: se suelta el micrófono fijado y se sigue con la entrada
    // del sistema, que nunca se fija y no puede alimentarlo.
    let (cruzoElTope, enLaVentana, soltada) = stateLock.withLock {
      () -> (Bool, Int, EntradaDeAudio?) in
      let cruzo = guardia.anotar(en: .now)
      let soltada = cruzo ? entradaFijada : nil
      if guardia.dejoDeFijar { entradaFijada = nil }
      return (cruzo, guardia.enLaVentana, soltada)
    }
    if cruzoElTope {
      AppLog.audio.notice(
        "\(enLaVentana) reconstrucciones del motor en \(GuardiaDeReconstruccion.ventana.components.seconds) s: dejo de fijar \(soltada?.nombre ?? "el micrófono", privacy: .public) y sigo con la entrada del sistema"
      )
    }
    // El motor nuevo vuelve al mismo micrófono. Si ya no está (se
    // desenchufó), fijarlo falla y el motor sigue al del sistema: el dictado
    // continúa en vez de morirse.
    if let entrada = stateLock.withLock({ entradaFijada }) {
      fijar(engine, a: entrada)
    }
    stateLock.withLock { audioEngine = engine }
    observeConfigurationChanges(of: engine)
    do {
      try startCapturing(on: engine, into: outputFormat)
    } catch {
      // Nothing else is coming. Ending the session with a reason beats
      // leaving the shape up in front of a microphone that is not running.
      reportFailure(.unavailable)
    }
  }

  private func fijar(_ engine: AVAudioEngine, a entrada: EntradaDeAudio) {
    // Ya está ahí: volver a fijarlo no cambia nada y avisa otro cambio de
    // ruta.
    guard engine.inputNode.auAudioUnit.deviceID != entrada.id else {
      stateLock.withLock { entradaFijada = entrada }
      return
    }
    do {
      try engine.fijarEntrada(entrada)
      stateLock.withLock { entradaFijada = entrada }
      AppLog.audio.info("micrófono fijado: \(entrada.nombre, privacy: .public)")
    } catch {
      stateLock.withLock { entradaFijada = nil }
      AppLog.audio.notice(
        "no pude fijar \(entrada.nombre, privacy: .public); sigo la entrada del sistema"
      )
    }
  }

  /// Reabre en caliente, sin cortar la sesión: la misma reconstrucción que
  /// usa el cambio de ruta, en la misma cola, así que no pelea con ella.
  private func reabrir() {
    recoverFromRouteChange()
  }

  static func hasUsableHardwareInput(_ format: AVAudioFormat) -> Bool {
    format.channelCount > 0 && format.sampleRate > 0
  }

  func stop() {
#if DEBUG
    let entradaDeMetricas = stateLock.withLock { () -> EntradaWAVDeMetricas? in
      defer { wavDeMetricas = nil }
      guard running, wavDeMetricas != nil else { return nil }
      running = false
      return wavDeMetricas
    }
    if let entradaDeMetricas {
      entradaDeMetricas.parar()
      return
    }
#endif
    let shouldStop = stateLock.withLock { () -> Bool in
      guard running else { return false }
      running = false
      return true
    }

    guard shouldStop else { return }
    stopObservingConfigurationChanges()
    let (engine, entrada) = stateLock.withLock { (audioEngine, entradaFijada) }
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
    microfono?.sesionTermino(entrada: entrada)
  }

  private func receive(_ buffer: AVAudioPCMBuffer, converterBox: ConverterBox, copiaBox: ConverterBox?) {
    // Ceros exactos no publican nivel: para el HUD es un micrófono que no
    // llama, y su watchdog lo pasa a ámbar. Un nivel 0 lo dibujaba igual que
    // el silencio de una sala, que nunca es cero digital (CONTEXT.md: el
    // silencio y un micrófono muerto tienen que verse distinto).
    if vigilar(buffer) {
      publishLevel(of: buffer)
    }
    do {
      let convertedBuffer = try convert(buffer, using: converterBox)
      guardarEnRAM(convertedBuffer, copiaBox: copiaBox)
      if !sink(convertedBuffer) {
        reportFailure(.analyzerBackpressure)
      }
    } catch let error as InputError {
      reportFailure(error)
    } catch {
      reportFailure(.conversionFailed(error.localizedDescription))
    }
  }

  private func convert(
    _ inputBuffer: AVAudioPCMBuffer,
    using converterBox: ConverterBox
  ) throws -> AVAudioPCMBuffer {
    let ratio = converterBox.outputFormat.sampleRate / inputBuffer.format.sampleRate
    let capacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 1

    guard let outputBuffer = AVAudioPCMBuffer(
      pcmFormat: converterBox.outputFormat,
      frameCapacity: capacity
    ) else {
      throw InputError.conversionFailed("Unable to allocate an audio buffer.")
    }

    let converter = try converterBox.converter(for: inputBuffer.format)
    let inputProvider = InputProvider(buffer: inputBuffer)
    var conversionError: NSError?
    let status = converter.convert(
      to: outputBuffer,
      error: &conversionError
    ) { _, inputStatus in
      inputProvider.next(status: inputStatus)
    }

    if let conversionError {
      throw InputError.conversionFailed(conversionError.localizedDescription)
    }

    guard status == .haveData || status == .inputRanDry else {
      throw InputError.conversionFailed("Unexpected converter status \(status.rawValue).")
    }

    return outputBuffer
  }

  /// El formato de la copia en RAM: el que piden los dos motores cuando
  /// transcriben desde memoria.
  static let formatoDeLaCopia = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: PoliticaDeGrabacion.tasa,
    channels: 1,
    interleaved: false
  )

  /// El conversor de la copia, o nil cuando no hace falta ninguno: sin
  /// grabadora no hay copia, y con Parakeet lo que va al motor ya es 16 kHz
  /// mono Float32 y se guarda tal cual. Con Apple el formato lo elige
  /// `SpeechAnalyzer`, y la copia sale de lo ya convertido —sin volver a
  /// remuestrear desde el hardware—.
  private func copiaBox(para outputFormat: AVAudioFormat) -> ConverterBox? {
    guard grabadora != nil, let formato = Self.formatoDeLaCopia, outputFormat != formato else {
      return nil
    }
    return ConverterBox(outputFormat: formato)
  }

  /// La copia en RAM. Una copia que falla no tumba el dictado: el motor
  /// sigue escuchando, y lo único que se pierde es poder reintentar.
  private func guardarEnRAM(_ convertido: AVAudioPCMBuffer, copiaBox: ConverterBox?) {
    guard let grabadora else { return }
    let copia: AVAudioPCMBuffer
    if let copiaBox {
      guard let convertida = try? convert(convertido, using: copiaBox) else { return }
      copia = convertida
    } else {
      copia = convertido
    }
    guard let canal = copia.floatChannelData?[0], copia.frameLength > 0 else { return }
    grabadora.agregar(UnsafeBufferPointer(start: canal, count: Int(copia.frameLength)))
  }

  /// Pasa el búfer del hardware —siempre Float32, antes de convertir nada,
  /// así que sirve igual para los dos motores— por el detector de ceros.
  /// Devuelve si el búfer trae sonido.
  private func vigilar(_ buffer: AVAudioPCMBuffer) -> Bool {
    guard let canal = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return true }
    let pico = DetectorDeMicMuerto.pico(UnsafeBufferPointer(start: canal, count: Int(buffer.frameLength)))
    let (evento, primerBufer) = stateLock.withLock {
      () -> (DetectorDeMicMuerto.Evento?, (Duration, Bool)?) in
      defer { abiertoEn = nil }
      return (
        detector.procesar(cuadros: Int(buffer.frameLength), tasa: buffer.format.sampleRate, pico: pico),
        abiertoEn.map { ($0.duration(to: .now), motorEraTibio) }
      )
    }
    if let (espera, tibio) = primerBufer {
      let ms = espera.components.seconds * 1_000 + espera.components.attoseconds / 1_000_000_000_000_000
      AppLog.audio.info("primer búfer a \(ms) ms de abrir (motor tibio: \(tibio ? "sí" : "no", privacy: .public))")
    }
    if let evento {
      if evento == .reabrir { reabrir() }
      microfono?.detectorVio(evento)
    }
    return pico > 0
  }

  /// RMS of the first channel (vDSP, so the audio thread barely notices)
  /// mapped to 0–1 over a 50 dB window: a quiet room sits near zero and
  /// speech fills most of the range.
  private func publishLevel(of buffer: AVAudioPCMBuffer) {
    guard let levelHandler,
       let samples = buffer.floatChannelData?[0],
       buffer.frameLength > 0
    else { return }

    let rms = vDSP.rootMeanSquare(
      UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))
    )
    let db = 20 * log10(max(rms, .leastNormalMagnitude))
    levelHandler(min(1, max(0, (db + 50) / 50)))
  }

  private func reportFailure(_ error: InputError) {
    let shouldReport = stateLock.withLock { () -> Bool in
      guard !reportedFailure else { return false }
      reportedFailure = true
      return true
    }

    guard shouldReport else { return }
    AppLog.audio.error(
      "microphone failed: \(error.errorDescription ?? "unknown", privacy: .public)"
    )
    onEnd()
    failureHandler(error)
  }
}
