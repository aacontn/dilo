import AVFAudio
import DiloEngines
import DiloReuniones
import Foundation
import os

/// La pista `yo`: un `AVAudioEngine` propio, no el del dictado, sobre el
/// micrófono que decide `PlanDeMicrofono.paraLaReunion`: la entrada del sistema
/// —la que con más probabilidad usa la llamada—, salvo que sea Bluetooth y haya
/// otro, o el que se eligió en Ajustes (spec, «Captura»). Lo fija sólo en este
/// motor: Dilo sigue sin escribir la entrada del sistema.
///
/// Se reconstruye cuando la ruta cambia de verdad, con la misma guardia que
/// el dictado (`GuardiaDeReconstruccion`): más de cuatro reconstrucciones en
/// 5 s y suelta el micrófono fijado.
final class CapturaDelMicrofono: @unchecked Sendable {
  private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "reuniones")

  private let bufer: BuferAnular
  private let uidElegido: String?
  private let cerrojo = NSLock()
  private var motor: AVAudioEngine?
  private var observador: (any NSObjectProtocol)?
  private var huella: GuardiaDeReconstruccion.Huella?
  private var guardia = GuardiaDeReconstruccion()
  private var activa = false

  var alFallar: (@Sendable (String) -> Void)?
  private(set) var dispositivo: String?

  init(bufer: BuferAnular, uidElegido: String?) {
    self.bufer = bufer
    self.uidElegido = uidElegido
  }

  func empezar() throws {
    _ = RelojDelMac.ahora
    cerrojo.withLock { activa = true }
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
    let fija = cerrojo.withLock { !guardia.dejoDeFijar }
    let entradas = DispositivosDeAudio.entradas()
    let delSistema = DispositivosDeAudio.entradaDelSistema()
    let plan = PlanDeMicrofono.paraLaReunion(
      uidElegido: uidElegido, entradas: entradas, entradaDelSistema: delSistema, tapaCerrada: Tapa.estaCerrada
    )
    if fija, let entrada = plan.fijarA {
      try motor.fijarEntrada(entrada)
      dispositivo = entrada.nombre
    } else {
      dispositivo = entradas.first { $0.id == delSistema }?.nombre
    }
    let entrada = motor.inputNode
    let bufer = self.bufer
    // Sin formato: el del bus en vivo. Pasarle uno leído un momento antes
    // revienta con una excepción de Objective-C si el hardware ya cambió.
    entrada.installTap(onBus: 0, bufferSize: 4_096, format: nil) { buffer, cuando in
      guard let canales = buffer.floatChannelData, buffer.frameLength > 0 else { return }
      let n = Int(buffer.format.channelCount)
      let host = cuando.isHostTimeValid ? RelojDelMac.segundos(ticks: cuando.hostTime) : RelojDelMac.ahora
      bufer.escribir(
        cuadros: Int(buffer.frameLength), canales: n, tasa: buffer.format.sampleRate, host: host
      ) { cuadro, canal in canales[canal][cuadro] }
    }
    motor.prepare()
    let formato = entrada.inputFormat(forBus: 0)
    let huella = GuardiaDeReconstruccion.Huella(
      dispositivo: entrada.auAudioUnit.deviceID, tasa: formato.sampleRate, canales: formato.channelCount
    )
    do {
      try motor.start()
    } catch {
      entrada.removeTap(onBus: 0)
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
    Self.logger.notice("Micrófono de la reunión: \(formato.sampleRate, privacy: .public) Hz, \(formato.channelCount, privacy: .public) canales")
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
    if cruzo { Self.logger.notice("Demasiadas reconstrucciones del micrófono de la reunión: sigo con la entrada del sistema") }
    if let observador = cerrojo.withLock({ self.observador }) { NotificationCenter.default.removeObserver(observador) }
    motor.inputNode.removeTap(onBus: 0)
    motor.stop()
    do {
      try armar()
    } catch {
      Self.logger.error("No pude reabrir el micrófono de la reunión: \(error.localizedDescription, privacy: .public)")
      alFallar?(error.localizedDescription)
    }
  }
}
