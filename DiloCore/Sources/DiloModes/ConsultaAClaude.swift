import Foundation

/// Las fallas de una consulta a Claude son las mismas que las de traducir:
/// la clave, el límite, la red, el plazo, el `refusal` y el `max_tokens`.
/// Un solo tipo, para que el aprendizaje y la traducción se lean igual en el
/// log (`nombreEnElLog`).
public typealias FallaDeClaude = FallaDeTraduccion

/// Una pregunta a Claude que contesta JSON con forma.
///
/// La usa el aprendizaje (2026-10-19): Claude Haiku 5.5 revisa cada
/// corrección y Claude Sonnet 5.5 ordena Tus palabras de vez en cuando. Es el
/// mismo `POST /v1/messages` que `TraductorConClaude` —la misma clave, la
/// misma lectura de la respuesta (`RespuestaDeAnthropic`), las mismas fallas—
/// más `output_config.format`, que obliga a la salida a calzar con un
/// esquema JSON: lo que vuelve se valida igual, pero ya no hay que pescar el
/// JSON dentro de un «Claro, aquí tienes:».
///
/// **Lo que este request no lleva**, igual que la traducción: ni
/// `temperature`, ni `top_p`, ni `top_k` (400 en Haiku, Sonnet y Opus 5.5);
/// ni `thinking` —omitirlo es pensar de forma adaptativa, y Sonnet 5.5
/// rechaza `disabled`—; ni un `assistant` final. La profundidad se elige con
/// `output_config.effort`.
///
/// Sólo `Foundation`: `scripts/probar-aprendizaje.sh` lo compila con el
/// driver.
public struct ConsultaAClaude: Sendable {
  public typealias Transporte = @Sendable (URLRequest) async throws -> (Data, URLResponse)

  /// Lo que se le pregunta. El esquema viaja ya serializado: un diccionario
  /// de `Any` no cruza entre tareas.
  public struct Pedido: Sendable, Equatable {
    public var modelo: String
    /// `low`, `medium`, `high`… Haiku y Opus 5.5 traen `medium` por omisión
    /// y Sonnet 5.5 `high`: se manda siempre, explícito.
    public var esfuerzo: String
    /// Holgado: lo que el modelo piensa también cuenta contra este número.
    public var maximoDeTokens: Int
    public var sistema: String
    public var peticion: String
    /// El JSON Schema de la salida (`output_config.format.schema`).
    public var esquema: String
    public var plazo: Duration

    public init(
      modelo: String, esfuerzo: String, maximoDeTokens: Int,
      sistema: String, peticion: String, esquema: String, plazo: Duration
    ) {
      self.modelo = modelo
      self.esfuerzo = esfuerzo
      self.maximoDeTokens = maximoDeTokens
      self.sistema = sistema
      self.peticion = peticion
      self.esquema = esquema
      self.plazo = plazo
    }
  }

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

  /// El texto de la respuesta —el JSON—, o una `FallaDeClaude`. Nada más sale
  /// de acá salvo la cancelación de quien espera.
  public func pedir(_ pedido: Pedido) async throws -> String {
    let request = try armar(pedido)
    let plazo = pedido.plazo
    return try await withThrowingTaskGroup(of: String.self) { grupo in
      grupo.addTask { try await self.enviar(request) }
      grupo.addTask {
        try await Task.sleep(for: plazo)
        throw FallaDeClaude.tardoDemasiado
      }
      // El que pierde se cancela: URLSession corta la conexión.
      defer { grupo.cancelAll() }
      guard let primero = try await grupo.next() else { throw FallaDeClaude.tardoDemasiado }
      return primero
    }
  }

  func armar(_ pedido: Pedido) throws(FallaDeClaude) -> URLRequest {
    guard let clave = clave?.trimmingCharacters(in: .whitespacesAndNewlines), !clave.isEmpty else {
      throw .faltaLaClave
    }
    guard let esquema = try? JSONSerialization.jsonObject(with: Data(pedido.esquema.utf8)) else {
      // Un esquema mal escrito es un error de Dilo; nunca se manda.
      throw .pedidoRechazado(codigo: 0)
    }
    var request = URLRequest(url: urlBase.appending(path: "messages"))
    request.httpMethod = "POST"
    request.setValue(clave, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    // El plazo propio manda; sin esto, URLSession corta a los 60 s sin
    // bytes, y una respuesta sin streaming no manda ninguno hasta terminar.
    request.timeoutInterval = Double(pedido.plazo.components.seconds) + 5
    let cuerpo: [String: Any] = [
      "model": pedido.modelo,
      "max_tokens": pedido.maximoDeTokens,
      "system": pedido.sistema,
      "messages": [["role": "user", "content": pedido.peticion]],
      "output_config": [
        "effort": pedido.esfuerzo,
        "format": ["type": "json_schema", "schema": esquema],
      ],
    ]
    guard let datos = try? JSONSerialization.data(withJSONObject: cuerpo) else {
      throw .respuestaInutil
    }
    request.httpBody = datos
    return request
  }

  func enviar(_ request: URLRequest) async throws -> String {
    let datos: Data
    let respuesta: URLResponse
    do {
      (datos, respuesta) = try await transporte(request)
    } catch let error as URLError where error.code != .cancelled {
      throw FallaDeClaude.por(error)
    }
    if let http = respuesta as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
      throw FallaDeClaude.por(codigo: http.statusCode)
    }
    return try leer(datos)
  }

  /// Sólo los bloques `text`; `refusal` y `max_tokens` son fallas, nunca un
  /// JSON a medias.
  func leer(_ datos: Data) throws(FallaDeClaude) -> String {
    let texto: String
    do {
      texto = try RespuestaDeAnthropic.texto(de: datos)
    } catch {
      switch error {
      case .ilegible: throw .respuestaInutil
      case .seNego: throw .seNego
      case .cortada: throw .cortada
      }
    }
    let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !limpio.isEmpty else { throw .respuestaInutil }
    return limpio
  }
}
