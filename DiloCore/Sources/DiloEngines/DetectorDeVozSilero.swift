import FluidAudio
import Foundation

/// El detector de voz de la **escucha de nombres** y del guion en vivo de una
/// reunión: Silero v6 en Core ML, por
/// FluidAudio, un trozo de 256 ms a la vez con su estado.
///
/// Es lo que corre todo el rato con la escucha prendida, y por eso es lo que
/// fija cuánto gasta en una pieza callada: medido en la espiga del
/// 2026-10-30, por debajo del 1 % de un núcleo de un M1. El **Motor de voz**
/// sólo corre cuando esto dice que hay voz (`VentanaDeEscucha`).
///
/// El modelo pesa ~1 MB y se baja la primera vez que se prende la escucha o
/// que se graba una reunión, a la carpeta de modelos de Dilo: en los dos casos
/// lo pidió la persona. Nada más lo baja.
public actor DetectorDeVozSilero {
  /// 4.096 muestras a 16 kHz: el trozo para el que está hecho el modelo.
  public static let trozo = VadManager.chunkSize

  /// Dónde vive el modelo: `models/vad/Models/silero-vad/` dentro de la
  /// carpeta de Dilo (FluidAudio agrega `Models/` y el nombre del repo).
  public static var carpeta: URL {
    ParakeetModelStore.carpeta.appendingPathComponent("vad", isDirectory: true)
  }

  private let carpeta: URL
  private var manager: VadManager?
  private var estado = VadStreamState.initial()

  public init(carpeta: URL = DetectorDeVozSilero.carpeta) {
    self.carpeta = carpeta
  }

  /// La probabilidad de voz del trozo, de 0 a 1. La primera vez carga el
  /// modelo (y lo baja si no está).
  public func probabilidad(_ trozo: [Float]) async throws -> Float {
    let manager = try await cargado()
    let resultado = try await manager.processStreamingChunk(trozo, state: estado, config: .default)
    estado = resultado.state
    return resultado.probability
  }

  /// Carga el modelo, y lo baja si no está. Falla sin red la primera vez.
  public func preparar() async throws {
    _ = try await cargado()
  }

  /// Si el modelo ya está en disco: sin él, prender la escucha lo baja.
  public static var estaDescargado: Bool {
    let modelo = carpeta.appendingPathComponent("Models/silero-vad/\(ModelNames.VAD.sileroVadFile)")
    return FileManager.default.fileExists(atPath: modelo.path)
  }

  /// Lo que viene no sigue a lo anterior: se pausó la escucha.
  public func reiniciar() {
    estado = VadStreamState.initial()
  }

  private func cargado() async throws -> VadManager {
    if let manager { return manager }
    // Sólo se lee la probabilidad: el corte lo pone `VentanaDeEscucha`.
    let nuevo = try await VadManager(config: .default, modelDirectory: carpeta)
    manager = nuevo
    return nuevo
  }
}
