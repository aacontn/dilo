import AVFAudio
import DiloEngines
import DiloText
import Foundation
import os

/// Lee un texto con Phonon: lo dice (`TextoParaLeer`), lo parte por
/// oraciones (`TrozosParaLeer`) y va sintetizando el trozo siguiente
/// mientras suena el anterior.
///
/// El primer audio llega cuando está el primer trozo, no el texto entero, y
/// detener es inmediato: cancela la síntesis —que mata el proceso en
/// curso— y para el reproductor con lo que tenía en cola. El motor de audio
/// existe sólo mientras lee: un `AVAudioEngine` prendido en reposo gasta CPU
/// y memoria que Dilo no tiene (spec §3).
@MainActor
final class LectorPhonon {
  private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "lectura")

  /// Se llama con `true` cuando suena el primer trozo y con `false` cuando
  /// termina, se detiene o falla.
  var alCambiarDeEstado: ((Bool) -> Void)?

  private let sintetizador: SintetizadorPhonon
  private var tarea: Task<Void, Never>?
  private var motor: AVAudioEngine?
  private var reproductor: AVAudioPlayerNode?

  init(instalacion: InstalacionDePhonon) {
    sintetizador = SintetizadorPhonon(instalacion: instalacion)
  }

  var leyendo: Bool { tarea != nil }

  /// - Parameter alFallar: si falla antes de que suene nada, para que quien
  ///   llama lea con Apple en vez de quedarse callado. Si falla a la mitad,
  ///   lo leído ya se oyó y se corta ahí.
  func leer(_ texto: String, voz: VozDePhonon, alFallar: @escaping (any Error) -> Void) {
    detener()
    let trozos = TrozosParaLeer.partir(TextoParaLeer.preparar(texto))
    guard !trozos.isEmpty else { return }
    // Si falla, se vuelve a intentar con el primer trozo y ahí cuenta como falla.
    _ = try? reproductorListo()
    let sintetizador = self.sintetizador

    tarea = Task { [weak self] in
      var sono = false
      do {
        for trozo in trozos {
          let muestras = try await sintetizador.sintetizar(trozo, voz: voz)
          try Task.checkCancellation()
          guard let self, let bufer = Self.bufer(de: muestras) else { continue }
          let reproductor = try self.reproductorListo()
          reproductor.scheduleBuffer(bufer, completionHandler: nil)
          if !sono { self.alCambiarDeEstado?(true) }
          sono = true
        }
        // Un respiro de silencio al final, y se espera a que suene: recién
        // ahí terminó lo de antes y se puede apagar el motor de audio.
        if sono, let self, let reproductor = self.reproductor,
          let cola = Self.bufer(de: [Float](repeating: 0, count: Int(SintetizadorPhonon.frecuencia / 20)))
        {
          await reproductor.scheduleBuffer(cola, completionCallbackType: .dataPlayedBack)
        }
      } catch {
        // Detener mata el proceso, que entonces sale con error y no con
        // `CancellationError`: lo que manda es si la tarea se canceló. Ahí ya
        // limpió `detener()`, y quizás ya empezó otra lectura.
        if Task.isCancelled { return }
        Self.logger.error("Phonon falló: \(String(describing: error), privacy: .public)")
        if !sono { alFallar(error) }
      }
      if Task.isCancelled { return }
      self?.terminar()
    }
  }

  func detener() {
    guard let tarea else { return }
    tarea.cancel()
    self.tarea = nil
    terminar()
  }

  private func terminar() {
    reproductor?.stop()
    motor?.stop()
    reproductor = nil
    motor = nil
    tarea = nil
    alCambiarDeEstado?(false)
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
    motor.attach(reproductor)
    motor.connect(reproductor, to: motor.mainMixerNode, format: Self.formato)
    try motor.start()
    reproductor.play()
    self.motor = motor
    self.reproductor = reproductor
    return reproductor
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
