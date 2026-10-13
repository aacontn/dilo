import AVFAudio
import Foundation
import Speech

/// El motor de Apple sobre audio que ya está en RAM: el reintento de una
/// toma que no sacó texto, y la segunda opinión cuando escuchó Parakeet.
///
/// No usa la sesión tibia de `SpeechRecognitionService`: ésa es del
/// micrófono, tiene preset de streaming y la va a pedir el próximo dictado.
/// Arma un analizador de una vez con el preset de transcripción completa,
/// que es el que corresponde a un audio que ya terminó. Nada toca el disco:
/// el audio entra como un solo búfer en memoria.
enum TranscripcionAppleDesdeRAM {
  enum Falla: Error {
    case sinMotor
    case sinFormato
    case conversion
  }

  static func transcribir(
    _ muestras: [Float],
    tasa: Double = 16_000,
    locale: Locale,
    tusPalabras: [String]
  ) async throws -> String {
    guard !muestras.isEmpty else { return "" }
    guard SpeechTranscriber.isAvailable,
      let idioma = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    else { throw Falla.sinMotor }

    let transcriptor = SpeechTranscriber(locale: idioma, preset: .transcription)
    let modulos: [any SpeechModule] = [transcriptor]
    guard let formato = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modulos) else {
      throw Falla.sinFormato
    }
    let analizador = SpeechAnalyzer(modules: modulos)
    if !tusPalabras.isEmpty {
      let contexto = AnalysisContext()
      contexto.contextualStrings[.general] = tusPalabras
      // Igual que en vivo: si no acepta el contexto, se transcribe igual y
      // la post-corrección de DiloText alcanza lo mismo después.
      try? await analizador.setContext(contexto)
    }

    let buffer = try convertir(muestras, desde: tasa, a: formato)
    let (entrada, continuacion) = AsyncStream.makeStream(of: AnalyzerInput.self)
    continuacion.yield(AnalyzerInput(buffer: buffer))
    continuacion.finish()

    let resultados = Task { () throws -> String in
      var acumulado = SpeechRecognitionService.ResultAccumulator()
      for try await resultado in transcriptor.results where resultado.isFinal {
        _ = acumulado.receive(String(resultado.text.characters), isFinal: true)
      }
      return acumulado.completedText
    }
    do {
      try await analizador.start(inputSequence: entrada)
      try await analizador.finalizeAndFinishThroughEndOfInput()
    } catch {
      resultados.cancel()
      await analizador.cancelAndFinishNow()
      throw error
    }
    return try await resultados.value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// De 16 kHz mono Float32 al formato que pide el analizador, en una sola
  /// pasada sobre un búfer en memoria.
  private static func convertir(
    _ muestras: [Float],
    desde tasa: Double,
    a destino: AVAudioFormat
  ) throws -> AVAudioPCMBuffer {
    guard
      let origen = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: tasa, channels: 1, interleaved: false),
      let crudo = AVAudioPCMBuffer(pcmFormat: origen, frameCapacity: AVAudioFrameCount(muestras.count)),
      let conversor = AVAudioConverter(from: origen, to: destino),
      let canal = crudo.floatChannelData?[0]
    else { throw Falla.conversion }
    crudo.frameLength = AVAudioFrameCount(muestras.count)
    muestras.withUnsafeBufferPointer { fuente in
      guard let base = fuente.baseAddress else { return }
      canal.update(from: base, count: muestras.count)
    }
    let capacidad = AVAudioFrameCount((Double(muestras.count) * destino.sampleRate / tasa).rounded(.up)) + 1_024
    guard let salida = AVAudioPCMBuffer(pcmFormat: destino, frameCapacity: capacidad) else {
      throw Falla.conversion
    }
    // El bloque de entrada corre sincrónico dentro de `convert`: entrega el
    // búfer una vez y después dice que se acabó.
    nonisolated(unsafe) var entregado = false
    var error: NSError?
    let estado = conversor.convert(to: salida, error: &error) { _, estadoDeEntrada in
      if entregado {
        estadoDeEntrada.pointee = .endOfStream
        return nil
      }
      entregado = true
      estadoDeEntrada.pointee = .haveData
      return crudo
    }
    guard error == nil, estado != .error else { throw Falla.conversion }
    return salida
  }
}
