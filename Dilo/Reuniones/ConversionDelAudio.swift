import AVFAudio
import DiloReuniones
import Foundation
import os

/// Lo que se hace con el audio de una reunión lista (spec, «Cuánto dura»):
/// los WAV pasan a AAC de 32 kbps y, según el ajuste, el audio va a la
/// Papelera a los 30 días o al terminar. El guion se queda para siempre, y
/// Dilo nunca borra nada en definitivo.
enum ConversionDelAudio {
  private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "reuniones")

  /// Aplica la retención a todas las reuniones. Corre en segundo plano y sin
  /// modelos: es leer `reunion.json` y, a veces, convertir un archivo.
  static func aplicar(_ reuniones: [ReunionEnDisco], politica: PoliticaDelAudio, ahora: Date = Date()) {
    for enDisco in reuniones {
      switch RetencionDelAudio.accion(
        para: enDisco.reunion, politica: politica, enElRespaldo: enDisco.enElRespaldo, ahora: ahora
      ) {
      case .nada: continue
      case .pasarAAAC: pasarAAAC(enDisco)
      case .aLaPapelera: aLaPapelera(enDisco)
      }
    }
  }

  static func pasarAAAC(_ enDisco: ReunionEnDisco) {
    var reunion = enDisco.reunion
    var convertidas: [URL] = []
    for i in reunion.pistas.indices {
      var partes: [String] = []
      for parte in reunion.pistas[i].partes {
        guard parte.hasSuffix(".wav") else {
          partes.append(parte)
          continue
        }
        let nombre = RetencionDelAudio.nombreAAC(de: parte)
        do {
          try convertir(enDisco.archivo(parte), a: enDisco.archivo(nombre))
          partes.append(nombre)
          convertidas.append(enDisco.archivo(parte))
        } catch {
          logger.error("No pude pasar a AAC: \(error.localizedDescription, privacy: .public)")
          return
        }
      }
      reunion.pistas[i].partes = partes
    }
    reunion.audio = .aac
    do {
      try EscritorDeReunion.guardar(reunion, en: enDisco.carpeta)
    } catch {
      return
    }
    // Sólo con el reunion.json nuevo en disco: si no, la reunión nombraría
    // archivos que ya no están.
    for wav in convertidas { try? FileManager.default.trashItem(at: wav, resultingItemURL: nil) }
  }

  static func aLaPapelera(_ enDisco: ReunionEnDisco) {
    var reunion = enDisco.reunion
    let archivos = reunion.archivosDeAudio.map(enDisco.archivo)
    reunion.audio = .borrado
    for i in reunion.pistas.indices { reunion.pistas[i].partes = [] }
    guard (try? EscritorDeReunion.guardar(reunion, en: enDisco.carpeta)) != nil else { return }
    for archivo in archivos where FileManager.default.fileExists(atPath: archivo.path(percentEncoded: false)) {
      try? FileManager.default.trashItem(at: archivo, resultingItemURL: nil)
    }
  }

  /// WAV de 16 kHz a AAC de 32 kbps, mono: ~14 MB por hora por pista.
  static func convertir(_ wav: URL, a destino: URL) throws {
    let entrada = try AVAudioFile(forReading: wav)
    let ajustes: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: entrada.fileFormat.sampleRate,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 32_000,
    ]
    try? FileManager.default.removeItem(at: destino)
    let salida = try AVAudioFile(
      forWriting: destino, settings: ajustes, commonFormat: .pcmFormatFloat32, interleaved: false
    )
    guard let buffer = AVAudioPCMBuffer(pcmFormat: entrada.processingFormat, frameCapacity: 65_536) else {
      throw CocoaError(.fileWriteUnknown)
    }
    while entrada.framePosition < entrada.length {
      try entrada.read(into: buffer)
      if buffer.frameLength == 0 { break }
      try salida.write(from: buffer)
    }
  }

  static func duracion(_ url: URL) -> Double {
    guard let archivo = try? AVAudioFile(forReading: url) else { return 0 }
    return Double(archivo.length) / archivo.fileFormat.sampleRate
  }
}
