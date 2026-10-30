import Foundation

/// Una palabra del **Guion**: una línea de `guion.jsonl`.
///
/// La unidad es la palabra con su tiempo, no el turno (lección 3 del Tauri:
/// «por turnos no es la solución»). El hablante se pega a cada palabra, y las
/// líneas que se leen se arman después (`LineasDelGuion`).
public struct PalabraDelGuion: Codable, Sendable, Equatable {
  /// Lo que dice de una palabra además de su texto.
  public enum Marca: String, Codable, Sendable, Comparable {
    /// Del guion en vivo: la pasada final la puede corregir.
    case tentativa
    /// La persona estaba dictando: no es la reunión, aunque quede en el WAV.
    case dictado
    /// Una palabra de `yo` que repite una de `ellos`: el micrófono re-captó
    /// los parlantes.
    case eco
    /// Dos voces de `ellos` superaron el umbral a la vez en el tramo de la
    /// palabra.
    case solape

    public static func < (a: Marca, b: Marca) -> Bool { a.rawValue < b.rawValue }
  }

  public var pista: Pista
  /// El id del hablante (`yo`, `h2`…). Nil si nadie pudo decirlo: una
  /// palabra de `ellos` en un tramo que el diarizador dejó vacío.
  public var hablante: String?
  /// Segundos desde que empezó la reunión, ya en el reloj del Mac: las dos
  /// pistas se intercalan por este número (`AlineacionDeRelojes`).
  public var desde: Double
  public var hasta: Double
  public var texto: String
  public var marcas: [Marca]

  public init(
    pista: Pista, hablante: String?, desde: Double, hasta: Double, texto: String, marcas: [Marca] = []
  ) {
    self.pista = pista
    self.hablante = hablante
    self.desde = desde
    self.hasta = hasta
    self.texto = texto
    self.marcas = marcas
  }

  public func tiene(_ marca: Marca) -> Bool { marcas.contains(marca) }

  public mutating func marcar(_ marca: Marca) {
    guard !marcas.contains(marca) else { return }
    marcas.append(marca)
    marcas.sort()
  }

  /// Si va al guion que se lee: lo dictado y el eco quedan en el archivo,
  /// marcados, pero no son la reunión.
  public var vaAlGuion: Bool { !tiene(.dictado) && !tiene(.eco) }

  /// El centro de la palabra: el punto que se compara contra otros relojes.
  public var centro: Double { (desde + hasta) / 2 }
}

/// `guion.jsonl`: una palabra por línea, en orden de tiempo.
public enum ArchivoDelGuion {
  public static func codificar(_ palabras: [PalabraDelGuion]) throws -> Data {
    let codificador = JSONEncoder()
    codificador.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var datos = Data()
    for palabra in palabras {
      datos.append(try codificador.encode(palabra))
      datos.append(0x0A)
    }
    return datos
  }

  /// Lee lo que se pueda: una línea rota (el disco se llenó a la mitad) no se
  /// lleva al resto del guion.
  public static func leer(_ datos: Data) -> [PalabraDelGuion] {
    let decodificador = JSONDecoder()
    return datos.split(separator: 0x0A).compactMap { try? decodificador.decode(PalabraDelGuion.self, from: Data($0)) }
  }
}
