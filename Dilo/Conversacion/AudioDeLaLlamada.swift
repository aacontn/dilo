import AVFAudio
import DiloEngines
import Foundation
import os

/// El audio de una llamada con parlantes: voz y micrófono en un solo motor, con
/// la cancelación de eco de Apple.
///
/// Por niveles no se puede separar a la persona de lo que suena: medido en el
/// Mac mini de Alfonso, con los parlantes y la webcam, su voz llega al micrófono
/// a 0,40-0,48 y la de Kami a 0,26-0,46. Con el procesamiento de voz, Kami queda
/// en 0,00 y la persona pasa hasta 0,60, y hasta 0,48 hablándole encima
/// (2026-10-31). Para eso voz y micrófono tienen que ser un mismo motor, así que
/// mientras dura la llamada la voz suena por acá.
///
/// **El orden importa**: el grafo se arma antes de prender el procesamiento. Al
/// revés, `start()` falla con -10875. Con eso prendido el micrófono entrega
/// cuatro canales iguales: se usa el primero.
final class AudioDeLaLlamada: @unchecked Sendable {
  private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "conversacion")

  let reproductor = AVAudioPlayerNode()
  let velocidad = AVAudioUnitTimePitch()

  private let motor = AVAudioEngine()
  private let cerrojo = NSLock()
  private var activa = false
  private var silenciada = false
  private var guardia = GuardiaDeReconstruccion()
  private var observador: (any NSObjectProtocol)?
  private let medidor: MedidorDeSalida
  private let entregar: @Sendable ([Float]) -> Void

  /// Se cayó y no se pudo volver a arrancar.
  var alFallar: (@Sendable (String) -> Void)?

  init(medidor: MedidorDeSalida, entregar: @escaping @Sendable ([Float]) -> Void) {
    self.medidor = medidor
    self.entregar = entregar
  }

  func empezar(entrada: EntradaDeAudio?, formatoDeLaVoz: AVAudioFormat) throws {
    if let entrada { try motor.fijarEntrada(entrada) }
    motor.attach(reproductor)
    motor.attach(velocidad)
    motor.connect(reproductor, to: velocidad, format: formatoDeLaVoz)
    motor.connect(velocidad, to: motor.mainMixerNode, format: formatoDeLaVoz)
    _ = motor.outputNode

    let nodo = motor.inputNode
    try nodo.setVoiceProcessingEnabled(true)
    // Lo demás que suena en el Mac no se baja: nunca se toca el volumen.
    nodo.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)

    let conversor = MicrofonoDeLaEscucha.Conversor(salida: MicrofonoDeLaEscucha.formato)
    let entregar = self.entregar
    nodo.installTap(onBus: 0, bufferSize: 4_800, format: nil) { [weak self] buffer, _ in
      guard let self, !cerrojo.withLock({ silenciada }), buffer.frameLength > 0,
        let mono = Self.primerCanal(de: buffer), let muestras = conversor.convertir(mono)
      else { return }
      entregar(muestras)
    }
    motor.mainMixerNode.installTap(onBus: 0, bufferSize: 2_048, format: nil, block: medidor.bloque)
    motor.prepare()
    do {
      try motor.start()
    } catch {
      nodo.removeTap(onBus: 0)
      motor.mainMixerNode.removeTap(onBus: 0)
      throw error
    }
    cerrojo.withLock { activa = true }
    observador = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: motor, queue: nil
    ) { [weak self] _ in self?.cambioDeRuta() }
  }

  /// Silenciar corta el micrófono en el procesamiento y bota lo que llegue: el
  /// motor sigue, porque por él suena la voz.
  func silenciar(_ silenciar: Bool) {
    cerrojo.withLock { silenciada = silenciar }
    motor.inputNode.isVoiceProcessingInputMuted = silenciar
  }

  func detener() {
    cerrojo.withLock { activa = false }
    if let observador { NotificationCenter.default.removeObserver(observador) }
    observador = nil
    motor.inputNode.removeTap(onBus: 0)
    motor.mainMixerNode.removeTap(onBus: 0)
    reproductor.stop()
    motor.stop()
  }

  /// Fijar y arrancar un motor hace que ese mismo motor avise un cambio de ruta
  /// sin detenerse: sólo importa si de verdad se paró.
  private func cambioDeRuta() {
    guard cerrojo.withLock({ activa }), !motor.isRunning else { return }
    let cruzo = cerrojo.withLock { guardia.anotar(en: .now) }
    do {
      guard !cruzo else { throw EngineError.sinMicrofono }
      try motor.start()
      reproductor.play()
    } catch {
      Self.logger.error("llamada: el audio no volvió: \(error.localizedDescription, privacy: .public)")
      alFallar?(error.localizedDescription)
    }
  }

  private static func primerCanal(de buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard buffer.format.channelCount > 1 else { return buffer }
    guard let formato = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1),
      let mono = AVAudioPCMBuffer(pcmFormat: formato, frameCapacity: buffer.frameLength),
      let origen = buffer.floatChannelData?[0], let destino = mono.floatChannelData?[0]
    else { return nil }
    mono.frameLength = buffer.frameLength
    destino.update(from: origen, count: Int(buffer.frameLength))
    return mono
  }
}
