import FluidAudio
import Foundation

/// Una palabra con su tiempo, en segundos desde el principio del archivo.
public struct PalabraConTiempo: Sendable, Equatable {
  public let texto: String
  public let inicio: TimeInterval
  public let fin: TimeInterval

  public init(texto: String, inicio: TimeInterval, fin: TimeInterval) {
    self.texto = texto
    self.inicio = inicio
    self.fin = fin
  }

  /// Junta los tokens en palabras: un token que abre palabra trae su espacio
  /// adelante (o la `▁` de SentencePiece, si llegó sin traducir); los demás
  /// —el resto de la palabra, la coma— se pegan a la anterior. La palabra va
  /// del inicio de su primer token al fin del último.
  public static func palabras(de tokens: [TokenDeVoz]) -> [PalabraConTiempo] {
    var salida: [PalabraConTiempo] = []
    var texto = ""
    var inicio: TimeInterval = 0
    var fin: TimeInterval = 0

    func cerrar() {
      let limpio = texto.trimmingCharacters(in: .whitespaces)
      if !limpio.isEmpty { salida.append(PalabraConTiempo(texto: limpio, inicio: inicio, fin: fin)) }
      texto = ""
    }

    for token in tokens {
      guard !token.texto.isEmpty, token.texto != "<blank>", token.texto != "<pad>" else { continue }
      let abre = token.texto.hasPrefix(" ") || token.texto.hasPrefix("▁")
      if abre || texto.isEmpty {
        cerrar()
        texto = token.texto.replacingOccurrences(of: "▁", with: " ")
        inicio = token.inicio
      } else {
        texto += token.texto
      }
      fin = token.fin
    }
    cerrar()
    return salida
  }
}

extension ParakeetEngine {
  /// Transcribe un archivo entero con tiempos por palabra: la pasada final de
  /// una reunión sobre el WAV de cada pista. Usa el mismo modelo que el
  /// dictado (`conElModelo`) y el camino de FluidAudio para archivos largos,
  /// que lee de disco sin cargar la hora entera a la RAM. `avance` va de 0 a
  /// 1 por las ventanas ya decodificadas.
  public func transcribirArchivoConTiempos(
    _ url: URL, avance: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws -> [PalabraConTiempo] {
    try await conElModelo { modelo in
      guard let parakeet = modelo as? ModeloDeParakeet else { throw EngineError.modeloNoDescargado }
      return try await parakeet.transcribirArchivo(url, avance: avance)
    }
  }
}

extension ModeloDeParakeet {
  func transcribirArchivo(_ url: URL, avance: @escaping @Sendable (Double) -> Void) async throws -> [PalabraConTiempo] {
    let flujo = await manager.transcriptionProgressStream
    let vigia = Task {
      do {
        for try await fraccion in flujo { avance(fraccion) }
      } catch {}
    }
    defer { vigia.cancel() }
    var estado = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
    let resultado = try await manager.transcribe(url, decoderState: &estado, language: .spanish)
    avance(1)
    let tokens = (resultado.tokenTimings ?? []).map {
      TokenDeVoz(texto: $0.token, inicio: $0.startTime, fin: $0.endTime)
    }
    return PalabraConTiempo.palabras(de: tokens)
  }
}
