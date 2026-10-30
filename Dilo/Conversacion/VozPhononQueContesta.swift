import AVFAudio
import DiloEngines
import DiloModes
import DiloText
import Foundation
import Synchronization
import os

/// La voz de la **Conversación** con Phonon, la misma de «Leer en voz alta».
///
/// Cumple `VozQueContesta`: cada oración que llega se sintetiza en orden
/// mientras suena la anterior, y el turno termina cuando sonó lo último. Si
/// Phonon no está instalado, «Leer en voz alta» eligió Apple, la persona eligió
/// una voz de Apple en la barra o Phonon falla antes de sonar, el turno lo dice
/// `VozDelSistema`: la conversación nunca se queda callada por la voz.
///
/// La velocidad la pone un `AVAudioUnitTimePitch`: Phonon no tiene velocidad
/// propia, y estirar el audio sin cambiar el tono es lo que hace el sistema.
/// El motor de audio existe sólo mientras habla, como en `LectorPhonon`.
@MainActor
final class VozPhononQueContesta: VozQueContesta {
  private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "conversacion")

  var alEmpezar: (@MainActor () -> Void)?
  var alTerminar: (@MainActor () -> Void)?

  /// Lo que está sonando, escrito desde el hilo de audio. Es contra lo que se
  /// compara el micrófono para saber si la persona le habla encima. Con Apple
  /// no se puede medir: `AVSpeechSynthesizer` no pasa por este motor.
  private let medidorDeSalida = MedidorDeSalida()
  var nivelDeSalida: (@Sendable () -> Float?)? {
    let medidor = medidorDeSalida
    return { medidor.nivel.withLock { $0 } }
  }

  private let settings: AppSettings
  private let instalacion: InstalacionDePhonon
  private let sintetizador: SintetizadorPhonon
  private let respaldo = VozDelSistema()
  private var ajustes = AjustesDeLaVoz.deFabrica

  /// Lo último que se vio en disco. Se mira al crear y al ajustar, fuera del
  /// hilo principal; una oración no espera a nadie.
  private var phononListo = false

  /// Quién dice el turno en curso; nil entre turnos.
  private enum Quien { case phonon, respaldo }
  private var quien: Quien?

  private var cola: [String] = []
  private var tarea: Task<Void, Never>?
  private var porSonar = 0
  private var sono = false
  private var turnoCerrado = false
  /// Sube con cada `detener()`: un aviso del reproductor de un turno ya
  /// callado trae otra generación y no cuenta.
  private var generacion = 0

  private var motor: AVAudioEngine?
  private var reproductor: AVAudioPlayerNode?
  private var velocidad: AVAudioUnitTimePitch?

  init(settings: AppSettings, instalacion: InstalacionDePhonon = PhononEnDilo.compartido.instalacion) {
    self.settings = settings
    self.instalacion = instalacion
    sintetizador = SintetizadorPhonon(instalacion: instalacion)
    respaldo.alEmpezar = { [weak self] in self?.alEmpezar?() }
    respaldo.alTerminar = { [weak self] in self?.terminarElTurno() }
    mirarElDisco()
  }

  func ajustar(_ ajustes: AjustesDeLaVoz) {
    self.ajustes = ajustes
    respaldo.ajustar(ajustes)
    velocidad?.rate = Float(ajustes.velocidad)
    mirarElDisco()
  }

  func decir(_ oracion: String) {
    let limpia = oracion.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !limpia.isEmpty else { return }
    if quien == nil { quien = usaPhonon ? .phonon : .respaldo }
    switch quien {
    case .respaldo, nil:
      medidorDeSalida.nivel.withLock { $0 = nil }
      respaldo.decir(limpia)
    case .phonon:
      cola.append(limpia)
      // Si falla, `encolar` lo vuelve a intentar y ahí pasa al respaldo.
      _ = try? reproductorListo()
      if tarea == nil { sintetizarLaCola() }
    }
  }

  func cerrarElTurno() {
    switch quien {
    case .respaldo:
      respaldo.cerrarElTurno()
    case .phonon:
      turnoCerrado = true
      avisarSiTermino()
    case nil:
      // Un turno sin texto termina en el acto, como pide el contrato.
      alTerminar?()
    }
  }

  func detener() {
    generacion += 1
    tarea?.cancel()
    tarea = nil
    cola.removeAll()
    respaldo.detener()
    apagarElAudio()
    medidorDeSalida.nivel.withLock { $0 = 0 }
    quien = nil
    porSonar = 0
    sono = false
    turnoCerrado = false
  }

  /// Phonon dice el turno sólo con la voz de fábrica de la barra: una voz
  /// elegida ahí es de Apple, y la persona la eligió a propósito.
  private var usaPhonon: Bool {
    ajustes.voz == nil && phononListo
      && MotorDeLectura(guardado: settings.readAloudMotor) == .phonon
  }

  private func mirarElDisco() {
    let voz = VocesDePhonon.voz(settings.readAloudVozPhonon)
    Task {
      let estado = await Task.detached(priority: .utility) { InstalacionDePhonon.estado(voz: voz) }.value
      self.phononListo = estado.listo
    }
  }

  private func sintetizarLaCola() {
    let voz = VocesDePhonon.voz(settings.readAloudVozPhonon)
    let sintetizador = self.sintetizador
    let generacion = self.generacion
    tarea = Task { [weak self] in
      while let self, self.generacion == generacion, !self.cola.isEmpty {
        let oracion = self.cola.removeFirst()
        do {
          for trozo in TrozosParaLeer.partir(TextoParaLeer.preparar(oracion)) {
            let muestras = try await sintetizador.sintetizar(trozo, voz: voz)
            try Task.checkCancellation()
            guard self.generacion == generacion else { return }
            try self.encolar(muestras, generacion: generacion)
          }
        } catch {
          // Detener mata el proceso y sale con error: lo que manda es si se
          // canceló. Si no, y no sonó nada, el turno pasa entero a Apple.
          if Task.isCancelled || self.generacion != generacion { return }
          Self.logger.error("Phonon falló en la conversación: \(String(describing: error), privacy: .public)")
          if !self.sono {
            self.pasarAlRespaldo(desde: oracion)
            return
          }
        }
      }
      guard let self, self.generacion == generacion else { return }
      self.tarea = nil
      self.avisarSiTermino()
    }
  }

  private func encolar(_ muestras: [Float], generacion: Int) throws {
    guard let bufer = Self.bufer(de: muestras) else { return }
    let reproductor = try reproductorListo()
    porSonar += 1
    reproductor.scheduleBuffer(bufer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      Task { @MainActor in self?.sonoUnBufer(generacion: generacion) }
    }
    if !sono {
      sono = true
      alEmpezar?()
    }
  }

  private func sonoUnBufer(generacion: Int) {
    guard generacion == self.generacion else { return }
    porSonar = max(porSonar - 1, 0)
    avisarSiTermino()
  }

  /// Lo que quedaba del turno lo dice Apple, desde la oración que falló.
  private func pasarAlRespaldo(desde oracion: String) {
    let pendientes = [oracion] + cola
    cola.removeAll()
    tarea = nil
    apagarElAudio()
    quien = .respaldo
    medidorDeSalida.nivel.withLock { $0 = nil }
    pendientes.forEach { respaldo.decir($0) }
    if turnoCerrado { respaldo.cerrarElTurno() }
  }

  private func avisarSiTermino() {
    guard quien == .phonon, turnoCerrado, cola.isEmpty, tarea == nil, porSonar == 0 else { return }
    apagarElAudio()
    terminarElTurno()
  }

  private func terminarElTurno() {
    medidorDeSalida.nivel.withLock { $0 = 0 }
    quien = nil
    sono = false
    turnoCerrado = false
    porSonar = 0
    alTerminar?()
  }

  private static let formato = AVAudioFormat(
    standardFormatWithSampleRate: SintetizadorPhonon.frecuencia, channels: 1
  )!

  /// Prende la salida antes de que haya audio y la deja andando en silencio.
  ///
  /// Una salida recién encendida puede perderse lo primero que le llega, y
  /// ahí está la consonante de «Yo» y «Ya»: unos 60 ms muy suaves que terminan
  /// a los 180 ms del audio. Sin ella se oye «Io», «Ia». Lo que tarda Phonon
  /// en sintetizar el primer trozo le da tiempo de despertar sin demorar nada.
  private func reproductorListo() throws -> AVAudioPlayerNode {
    if let reproductor { return reproductor }
    let motor = AVAudioEngine()
    let reproductor = AVAudioPlayerNode()
    let velocidad = AVAudioUnitTimePitch()
    velocidad.rate = Float(ajustes.velocidad)
    motor.attach(reproductor)
    motor.attach(velocidad)
    motor.connect(reproductor, to: velocidad, format: Self.formato)
    motor.connect(velocidad, to: motor.mainMixerNode, format: Self.formato)
    motor.mainMixerNode.installTap(onBus: 0, bufferSize: 2_048, format: nil, block: medidorDeSalida.bloque)
    try motor.start()
    reproductor.play()
    self.motor = motor
    self.reproductor = reproductor
    self.velocidad = velocidad
    return reproductor
  }

  private func apagarElAudio() {
    reproductor?.stop()
    motor?.mainMixerNode.removeTap(onBus: 0)
    motor?.stop()
    reproductor = nil
    velocidad = nil
    motor = nil
  }

  private static func bufer(de muestras: [Float]) -> AVAudioPCMBuffer? {
    guard !muestras.isEmpty,
      let bufer = AVAudioPCMBuffer(pcmFormat: formato, frameCapacity: AVAudioFrameCount(muestras.count))
    else { return nil }
    bufer.frameLength = AVAudioFrameCount(muestras.count)
    muestras.withUnsafeBufferPointer { origen in
      bufer.floatChannelData![0].update(from: origen.baseAddress!, count: muestras.count)
    }
    return bufer
  }
}

/// Qué tan fuerte está sonando la voz. Nil si no se sabe (dice Apple).
///
/// Vive fuera de `VozPhononQueContesta` a propósito: el tap corre en una cola de
/// audio, y un bloque escrito dentro de una clase `@MainActor` hereda ese
/// aislamiento. Swift lo revisa al entrar y mata la app; así se cayó la 0.12.0
/// la primera vez que Kami habló.
final class MedidorDeSalida: Sendable {
  let nivel = Mutex<Float?>(0)

  var bloque: AVAudioNodeTapBlock {
    { [self] bufer, _ in
      guard let canal = bufer.floatChannelData?[0], bufer.frameLength > 0 else { return }
      let muestras = Array(UnsafeBufferPointer(start: canal, count: Int(bufer.frameLength)))
      let medido = OidoDeLaLlamada.nivel(de: muestras)
      nivel.withLock { $0 = medido }
    }
  }
}
