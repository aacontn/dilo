import DiloReuniones
import FluidAudio
import Foundation

/// La huella de una voz: un embedding de CAM++ (192 números), para reconocer
/// a la misma persona en otra reunión (spec, «Voces que se recuerdan», F2).
///
/// En la Fase 1 sólo la usa el banco, para medir qué similitud da la misma
/// persona en dos archivos y de ahí sacar el umbral. Es dato biométrico de
/// otras personas: vive sólo en el Mac y nunca va a Claude ni al MCP.
public actor HuellasDeVoz {
  public let carpetaDeModelos: URL
  private var embedder: CampPlusEmbedder?

  public init(carpetaDeModelos: URL) {
    self.carpetaDeModelos = carpetaDeModelos
  }

  public func preparar() async throws {
    guard embedder == nil else { return }
    let carpeta = carpetaDeModelos.appending(path: Repo.campPlus.folderName, directoryHint: .isDirectory)
    if !CampPlusModels.modelsExist(at: carpeta) {
      try FileManager.default.createDirectory(at: carpetaDeModelos, withIntermediateDirectories: true)
      try await ModelHub.download(.campPlus, to: carpetaDeModelos)
    }
    embedder = CampPlusEmbedder(models: try CampPlusModels.load(from: carpeta))
  }

  /// La huella de los tramos de una voz, juntos. Con menos de 1 s no hay
  /// huella que valga.
  public func huella(de muestras: [Float]) async throws -> [Float]? {
    try await preparar()
    guard muestras.count >= 16_000, let embedder else { return nil }
    return try await embedder.embed(audio: muestras)
  }

  public func soltar() { embedder = nil }

  /// Similitud coseno de dos huellas ya normalizadas.
  public static func similitud(_ a: [Float], _ b: [Float]) -> Float {
    CampPlusEmbedder.cosine(a, b)
  }
}
