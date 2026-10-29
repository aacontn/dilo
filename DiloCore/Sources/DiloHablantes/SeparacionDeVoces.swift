import CoreML
import DiloReuniones
import FluidAudio
import Foundation
import os

/// Quién habló en una pista: corre el diarizador elegido sobre el archivo
/// entero y devuelve la actividad de cada hablante (spec, «Quién habló»).
///
/// Los modelos se bajan a pedido la primera vez y se sueltan al terminar:
/// nada de esto está en la RAM hasta que alguien graba una reunión
/// (spec, «Números»). Los diarizadores de FluidAudio no son thread-safe, por
/// eso viven dentro de este actor y nunca salen.
public actor SeparacionDeVoces {
  private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "reuniones")

  /// Dónde se guardan los modelos. FluidAudio les cuelga el nombre del repo.
  public let carpetaDeModelos: URL
  /// Las unidades de cómputo para Core ML. `.all` deja que el sistema elija
  /// Neural Engine, GPU o CPU según el modelo.
  public let computo: MLComputeUnits

  private var nemotron: (Diarizador, Nemotron3Diarizer)?
  private var otro: (Diarizador, any Diarizer)?
  /// VBx no se guarda cargado: su manager no es `Sendable` y su `process`
  /// corre fuera del actor. Se arma uno por archivo; los modelos ya quedan en
  /// disco desde `preparar`.
  private var vbxListo = false

  public init(carpetaDeModelos: URL, computo: MLComputeUnits = .all) {
    self.carpetaDeModelos = carpetaDeModelos
    self.computo = computo
  }

  /// Baja (si hace falta) y carga el modelo. `avance` va de 0 a 1.
  public func preparar(_ diarizador: Diarizador, avance: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
    let manejador: ProgressHandler = { avance($0.fractionCompleted) }
    do {
      try FileManager.default.createDirectory(at: carpetaDeModelos, withIntermediateDirectories: true)
      switch diarizador {
      case .nemotron3Fast32, .nemotron3Fast32W8A8, .nemotron3C128W8A8, .nemotron3Offline:
        if nemotron?.0 == diarizador { return }
        guard let config = diarizador.configDeNemotron else { throw FallaDeLaSeparacion.modeloNoDisponible("preset") }
        let modelos = try await Nemotron3Models.loadFromHuggingFace(
          config: config, cacheDirectory: carpetaDeModelos, computeUnits: computo, progressHandler: manejador
        )
        nemotron = (diarizador, Nemotron3Diarizer(config: config, models: modelos))
      case .sortformer:
        if otro?.0 == diarizador { return }
        let config = SortformerConfig.balancedV2_1
        let modelos = try await SortformerModels.loadFromHuggingFace(
          config: config, cacheDirectory: carpetaDeModelos, progressHandler: manejador
        )
        let sortformer = SortformerDiarizer(config: config)
        sortformer.initialize(models: modelos)
        otro = (diarizador, sortformer)
      case .lseend:
        if otro?.0 == diarizador { return }
        let lseend = LSEENDDiarizer()
        try await lseend.initialize(variant: .dihard3, cacheDirectory: carpetaDeModelos, progressHandler: manejador)
        otro = (diarizador, lseend)
      case .vbx:
        if vbxListo { return }
        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels(directory: carpetaDeModelos)
        vbxListo = true
      }
      avance(1)
    } catch let falla as FallaDeLaSeparacion {
      throw falla
    } catch {
      Self.logger.error("No se pudo preparar \(diarizador.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
      throw FallaDeLaSeparacion.modeloNoDisponible(error.localizedDescription)
    }
  }

  /// Separa las voces de una pista hecha de una o varias partes. `avance` va
  /// de 0 a 1, por el audio ya leído.
  public func separar(
    _ diarizador: Diarizador, audio: LectorDeAudio, avance: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws -> ActividadDeHablantes {
    try await preparar(diarizador)
    let total = max(audio.totalDeMuestras, 1)
    guard audio.totalDeMuestras > 0 else { throw FallaDeLaSeparacion.sinAudio }
    do {
      switch diarizador {
      case .nemotron3Fast32, .nemotron3Fast32W8A8, .nemotron3C128W8A8, .nemotron3Offline:
        guard let (_, modelo) = nemotron else { throw FallaDeLaSeparacion.modeloNoDisponible("Nemotron 3") }
        return try Self.separarConNemotron(modelo, audio: audio, total: total, avance: avance)
      case .sortformer, .lseend:
        guard let (_, modelo) = otro else { throw FallaDeLaSeparacion.modeloNoDisponible(diarizador.rawValue) }
        return try Self.separarEnStreaming(modelo, audio: audio, total: total, avance: avance)
      case .vbx:
        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels(directory: carpetaDeModelos)
        let muestras = try audio.todo()
        let resultado = try await manager.process(audio: muestras)
        avance(1)
        return Self.actividad(de: resultado.segments, duracion: Double(muestras.count) / 16_000)
      }
    } catch let falla as FallaDeLaSeparacion {
      throw falla
    } catch {
      throw FallaDeLaSeparacion.procesando(error.localizedDescription)
    }
  }

  /// Suelta los modelos de la RAM. La próxima reunión los vuelve a cargar del
  /// disco, sin bajarlos.
  public func soltar() {
    nemotron = nil
    otro?.1.cleanup()
    otro = nil
    vbxListo = false
  }

  /// Nemotron 3 por su camino en vivo, trozo a trozo: es exacto cuadro a
  /// cuadro con `processComplete` (documentación de FluidAudio) y no necesita
  /// la hora entera en la RAM.
  static func separarConNemotron(
    _ modelo: Nemotron3Diarizer, audio: LectorDeAudio, total: Int, avance: @Sendable (Double) -> Void
  ) throws -> ActividadDeHablantes {
    modelo.reset()
    var probabilidades: [Float] = []
    var leidas = 0
    try audio.recorrer { trozo in
      try autoreleasepool {
        modelo.appendAudio(trozo)
        for resultado in try modelo.processBufferedAudio() { probabilidades += resultado.probabilities }
      }
      leidas += trozo.count
      avance(Double(leidas) / Double(total))
    }
    for resultado in try modelo.finishStream() { probabilidades += resultado.probabilities }
    return ActividadDeHablantes(
      segundosPorCuadro: Double(modelo.config.outputFrameSeconds),
      hablantes: modelo.config.numSpeakers,
      probabilidades: probabilidades
    )
  }

  /// Sortformer y LS-EEND por el contrato común de FluidAudio, en vivo y
  /// cerrando la sesión al final para que el último tramo quede firme.
  static func separarEnStreaming(
    _ modelo: any Diarizer, audio: LectorDeAudio, total: Int, avance: @Sendable (Double) -> Void
  ) throws -> ActividadDeHablantes {
    modelo.reset()
    var leidas = 0
    try audio.recorrer { trozo in
      try autoreleasepool { _ = try modelo.process(samples: trozo, sourceSampleRate: nil) }
      leidas += trozo.count
      avance(Double(leidas) / Double(total))
    }
    try modelo.finalizeSession()
    let linea = modelo.timeline
    return ActividadDeHablantes(
      segundosPorCuadro: Double(linea.config.frameDurationSeconds),
      hablantes: max(linea.config.numSpeakers, 1),
      probabilidades: Array(linea.finalizedPredictions.prefix(linea.numFinalizedFrames * max(linea.config.numSpeakers, 1)))
    )
  }

  /// Los segmentos de VBx como actividad de 10 ms. Los ids de VBx son texto
  /// («S1», «S2»…); se numeran por orden de llegada.
  static func actividad(de segmentos: [TimedSpeakerSegment], duracion: Double) -> ActividadDeHablantes {
    var indices: [String: Int] = [:]
    let ordenados = segmentos.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
    for segmento in ordenados where indices[segmento.speakerId] == nil {
      indices[segmento.speakerId] = indices.count
    }
    return ActividadDeHablantes.desde(
      segmentos: ordenados.map {
        .init(
          hablante: indices[$0.speakerId] ?? 0, desde: Double($0.startTimeSeconds), hasta: Double($0.endTimeSeconds)
        )
      },
      hablantes: max(indices.count, 1),
      duracion: duracion
    )
  }
}
