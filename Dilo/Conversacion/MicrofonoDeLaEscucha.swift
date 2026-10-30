import AVFAudio
import DiloEngines
import Foundation
import os

/// El micrófono de la **escucha de nombres**: un `AVAudioEngine` propio, ni
/// el del dictado ni el de la reunión, que entrega 16 kHz mono a quien
/// escucha.
///
/// Fija su micrófono sólo en este motor (`PlanDeMicrofono.paraLaEscucha`):
/// Dilo sigue sin escribir la entrada del sistema, y un Bluetooth que nadie
/// eligió no se abre. Se reconstruye cuando la ruta cambia de verdad, con la
/// misma guardia que el dictado (`GuardiaDeReconstruccion`).
///
/// Lo que entrega no se guarda acá: va directo al búfer de la escucha, que
/// vive en la RAM y se pisa solo.
final class MicrofonoDeLaEscucha: @unchecked Sendable {
  private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "escucha")
  static let formato = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

  private let cerrojo = NSLock()
  private var motor: AVAudioEngine?
  private var observador: (any NSObjectProtocol)?
  private var huella: GuardiaDeReconstruccion.Huella?
  private var guardia = GuardiaDeReconstruccion()
  private var entrada: EntradaDeAudio?
  private var activa = false
  private let entregar: @Sendable ([Float]) -> Void

  /// Si el micrófono se cayó y no se pudo reabrir.
  var alFallar: (@Sendable (String) -> Void)?

  init(entregar: @escaping @Sendable ([Float]) -> Void) {
    self.entregar = entregar
  }

  /// Abre el micrófono. `entrada` nil sigue a la entrada del sistema.
  func empezar(entrada: EntradaDeAudio?) throws {
    cerrojo.withLock {
      activa = true
      self.entrada = entrada
      guardia = GuardiaDeReconstruccion()
    }
    try armar()
  }

  func detener() {
    let (motor, observador) = cerrojo.withLock { () -> (AVAudioEngine?, (any NSObjectProtocol)?) in
      activa = false
      defer {
        self.motor = nil
        self.observador = nil
      }
      return (self.motor, self.observador)
    }
    if let observador { NotificationCenter.default.removeObserver(observador) }
    motor?.inputNode.removeTap(onBus: 0)
    motor?.stop()
  }

  private func armar() throws {
    let motor = AVAudioEngine()
    let (fija, entrada) = cerrojo.withLock { (!guardia.dejoDeFijar, self.entrada) }
    if fija, let entrada { try motor.fijarEntrada(entrada) }
    let nodo = motor.inputNode
    let conversor = Conversor(salida: Self.formato)
    let entregar = self.entregar
    // Sin formato: el del bus en vivo, como la reunión. Bloques de ~100 ms:
    // el detector de voz junta de a 256 ms, y bloques más chicos sólo
    // despiertan más veces al hilo.
    nodo.installTap(onBus: 0, bufferSize: 4_800, format: nil) { buffer, _ in
      guard buffer.frameLength > 0, let muestras = conversor.convertir(buffer) else { return }
      entregar(muestras)
    }
    motor.prepare()
    let formato = nodo.inputFormat(forBus: 0)
    guard formato.sampleRate > 0, formato.channelCount > 0 else {
      nodo.removeTap(onBus: 0)
      throw EngineError.sinMicrofono
    }
    let huella = GuardiaDeReconstruccion.Huella(
      dispositivo: nodo.auAudioUnit.deviceID, tasa: formato.sampleRate, canales: formato.channelCount
    )
    do {
      try motor.start()
    } catch {
      nodo.removeTap(onBus: 0)
      throw error
    }
    let observador = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: motor, queue: nil
    ) { [weak self] _ in self?.cambioDeRuta() }
    cerrojo.withLock {
      self.motor = motor
      self.observador = observador
      self.huella = huella
    }
    Self.logger.notice(
      "micrófono abierto: \(entrada?.nombre ?? "el del sistema", privacy: .public), \(formato.sampleRate, privacy: .public) Hz"
    )
  }

  private func cambioDeRuta() {
    let (seguir, motor, alArrancar) = cerrojo.withLock { (activa, self.motor, huella) }
    guard seguir, let motor else { return }
    let formato = motor.inputNode.inputFormat(forBus: 0)
    let ahora = GuardiaDeReconstruccion.Huella(
      dispositivo: motor.inputNode.auAudioUnit.deviceID, tasa: formato.sampleRate, canales: formato.channelCount
    )
    guard GuardiaDeReconstruccion.hayQueReconstruir(corriendo: motor.isRunning, alArrancar: alArrancar, ahora: ahora)
    else { return }
    let cruzo = cerrojo.withLock { guardia.anotar(en: .now) }
    if cruzo { Self.logger.notice("demasiadas reconstrucciones del micrófono de la escucha: sigo con la entrada del sistema") }
    if let observador = cerrojo.withLock({ self.observador }) { NotificationCenter.default.removeObserver(observador) }
    motor.inputNode.removeTap(onBus: 0)
    motor.stop()
    do {
      try armar()
    } catch {
      Self.logger.error("no pude reabrir el micrófono de la escucha: \(error.localizedDescription, privacy: .public)")
      alFallar?(error.localizedDescription)
    }
  }

  /// De lo que dé el hardware a 16 kHz mono. Lo toca sólo el hilo del tap; el
  /// conversor se rehace si el formato cambia (un Bluetooth que cambia de
  /// perfil) y guarda su estado entre bloques, para no meter un clic en
  /// cada costura.
  private final class Conversor: @unchecked Sendable {
    let salida: AVAudioFormat
    private var conversor: AVAudioConverter?
    private var entrada: AVAudioFormat?

    init(salida: AVAudioFormat) { self.salida = salida }

    func convertir(_ buffer: AVAudioPCMBuffer) -> [Float]? {
      if conversor == nil || entrada != buffer.format {
        conversor = AVAudioConverter(from: buffer.format, to: salida)
        entrada = buffer.format
      }
      guard let conversor else { return nil }
      let capacidad = AVAudioFrameCount(ceil(Double(buffer.frameLength) * salida.sampleRate / buffer.format.sampleRate)) + 16
      guard let convertido = AVAudioPCMBuffer(pcmFormat: salida, frameCapacity: capacidad) else { return nil }
      nonisolated(unsafe) var entregado = false
      var error: NSError?
      let estado = conversor.convert(to: convertido, error: &error) { _, estadoDeEntrada in
        if entregado {
          estadoDeEntrada.pointee = .noDataNow
          return nil
        }
        entregado = true
        estadoDeEntrada.pointee = .haveData
        return buffer
      }
      guard error == nil, estado != .error, let canal = convertido.floatChannelData?[0] else { return nil }
      return Array(UnsafeBufferPointer(start: canal, count: Int(convertido.frameLength)))
    }
  }
}
