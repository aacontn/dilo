import FluidAudio
import Foundation

/// Un audio del corpus de la espiga, ya a 16 kHz mono.
struct Clip: Sendable {
  enum Categoria: String, Sendable, CaseIterable {
    /// «Dilo, …» al principio: tiene que despertar.
    case positivos
    /// Palabras parecidas o el nombre a mitad de frase: no tiene que despertar.
    case duros
    /// El verbo «dilo» al principio («Dilo otra vez»): no tendría que despertar.
    case verbo
    /// Prosa sin el nombre: la medida de las falsas alarmas por hora.
    case prosa
  }

  let categoria: Categoria
  let nombre: String
  let texto: String
  let muestras: [Float]
  var segundos: Double { Double(muestras.count) / 16_000 }
}

enum Corpus {
  static func leer(_ carpeta: URL, categoria: Clip.Categoria) throws -> [Clip] {
    let dir = carpeta.appendingPathComponent(categoria.rawValue, isDirectory: true)
    let wavs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "wav" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let conversor = AudioConverter()
    return try wavs.map { wav in
      let texto = (try? String(contentsOf: wav.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)) ?? ""
      return Clip(
        categoria: categoria,
        nombre: wav.deletingPathExtension().lastPathComponent,
        texto: texto.trimmingCharacters(in: .whitespacesAndNewlines),
        muestras: try conversor.resampleAudioFile(wav)
      )
    }
  }
}

/// Un generador con semilla: el corpus sale igual en cada corrida.
struct Azar: RandomNumberGenerator {
  var estado: UInt64
  init(_ semilla: UInt64) { estado = semilla &+ 0x9E37_79B9_7F4A_7C15 }
  mutating func next() -> UInt64 {
    estado &+= 0x9E37_79B9_7F4A_7C15
    var z = estado
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
  mutating func uniforme() -> Float { Float(next() >> 40) / Float(1 << 24) }
}

/// Ruido de fondo. Los niveles son RMS en dBFS.
enum Ruido: String, CaseIterable, Sendable {
  case silencio, blanco, ventilador, rosa

  func generar(_ n: Int, dB: Float, azar: inout Azar) -> [Float] {
    let rms = powf(10, dB / 20)
    var salida = [Float](repeating: 0, count: n)
    switch self {
    case .silencio:
      // Un piso de 16 bits, como un micrófono en una pieza callada.
      for i in 0..<n { salida[i] = (azar.uniforme() - 0.5) * 2e-4 }
    case .blanco:
      for i in 0..<n { salida[i] = (azar.uniforme() - 0.5) * rms * 3.46 }
    case .ventilador:
      // Café (browniano) con fuga: grave, como un ventilador o un auto lejos.
      var y: Float = 0
      for i in 0..<n {
        y = 0.995 * y + (azar.uniforme() - 0.5) * 0.1
        salida[i] = y
      }
      normalizar(&salida, rms: rms)
    case .rosa:
      // Paul Kellet, versión corta.
      var b0: Float = 0, b1: Float = 0, b2: Float = 0
      for i in 0..<n {
        let w = azar.uniforme() - 0.5
        b0 = 0.99765 * b0 + w * 0.0990460
        b1 = 0.96300 * b1 + w * 0.2965164
        b2 = 0.57000 * b2 + w * 1.0526913
        salida[i] = b0 + b1 + b2 + w * 0.1848
      }
      normalizar(&salida, rms: rms)
    }
    return salida
  }

  private func normalizar(_ x: inout [Float], rms: Float) {
    let actual = sqrtf(x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count)))
    guard actual > 0 else { return }
    let k = rms / actual
    for i in x.indices { x[i] *= k }
  }
}

/// Un audio largo armado con clips y pausas sobre un fondo, con lo que dice
/// cada tramo para comparar.
struct Corrida: Sendable {
  struct Tramo: Sendable {
    let clip: Clip
    let inicio: Int
    var fin: Int { inicio + clip.muestras.count }
  }

  let nombre: String
  var muestras: [Float]
  var tramos: [Tramo]
  var segundos: Double { Double(muestras.count) / 16_000 }

  /// Clips en orden, con pausas al azar entre `pausa`, sobre ruido que cambia
  /// cada tanto. `conRuido` mezcla además uno de cada cuatro clips con
  /// ventilador a 10 dB de la voz.
  static func armar(
    _ nombre: String, clips: [Clip], pausa: ClosedRange<Double>, fondos: [(Ruido, Float)],
    conRuido: Bool, semilla: UInt64
  ) -> Corrida {
    var azar = Azar(semilla)
    var muestras: [Float] = []
    var tramos: [Tramo] = []
    for (i, clip) in clips.enumerated() {
      let (fondo, dB) = fondos[(i / 8) % fondos.count]
      let silencio = Int((pausa.lowerBound + Double(azar.uniforme()) * (pausa.upperBound - pausa.lowerBound)) * 16_000)
      muestras += fondo.generar(silencio, dB: dB, azar: &azar)
      var voz = clip.muestras
      let base = fondo.generar(voz.count, dB: dB, azar: &azar)
      for j in voz.indices { voz[j] += base[j] }
      if conRuido, i % 4 == 3 {
        let rmsVoz = sqrtf(clip.muestras.reduce(0) { $0 + $1 * $1 } / Float(max(1, clip.muestras.count)))
        let dBVoz = 20 * log10f(max(rmsVoz, 1e-6))
        let ruido = Ruido.ventilador.generar(voz.count, dB: dBVoz - 10, azar: &azar)
        for j in voz.indices { voz[j] += ruido[j] }
      }
      tramos.append(Tramo(clip: clip, inicio: muestras.count))
      muestras += voz
    }
    muestras += Ruido.silencio.generar(32_000, dB: 0, azar: &azar)
    return Corrida(nombre: nombre, muestras: muestras, tramos: tramos)
  }

  /// Diez minutos sin voz: fondos de varios niveles y golpes cortos (una
  /// puerta, un vaso), que es lo que más engaña a una puerta de energía.
  static func soloRuido(minutos: Double, semilla: UInt64) -> Corrida {
    var azar = Azar(semilla)
    var muestras: [Float] = []
    let fondos: [(Ruido, Float)] = [
      (.silencio, 0), (.blanco, -55), (.ventilador, -40), (.rosa, -45), (.ventilador, -30), (.blanco, -40),
    ]
    let total = Int(minutos * 60 * 16_000)
    var i = 0
    while muestras.count < total {
      let (fondo, dB) = fondos[i % fondos.count]
      var tramo = fondo.generar(Int(20 * 16_000), dB: dB, azar: &azar)
      // Un golpe cada ~4 s: 30 ms de ruido fuerte que decae.
      var k = Int(azar.uniforme() * 64_000)
      while k < tramo.count - 800 {
        for j in 0..<800 { tramo[k + j] += (azar.uniforme() - 0.5) * 0.6 * expf(-Float(j) / 160) }
        k += 48_000 + Int(azar.uniforme() * 32_000)
      }
      muestras += tramo
      i += 1
    }
    return Corrida(nombre: "ruido", muestras: Array(muestras.prefix(total)), tramos: [])
  }

  /// Escribe el audio armado como WAV de 16 bits, para escucharlo y volver a
  /// correr la espiga sobre lo mismo.
  func escribir(en carpeta: URL) throws {
    try FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
    let url = carpeta.appendingPathComponent("\(nombre).wav")
    var datos = Data()
    func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { datos.append(contentsOf: $0) } }
    let bytes = UInt32(muestras.count * 2)
    datos.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36) + bytes)
    datos.append(contentsOf: Array("WAVEfmt ".utf8)); le(UInt32(16)); le(UInt16(1)); le(UInt16(1))
    le(UInt32(16_000)); le(UInt32(32_000)); le(UInt16(2)); le(UInt16(16))
    datos.append(contentsOf: Array("data".utf8)); le(bytes)
    for m in muestras { le(Int16(max(-1, min(1, m)) * 32_767)) }
    try datos.write(to: url)
  }
}
