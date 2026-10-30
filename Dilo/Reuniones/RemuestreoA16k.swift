// Adaptado de `StreamingMonoResampler` de pasrom/meeting-transcriber (MIT,
// Copyright (c) 2025 pasrom): un conversor que se rearma cuando cambia la tasa
// de entrada, para que un tramo a 24 kHz no se escriba como si fuera de 48 kHz
// y salga al doble de velocidad. Acá la entrada ya llega en mono (el IOProc
// promedia los canales antes de copiar al búfer anular).
@preconcurrency import AVFAudio
import Foundation

/// Lleva bloques mono a cualquier tasa a 16 kHz, sin cortar el filtro entre un
/// bloque y el siguiente. No es thread-safe: lo usa sólo la cola que escribe
/// la pista.
final class RemuestreoA16k {
  static let tasa: Double = 16_000

  private let salida: AVAudioFormat
  private var conversor: AVAudioConverter?
  private var tasaDeEntrada: Double = 0

  init?() {
    guard let salida = AVAudioFormat(standardFormatWithSampleRate: Self.tasa, channels: 1) else { return nil }
    self.salida = salida
  }

  /// Un bloque a `tasa` Hz, a 16 kHz. A 16 kHz pasa tal cual.
  func convertir(_ muestras: UnsafeBufferPointer<Float>, tasa: Double) -> [Float] {
    guard !muestras.isEmpty, tasa > 0 else { return [] }
    if tasa == Self.tasa { return Array(muestras) }
    guard let conversor = conversor(para: tasa),
      let entrada = AVAudioPCMBuffer(pcmFormat: conversor.inputFormat, frameCapacity: AVAudioFrameCount(muestras.count)),
      let canal = entrada.floatChannelData?[0], let base = muestras.baseAddress
    else { return [] }
    entrada.frameLength = AVAudioFrameCount(muestras.count)
    canal.update(from: base, count: muestras.count)

    // Holgura de unas muestras: el conversor puede devolver lo que retuvo del
    // bloque anterior.
    let capacidad = AVAudioFrameCount((Double(muestras.count) * Self.tasa / tasa).rounded(.up)) + 64
    guard let destino = AVAudioPCMBuffer(pcmFormat: salida, frameCapacity: capacidad) else { return [] }
    var falla: NSError?
    let entrega = EntregaUnica(entrada)
    let estado = conversor.convert(to: destino, error: &falla) { _, estadoDeEntrada in
      entrega.siguiente(estadoDeEntrada)
    }
    guard falla == nil, estado != .error, destino.frameLength > 0, let datos = destino.floatChannelData?[0] else {
      return []
    }
    return Array(UnsafeBufferPointer(start: datos, count: Int(destino.frameLength)))
  }

  private func conversor(para tasa: Double) -> AVAudioConverter? {
    if let conversor, tasa == tasaDeEntrada { return conversor }
    guard let entrada = AVAudioFormat(standardFormatWithSampleRate: tasa, channels: 1),
      let nuevo = AVAudioConverter(from: entrada, to: salida)
    else { return nil }
    conversor = nuevo
    tasaDeEntrada = tasa
    return nuevo
  }
}

/// Entrega el búfer una vez y después dice que no hay más por ahora, para
/// que el conversor no se quede esperando ni repita el bloque.
private final class EntregaUnica: @unchecked Sendable {
  private let buffer: AVAudioPCMBuffer
  private var entregado = false

  init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

  func siguiente(_ estado: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    if entregado {
      estado.pointee = .noDataNow
      return nil
    }
    entregado = true
    estado.pointee = .haveData
    return buffer
  }
}
