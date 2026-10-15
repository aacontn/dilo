import AppIntents
import DiloModes

/// Un modo de Dilo tal como lo ven Atajos, Spotlight y Siri: su id y su
/// nombre, nada del prompt ni del proveedor.
///
/// Lleva una entrada más que no es un modo guardado, **«Sin modo»**: el
/// dictado de siempre, que no pasa por ninguna IA. Es lo que en el panel del
/// hover es no elegir ninguno; un atajo tiene que poder pedirlo por su
/// nombre, porque un parámetro vacío en Siri no se puede decir.
struct ModoDeDilo: AppEntity, Equatable {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Modo de Dilo"
  static let defaultQuery = ConsultaDeModos()

  /// No choca con ningún id real: los de fábrica son palabras (`limpio`,
  /// `correo`), los nuevos un UUID y los migrados `heredado.…`.
  static let idSinModo = "dilo.sin-modo"

  let id: String
  let nombre: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(nombre)")
  }

  var esSinModo: Bool { id == Self.idSinModo }

  static var sinModo: ModoDeDilo {
    ModoDeDilo(id: idSinModo, nombre: String(localized: "Sin modo"))
  }

  init(id: String, nombre: String) {
    self.id = id
    self.nombre = nombre
  }

  init(_ modo: Modo) {
    self.init(id: modo.id, nombre: modo.nombre)
  }
}

/// Los modos que existen ahora, leídos de la app viva cada vez: un modo
/// borrado en Ajustes deja de ofrecerse sin reiniciar nada.
struct ConsultaDeModos: EntityStringQuery {
  func entities(for identifiers: [String]) async throws -> [ModoDeDilo] {
    let todos = await MainActor.run { EjecucionDeAtajos.modos(PuenteDeAtajos.actual) }
    return identifiers.compactMap { id in todos.first { $0.id == id } }
  }

  func suggestedEntities() async throws -> [ModoDeDilo] {
    await MainActor.run { EjecucionDeAtajos.modos(PuenteDeAtajos.actual) }
  }

  func entities(matching texto: String) async throws -> [ModoDeDilo] {
    await MainActor.run { EjecucionDeAtajos.modos(PuenteDeAtajos.actual, que: texto) }
  }
}

/// Cuál de las dos mitades de lo último que dictaste (`UltimoDictado`).
enum MitadDelDictado: String, AppEnum {
  case entregado, original

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Versión del dictado"
  static let caseDisplayRepresentations: [MitadDelDictado: DisplayRepresentation] = [
    .entregado: "Lo que se pegó",
    .original: "Lo que dijiste",
  ]

  var mitad: UltimoDictado.Mitad {
    switch self {
    case .entregado: .entregado
    case .original: .original
    }
  }
}
