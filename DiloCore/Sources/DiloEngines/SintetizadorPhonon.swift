import AVFAudio
import Foundation

/// Un trozo de texto dicho por Phonon 40m: corre el CLI `ptts` una vez por
/// trozo y devuelve las muestras.
///
/// Un proceso por trozo y no uno vivo: el CLI no tiene modo servidor ni saca
/// audio por la salida estándar, y arrancar le cuesta poco —0,2 s de punta a
/// punta para una frase corta en un M1, con el modelo cuantizado en 8 bits
/// mapeado y no copiado—. A cambio, entre lecturas no queda nada cargado:
/// los ~200 MB del modelo existen sólo mientras el proceso habla, y la app
/// sigue en sus 60 MB de reposo (spec §3).
///
/// Detener mata el proceso en curso (`terminate`), así que no hay que esperar
/// a que termine su trozo.
public struct SintetizadorPhonon: Sendable {
  public static let frecuencia: Double = 24_000

  /// Dos hilos: en un M1 rinde lo mismo que cuatro y deja libres los núcleos
  /// para la app de adelante. Medido en el banco de voces.
  static let hilos = 2

  private let instalacion: InstalacionDePhonon

  public init(instalacion: InstalacionDePhonon) {
    self.instalacion = instalacion
  }

  public func sintetizar(_ texto: String, voz: VozDePhonon) async throws -> [Float] {
    let ejecutable = try await instalacion.ejecutableListo()
    let salida = FileManager.default.temporaryDirectory
      .appendingPathComponent("dilo-lectura-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: salida) }

    let proceso = Process()
    proceso.executableURL = ejecutable
    proceso.arguments = Self.argumentos(
      texto: texto, voz: InstalacionDePhonon.archivoDeVoz(voz),
      modelo: InstalacionDePhonon.carpetaDelModelo, salida: salida
    )
    proceso.environment = Self.entorno
    proceso.standardOutput = FileHandle.nullDevice
    proceso.standardError = FileHandle.nullDevice

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
        proceso.terminationHandler = { p in
          if p.terminationStatus == 0 {
            cont.resume()
          } else {
            cont.resume(throwing: FallaDeLectura.motorFallo(Int(p.terminationStatus)))
          }
        }
        do {
          try proceso.run()
        } catch {
          proceso.terminationHandler = nil
          cont.resume(throwing: error)
        }
      }
    } onCancel: {
      if proceso.isRunning { proceso.terminate() }
    }
    try Task.checkCancellation()
    return try Self.leerWAV(salida)
  }

  /// El texto llega ya dicho por `TextoParaLeer`, y `--lang es` deja que el
  /// normalizador del propio Phonon termine lo que aquél no tocó. En el banco
  /// de voces, con Regina e Iker, el normalizador de Phonon solo (con todas
  /// sus reglas, fechas y horas incluidas) dejó 8,6 % de WER y los dos juntos
  /// 5,6 %: leía «15/03/2026» como «1503-2026» y «3,5 UF» como «tres coma
  /// cinco unidades».
  static func argumentos(texto: String, voz: URL, modelo: URL, salida: URL) -> [String] {
    [
      "--model", modelo.path, "--lang", "es", "--quant", "q8",
      "--threads", String(hilos), "--voice", voz.path, texto, "-o", salida.path,
    ]
  }

  /// Sin red y sin escribir en `~/.cache`: el modelo y la voz son archivos
  /// locales, y si algo intentara ir a Hugging Face tiene que fallar, no
  /// colgarse esperando.
  static var entorno: [String: String] {
    let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dilo/phonon").path
    return [
      "RUST_LOG": "off",
      "HF_HUB_OFFLINE": "1",
      "HF_HOME": cache,
      "HOME": NSHomeDirectory(),
      "PATH": "/usr/bin:/bin",
    ]
  }

  static func leerWAV(_ url: URL) throws -> [Float] {
    let archivo = try AVAudioFile(forReading: url)
    guard let bufer = AVAudioPCMBuffer(
      pcmFormat: archivo.processingFormat, frameCapacity: AVAudioFrameCount(archivo.length)
    ) else { return [] }
    try archivo.read(into: bufer)
    guard let canal = bufer.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: canal, count: Int(bufer.frameLength)))
  }
}

public enum FallaDeLectura: Error, Equatable, Sendable {
  case motorFallo(Int)
}
