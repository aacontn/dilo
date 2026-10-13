import AVFAudio
import Foundation

/// Audio fabricado para las pruebas: silencio, ruido de sala, un tono que
/// pasa por voz y voz de verdad sintetizada con `say`. Nada de esto toca el
/// micrófono; lo que se escribe a disco es un WAV temporal que se borra al
/// leerlo.
enum AudioDePrueba {
  static let tasa = 16_000

  static func silencio(segundos: Double) -> [Float] {
    [Float](repeating: 0, count: Int(segundos * Double(tasa)))
  }

  /// Ruido blanco parejo de amplitud `amplitud`, con semilla fija para que
  /// una prueba que falla vuelva a fallar igual.
  static func ruido(segundos: Double, amplitud: Float, semilla: UInt64 = 7) -> [Float] {
    var estado = semilla
    return (0..<Int(segundos * Double(tasa))).map { _ in
      // xorshift64: barato y reproducible, que es todo lo que pide un ruido
      // de sala de mentira.
      estado ^= estado << 13
      estado ^= estado >> 7
      estado ^= estado << 17
      return amplitud * (Float(estado % 20_001) / 10_000 - 1)
    }
  }

  /// Un tono que el detector de energía toma por voz: la medida no oye
  /// palabras, oye nivel.
  static func tono(segundos: Double, amplitud: Float = 0.1) -> [Float] {
    (0..<Int(segundos * Double(tasa))).map { amplitud * Float(sin(Double($0) * 0.05)) }
  }

  /// Si esta máquina puede sintetizar voz en español. En un runner sin voces
  /// las pruebas que la piden se saltan con esa razón.
  static var haySintesis: Bool {
    FileManager.default.isExecutableFile(atPath: "/usr/bin/say")
  }

  /// `texto` dicho por la voz española del sistema, a 16 kHz mono.
  static func voz(_ texto: String, voz: String = "Mónica") throws -> [Float] {
    let wav = FileManager.default.temporaryDirectory
      .appendingPathComponent("dilo-prueba-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: wav) }

    let say = Process()
    say.executableURL = URL(filePath: "/usr/bin/say")
    say.arguments = ["-v", voz, "-o", wav.path, "--data-format=LEI16@16000", texto]
    try say.run()
    say.waitUntilExit()
    guard say.terminationStatus == 0 else { throw FallaDeAudio.sinVoz }

    let archivo = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard let buffer = AVAudioPCMBuffer(
      pcmFormat: archivo.processingFormat, frameCapacity: AVAudioFrameCount(archivo.length)
    ) else { throw FallaDeAudio.sinVoz }
    try archivo.read(into: buffer)
    guard let canal = buffer.floatChannelData?[0] else { throw FallaDeAudio.sinVoz }
    return Array(UnsafeBufferPointer(start: canal, count: Int(buffer.frameLength)))
  }

  enum FallaDeAudio: Error { case sinVoz }
}
