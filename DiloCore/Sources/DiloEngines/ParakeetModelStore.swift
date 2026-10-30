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

/// Un modelo de Parakeet en disco —v3 o Ultra—: dónde vive, si está, cuánto
/// pesa, cómo se baja y cómo se manda a la Papelera.
///
/// Vive en `~/Library/Application Support/Dilo/models/<carpeta del repo>/` y
/// no en la carpeta que FluidAudio elige sola (`…/FluidAudio/Models/`): el
/// modelo es de Dilo y se borra con Dilo. La base se puede cambiar
/// (`carpeta:`) para que el banco de comparación y las mediciones bajen a
/// `/Volumes/SSD2` sin tocar el disco interno.
public actor ParakeetModelStore {
  private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "engines")

  /// La variante int8 del encoder de v3: es la que FluidAudio trae por
  /// defecto y la que Dilo bajó siempre. Ultra tiene un solo encoder y
  /// FluidAudio ignora este parámetro para ella.
  private static let precision: ParakeetEncoderPrecision = .int8

  /// La carpeta de los modelos de la app.
  public static var carpeta: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base
      .appendingPathComponent("Dilo", isDirectory: true)
      .appendingPathComponent("models", isDirectory: true)
  }

  /// Qué variantes están completas en disco **ahora**. Se pregunta cada vez
  /// y no se cachea: una descarga termina con la app abierta.
  public static func enDisco(en carpeta: URL = carpeta) -> Set<VarianteDeParakeet> {
    Set(VarianteDeParakeet.allCases.filter { estaDescargado($0, en: carpeta) })
  }

  /// La carpeta exacta de una variante. FluidAudio arma la ruta real
  /// quitándole el último componente a lo que uno le pasa y pegándole el
  /// nombre del repo, así que pasarle esta misma URL deja los archivos justo
  /// acá.
  public static func carpetaDelModelo(_ variante: VarianteDeParakeet, en carpeta: URL = carpeta) -> URL {
    carpeta.appendingPathComponent(variante.nombreDeCarpeta, isDirectory: true)
  }

  public static func estaDescargado(_ variante: VarianteDeParakeet, en carpeta: URL = carpeta) -> Bool {
    AsrModels.modelsExist(
      at: carpetaDelModelo(variante, en: carpeta),
      version: variante.version,
      encoderPrecision: precision
    )
  }

  /// Lo que ocupa en disco, en bytes. Cero cuando no está.
  public static func tamanoEnDisco(_ variante: VarianteDeParakeet, en carpeta: URL = carpeta) -> Int64 {
    // Resuelto: en el taller la carpeta puede ser un enlace al modelo de la
    // app, y el enumerador no entra por un enlace.
    guard let enumerador = FileManager.default.enumerator(
      at: carpetaDelModelo(variante, en: carpeta).resolvingSymlinksInPath(),
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

  public nonisolated let variante: VarianteDeParakeet
  public nonisolated let carpeta: URL
  private var descarga: Task<Void, any Error>?

  public init(variante: VarianteDeParakeet, carpeta: URL = ParakeetModelStore.carpeta) {
    self.variante = variante
    self.carpeta = carpeta
  }

  public nonisolated var carpetaDelModelo: URL { Self.carpetaDelModelo(variante, en: carpeta) }
  public nonisolated var estaDescargado: Bool { Self.estaDescargado(variante, en: carpeta) }

  public var descargando: Bool { descarga != nil }

  /// Baja el modelo, informando el avance. Vuelve al tiro si ya estaba.
  ///
  /// Dos llamadas seguidas esperan la misma descarga en vez de arrancar una
  /// segunda: apretar el botón dos veces no debería bajar el modelo dos veces.
  public func descargar(
    progreso: @escaping @Sendable (ProgresoDeDescarga) -> Void
  ) async throws {
    if estaDescargado { return }

    if let descarga {
      try await descarga.value
      return
    }

    let base = carpeta
    let destino = carpetaDelModelo
    let version = variante.version
    let precision = Self.precision
    let tarea = Task { () throws -> Void in
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
      _ = try await AsrModels.download(
        to: destino,
        version: version,
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
      Self.logger.info("modelo \(self.variante.rawValue, privacy: .public) de Parakeet listo en disco")
    } catch {
      descarga = nil
      // Una descarga a medias deja archivos que `modelsExist` da por buenos
      // y que después revientan al cargar. El pedazo se borra de verdad, no
      // a la Papelera: no es nada de la persona, es basura de red.
      if !estaDescargado { try? FileManager.default.removeItem(at: destino) }
      throw error
    }
  }

  /// Corta la descarga en curso. Lo que alcanzó a bajar se borra.
  public func cancelarDescarga() {
    descarga?.cancel()
    descarga = nil
  }

  /// Manda el modelo a la Papelera. **Nunca un borrado definitivo**: son
  /// cientos de megas que costó bajar, y quien comparó las dos variantes
  /// puede querer volver sin esperar otra descarga.
  public func moverALaPapelera() throws {
    cancelarDescarga()
    guard FileManager.default.fileExists(atPath: carpetaDelModelo.path) else { return }
    try FileManager.default.trashItem(at: carpetaDelModelo, resultingItemURL: nil)
  }

  /// Carga los modelos ya bajados. No baja nada: si falta, es un error que
  /// la capa de arriba convierte en caída a Apple.
  func cargar() async throws -> AsrModels {
    guard estaDescargado else { throw EngineError.modeloNoDescargado }
    return try await AsrModels.load(
      from: carpetaDelModelo,
      version: variante.version,
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
