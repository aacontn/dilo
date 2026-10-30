import DiloReuniones
import FluidAudio
import Foundation

/// Lee audio a 16 kHz mono en trozos, sin cargar una hora entera a la RAM.
///
/// Las pistas de Dilo ya son WAV de 16 bits a 16 kHz (`CabeceraWAV`): se leen
/// directo. Cualquier otro archivo —el banco recibe lo que Alfonso grabó con
/// otra cosa— pasa por el conversor de FluidAudio, entero.
public struct LectorDeAudio: Sendable {
  public let partes: [URL]

  public init(partes: [URL]) {
    self.partes = partes
  }

  /// 30 s por trozo: lo bastante para que Nemotron 3 avance varias llamadas
  /// de una vez y poco para la RAM (1,9 MB).
  public static let muestrasPorTrozo = 30 * 16_000

  /// Cuántas muestras hay en total, para el avance.
  public var totalDeMuestras: Int {
    partes.reduce(0) { total, url in
      let tamaño = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int) ?? 0
      return total + CabeceraWAV.bytesReales(tamañoDelArchivo: tamaño) / CabeceraWAV.bytesPorMuestra
    }
  }

  /// Entrega cada trozo en orden. Una parte sin cabecera nuestra se convierte
  /// entera con FluidAudio.
  public func recorrer(_ cuerpo: ([Float]) throws -> Void) throws {
    for url in partes {
      let archivo = try FileHandle(forReadingFrom: url)
      defer { try? archivo.close() }
      let cabecera = try archivo.read(upToCount: CabeceraWAV.tamaño) ?? Data()
      guard CabeceraWAV.bytesDeDatos(en: cabecera) != nil else {
        try cuerpo(try AudioConverter().resampleAudioFile(url))
        continue
      }
      while let datos = try archivo.read(upToCount: Self.muestrasPorTrozo * CabeceraWAV.bytesPorMuestra),
        !datos.isEmpty
      {
        try cuerpo(Self.flotantes(datos))
      }
    }
  }

  /// Todo junto, para lo que no sabe ir por trozos.
  public func todo() throws -> [Float] {
    var salida: [Float] = []
    salida.reserveCapacity(totalDeMuestras)
    try recorrer { salida.append(contentsOf: $0) }
    return salida
  }

  static func flotantes(_ datos: Data) -> [Float] {
    let n = datos.count / CabeceraWAV.bytesPorMuestra
    var salida = [Float](repeating: 0, count: n)
    datos.withUnsafeBytes { crudo in
      let pcm = crudo.bindMemory(to: Int16.self)
      for i in 0..<n { salida[i] = Float(Int16(littleEndian: pcm[i])) / Float(Int16.max) }
    }
    return salida
  }
}
