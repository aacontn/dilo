import Foundation

/// Una nota que la persona escribió durante la reunión: una línea de
/// `notas.jsonl`, junto al guion.
public struct NotaDeLaReunion: Codable, Sendable, Equatable, Identifiable {
  /// Segundos desde que empezó la reunión.
  public var en: Double
  public var texto: String

  public init(en: Double, texto: String) {
    self.en = en
    self.texto = texto
  }

  public var id: Double { en }

  /// Lo escrito, en una línea y sin espacios de sobra, o nil si no hay nada:
  /// cada nota es un renglón de `guion.md`.
  public static func limpiar(_ texto: String) -> String? {
    let limpio = texto.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return limpio.isEmpty ? nil : limpio
  }
}

/// `notas.jsonl`. Las notas viven aparte del guion porque nacen antes que él y
/// porque la pasada final lo reescribe entero.
public enum ArchivoDeNotas {
  public static func codificar(_ notas: [NotaDeLaReunion]) -> Data {
    let codificador = JSONEncoder()
    codificador.outputFormatting = [.sortedKeys]
    var datos = Data()
    for nota in notas {
      guard let linea = try? codificador.encode(nota) else { continue }
      datos.append(linea)
      datos.append(0x0A)
    }
    return datos
  }

  /// Una línea rota no se lleva a las demás.
  public static func leer(_ datos: Data) -> [NotaDeLaReunion] {
    let decodificador = JSONDecoder()
    return datos.split(separator: 0x0A).compactMap { try? decodificador.decode(NotaDeLaReunion.self, from: Data($0)) }
  }
}
