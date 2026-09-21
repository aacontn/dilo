import Foundation

/// Cómo se le pide a un proveedor que reescriba un texto.
///
/// Un método. El resto —qué prompt, con qué modo, qué hacer si falla— vive
/// afuera, en reglas puras que se testean sin red.
public protocol ClienteDeProveedor: Sendable {
  func responder(
    instrucciones: String, peticion: String, modelo: String
  ) async throws -> String
}

public enum FallaDelProveedor: Error, Equatable {
  case faltaLaClave
  case faltaLaURLBase
  case respondioMal(codigo: Int)
  case respuestaIlegible
  case respuestaVacia
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
    let request = try armar(
      instrucciones: instrucciones, peticion: peticion, modelo: modelo
    )
    let (datos, respuesta) = try await transporte(request)
    if let http = respuesta as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
      throw FallaDelProveedor.respondioMal(codigo: http.statusCode)
    }
    let texto = try leer(datos)
    let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !limpio.isEmpty else { throw FallaDelProveedor.respuestaVacia }
    return limpio
  }

  func armar(
    instrucciones: String, peticion: String, modelo: String
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
      cuerpo = [
        "model": modelo,
        "max_tokens": 4096,
        "system": instrucciones,
        "messages": [["role": "user", "content": peticion]],
      ]
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
      let bloques = raiz["content"] as? [[String: Any]]
      let texto = bloques?.compactMap { bloque -> String? in
        guard bloque["type"] as? String == "text" else { return nil }
        return bloque["text"] as? String
      }.joined()
      guard let texto else { throw FallaDelProveedor.respuestaIlegible }
      return texto
    }
  }
}
