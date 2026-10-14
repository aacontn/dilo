import AVFAudio
import DiloEngines
import Foundation

/// La captura de micrófono de la app puesta detrás del contrato que pide
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
  /// La copia en RAM de cada dictado: la misma grabadora que usa Apple, así
  /// que reintentar no depende de qué motor escuchó.
  private let grabadora: GrabadoraEnRAM?
  /// El mismo micrófono de sesión que usa Apple.
  private let microfono: MicrofonoDeLaSesion?

  init(grabadora: GrabadoraEnRAM? = nil, microfono: MicrofonoDeLaSesion? = nil) {
    self.grabadora = grabadora
    self.microfono = microfono
  }

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
      levelHandler: nivel,
      grabadora: grabadora,
      microfono: microfono
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
