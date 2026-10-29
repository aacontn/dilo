import DiloEngines
import DiloHablantes
import DiloReuniones
import Foundation
import os

/// La segunda pasada, al terminar (spec, «Terminar»): Parakeet sobre el
/// archivo entero de cada pista, quién habló en `ellos`, y el guion escrito.
/// Es la que manda: corrige palabra a palabra, no reemplaza bloques.
///
/// Los modelos se bajan a pedido la primera vez y se sueltan al terminar. El
/// avance que publica es real: el de cada etapa por el audio ya leído.
struct PasadaFinal: Sendable {
  private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "reuniones")
  static let versionDelMotor = "Parakeet TDT v3 int8 (FluidAudio 0.18.0)"

  let parakeet: ParakeetEngine
  let separacion: SeparacionDeVoces

  /// Afina una reunión y devuelve cómo quedó. Nunca lanza: lo que falla queda
  /// escrito en `reunion.falla`, con su arreglo, y la reunión se puede volver
  /// a afinar.
  func afinar(
    _ enDisco: ReunionEnDisco,
    diarizador preferido: Diarizador,
    avance: @escaping @Sendable (AvanceDeLaPasada) -> Void
  ) async -> Reunion {
    var reunion = enDisco.reunion
    guard ReparacionDeReuniones.partesQueFaltan(enDisco).isEmpty else {
      // Una parte quedó en el SSD que no está: se afina cuando vuelva.
      return reunion
    }
    reunion.estado = .afinando
    reunion.falla = nil
    guardar(reunion, en: enDisco)
    defer { Task { await separacion.soltar() } }

    avance(AvanceDeLaPasada(etapa: .preparando))
    let palabrasDeYo: [PalabraDeLaPista]
    let palabrasDeEllos: [PalabraDeLaPista]
    do {
      palabrasDeYo = try await transcribir(.yo, de: enDisco, etapa: .transcribiendoYo, avance: avance)
      palabrasDeEllos = try await transcribir(.ellos, de: enDisco, etapa: .transcribiendoEllos, avance: avance)
    } catch {
      Self.logger.error("La pasada no pudo transcribir: \(error.localizedDescription, privacy: .public)")
      reunion.falla = (error as? EngineError) == .modeloNoDescargado
        ? String(localized: "Falta el modelo de voz: bájalo en Ajustes → Motor de voz y vuelve a afinar.")
        : String(localized: "No pude transcribir la reunión (\(error.localizedDescription)). Vuelve a afinarla.")
      guardar(reunion, en: enDisco)
      return reunion
    }

    // Quién habló, sólo si la llamada dijo algo. Nemotron 3 de fábrica; si
    // falla, Sortformer; si también, el guion sale igual con una sola voz
    // para la llamada y lo dice.
    var actividad: ActividadDeHablantes?
    var notaDeVoces: String?
    let audioDeEllos = lector(.ellos, de: enDisco)
    if !palabrasDeEllos.isEmpty, audioDeEllos.totalDeMuestras > 0 {
      let candidatos = preferido.esNemotron ? [preferido, .sortformer] : [preferido]
      for diarizador in candidatos {
        do {
          actividad = try await separacion.separar(diarizador, audio: audioDeEllos) { fraccion in
            avance(AvanceDeLaPasada(etapa: .separandoVoces, fraccionDeLaEtapa: fraccion))
          }
          reunion.versiones.diarizador = diarizador.version
          notaDeVoces = nil
          break
        } catch {
          Self.logger.error("\(diarizador.rawValue, privacy: .public) no separó las voces: \(error.localizedDescription, privacy: .public)")
          notaDeVoces = String(localized: "Las voces de la llamada no se separaron: \(error.localizedDescription)")
        }
      }
    }

    avance(AvanceDeLaPasada(etapa: .armandoElGuion))
    let armado = ArmadoDelGuion.armar(
      yo: palabrasDeYo, ellos: palabrasDeEllos, actividad: actividad,
      relojes: LectorDeReuniones.relojes(de: enDisco), reunion: reunion
    )
    reunion.hablantes = armado.hablantes
    reunion.versiones.motorDeVoz = Self.versionDelMotor
    reunion.versiones.app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    reunion.estado = .lista
    reunion.afinadaEl = Date()
    reunion.falla = notaDeVoces
    do {
      try EscritorDeReunion.guardarGuion(armado.palabras, reunion: reunion, en: enDisco.carpeta)
    } catch {
      reunion.estado = .afinando
      reunion.falla = String(localized: "No pude escribir el guion: \(error.localizedDescription)")
    }
    guardar(reunion, en: enDisco)
    avance(AvanceDeLaPasada(etapa: .armandoElGuion, fraccionDeLaEtapa: 1))
    Self.logger.notice(
      "Guion listo: \(armado.palabras.count) palabras, \(armado.hablantes.count) hablantes"
    )
    return reunion
  }

  /// Las palabras de una pista, parte por parte, con el tiempo corrido por lo
  /// que duraron las partes anteriores: las anclas cuentan muestras desde la
  /// primera de la pista.
  private func transcribir(
    _ pista: Pista, de enDisco: ReunionEnDisco, etapa: AvanceDeLaPasada.Etapa,
    avance: @escaping @Sendable (AvanceDeLaPasada) -> Void
  ) async throws -> [PalabraDeLaPista] {
    let partes = enDisco.reunion.pista(pista)?.partes ?? []
    let duraciones = partes.map { duracion(enDisco.archivo($0)) }
    let total = max(duraciones.reduce(0, +), 0.001)
    var corrido = 0.0
    var salida: [PalabraDeLaPista] = []
    for (parte, segundos) in zip(partes, duraciones) {
      defer { corrido += segundos }
      // Menos de medio segundo no tiene palabras que valgan una pasada.
      guard segundos >= 0.5 else { continue }
      let desde = corrido
      let palabras = try await parakeet.transcribirArchivoConTiempos(enDisco.archivo(parte)) { fraccion in
        avance(AvanceDeLaPasada(etapa: etapa, fraccionDeLaEtapa: (desde + fraccion * segundos) / total))
      }
      salida += palabras.map { PalabraDeLaPista(texto: $0.texto, desde: $0.inicio + desde, hasta: $0.fin + desde) }
    }
    avance(AvanceDeLaPasada(etapa: etapa, fraccionDeLaEtapa: 1))
    return salida
  }

  private func lector(_ pista: Pista, de enDisco: ReunionEnDisco) -> LectorDeAudio {
    LectorDeAudio(partes: (enDisco.reunion.pista(pista)?.partes ?? []).map(enDisco.archivo))
  }

  /// Segundos de audio de un WAV propio por su tamaño; de otro archivo (un
  /// `.m4a` tras la retención), por AVFoundation.
  private func duracion(_ url: URL) -> Double {
    let tamaño = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int) ?? 0
    if url.pathExtension.lowercased() == "wav" {
      return Double(CabeceraWAV.bytesReales(tamañoDelArchivo: tamaño) / CabeceraWAV.bytesPorMuestra) / 16_000
    }
    return ConversionDelAudio.duracion(url)
  }

  private func guardar(_ reunion: Reunion, en enDisco: ReunionEnDisco) {
    try? EscritorDeReunion.guardar(reunion, en: enDisco.carpeta)
  }
}
