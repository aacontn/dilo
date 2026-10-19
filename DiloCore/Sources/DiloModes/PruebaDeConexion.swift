import Foundation

/// «Probar conexión» de Ajustes → Claude: si la clave de Anthropic sirve,
/// con la llamada más chica que la API tiene.
///
/// Es `GET /v1/models/claude-haiku-5-5` (2026-10-19): con la clave, valida
/// que la cuenta exista, que la clave no esté revocada y que el modelo de
/// fábrica de Dilo esté disponible para ella, **sin generar un token**, así
/// que no cuesta nada. Un `POST /v1/messages` de prueba también contestaría,
/// pero cobra y piensa. Se llama sólo al apretar el botón; nunca al abrir la
/// sección, nunca desde un test.
///
/// Las fallas son las de traducir (`FallaDeClaude`): la misma frase para el
/// mismo problema en la muesca y en Ajustes.
///
/// Sólo `Foundation`, como `TraductorConClaude`.
public struct PruebaDeConexion: Sendable {
  public typealias Transporte = @Sendable (URLRequest) async throws -> (Data, URLResponse)

  public enum Resultado: Equatable, Sendable {
    /// La clave sirve y el modelo está disponible.
    case lista(modelo: String)
    case falla(FallaDeClaude)
  }

  /// El modelo que se pregunta: el de fábrica de los modos y de traducir.
  public static let modelo = ModelosDeAnthropic.deFabrica.id
  /// Poco: es una pregunta de metadatos, no una generación.
  public static let plazo: TimeInterval = 10

  public let clave: String?
  public let urlBase: URL
  public let transporte: Transporte

  public init(
    clave: String?,
    urlBase: URL = TraductorConClaude.urlBasePorDefecto,
    transporte: @escaping Transporte = { peticion in
      try await URLSession.shared.data(for: peticion)
    }
  ) {
    self.clave = clave
    self.urlBase = urlBase
    self.transporte = transporte
  }

  public func probar() async -> Resultado {
    let request: URLRequest
    do {
      request = try armar()
    } catch {
      return .falla(error)
    }
    do {
      let (datos, respuesta) = try await transporte(request)
      guard let http = respuesta as? HTTPURLResponse else { return .falla(.respuestaInutil) }
      guard (200..<300).contains(http.statusCode) else {
        return .falla(FallaDeClaude.por(codigo: http.statusCode))
      }
      return Self.leer(datos)
    } catch let error as URLError {
      return .falla(FallaDeClaude.por(error))
    } catch {
      return .falla(.sinConexion)
    }
  }

  func armar() throws(FallaDeClaude) -> URLRequest {
    guard let clave = clave?.trimmingCharacters(in: .whitespacesAndNewlines), !clave.isEmpty else {
      throw .faltaLaClave
    }
    var request = URLRequest(url: urlBase.appending(path: "models").appending(path: Self.modelo))
    request.httpMethod = "GET"
    request.setValue(clave, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.timeoutInterval = Self.plazo
    return request
  }

  /// La respuesta trae el modelo con su `id`; si no, algo cambió en la API y
  /// no se puede decir que la conexión esté bien.
  static func leer(_ datos: Data) -> Resultado {
    guard
      let objeto = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
      let id = objeto["id"] as? String, !id.isEmpty
    else { return .falla(.respuestaInutil) }
    return .lista(modelo: id)
  }
}
