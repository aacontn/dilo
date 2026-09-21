import AVFAudio
import DiloEngines
import Foundation

/// La captura de micrófono de Talkify puesta detrás del contrato que pide
/// `DiloEngines`.
///
/// Existe para que el motor Parakeet reciba el mismo audio que Apple, con la
/// recuperación de cambio de ruta de los audífonos Bluetooth ya resuelta, sin
/// que `DiloCore` tenga que ver el árbol de la app.
final class MicrophoneCapture: AudioCapture {
  /// `MicrophoneInput` se arma y se bota en cada sesión, y `detener()` puede
  /// llegar desde otro hilo que `iniciar()`.
  private final class Caja: @unchecked Sendable {
    private let candado = NSLock()
    private var input: MicrophoneInput?

    func guardar(_ nuevo: MicrophoneInput?) {
      candado.withLock { input = nuevo }
    }

    func tomar() -> MicrophoneInput? {
      candado.withLock {
        defer { input = nil }
        return input
      }
    }
  }

  private let caja = Caja()

  func iniciar(
    sampleRate: Double,
    muestras: @escaping @Sendable ([Float]) -> Void,
    nivel: @escaping @Sendable (Float) -> Void,
    falla: @escaping @Sendable (String) -> Void
  ) throws {
    guard let formato = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: 1,
      interleaved: false
    ) else {
      throw EngineError.sinMicrofono
    }

    let input = MicrophoneInput(
      sink: { buffer in
        guard let canal = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return true }
        muestras(Array(UnsafeBufferPointer(start: canal, count: Int(buffer.frameLength))))
        // El motor acumula en memoria: nunca hay contrapresión que reportar.
        return true
      },
      onEnd: {},
      failureHandler: { falla($0.localizedDescription) },
      levelHandler: nivel
    )

    do {
      try input.start(outputFormat: formato)
    } catch {
      throw error
    }
    caja.guardar(input)
  }

  func detener() {
    caja.tomar()?.stop()
  }
}
