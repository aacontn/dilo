import Foundation

/// Un dictado tal como lo ve un agente.
///
/// Sale del historial de la app (`DictationHistoryStore.Entrada`), pero con
/// un id que un agente puede guardar y volver a pedir: el de la app es día +
/// hora + los primeros 24 caracteres, cómodo para SwiftUI y frágil para
/// alguien que lo copia entre dos llamadas.
public struct DictadoParaAgentes: Codable, Equatable, Sendable {
  /// `2026-10-12T09:41:07`, con `#2` si hubo dos en el mismo segundo
  /// (`IdsDeDictados`). Estable mientras el archivo del día no se edite a mano.
  public var id: String
  /// La app a la que iba el texto, si el historial la anotó.
  public var app: String?
  public var modo: String?
  public var motor: String?
  public var texto: String
  /// Sólo en los extractos: el texto está cortado y el entero se pide con
  /// `ver_dictado`. Ausente (y no `false`) cuando está entero, para que la
  /// salida no se llene de una clave que casi nunca dice nada.
  public var recortado: Bool?

  public init(
    id: String, app: String? = nil, modo: String? = nil, motor: String? = nil,
    texto: String, recortado: Bool? = nil
  ) {
    self.id = id
    self.app = app
    self.modo = modo
    self.motor = motor
    self.texto = texto
    self.recortado = recortado
  }
}

/// Lo que el servidor puede leer de Dilo. En la app lo implementa
/// `FuenteDelHistorial`, sobre `DictationHistoryStore.entradas(in:)` y las
/// claves de `UserDefaults` que escribe `AppSettings`; en los tests, una
/// fuente falsa.
public protocol FuenteDeDilo: Sendable {
  /// El historial está apagado de fábrica. Se pregunta en cada llamada y no
  /// al arrancar: un servidor vive lo que dura la sesión del agente, y la
  /// persona puede encenderlo mientras tanto.
  var historialEncendido: Bool { get }
  /// Todos los dictados guardados, del más nuevo al más viejo.
  func dictados() async throws -> [DictadoParaAgentes]
  /// Tus palabras: los nombres y términos que la persona le enseñó a Dilo.
  func tusPalabras() -> [String]
}

/// Los ids de los dictados de un día.
///
/// El historial guarda la hora al segundo, así que dos dictados en el mismo
/// segundo empatan; el segundo lleva `#2`, el tercero `#3`. Se numeran en el
/// orden en que se escribieron —del más viejo al más nuevo— para que un
/// dictado nuevo nunca le cambie el id a uno que un agente ya tiene.
public enum IdsDeDictados {
  /// `("2026-10-12", "[09:41:07]")` → `2026-10-12T09:41:07`.
  public static func base(dia: String, hora: String) -> String {
    let limpia = hora.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
    return "\(dia)T\(limpia)"
  }

  /// Los ids de una lista que viene **del más nuevo al más viejo**, en el
  /// mismo orden.
  public static func asignar(_ bases: [String]) -> [String] {
    var vistos: [String: Int] = [:]
    var ids = [String](repeating: "", count: bases.count)
    for indice in bases.indices.reversed() {
      let base = bases[indice]
      let vez = (vistos[base] ?? 0) + 1
      vistos[base] = vez
      ids[indice] = vez == 1 ? base : "\(base)#\(vez)"
    }
    return ids
  }
}
