import FluidAudio
import Foundation
import os

/// Cuánto lleva una descarga y en qué va.
///
/// Es un tipo propio y no el de FluidAudio a propósito: la dependencia se
/// queda encerrada en este módulo, y Ajustes no tiene por qué compilar contra
/// ella para dibujar una barra.
public struct ProgresoDeDescarga: Sendable, Equatable {
  public let fraccion: Double
  /// Qué está pasando, en español y listo para mostrar.
  public let fase: String

  public init(fraccion: Double, fase: String) {
    self.fraccion = fraccion
    self.fase = fase
  }
}

/// El modelo de Parakeet v3 en disco: dónde vive, si está, cuánto pesa, cómo
/// se baja y cómo se borra.
///
/// Vive en `~/Library/Application Support/Dilo/models/` y no en la carpeta
/// que FluidAudio elige sola (`…/FluidAudio/Models/`): el modelo es de Dilo,
/// se borra con Dilo, y cuando el target de App Store corra en su contenedor
/// la ruta sigue siendo la misma relativa a Application Support.
public actor ParakeetModelStore {
  private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "engines")

  /// La variante int8: es la que FluidAudio trae por defecto para v3 y la
  /// única que existe publicada para este modelo.
  private static let precision: ParakeetEncoderPrecision = .int8

  public static var carpeta: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base
      .appendingPathComponent("Dilo", isDirectory: true)
      .appendingPathComponent("models", isDirectory: true)
  }

  /// La carpeta exacta del modelo. FluidAudio arma la ruta real quitándole el
  /// último componente a lo que uno le pasa y pegándole el nombre del repo,
  /// así que pasarle esta misma URL deja los archivos justo acá.
  public static var carpetaDelModelo: URL {
    carpeta.appendingPathComponent(Repo.parakeetV3.folderName, isDirectory: true)
  }

  public static var estaDescargado: Bool {
    AsrModels.modelsExist(at: carpetaDelModelo, version: .v3, encoderPrecision: precision)
  }

  /// Lo que ocupa en disco, en bytes. Cero cuando no está.
  public static var tamanoEnDisco: Int64 {
    guard let enumerador = FileManager.default.enumerator(
      at: carpetaDelModelo,
      includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
    ) else { return 0 }

    var total: Int64 = 0
    for case let url as URL in enumerador {
      let valores = try? url.resourceValues(
        forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
      )
      total += Int64(valores?.totalFileAllocatedSize ?? valores?.fileAllocatedSize ?? 0)
    }
    return total
  }

  private var descarga: Task<Void, any Error>?

  public init() {}

  public var descargando: Bool { descarga != nil }

  /// Baja el modelo, informando el avance. Vuelve al tiro si ya estaba.
  ///
  /// Dos llamadas seguidas esperan la misma descarga en vez de arrancar una
  /// segunda: apretar el botón dos veces no debería bajar el modelo dos veces.
  public func descargar(
    progreso: @escaping @Sendable (ProgresoDeDescarga) -> Void
  ) async throws {
    if Self.estaDescargado { return }

    if let descarga {
      try await descarga.value
      return
    }

    let destino = Self.carpetaDelModelo
    let precision = Self.precision
    let tarea = Task { () throws -> Void in
      try FileManager.default.createDirectory(
        at: Self.carpeta, withIntermediateDirectories: true
      )
      _ = try await AsrModels.download(
        to: destino,
        version: .v3,
        encoderPrecision: precision,
        progressHandler: { avance in
          progreso(ProgresoDeDescarga(
            fraccion: avance.fractionCompleted,
            fase: Self.describir(avance.phase)
          ))
        }
      )
    }
    descarga = tarea

    do {
      try await tarea.value
      descarga = nil
      Self.logger.info("modelo de Parakeet listo en disco")
    } catch {
      descarga = nil
      // Una descarga a medias deja archivos que `modelsExist` da por buenos
      // y que después revientan al cargar. Se borra el pedazo.
      if !Self.estaDescargado { try? FileManager.default.removeItem(at: destino) }
      throw error
    }
  }

  /// Corta la descarga en curso. Lo que alcanzó a bajar se borra.
  public func cancelarDescarga() {
    descarga?.cancel()
    descarga = nil
  }

  public func borrar() throws {
    cancelarDescarga()
    guard FileManager.default.fileExists(atPath: Self.carpetaDelModelo.path) else { return }
    try FileManager.default.removeItem(at: Self.carpetaDelModelo)
  }

  /// Carga los modelos ya bajados. No baja nada: si falta, es un error que
  /// la capa de arriba convierte en caída a Apple.
  func cargar() async throws -> AsrModels {
    guard Self.estaDescargado else { throw EngineError.modeloNoDescargado }
    return try await AsrModels.load(
      from: Self.carpetaDelModelo,
      version: .v3,
      encoderPrecision: Self.precision
    )
  }

  private static func describir(_ fase: DownloadPhase) -> String {
    switch fase {
    case .listing:
      "Viendo qué falta…"
    case let .downloading(listos, total):
      total > 0 ? "Bajando \(listos + 1) de \(total)" : "Bajando…"
    case .compiling:
      "Preparando el modelo…"
    }
  }
}
