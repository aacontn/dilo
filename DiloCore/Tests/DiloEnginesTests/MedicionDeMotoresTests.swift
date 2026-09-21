import AVFoundation
import FluidAudio
import Foundation
import Speech
import Testing

@testable import DiloEngines

/// La medición de "soltar → texto" de los dos motores, con un WAV fijo en
/// español.
///
/// No corre en `swift test` normal: baja 2 GB de modelo y pide permiso de
/// reconocimiento de voz. Se enciende a mano, que es cuando se quiere el
/// número:
///
/// ```bash
/// say -v "Mónica" -o /tmp/d.aiff "…"   # el dictado de referencia
/// afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/d.aiff /Volumes/SSD2/scratch/dilo-mac/dictado-es.wav
/// DILO_BENCH=1 DILO_BENCH_WAV=/Volumes/SSD2/scratch/dilo-mac/dictado-es.wav \
///   swift test --scratch-path /Volumes/SSD2/derived-data/dilocore-motor-doble \
///   --filter MedicionDeMotoresTests
/// ```
///
/// Los números medidos están en el comentario de cabecera de
/// `ParakeetEngine` y en el reporte de la Tarea 3.
struct MedicionDeMotoresTests {
  private static var encendida: Bool {
    ProcessInfo.processInfo.environment["DILO_BENCH"] == "1"
  }

  private static var wav: URL? {
    ProcessInfo.processInfo.environment["DILO_BENCH_WAV"].map { URL(filePath: $0) }
  }

  private static let repeticiones = 5

  @Test(.enabled(if: MedicionDeMotoresTests.encendida))
  func parakeetSoltarATexto() async throws {
    let url = try #require(Self.wav, "falta DILO_BENCH_WAV")
    let muestras = try Self.leerMono16k(url)
    let segundos = Double(muestras.count) / ParakeetEngine.sampleRate

    let almacen = ParakeetModelStore()
    if !ParakeetModelStore.estaDescargado {
      let inicio = Date()
      try await almacen.descargar { avance in
        if Int(avance.fraccion * 100) % 20 == 0 {
          print("  descarga \(Int(avance.fraccion * 100)) % — \(avance.fase)")
        }
      }
      print("descarga: \(Int(Date().timeIntervalSince(inicio))) s")
    }
    let mb = Double(ParakeetModelStore.tamanoEnDisco) / 1_048_576
    print("modelo en disco: \(String(format: "%.0f", mb)) MB — \(ParakeetModelStore.carpetaDelModelo.path)")

    let modelos = try await almacen.cargar()
    let manager = AsrManager(config: .default)
    let cargaInicio = Date()
    try await manager.loadModels(modelos)
    print("carga en frío del modelo: \(Self.ms(Date().timeIntervalSince(cargaInicio)))")

    let capas = await manager.decoderLayerCount

    // Pasada de calentamiento: la primera predicción de Core ML compila el
    // grafo y no es la que mide nadie con la tecla en la mano.
    var calienta = TdtDecoderState.make(decoderLayers: capas)
    _ = try await manager.transcribe(muestras, decoderState: &calienta, language: .spanish)

    var tiempos: [TimeInterval] = []
    var texto = ""
    for _ in 0..<Self.repeticiones {
      var estado = TdtDecoderState.make(decoderLayers: capas)
      let inicio = Date()
      let resultado = try await manager.transcribe(
        muestras, decoderState: &estado, language: .spanish
      )
      tiempos.append(Date().timeIntervalSince(inicio))
      texto = resultado.text
    }

    print("PARAKEET soltar→texto sobre \(Self.s(segundos)) de audio:")
    print("  p50 \(Self.ms(Self.mediana(tiempos))) · min \(Self.ms(tiempos.min()!)) · max \(Self.ms(tiempos.max()!))")
    print("  texto: \(texto)")

    // El costo de un parcial de 2 s arrastrando el estado del decoder, que es
    // lo que decide si los parciales se encienden.
    let trozo = Array(muestras.prefix(Int(ParakeetEngine.sampleRate * 2)))
    var estadoParcial = TdtDecoderState.make(decoderLayers: capas)
    var parciales: [TimeInterval] = []
    for _ in 0..<Self.repeticiones {
      let inicio = Date()
      _ = try await manager.transcribe(trozo, decoderState: &estadoParcial, language: .spanish)
      parciales.append(Date().timeIntervalSince(inicio))
    }
    print("  parcial de 2 s: p50 \(Self.ms(Self.mediana(parciales)))")
  }

  @Test(.enabled(if: MedicionDeMotoresTests.encendida))
  func appleSoltarATexto() async throws {
    let url = try #require(Self.wav, "falta DILO_BENCH_WAV")
    // Nada de `SFSpeechRecognizer.requestAuthorization` acá: el binario de
    // los tests no tiene Info.plist y pedir el permiso lo mata con SIGABRT.
    // `SpeechAnalyzer` sobre un archivo no pasa por TCC.
    guard let locale = await SpeechTranscriber.supportedLocale(
      equivalentTo: Locale(identifier: "es-CL")
    ) else {
      print("APPLE: es-CL no está soportado; no se midió")
      return
    }

    var tiempos: [TimeInterval] = []
    var texto = ""
    var segundos = 0.0
    for _ in 0..<Self.repeticiones {
      let (medido, salida, duracion) = try await Self.medirApple(url: url, locale: locale)
      tiempos.append(medido)
      texto = salida
      segundos = duracion
    }

    print("APPLE soltar→texto sobre \(Self.s(segundos)) de audio (alimentado en tiempo real):")
    print("  p50 \(Self.ms(Self.mediana(tiempos))) · min \(Self.ms(tiempos.min()!)) · max \(Self.ms(tiempos.max()!))")
    print("  texto: \(texto)")
  }

  /// Alimenta el audio a SpeechAnalyzer al ritmo en que se habló —que es lo
  /// que pasa de verdad con el micrófono— y recién ahí mide lo que tarda
  /// desde "soltar" hasta tener el texto. Medir la pasada entera sobre el
  /// archivo diría otra cosa y sería mentira.
  private static func medirApple(
    url: URL, locale: Locale
  ) async throws -> (TimeInterval, String, Double) {
    let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    if let instalacion = try await AssetInventory.assetInstallationRequest(
      supporting: [transcriber]
    ) {
      try await instalacion.downloadAndInstall()
    }

    let modulos: [any SpeechModule] = [transcriber]
    let formato = try #require(
      await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modulos)
    )
    let analyzer = SpeechAnalyzer(
      modules: modulos,
      options: SpeechAnalyzer.Options(priority: .high, modelRetention: .lingering)
    )
    try await analyzer.prepareToAnalyze(in: formato)

    let (stream, continuation) = AsyncStream.makeStream(
      of: AnalyzerInput.self, bufferingPolicy: .bufferingNewest(64)
    )
    let recoleccion = Task { () -> String in
      var firme = ""
      var volatil = ""
      for try await resultado in transcriber.results {
        let trozo = String(resultado.text.characters)
        if resultado.isFinal {
          firme += trozo
          volatil = ""
        } else {
          volatil = trozo
        }
      }
      return firme + volatil
    }

    try await analyzer.start(inputSequence: stream)

    let buffers = try trozosDeArchivo(url, formato: formato)
    let duracionDeUnTrozo = 0.1
    for buffer in buffers {
      continuation.yield(AnalyzerInput(buffer: buffer))
      try await Task.sleep(for: .seconds(duracionDeUnTrozo))
    }

    // Acá se suelta la tecla.
    let inicio = Date()
    continuation.finish()
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    let texto = try await recoleccion.value
    let medido = Date().timeIntervalSince(inicio)

    return (medido, texto, Double(buffers.count) * duracionDeUnTrozo)
  }

  /// El archivo cortado en trozos de 100 ms en el formato que pide el
  /// analizador, para poder alimentarlo al ritmo del habla.
  private static func trozosDeArchivo(
    _ url: URL, formato: AVAudioFormat
  ) throws -> [AVAudioPCMBuffer] {
    let archivo = try AVAudioFile(forReading: url)
    let convertidor = try #require(AVAudioConverter(from: archivo.processingFormat, to: formato))
    let porTrozo = AVAudioFrameCount(archivo.processingFormat.sampleRate * 0.1)

    var trozos: [AVAudioPCMBuffer] = []
    while true {
      guard let entrada = AVAudioPCMBuffer(
        pcmFormat: archivo.processingFormat, frameCapacity: porTrozo
      ) else { break }
      // `read(into:frameCount:)` lanza eofErr en el último trozo en vez de
      // devolver cero cuadros.
      do {
        try archivo.read(into: entrada, frameCount: porTrozo)
      } catch {
        break
      }
      if entrada.frameLength == 0 { break }

      let razon = formato.sampleRate / archivo.processingFormat.sampleRate
      let capacidad = AVAudioFrameCount(Double(entrada.frameLength) * razon) + 1
      guard let salida = AVAudioPCMBuffer(pcmFormat: formato, frameCapacity: capacidad) else {
        break
      }
      var entregado = false
      var error: NSError?
      convertidor.convert(to: salida, error: &error) { _, estado in
        if entregado {
          estado.pointee = .noDataNow
          return nil
        }
        entregado = true
        estado.pointee = .haveData
        return entrada
      }
      if error != nil { break }
      trozos.append(salida)
    }
    return trozos
  }

  private static func leerMono16k(_ url: URL) throws -> [Float] {
    let archivo = try AVAudioFile(forReading: url)
    let destino = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: ParakeetEngine.sampleRate,
        channels: 1,
        interleaved: false
      )
    )
    let convertidor = try #require(AVAudioConverter(from: archivo.processingFormat, to: destino))
    let razon = destino.sampleRate / archivo.processingFormat.sampleRate
    let capacidad = AVAudioFrameCount(Double(archivo.length) * razon) + 1024
    let salida = try #require(AVAudioPCMBuffer(pcmFormat: destino, frameCapacity: capacidad))

    var terminado = false
    var error: NSError?
    convertidor.convert(to: salida, error: &error) { cuantos, estado in
      if terminado {
        estado.pointee = .endOfStream
        return nil
      }
      guard let entrada = AVAudioPCMBuffer(
        pcmFormat: archivo.processingFormat, frameCapacity: cuantos
      ) else {
        estado.pointee = .endOfStream
        return nil
      }
      do {
        try archivo.read(into: entrada, frameCount: cuantos)
      } catch {
        estado.pointee = .endOfStream
        return nil
      }
      if entrada.frameLength == 0 {
        terminado = true
        estado.pointee = .endOfStream
        return nil
      }
      estado.pointee = .haveData
      return entrada
    }
    if let error { throw error }

    let datos = try #require(salida.floatChannelData?[0])
    return Array(UnsafeBufferPointer(start: datos, count: Int(salida.frameLength)))
  }

  private static func mediana(_ valores: [TimeInterval]) -> TimeInterval {
    let ordenados = valores.sorted()
    return ordenados[ordenados.count / 2]
  }

  private static func ms(_ segundos: TimeInterval) -> String {
    String(format: "%.0f ms", segundos * 1000)
  }

  private static func s(_ segundos: Double) -> String {
    String(format: "%.1f s", segundos)
  }
}
