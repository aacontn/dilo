import Foundation

/// Un mensaje de la **Conversación**, como viaja a Anthropic: lo que dijo la
/// persona o lo que contestó Dilo. Sólo texto: el audio nunca sale del Mac.
public struct MensajeDeLaConversacion: Equatable, Sendable {
  public enum Rol: String, Sendable {
    case persona = "user"
    case dilo = "assistant"
  }

  public let rol: Rol
  public let texto: String

  public init(_ rol: Rol, _ texto: String) {
    self.rol = rol
    self.texto = texto
  }
}

/// Lo que se le dice a Claude en una **Conversación**, versionado.
///
/// En español a propósito, y no en inglés como el de traducir: acá la salida
/// **es** español de Chile hablado, y la instrucción en el mismo idioma
/// arrastra el registro. Pide lo que una voz necesita y una pantalla no:
/// frases cortas, nada de listas ni markdown, números y siglas como se dicen.
/// Quien cambie una línea sube `version`.
public enum PromptDeLaConversacion {
  public static let version = 2

  public static let instrucciones = """
    Eres Dilo, un asistente que conversa en voz alta con la persona, como en una llamada. \
    Lo que escribes se lee en voz alta con una voz sintética en el Mac de la persona, y lo \
    que ella dice te llega transcrito por un motor de voz que a veces se equivoca en una \
    palabra: si algo no calza, entiende lo más probable y hazlo. Pregunta sólo si de verdad no se puede, y nunca dos veces lo mismo.

    Cómo hablar:
    - Español de Chile, con tuteo, cercano y directo. Sin relleno, sin «¡Excelente pregunta!».
    - Respuestas cortas: una a tres oraciones para la charla y las preguntas simples. Si te \
    piden algo largo (un plan, una explicación a fondo), dilo en párrafos cortos y ofrece seguir.
    - Nada de markdown: ni asteriscos, ni viñetas, ni títulos, ni tablas, ni bloques de código. \
    Si hay pasos, dilos con palabras: «primero…, después…, al final…».
    - Escribe los números, las horas y las siglas como se dicen en voz alta cuando eso ayuda.
    - Si te interrumpen, la persona ya no quiere seguir escuchando lo anterior: contesta lo nuevo.
    - No inventes datos de la persona ni de su computador: no ves su pantalla ni sus archivos.
    """
}

/// El pedido de un **Turno**: qué modelo, cuánto piensa y lo conversado.
public struct PedidoDeConversacion: Equatable, Sendable {
  public var modelo: String
  public var esfuerzo: String
  public var maximoDeTokens: Int
  /// Lo conversado hasta acá, terminando con lo que la persona acaba de
  /// decir. Nunca termina en `assistant`: el prefill es un 400 en los
  /// modelos 5.5.
  public var historial: [MensajeDeLaConversacion]

  public init(modelo: String, esfuerzo: String, maximoDeTokens: Int, historial: [MensajeDeLaConversacion]) {
    self.modelo = modelo
    self.esfuerzo = esfuerzo
    self.maximoDeTokens = maximoDeTokens
    self.historial = historial
  }

  public init(nivel: NivelDeModelo, historial: [MensajeDeLaConversacion]) {
    self.init(
      modelo: nivel.modelo.id, esfuerzo: nivel.esfuerzo, maximoDeTokens: nivel.maximoDeTokens,
      historial: historial
    )
  }
}

/// Lo que va llegando de una respuesta en streaming.
public enum EventoDeLaRespuesta: Equatable, Sendable {
  /// Un pedazo de texto, en el orden en que Claude lo escribe. Sólo los
  /// bloques `text`: lo que llega en `thinking` no se dice.
  case texto(String)
  /// La respuesta terminó entera. `cortada` es `stop_reason: "max_tokens"`:
  /// lo ya dicho se dijo, y no se sigue.
  case fin(UsoDeTokens, cortada: Bool)
}

/// Lee las líneas del stream SSE de `POST /v1/messages` con `stream: true`.
///
/// Anthropic manda un evento por línea `data:` —su JSON entero en una
/// línea—, así que se interpreta cada `data:` al llegar y no se espera la
/// línea en blanco que cierra el evento: `URLSession.AsyncBytes.lines` se
/// salta las líneas vacías y con esa espera nunca saldría nada.
///
/// Puro: recibe líneas y devuelve eventos, sin red. El uso de tokens se
/// junta de dos eventos —la entrada viene en `message_start` y la salida en
/// `message_delta`— y sale con el `fin`.
public struct LectorDeLaRespuesta: Sendable {
  public private(set) var uso = UsoDeTokens()
  private var cortada = false
  public private(set) var termino = false

  public init() {}

  /// Lo que trae esta línea: nada, un pedazo de texto o el fin. Una falla
  /// del stream —`refusal`, un evento `error`— sale como `FallaDeClaude`.
  public mutating func leer(_ linea: String) throws(FallaDeClaude) -> EventoDeLaRespuesta? {
    guard linea.hasPrefix("data:") else { return nil }
    let json = linea.dropFirst(5).trimmingCharacters(in: .whitespaces)
    guard let datos = json.data(using: .utf8),
      let evento = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
      let tipo = evento["type"] as? String
    else { return nil }

    switch tipo {
    case "message_start":
      if let usage = (evento["message"] as? [String: Any])?["usage"] as? [String: Any] {
        sumar(usage)
      }
      return nil
    case "content_block_delta":
      guard let delta = evento["delta"] as? [String: Any],
        delta["type"] as? String == "text_delta",
        let texto = delta["text"] as? String, !texto.isEmpty
      else { return nil }
      return .texto(texto)
    case "message_delta":
      if let usage = evento["usage"] as? [String: Any] { sumar(usage) }
      switch (evento["delta"] as? [String: Any])?["stop_reason"] as? String {
      case "refusal": throw .seNego
      case "max_tokens": cortada = true
      default: break
      }
      return nil
    case "message_stop":
      termino = true
      return .fin(uso, cortada: cortada)
    case "error":
      let error = evento["error"] as? [String: Any]
      throw Self.falla(deTipo: error?["type"] as? String)
    default:
      // `ping`, `content_block_start`, `content_block_stop` y lo que se
      // agregue mañana: nada que decir.
      return nil
    }
  }

  /// `message_delta` trae el uso acumulado; `message_start`, la entrada. Se
  /// toma el mayor de cada campo y no la suma: la salida del delta ya
  /// incluye la del comienzo.
  private mutating func sumar(_ usage: [String: Any]) {
    func valor(_ clave: String) -> Int? { (usage[clave] as? NSNumber)?.intValue }
    if let v = valor("input_tokens") { uso.entrada = max(uso.entrada, v) }
    if let v = valor("output_tokens") { uso.salida = max(uso.salida, v) }
    if let v = valor("cache_creation_input_tokens") { uso.escritosEnCache = max(uso.escritosEnCache, v) }
    if let v = valor("cache_read_input_tokens") { uso.leidosDeCache = max(uso.leidosDeCache, v) }
  }

  /// Un evento `error` a mitad del stream: el mismo nombre que su código.
  public static func falla(deTipo tipo: String?) -> FallaDeClaude {
    switch tipo {
    case "overloaded_error": .anthropicNoResponde(codigo: 529)
    case "api_error": .anthropicNoResponde(codigo: 500)
    case "rate_limit_error": .demasiadosPedidos
    case "authentication_error", "permission_error": .claveRechazada
    case "request_too_large", "invalid_request_error": .pedidoRechazado(codigo: 400)
    default: .respuestaInutil
    }
  }
}

/// Conversa con Claude por la API de Anthropic, **con streaming**: el texto
/// llega a pedazos y la voz empieza con la primera oración completa, en vez
/// de esperar la respuesta entera.
///
/// Es el mismo `POST /v1/messages` que `TraductorConClaude` y
/// `ConsultaAClaude` —la misma clave, `anthropic-version`, las mismas fallas
/// (`FallaDeClaude`)— más `stream: true`. **Lo que no lleva**, igual que
/// ellos: ni `temperature`, ni `top_p`, ni `top_k`, ni `thinking` (omitirlo es
/// pensar de forma adaptativa; Sonnet 5.5 y Opus 5.5 rechazan `disabled`), ni
/// un `assistant` final. La profundidad la da `output_config.effort`.
///
/// Lleva `cache_control` arriba del todo: la API pone sola el corte de la
/// caché al final de lo conversado, y el turno siguiente lee de ahí lo que
/// ya mandó, a un décimo del precio. Una conversación corta no llega al
/// mínimo cacheable y no cuesta nada tenerlo puesto.
///
/// Sólo `Foundation`: `scripts/probar-conversacion.sh` lo compila con su
/// driver.
public struct ClienteDeConversacion: Sendable {
  /// Las líneas de la respuesta y su encabezado HTTP. Una costura para que
  /// los tests le pasen líneas escritas a mano; en la app es
  /// `URLSession.bytes(for:)`.
  public typealias Transporte = @Sendable (URLRequest) async throws -> (
    lineas: AsyncThrowingStream<String, any Error>, respuesta: URLResponse
  )

  /// Cuánto se espera el primer byte. Opus en `high` puede pensar un rato
  /// antes de escribir la primera palabra; pasado esto, la conversación
  /// dice que Claude tardó.
  public static let plazoDelPrimerByte: TimeInterval = 45

  public let clave: String?
  public let urlBase: URL
  public let transporte: Transporte

  public init(
    clave: String?,
    urlBase: URL = TraductorConClaude.urlBasePorDefecto,
    transporte: @escaping Transporte = ClienteDeConversacion.transporteDeURLSession
  ) {
    self.clave = clave
    self.urlBase = urlBase
    self.transporte = transporte
  }

  /// Los eventos de la respuesta, a medida que llegan. Termina con `.fin` o
  /// con una `FallaDeClaude`; cancelar la tarea que lo recorre corta la
  /// conexión.
  public func responder(_ pedido: PedidoDeConversacion) -> AsyncThrowingStream<EventoDeLaRespuesta, any Error> {
    AsyncThrowingStream { continuacion in
      let tarea = Task {
        do {
          let request = try armar(pedido)
          let (lineas, respuesta) = try await transporte(request)
          if let http = respuesta as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FallaDeClaude.por(codigo: http.statusCode)
          }
          var lector = LectorDeLaRespuesta()
          for try await linea in lineas {
            if let evento = try lector.leer(linea) { continuacion.yield(evento) }
            if lector.termino { break }
          }
          // Un stream que se corta sin `message_stop` no es una respuesta
          // entera: lo dicho se dijo, pero no se anota como terminado.
          guard lector.termino else { throw FallaDeClaude.sinConexion }
          continuacion.finish()
        } catch let error as URLError where error.code != .cancelled {
          continuacion.finish(throwing: FallaDeClaude.por(error))
        } catch {
          continuacion.finish(throwing: error)
        }
      }
      continuacion.onTermination = { _ in tarea.cancel() }
    }
  }

  func armar(_ pedido: PedidoDeConversacion) throws(FallaDeClaude) -> URLRequest {
    guard let clave = clave?.trimmingCharacters(in: .whitespacesAndNewlines), !clave.isEmpty else {
      throw .faltaLaClave
    }
    guard pedido.historial.last?.rol == .persona else {
      // Terminar en `assistant` es un prefill: 400 en los modelos 5.5.
      throw .pedidoRechazado(codigo: 0)
    }
    var request = URLRequest(url: urlBase.appending(path: "messages"))
    request.httpMethod = "POST"
    request.setValue(clave, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    // Con streaming el plazo de URLSession cuenta entre bytes, no la
    // respuesta entera: lo que importa es que empiece a hablar.
    request.timeoutInterval = Self.plazoDelPrimerByte
    let cuerpo: [String: Any] = [
      "model": pedido.modelo,
      "max_tokens": pedido.maximoDeTokens,
      "stream": true,
      "system": PromptDeLaConversacion.instrucciones,
      "messages": pedido.historial.map { ["role": $0.rol.rawValue, "content": $0.texto] },
      "output_config": ["effort": pedido.esfuerzo],
      "cache_control": ["type": "ephemeral"],
    ]
    guard let datos = try? JSONSerialization.data(withJSONObject: cuerpo) else {
      throw .respuestaInutil
    }
    request.httpBody = datos
    return request
  }

  /// `URLSession.bytes(for:)`, línea por línea.
  public static let transporteDeURLSession: Transporte = { request in
    let (bytes, respuesta) = try await URLSession.shared.bytes(for: request)
    let lineas = AsyncThrowingStream<String, any Error> { continuacion in
      let tarea = Task {
        do {
          for try await linea in bytes.lines { continuacion.yield(linea) }
          continuacion.finish()
        } catch {
          continuacion.finish(throwing: error)
        }
      }
      continuacion.onTermination = { _ in tarea.cancel() }
    }
    return (lineas, respuesta)
  }
}
