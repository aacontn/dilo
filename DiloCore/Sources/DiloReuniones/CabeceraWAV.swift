import Foundation

/// La cabecera de los WAV de las pistas: PCM de 16 bits, mono, 16 kHz, lo que
/// esperan Parakeet, Sortformer y Nemotron.
///
/// Los tamaños de la cabecera se reescriben cada 10 s mientras graba (spec,
/// «Nunca perder»). Si la app muere entre medio, el archivo tiene más datos
/// que los que dice su cabecera; repararlo es volver a escribirla con el
/// tamaño real.
public enum CabeceraWAV {
  public static let tamaño = 44
  public static let tasa: UInt32 = 16_000
  public static let canales: UInt16 = 1
  public static let bitsPorMuestra: UInt16 = 16
  public static let bytesPorMuestra = Int(bitsPorMuestra / 8)

  /// La cabecera para `bytesDeDatos` bytes de PCM.
  public static func datos(bytesDeDatos: Int) -> Data {
    let datos = UInt32(clamping: bytesDeDatos)
    var d = Data(capacity: tamaño)
    d.append(contentsOf: Array("RIFF".utf8))
    d.append(le: UInt32(clamping: Int(datos) + 36))
    d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8))
    d.append(le: UInt32(16))
    d.append(le: UInt16(1))
    d.append(le: canales)
    d.append(le: tasa)
    d.append(le: tasa * UInt32(canales) * UInt32(bitsPorMuestra / 8))
    d.append(le: canales * (bitsPorMuestra / 8))
    d.append(le: bitsPorMuestra)
    d.append(contentsOf: Array("data".utf8))
    d.append(le: datos)
    return d
  }

  /// Los bytes de datos que dice una cabecera, o nil si no es la nuestra.
  public static func bytesDeDatos(en cabecera: Data) -> Int? {
    guard cabecera.count >= tamaño,
      cabecera.prefix(4) == Data("RIFF".utf8),
      cabecera.subdata(in: 8..<12) == Data("WAVE".utf8),
      cabecera.subdata(in: 36..<40) == Data("data".utf8)
    else { return nil }
    return Int(cabecera.subdata(in: 40..<44).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
  }

  /// Cuántos bytes de datos tiene en verdad un archivo de `tamañoDelArchivo`:
  /// lo que hay después de la cabecera, sin la media muestra que una escritura
  /// cortada puede dejar colgando.
  public static func bytesReales(tamañoDelArchivo: Int) -> Int {
    let datos = max(0, tamañoDelArchivo - tamaño)
    return datos - datos % bytesPorMuestra
  }

  /// Repara un WAV en disco: reescribe la cabecera con lo que de verdad hay.
  /// Devuelve los segundos de audio que quedaron. Un archivo que ni siquiera
  /// llegó a tener cabecera se completa con una vacía.
  @discardableResult
  public static func reparar(_ url: URL) throws -> Double {
    let archivo = try FileHandle(forUpdating: url)
    defer { try? archivo.close() }
    let tamañoDelArchivo = Int(try archivo.seekToEnd())
    let bytes = bytesReales(tamañoDelArchivo: tamañoDelArchivo)
    if tamañoDelArchivo < tamaño {
      try archivo.truncate(atOffset: 0)
    } else if tamañoDelArchivo != tamaño + bytes {
      try archivo.truncate(atOffset: UInt64(tamaño + bytes))
    }
    try archivo.seek(toOffset: 0)
    try archivo.write(contentsOf: datos(bytesDeDatos: bytes))
    return Double(bytes / bytesPorMuestra) / Double(tasa)
  }

  /// Float32 en −1…1 a PCM de 16 bits, con recorte: un pico que pasa de 1
  /// no da la vuelta al signo.
  public static func pcm16(_ muestras: [Float]) -> Data {
    var datos = Data(count: muestras.count * bytesPorMuestra)
    datos.withUnsafeMutableBytes { crudo in
      let destino = crudo.bindMemory(to: Int16.self)
      for (i, m) in muestras.enumerated() {
        let recortada = max(-1, min(1, m))
        destino[i] = Int16(recortada * Float(Int16.max)).littleEndian
      }
    }
    return datos
  }
}

extension Data {
  fileprivate mutating func append<T: FixedWidthInteger>(le valor: T) {
    var v = valor.littleEndian
    Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
  }
}
