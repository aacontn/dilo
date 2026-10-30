import AVFAudio
import DiloEngines
import DiloModes
import FluidAudio
import Foundation
import Speech

/// Cuánta CPU gastó el proceso, en segundos de núcleo, y cuánta RAM ocupa.
enum Medida {
  static func cpu() -> Double {
    var uso = rusage()
    getrusage(RUSAGE_SELF, &uso)
    func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return s(uso.ru_utime) + s(uso.ru_stime)
  }

  /// La huella física, la que muestra el Monitor de Actividad.
  static func ramMB() -> Double {
    var info = task_vm_info_data_t()
    var cuenta = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let r = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(cuenta)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &cuenta)
      }
    }
    return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
  }

  static func ms(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
  }
}

/// El detector de voz que decide qué trozos se miran.
@MainActor
protocol DetectorDeVoz: AnyObject {
  var nombre: String { get }
  func probabilidad(_ trozo: [Float]) async throws -> Float
  func reiniciar() async
}

/// Silero v6 por FluidAudio, un trozo de 256 ms a la vez con su estado.
@MainActor
final class DetectorSilero: DetectorDeVoz {
  let nombre = "silero"
  let manager: VadManager
  var estado = VadStreamState.initial()

  init(manager: VadManager) { self.manager = manager }

  func probabilidad(_ trozo: [Float]) async throws -> Float {
    let r = try await manager.processStreamingChunk(trozo, state: estado, config: .default)
    estado = r.state
    return r.probability
  }

  func reiniciar() async { estado = VadStreamState.initial() }
}

/// Una puerta de energía sin modelo: voz es estar 10 dB sobre el piso de
/// ruido, que sigue al mínimo y sube despacio.
@MainActor
final class DetectorDeEnergia: DetectorDeVoz {
  let nombre = "energia"
  var piso: Float = -60

  func probabilidad(_ trozo: [Float]) async throws -> Float {
    let rms = sqrtf(trozo.reduce(0) { $0 + $1 * $1 } / Float(max(1, trozo.count)))
    let dB = 20 * log10f(max(rms, 1e-7))
    // El piso baja al tiro y sube 0,5 dB por trozo (~2 dB/s).
    piso = dB < piso ? dB : min(dB, piso + 0.5)
    let sobre = dB - max(piso, -70)
    guard dB > -50 else { return 0 }
    return max(0, min(1, (sobre - 6) / 8))
  }

  func reiniciar() async { piso = -60 }
}

/// Lo que dijo un decisor sobre un tramo.
struct Busqueda: Sendable {
  let hayNombre: Bool
  let texto: String
  /// La primera palabra con la confianza más baja de sus tokens, para ver
  /// si «Digo» fue un «Dilo» dudoso.
  var primera: (String, Float)? = nil
  /// Dónde terminó el nombre, en segundos desde el principio del tramo.
  let finDelNombre: Double?
  let ms: Double
}

@MainActor
protocol Decisor: AnyObject {
  var nombre: String { get }
  func buscar(_ tramo: [Float]) async throws -> Busqueda
}

/// (a) Parakeet sobre el tramo y `NombreQueDespierta` sobre el texto.
@MainActor
final class DecisorParakeet: Decisor {
  let nombre: String
  let manager: AsrManager
  let regla: NombreQueDespierta

  init(manager: AsrManager, regla: NombreQueDespierta, nombre: String = "parakeet") {
    self.manager = manager
    self.regla = regla
    self.nombre = nombre
  }

  var ultimaPrimera: (String, Float)?

  func transcribir(_ tramo: [Float]) async throws -> (String, [PalabraConTiempo]) {
    // Menos de 1 s el modelo no lo acepta: se rellena con silencio.
    var audio = tramo
    if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }
    var estado = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
    let r = try await manager.transcribe(audio, decoderState: &estado, language: .spanish)
    let tokens = (r.tokenTimings ?? []).map { TokenDeVoz(texto: $0.token, inicio: $0.startTime, fin: $0.endTime) }
    let texto = r.tokenTimings.map { _ in CosturaDeTrozos.texto(de: tokens) } ?? r.text
    // La primera palabra: sus tokens hasta el siguiente que abre palabra.
    var primera = ""
    var confianza: Float = 1
    for (i, t) in (r.tokenTimings ?? []).enumerated() {
      let abre = t.token.hasPrefix(" ") || t.token.hasPrefix("▁")
      if i > 0, abre { break }
      if t.token.allSatisfy({ $0.isPunctuation || $0 == " " }) { break }
      primera += t.token.replacingOccurrences(of: "▁", with: "")
      confianza = min(confianza, t.confidence)
    }
    ultimaPrimera = (primera.trimmingCharacters(in: .whitespaces), confianza)
    return (texto, PalabraConTiempo.palabras(de: tokens))
  }

  func buscar(_ tramo: [Float]) async throws -> Busqueda {
    let reloj = ContinuousClock()
    var texto = ""
    var palabras: [PalabraConTiempo] = []
    let d = try await reloj.measure { (texto, palabras) = try await transcribir(tramo) }
    let llamado = regla.oir(texto)
    let fin = palabras.first { SenalesDelTurno.plegar($0.texto) == "dilo" }?.fin
    return Busqueda(hayNombre: llamado != nil, texto: texto, primera: ultimaPrimera, finDelNombre: fin, ms: Medida.ms(d))
  }
}

/// (b) El CTC de FluidAudio buscando «dilo» en el principio del tramo.
@MainActor
final class DecisorCTC: Decisor {
  let nombre = "ctc"
  let spotter: CtcKeywordSpotter
  let vocabulario: CustomVocabularyContext
  var umbral: Float

  init(modelos: CtcModels, tokenizer: CtcTokenizer, umbral: Float) {
    spotter = CtcKeywordSpotter(models: modelos)
    let termino = CustomVocabularyTerm(text: "dilo", ctcTokenIds: tokenizer.encode("dilo"))
    vocabulario = CustomVocabularyContext(terms: [termino], minTermLength: 3)
    self.umbral = umbral
  }

  /// El mejor puntaje de «dilo» que empieza en el primer 0,8 s, o nil.
  func puntaje(_ tramo: [Float]) async throws -> (Float, Double)? {
    let r = try await spotter.spotKeywordsWithLogProbs(audioSamples: tramo, customVocabulary: vocabulario, minScore: -1_000)
    return r.detections.filter { $0.startTime < 0.8 }.max { $0.score < $1.score }.map { ($0.score, $0.endTime) }
  }

  func buscar(_ tramo: [Float]) async throws -> Busqueda {
    let reloj = ContinuousClock()
    var mejor: (Float, Double)?
    let d = try await reloj.measure { mejor = try await puntaje(tramo) }
    let hay = (mejor?.0 ?? -.infinity) >= umbral
    return Busqueda(hayNombre: hay, texto: mejor.map { String(format: "dilo %.2f", $0.0) } ?? "", finDelNombre: mejor?.1, ms: Medida.ms(d))
  }
}

/// (c) `SpeechTranscriber` de macOS 26 sobre el tramo ya grabado.
enum TranscriptorDeApple {
  static func transcribir(_ muestras: [Float], locale: Locale) async throws -> String {
    guard let idioma = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return "" }
    let transcriptor = SpeechTranscriber(locale: idioma, preset: .transcription)
    let modulos: [any SpeechModule] = [transcriptor]
    guard let formato = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modulos) else { return "" }
    let analizador = SpeechAnalyzer(modules: modulos)
    let buffer = try convertir(muestras, a: formato)
    let (entrada, continuacion) = AsyncStream.makeStream(of: AnalyzerInput.self)
    continuacion.yield(AnalyzerInput(buffer: buffer))
    continuacion.finish()
    let resultados = Task { () throws -> String in
      var texto = ""
      for try await r in transcriptor.results where r.isFinal { texto += String(r.text.characters) }
      return texto
    }
    try await analizador.start(inputSequence: entrada)
    try await analizador.finalizeAndFinishThroughEndOfInput()
    return try await resultados.value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func convertir(_ muestras: [Float], a destino: AVAudioFormat) throws -> AVAudioPCMBuffer {
    let origen = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let crudo = AVAudioPCMBuffer(pcmFormat: origen, frameCapacity: AVAudioFrameCount(muestras.count))!
    crudo.frameLength = AVAudioFrameCount(muestras.count)
    muestras.withUnsafeBufferPointer { crudo.floatChannelData![0].update(from: $0.baseAddress!, count: muestras.count) }
    let conversor = AVAudioConverter(from: origen, to: destino)!
    let capacidad = AVAudioFrameCount(Double(muestras.count) * destino.sampleRate / 16_000) + 1_024
    let salida = AVAudioPCMBuffer(pcmFormat: destino, frameCapacity: capacidad)!
    nonisolated(unsafe) var entregado = false
    var error: NSError?
    _ = conversor.convert(to: salida, error: &error) { _, estado in
      if entregado {
        estado.pointee = .endOfStream
        return nil
      }
      entregado = true
      estado.pointee = .haveData
      return crudo
    }
    if let error { throw error }
    return salida
  }
}
