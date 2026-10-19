import Foundation

/// Por qué Claude no tradujo. Cada caso es algo que la muesca dice distinto,
/// porque cada uno se arregla distinto: una clave mala no se arregla
/// esperando, y un Anthropic saturado no se arregla cambiando la clave. El
/// texto visible lo pone la app, que tiene el catálogo de idiomas.
public enum FallaDeTraduccion: Error, Equatable, Sendable {
  case faltaLaClave
  /// 401 o 403: la clave no existe, se revocó o no tiene permiso.
  case claveRechazada
  /// 429: el límite de la cuenta.
  case demasiadosPedidos
  /// 5xx, y el 529 de cuando Anthropic está saturado.
  case anthropicNoResponde(codigo: Int)
  /// Cualquier otro 4xx: un pedido que la API no acepta. Si aparece, es un
  /// error de Dilo (un parámetro que el modelo ya no admite), no de la
  /// persona.
  case pedidoRechazado(codigo: Int)
  /// Sin internet, DNS, TLS: no hubo conversación con Anthropic.
  case sinConexion
  case tardoDemasiado
  /// `stop_reason: "refusal"`: un clasificador de seguridad declinó.
  case seNego
  /// `stop_reason: "max_tokens"`: la traducción salió cortada. Nunca se pega
  /// a medias.
  case cortada
  /// Una respuesta que no se pudo leer o que venía vacía.
  case respuestaInutil

  /// Para el log: una palabra, sin texto de nadie.
  public var nombreEnElLog: String {
    switch self {
    case .faltaLaClave: "faltaLaClave"
    case .claveRechazada: "claveRechazada"
    case .demasiadosPedidos: "demasiadosPedidos"
    case let .anthropicNoResponde(codigo): "anthropicNoResponde(\(codigo))"
    case let .pedidoRechazado(codigo): "pedidoRechazado(\(codigo))"
    case .sinConexion: "sinConexion"
    case .tardoDemasiado: "tardoDemasiado"
    case .seNego: "seNego"
    case .cortada: "cortada"
    case .respuestaInutil: "respuestaInutil"
    }
  }

  /// La falla que corresponde a un código HTTP que no es 2xx.
  public static func por(codigo: Int) -> FallaDeTraduccion {
    switch codigo {
    case 401, 403: .claveRechazada
    case 429: .demasiadosPedidos
    case 408: .tardoDemasiado
    case 500...: .anthropicNoResponde(codigo: codigo)
    default: .pedidoRechazado(codigo: codigo)
    }
  }

  /// La falla que corresponde a un error de red. El timeout de URLSession es
  /// el mismo problema que el plazo propio: no contestó a tiempo.
  public static func por(_ error: URLError) -> FallaDeTraduccion {
    error.code == .timedOut ? .tardoDemasiado : .sinConexion
  }
}

/// Lo que se lee de una respuesta de la API de mensajes de Anthropic. Lo
/// comparten la traducción y los modos (`ClienteHTTP`), para que los dos
/// miren `stop_reason` igual.
public enum RespuestaDeAnthropic {
  public enum Falla: Error, Equatable, Sendable {
    case ilegible
    case seNego
    case cortada
  }

  /// El texto de la respuesta: sólo los bloques `text`, en orden. Los
  /// modelos actuales piensan antes de contestar y mandan bloques `thinking`
  /// (vacíos, salvo que se pida verlos) delante del texto; se ignoran.
  ///
  /// `stop_reason` se mira antes que el texto. Un `refusal` puede traer un
  /// texto a medias, y un `max_tokens` trae una traducción cortada: ninguno
  /// de los dos es algo para pegar en el documento de alguien.
  public static func texto(de datos: Data) throws(Falla) -> String {
    guard let raiz = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
      let bloques = raiz["content"] as? [[String: Any]]
    else {
      throw .ilegible
    }
    switch raiz["stop_reason"] as? String {
    case "refusal": throw .seNego
    case "max_tokens": throw .cortada
    default: break
    }
    return bloques.compactMap { bloque -> String? in
      guard bloque["type"] as? String == "text" else { return nil }
      return bloque["text"] as? String
    }.joined()
  }
}

/// Traduce un dictado con Claude Haiku 5.5 por la API de Anthropic.
///
/// Alfonso, 2026-10-19: «Las traducciones son malísimas. Hagamos un modo de
/// traducción más pro […] que se vea como inglés nativo […] que lo haga
/// Haiku 5.5». HTTP crudo con `URLSession`, como `ClienteHTTP`: Swift no
/// tiene SDK oficial de Anthropic y una dependencia nueva no se justifica
/// para un POST.
///
/// **Lo que este request no lleva, y por qué** (cada uno devuelve 400 en los
/// modelos Claude actuales): ni `temperature`, ni `top_p`, ni `top_k`; ni
/// `thinking` ni `budget_tokens` —Haiku 5.5 piensa de forma adaptativa por
/// omisión y la profundidad se elige con `output_config.effort`—; ni un
/// mensaje final de `assistant` para precargar la respuesta.
///
/// La clave entra por parámetro (la lee del Llavero quien arma esto, en el
/// momento de traducir) y nunca se escribe en un log, ni truncada.
public struct TraductorConClaude: Sendable {
  public typealias Transporte = @Sendable (URLRequest) async throws -> (Data, URLResponse)

  /// Claude Haiku 5.5, el id exacto y sin sufijo de fecha. La traducción no
  /// sigue el modelo que se elija para los modos: está afinada para éste.
  public static let modelo = ModelosDeAnthropic.haiku.id
  /// Cuánto piensa antes de traducir. `low` porque un dictado se espera con
  /// la muesca abierta y cada segundo se nota; si la calidad no alcanza, el
  /// siguiente escalón es `medium` —el de fábrica de Haiku 5.5—, que piensa
  /// más y tarda más. Se cambia acá y en ningún otro lado.
  public static let esfuerzo = "low"
  /// El techo de la respuesta. Holgado porque lo que el modelo piensa también
  /// cuenta contra este número: un techo justo para el texto corta un
  /// dictado largo aunque la traducción cupiera de sobra.
  public static let maximoDeTokens = 8_000
  /// Cuánto se espera la traducción entera. Un dictado de un párrafo vuelve
  /// en uno o dos segundos con esfuerzo `low`; doce es el margen para una
  /// red lenta, no lo esperado. Pasado eso, la muesca lo dice.
  public static let plazoPorDefecto = Duration.seconds(12)
  public static let urlBasePorDefecto = URL(string: "https://api.anthropic.com/v1")!

  public let clave: String?
  public let urlBase: URL
  public var plazo: Duration
  public let transporte: Transporte

  public init(
    clave: String?,
    urlBase: URL = TraductorConClaude.urlBasePorDefecto,
    plazo: Duration = TraductorConClaude.plazoPorDefecto,
    transporte: @escaping Transporte = { peticion in
      try await URLSession.shared.data(for: peticion)
    }
  ) {
    self.clave = clave
    self.urlBase = urlBase
    self.plazo = plazo
    self.transporte = transporte
  }

  /// La traducción, o una `FallaDeTraduccion`. Nada más sale de acá salvo la
  /// cancelación de quien espera.
  public func traducir(_ texto: String, a destino: DestinoDeTraduccion) async throws -> String {
    // Nada que traducir no es una falla, y no vale un viaje a Anthropic.
    guard !texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return texto }
    let request = try armar(texto, a: destino)
    let plazo = plazo
    return try await withThrowingTaskGroup(of: String.self) { grupo in
      grupo.addTask { try await self.enviar(request, dictado: texto) }
      grupo.addTask {
        try await Task.sleep(for: plazo)
        throw FallaDeTraduccion.tardoDemasiado
      }
      // El que pierde se cancela: URLSession corta la conexión, y una
      // petición colgada no se queda con las palabras de alguien.
      defer { grupo.cancelAll() }
      guard let primero = try await grupo.next() else { throw FallaDeTraduccion.tardoDemasiado }
      return primero
    }
  }

  func armar(_ texto: String, a destino: DestinoDeTraduccion) throws(FallaDeTraduccion) -> URLRequest {
    guard let clave = clave?.trimmingCharacters(in: .whitespacesAndNewlines), !clave.isEmpty else {
      throw .faltaLaClave
    }
    var request = URLRequest(url: urlBase.appending(path: "messages"))
    request.httpMethod = "POST"
    request.setValue(clave, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let cuerpo: [String: Any] = [
      "model": Self.modelo,
      "max_tokens": Self.maximoDeTokens,
      "system": PromptDeTraduccion.instrucciones(para: destino),
      "messages": [["role": "user", "content": PromptDeTraduccion.peticion(texto, a: destino)]],
      "output_config": ["effort": Self.esfuerzo],
    ]
    guard let datos = try? JSONSerialization.data(withJSONObject: cuerpo) else {
      throw .respuestaInutil
    }
    request.httpBody = datos
    return request
  }

  func enviar(_ request: URLRequest, dictado: String) async throws -> String {
    let datos: Data
    let respuesta: URLResponse
    do {
      (datos, respuesta) = try await transporte(request)
    } catch let error as URLError where error.code != .cancelled {
      throw FallaDeTraduccion.por(error)
    }
    if let http = respuesta as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
      throw FallaDeTraduccion.por(codigo: http.statusCode)
    }
    return try leer(datos, dictado: dictado)
  }

  func leer(_ datos: Data, dictado: String) throws(FallaDeTraduccion) -> String {
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
    let limpio = PromptDeTraduccion.limpiar(texto, dictado: dictado)
    guard !limpio.isEmpty else { throw .respuestaInutil }
    return limpio
  }
}
