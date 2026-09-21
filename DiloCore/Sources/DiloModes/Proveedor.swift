import Foundation

/// Quién reescribe el texto de un modo.
///
/// Dilo no trae un LLM adentro (eso sería una dependencia nueva y pesada) ni
/// nombres de negocio en el núcleo: los proveedores entran por contrato. Lo
/// único que este tipo sabe es cómo se le habla a cada uno y si el texto sale
/// o no de esta compu.
public struct Proveedor: Codable, Equatable, Identifiable, Sendable {
  /// Cómo se le habla. No es el nombre de la empresa: es el formato del
  /// request, y por eso `compatibleOpenAI` sirve para Ollama, LM Studio o
  /// cualquier endpoint que hable ese dialecto.
  public enum Dialecto: String, Codable, Sendable {
    case enElChip
    case compatibleOpenAI
    case gemini
    case anthropic
  }

  public var id: String
  public var nombre: String
  public var dialecto: Dialecto
  /// Nil sólo para el modelo que corre en el chip, que no tiene endpoint.
  public var urlBase: URL?
  /// El id de modelo tal cual lo muestra la consola del proveedor. Vacío
  /// cuenta como "sin configurar": un POST sin modelo manda tu dictado a un
  /// servidor para nada (spec 2026-07-29, cambio 1).
  public var modelo: String

  public init(
    id: String,
    nombre: String,
    dialecto: Dialecto,
    urlBase: URL? = nil,
    modelo: String = ""
  ) {
    self.id = id
    self.nombre = nombre
    self.dialecto = dialecto
    self.urlBase = urlBase
    self.modelo = modelo
  }

  /// Si el texto se queda en esta compu. Se **deriva**, nunca se guarda: el
  /// proveedor a medida viene apuntando a Ollama en localhost, y si alguien lo
  /// cambia a un servidor remoto tiene que dejar de decir LOCAL solo, sin
  /// depender de que nadie se acuerde de bajar una bandera.
  public var esLocal: Bool {
    if dialecto == .enElChip { return true }
    guard let host = urlBase?.host()?.lowercased() else { return false }
    return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
  }

  /// Si necesita una clave guardada para funcionar. El modelo del chip no:
  /// ese es todo su punto.
  public var necesitaClave: Bool { dialecto != .enElChip && !esLocal }

  /// La cuenta con que la clave se guarda en el Llavero. Nunca en
  /// `UserDefaults` ni en un archivo (spec, restricciones transversales).
  public var cuentaEnElLlavero: String { "proveedor.\(id)" }

  /// El catálogo de fábrica. El del chip primero porque es el único que
  /// funciona recién instalado, sin cuenta, sin clave y sin internet.
  public static let deFabrica: [Proveedor] = [
    Proveedor(
      id: "chip",
      nombre: "El modelo de Apple, acá mismo",
      dialecto: .enElChip
    ),
    Proveedor(
      id: "openai",
      nombre: "OpenAI",
      dialecto: .compatibleOpenAI,
      urlBase: URL(string: "https://api.openai.com/v1"),
      modelo: ""
    ),
    Proveedor(
      id: "gemini",
      nombre: "Google Gemini",
      dialecto: .gemini,
      urlBase: URL(string: "https://generativelanguage.googleapis.com/v1beta"),
      modelo: ""
    ),
    Proveedor(
      id: "anthropic",
      nombre: "Anthropic",
      dialecto: .anthropic,
      urlBase: URL(string: "https://api.anthropic.com/v1"),
      modelo: ""
    ),
    Proveedor(
      id: "propio",
      nombre: "El tuyo (compatible con OpenAI)",
      dialecto: .compatibleOpenAI,
      urlBase: URL(string: "http://localhost:11434/v1"),
      modelo: ""
    ),
  ]
}

public extension [Proveedor] {
  func proveedor(_ id: String?) -> Proveedor? {
    guard let id else { return nil }
    return first { $0.id == id }
  }
}
