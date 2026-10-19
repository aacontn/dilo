import Foundation

/// Cómo se le pide a un proveedor que reescriba un texto.
///
/// Un método. El resto —qué prompt, con qué modo, qué hacer si falla— vive
/// afuera, en reglas puras que se testean sin red.
public protocol ClienteDeProveedor: Sendable {
  func responder(
    instrucciones: String, peticion: String, modelo: String
  ) async throws -> String

  /// Lo mismo, pidiendo la salida con forma (`{"texto": …}`) y sin azar. Es
  /// lo que usan los modos: un «Claro, aquí tienes:» queda fuera del campo,
  /// y el mismo dictado da la misma limpieza dos veces.
  func reescribir(
    instrucciones: String, peticion: String, modelo: String
  ) async throws -> String
}

public extension ClienteDeProveedor {
  func reescribir(
    instrucciones: String, peticion: String, modelo: String
  ) async throws -> String {
    SalidaConForma.desarmar(
      try await responder(instrucciones: instrucciones, peticion: peticion, modelo: modelo)
    )
  }
}

public enum FallaDelProveedor: Error, Equatable {
  case faltaLaClave
  case faltaLaURLBase
  case respondioMal(codigo: Int)
  case respuestaIlegible
  case respuestaVacia
  /// Anthropic: un clasificador de seguridad declinó (`stop_reason:
  /// "refusal"`).
  case seNego
  /// Anthropic: la respuesta llegó al techo de tokens y salió cortada. Un
  /// texto a medias no se pega.
  case respuestaCortada
}

/// El cliente HTTP para OpenAI, Gemini, Anthropic y cualquier endpoint que
/// hable el dialecto de OpenAI (Ollama, LM Studio, el servidor de alguien).
///
/// El transporte es una costura: los tests arman el request y leen la
/// respuesta sin abrir un socket. Una clave nunca se escribe en un log, ni
/// siquiera truncada.
public struct ClienteHTTP: ClienteDeProveedor {
  public typealias Transporte = @Sendable (URLRequest) async throws -> (Data, URLResponse)

  public let proveedor: Proveedor
  public let clave: String?
  public let transporte: Transporte

  public init(
    proveedor: Proveedor,
    clave: String?,
    transporte: @escaping Transporte = { peticion in
      try await URLSession.shared.data(for: peticion)
    }
  ) {
    self.proveedor = proveedor
    self.clave = clave
    self.transporte = transporte
  }

  public func responder(
    instrucciones: String, peticion: String, modelo: String
  ) async throws -> String {
    try await enviar(armar(instrucciones: instrucciones, peticion: peticion, modelo: modelo))
  }

  public func reescribir(
    instrucciones: String, peticion: String, modelo: String
  ) async throws -> String {
    do {
      return SalidaConForma.desarmar(
        try await enviar(
          armar(instrucciones: instrucciones, peticion: peticion, modelo: modelo, conForma: true)
        )
      )
    } catch let FallaDelProveedor.respondioMal(codigo) where codigo == 400 {
      // Un compatible viejo que no conoce el esquema, o un modelo de
      // razonamiento que sólo acepta su propia temperatura, contesta 400. Se
      // repite una vez sin las opciones y al mismo proveedor: nunca a otro.
      return SalidaConForma.desarmar(
        try await responder(instrucciones: instrucciones, peticion: peticion, modelo: modelo)
      )
    }
  }

  func enviar(_ request: URLRequest) async throws -> String {
    let (datos, respuesta) = try await transporte(request)
    if let http = respuesta as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
      throw FallaDelProveedor.respondioMal(codigo: http.statusCode)
    }
    let texto = try leer(datos)
    let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !limpio.isEmpty else { throw FallaDelProveedor.respuestaVacia }
    return limpio
  }

  /// - Parameter conForma: temperatura 0 y la salida `{"texto": …}`, con
  ///   el esquema en el dialecto de cada uno. Anthropic no tiene esquema
  ///   nativo: ahí lo pide el marco del prompt y la respuesta se desarma
  ///   igual. Y a Anthropic tampoco va la temperatura (ver abajo).
  func armar(
    instrucciones: String, peticion: String, modelo: String, conForma: Bool = false
  ) throws -> URLRequest {
    guard let base = proveedor.urlBase else { throw FallaDelProveedor.faltaLaURLBase }
    if proveedor.necesitaClave, clave?.isEmpty ?? true {
      throw FallaDelProveedor.faltaLaClave
    }

    var request: URLRequest
    var cuerpo: [String: Any]

    switch proveedor.dialecto {
    case .enElChip:
      // El modelo del chip no habla HTTP. Que llegue acá es un error de
      // cableado, no de configuración de la persona.
      throw FallaDelProveedor.faltaLaURLBase

    case .compatibleOpenAI:
      request = URLRequest(url: base.appending(path: "chat/completions"))
      if let clave, !clave.isEmpty {
        request.setValue("Bearer \(clave)", forHTTPHeaderField: "Authorization")
      }
      cuerpo = [
        "model": modelo,
        "messages": [
          ["role": "system", "content": instrucciones],
          ["role": "user", "content": peticion],
        ],
      ]

    case .gemini:
      request = URLRequest(
        url: base.appending(path: "models/\(modelo):generateContent")
      )
      // La clave va en el header, nunca en la query: una URL con la clave
      // adentro termina en un log de red o en el historial de alguien.
      if let clave, !clave.isEmpty {
        request.setValue(clave, forHTTPHeaderField: "x-goog-api-key")
      }
      cuerpo = [
        "systemInstruction": ["parts": [["text": instrucciones]]],
        "contents": [["role": "user", "parts": [["text": peticion]]]],
      ]

    case .anthropic:
      request = URLRequest(url: base.appending(path: "messages"))
      if let clave, !clave.isEmpty {
        request.setValue(clave, forHTTPHeaderField: "x-api-key")
      }
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
      // El techo y el esfuerzo dependen del modelo: a los de la lista de
      // Ajustes, `effort` bajo y espacio para lo que piensan; a uno escrito a
      // mano, lo de siempre (`ModelosDeAnthropic.opciones`).
      let opciones = ModelosDeAnthropic.opciones(para: modelo)
      cuerpo = [
        "model": modelo,
        "max_tokens": opciones.maximoDeTokens,
        "system": instrucciones,
        "messages": [["role": "user", "content": peticion]],
      ]
      if let esfuerzo = opciones.esfuerzo {
        cuerpo["output_config"] = ["effort": esfuerzo]
      }
    }

    if conForma {
      switch proveedor.dialecto {
      case .compatibleOpenAI:
        cuerpo["temperature"] = 0
        cuerpo["response_format"] = [
          "type": "json_schema",
          "json_schema": [
            "name": "dictado_reescrito", "strict": true, "schema": SalidaConForma.esquema,
          ],
        ]
      case .gemini:
        cuerpo["generationConfig"] = [
          "temperature": 0,
          "responseMimeType": "application/json",
          "responseSchema": [
            "type": "OBJECT",
            "properties": ["texto": ["type": "STRING"]],
            "required": ["texto"],
          ],
        ]
      case .anthropic, .enElChip:
        // Anthropic sin `temperature` (2026-10-19). Los modelos Claude
        // actuales —Haiku 5.5, Sonnet 5.5, Opus 5.5— devuelven 400 ante
        // cualquier valor de muestreo que no sea el suyo, y con
        // `temperature: 0` cada modo hacía un viaje perdido antes del
        // reintento sin opciones de `reescribir`. Los modelos viejos que sí
        // la aceptaban pierden el «sin azar», que la forma del prompt y el
        // validador ya sostienen.
        break
      }
    }

    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: cuerpo)
    return request
  }

  func leer(_ datos: Data) throws -> String {
    guard let raiz = try? JSONSerialization.jsonObject(with: datos) as? [String: Any] else {
      throw FallaDelProveedor.respuestaIlegible
    }

    switch proveedor.dialecto {
    case .compatibleOpenAI, .enElChip:
      let opciones = raiz["choices"] as? [[String: Any]]
      let mensaje = opciones?.first?["message"] as? [String: Any]
      guard let texto = mensaje?["content"] as? String else {
        throw FallaDelProveedor.respuestaIlegible
      }
      return texto

    case .gemini:
      let candidatos = raiz["candidates"] as? [[String: Any]]
      let contenido = candidatos?.first?["content"] as? [String: Any]
      let partes = contenido?["parts"] as? [[String: Any]]
      let texto = partes?.compactMap { $0["text"] as? String }.joined()
      guard let texto else { throw FallaDelProveedor.respuestaIlegible }
      return texto

    case .anthropic:
      // La misma lectura que la traducción: sólo bloques `text`, y un
      // `refusal` o un `max_tokens` son fallas, no texto para pegar.
      do {
        return try RespuestaDeAnthropic.texto(de: datos)
      } catch {
        switch error {
        case .ilegible: throw FallaDelProveedor.respuestaIlegible
        case .seNego: throw FallaDelProveedor.seNego
        case .cortada: throw FallaDelProveedor.respuestaCortada
        }
      }
    }
  }
}
