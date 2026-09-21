import Foundation

/// Lo mínimo para hablar con las herramientas de macOS que ya miden bien.
///
/// Medir memoria y CPU de otro proceso desde Swift puro exige el task port del
/// otro proceso, que macOS no regala. `footprint` sí lo tiene, viene con el
/// sistema y da exactamente el número que usa el kernel. Pedírselo es más
/// honesto que aproximarlo.
public enum Concha {
  public struct Resultado: Sendable {
    public let salida: String
    public let error: String
    public let codigo: Int32
  }

  /// Lanza sin esperar. Para el clic que para el dictado: si se esperara a que
  /// `osascript` termine antes de empezar a mirar el portapapeles, el texto
  /// podría llegar durante esa espera y la latencia medida saldría inflada por
  /// el tiempo del AppleScript, que no es de Dilo.
  public static func lanzar(_ ejecutable: String, _ argumentos: [String]) throws -> Process {
    let proceso = Process()
    proceso.executableURL = URL(fileURLWithPath: ejecutable)
    proceso.arguments = argumentos
    proceso.standardOutput = FileHandle.nullDevice
    proceso.standardError = FileHandle.nullDevice
    try proceso.run()
    return proceso
  }

  @discardableResult
  public static func correr(
    _ ejecutable: String,
    _ argumentos: [String],
    ambiente: [String: String]? = nil
  ) throws -> Resultado {
    let proceso = Process()
    proceso.executableURL = URL(fileURLWithPath: ejecutable)
    proceso.arguments = argumentos
    if let ambiente {
      proceso.environment = ProcessInfo.processInfo.environment.merging(ambiente) { _, nuevo in nuevo }
    }
    let salida = Pipe()
    let error = Pipe()
    proceso.standardOutput = salida
    proceso.standardError = error
    try proceso.run()
    // Leer antes de esperar: una salida larga llena el pipe y cuelga al hijo.
    let datosSalida = salida.fileHandleForReading.readDataToEndOfFile()
    let datosError = error.fileHandleForReading.readDataToEndOfFile()
    proceso.waitUntilExit()
    return Resultado(
      salida: String(decoding: datosSalida, as: UTF8.self),
      error: String(decoding: datosError, as: UTF8.self),
      codigo: proceso.terminationStatus
    )
  }
}

public struct ErrorDeMedicion: LocalizedError {
  public let mensaje: String
  public init(_ mensaje: String) { self.mensaje = mensaje }
  public var errorDescription: String? { mensaje }
}
