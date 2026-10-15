import Foundation

/// Un valor JSON cualquiera, tipado.
///
/// Alcanza para JSON-RPC sin arrastrar `[String: Any]`, que no es `Sendable`
/// y obliga a castear en cada lectura. Los números van como `Double` porque
/// así los trae JSON; los ids de JSON-RPC enteros vuelven a salir enteros
/// (`JSONEncoder` escribe `1`, no `1.0`), y eso lo vigila un test.
public enum ValorJSON: Codable, Equatable, Sendable {
  case nulo
  case bool(Bool)
  case numero(Double)
  case texto(String)
  case lista([ValorJSON])
  case objeto([String: ValorJSON])

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    // El orden importa: `Bool` antes que `Double`, o un `true` se leería
    // como número en los decodificadores que lo permiten.
    if c.decodeNil() {
      self = .nulo
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Double.self) {
      self = .numero(v)
    } else if let v = try? c.decode(String.self) {
      self = .texto(v)
    } else if let v = try? c.decode([ValorJSON].self) {
      self = .lista(v)
    } else {
      self = .objeto(try c.decode([String: ValorJSON].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .nulo: try c.encodeNil()
    case let .bool(v): try c.encode(v)
    case let .numero(v): try c.encode(v)
    case let .texto(v): try c.encode(v)
    case let .lista(v): try c.encode(v)
    case let .objeto(v): try c.encode(v)
    }
  }

  public subscript(_ clave: String) -> ValorJSON? {
    if case let .objeto(o) = self { return o[clave] }
    return nil
  }

  public var comoTexto: String? {
    if case let .texto(v) = self { return v }
    return nil
  }

  /// Sólo un número sin decimales: `2.5` como «máximo» no es un entero, y
  /// redondearlo en silencio es inventar lo que el agente no pidió.
  public var comoEntero: Int? {
    guard case let .numero(v) = self, v.rounded() == v, abs(v) < 1e15 else { return nil }
    return Int(v)
  }

  public static func entero(_ n: Int) -> ValorJSON { .numero(Double(n)) }

  /// Lee una línea de JSON. Nil si no es JSON.
  public static func leer(_ texto: String) -> ValorJSON? {
    try? JSONDecoder().decode(ValorJSON.self, from: Data(texto.utf8))
  }

  /// Una sola línea, con las claves ordenadas: por stdio un mensaje es una
  /// línea (un salto adentro partiría el mensaje en dos), y ordenarlas hace
  /// que la salida se pueda comparar en un test.
  public var enUnaLinea: String {
    Self.codificar(self, formato: [.sortedKeys, .withoutEscapingSlashes])
  }

  /// Para una persona en un terminal: sangrado y ordenado.
  public var legible: String {
    Self.codificar(self, formato: [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted])
  }

  static func codificar<T: Encodable>(_ valor: T, formato: JSONEncoder.OutputFormatting) -> String {
    let codificador = JSONEncoder()
    codificador.outputFormatting = formato
    return (try? codificador.encode(valor)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
  }

  /// Cualquier `Encodable` como valor JSON, para meterlo dentro de un sobre.
  static func desde<T: Encodable>(_ valor: T) -> ValorJSON {
    let texto = codificar(valor, formato: [.sortedKeys])
    return leer(texto) ?? .nulo
  }
}
