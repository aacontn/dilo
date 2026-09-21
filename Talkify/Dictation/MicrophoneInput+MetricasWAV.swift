#if DEBUG
import AVFAudio
import Accelerate
import Foundation
import os

/// El gancho de medición de la Tarea 7: hace que una sesión de dictado escuche
/// un archivo en vez del micrófono.
///
/// **Sólo existe en builds Debug** y sólo se activa si la variable de entorno
/// `DILO_METRICS_WAV` apunta a un archivo. Un build de release no tiene este
/// archivo compilado y `MicrophoneInput` no cambia de comportamiento.
///
/// Por qué hace falta: el número "soltar → texto < 300 ms" del spec §3 no se
/// puede medir en CI si para medirlo alguien tiene que hablar. Con el WAV
/// inyectado al ritmo real, la sesión se comporta igual que con voz —parciales
/// incluidos— y la medición es repetible.
///
/// Además de reproducir, anota en `<ruta del wav>.soltado` el instante exacto
/// en que el controlador manda a parar, que es lo que hace soltar la tecla.
/// Ese es el t0 de la medición; el t1 lo toma `scripts/metrics.sh` mirando el
/// portapapeles. Tomar el t0 adentro deja fuera el tiempo de abrir el menú
/// para disparar, que es del AppleScript y no de Dilo.
final class EntradaWAVDeMetricas: @unchecked Sendable {
  static let variable = "DILO_METRICS_WAV"

  /// Trozos de ~100 ms: es el orden de magnitud del tap real (1.024 cuadros a
  /// 44,1 kHz son 23 ms) sin castigar al reconocedor con demasiadas entregas.
  private static let segundosPorTrozo = 0.1

  private let archivo: AVAudioFile
  private let conversor: AVAudioConverter
  private let formatoDeSalida: AVAudioFormat
  private let cuadrosPorTrozo: AVAudioFrameCount
  /// El mismo sumidero que usa el tap real: desde el motor doble, quién
  /// escucha lo decide `MicrophoneInput`, no este gancho. Así la medición mide
  /// el motor que esté puesto y no sólo el de Apple.
  private let sink: @Sendable (AVAudioPCMBuffer) -> Bool
  private let nivel: (@Sendable (Float) -> Void)?
  private let marcaDeSoltado: URL
  private let cola = DispatchQueue(label: "cl.espaciodigital.dilo.metricas-wav", qos: .userInitiated)
  private let candado = NSLock()
  private var reproduciendo = false

  init(
    ruta: String,
    formatoDelAnalizador: AVAudioFormat,
    sink: @escaping @Sendable (AVAudioPCMBuffer) -> Bool,
    nivel: (@Sendable (Float) -> Void)?
  ) throws {
    let url = URL(fileURLWithPath: ruta)
    archivo = try AVAudioFile(forReading: url)
    guard let conversor = AVAudioConverter(from: archivo.processingFormat, to: formatoDelAnalizador)
    else {
      throw MicrophoneInput.InputError.converterCreationFailed
    }
    self.conversor = conversor
    formatoDeSalida = formatoDelAnalizador
    cuadrosPorTrozo = AVAudioFrameCount(
      max(1, archivo.processingFormat.sampleRate * Self.segundosPorTrozo)
    )
    self.sink = sink
    self.nivel = nivel
    marcaDeSoltado = URL(fileURLWithPath: ruta + ".soltado")
    try? FileManager.default.removeItem(at: marcaDeSoltado)
  }

  func empezar() {
    candado.withLock { reproduciendo = true }
    AppLog.audio.notice("gancho de métricas: reproduciendo \(self.archivo.url.lastPathComponent, privacy: .public)")
    cola.async { [self] in reproducir() }
  }

  /// Anota el instante de "soltar" antes que nada: todo lo que venga después
  /// —cortar la reproducción, avisar al log— ya es tiempo que no es de Dilo.
  func parar() {
    let ahora = Date().timeIntervalSince1970
    try? String(format: "%.6f", ahora).write(to: marcaDeSoltado, atomically: true, encoding: .utf8)
    candado.withLock { reproduciendo = false }
  }

  private func reproducir() {
    let empezo = Date()
    var trozo = 0
    while candado.withLock({ reproduciendo }) {
      guard
        let entrada = AVAudioPCMBuffer(
          pcmFormat: archivo.processingFormat,
          frameCapacity: cuadrosPorTrozo
        )
      else { return }

      do {
        try archivo.read(into: entrada, frameCount: cuadrosPorTrozo)
      } catch {
        // Al llegar al final, `read` tira eofErr en vez de devolver cero
        // cuadros. Es el fin del audio, no una falla.
        AppLog.audio.notice("gancho de métricas: fin del archivo")
        return
      }
      // Fin del archivo. No se cierra el flujo: el micrófono real tampoco se
      // cierra solo, lo cierra `stop()` cuando la persona suelta.
      guard entrada.frameLength > 0 else {
        AppLog.audio.notice("gancho de métricas: fin del archivo")
        return
      }

      publicarNivel(de: entrada)
      if let salida = convertir(entrada) {
        _ = sink(salida)
      }

      // Al ritmo real: si se entregara de golpe, el reconocedor vería cinco
      // segundos de audio en un milisegundo y la latencia medida sería la de un
      // caso que no existe.
      trozo += 1
      let proxima = empezo.addingTimeInterval(Double(trozo) * Self.segundosPorTrozo)
      let espera = proxima.timeIntervalSinceNow
      if espera > 0 { Thread.sleep(forTimeInterval: espera) }
    }
  }

  private func convertir(_ entrada: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    let razon = formatoDeSalida.sampleRate / entrada.format.sampleRate
    let capacidad = AVAudioFrameCount(ceil(Double(entrada.frameLength) * razon)) + 1
    guard let salida = AVAudioPCMBuffer(pcmFormat: formatoDeSalida, frameCapacity: capacidad)
    else { return nil }

    var entregado = false
    var error: NSError?
    let estado = conversor.convert(to: salida, error: &error) { _, estadoDeEntrada in
      if entregado {
        estadoDeEntrada.pointee = .noDataNow
        return nil
      }
      entregado = true
      estadoDeEntrada.pointee = .haveData
      return entrada
    }
    guard error == nil, estado == .haveData || estado == .inputRanDry else { return nil }
    return salida
  }

  private func publicarNivel(de buffer: AVAudioPCMBuffer) {
    guard let nivel, let muestras = buffer.floatChannelData?[0], buffer.frameLength > 0
    else { return }
    let rms = vDSP.rootMeanSquare(
      UnsafeBufferPointer(start: muestras, count: Int(buffer.frameLength))
    )
    let db = 20 * log10(max(rms, .leastNormalMagnitude))
    nivel(min(1, max(0, (db + 50) / 50)))
  }
}
#endif
