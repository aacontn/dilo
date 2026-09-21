import Foundation
import Testing

@testable import DiloModes

/// El request que sale y la respuesta que entra, sin abrir un socket.
struct ClienteHTTPTests {
  private func proveedor(_ dialecto: Proveedor.Dialecto, _ base: String) -> Proveedor {
    Proveedor(
      id: "x", nombre: "X", dialecto: dialecto,
      urlBase: URL(string: base), modelo: "m"
    )
  }

  private func cuerpo(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()))
      as? [String: Any] ?? [:]
  }

  @Test func openAIHablaChatCompletionsConBearer() throws {
    let cliente = ClienteHTTP(
      proveedor: proveedor(.compatibleOpenAI, "https://api.openai.com/v1"),
      clave: "secreta"
    )
    let request = try cliente.armar(
      instrucciones: "reescribe", peticion: "hola", modelo: "gpt-x"
    )
    #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secreta")
    #expect(cuerpo(request)["model"] as? String == "gpt-x")
  }

  @Test func geminiLlevaLaClaveEnElHeaderYNuncaEnLaURL() throws {
    let cliente = ClienteHTTP(
      proveedor: proveedor(.gemini, "https://generativelanguage.googleapis.com/v1beta"),
      clave: "secreta"
    )
    let request = try cliente.armar(
      instrucciones: "reescribe", peticion: "hola", modelo: "gemini-2.5-flash"
    )
    let url = try #require(request.url?.absoluteString)
    #expect(url.hasSuffix("models/gemini-2.5-flash:generateContent"))
    #expect(!url.contains("secreta"))
    #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "secreta")
  }

  @Test func anthropicMandaLaVersionQueSuAPIExige() throws {
    let cliente = ClienteHTTP(
      proveedor: proveedor(.anthropic, "https://api.anthropic.com/v1"), clave: "secreta"
    )
    let request = try cliente.armar(
      instrucciones: "reescribe", peticion: "hola", modelo: "claude-x"
    )
    #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "secreta")
    #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    #expect(cuerpo(request)["system"] as? String == "reescribe")
  }

  @Test func sinClaveNiSiquieraArmaElRequest() {
    let cliente = ClienteHTTP(
      proveedor: proveedor(.compatibleOpenAI, "https://api.openai.com/v1"), clave: nil
    )
    #expect(throws: FallaDelProveedor.faltaLaClave) {
      try cliente.armar(instrucciones: "a", peticion: "b", modelo: "m")
    }
  }

  @Test func elDeLocalhostNoExigeClave() throws {
    let cliente = ClienteHTTP(
      proveedor: proveedor(.compatibleOpenAI, "http://localhost:11434/v1"), clave: nil
    )
    let request = try cliente.armar(instrucciones: "a", peticion: "b", modelo: "llama3")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
  }

  @Test func leeLaRespuestaDeCadaDialecto() throws {
    let openai = ClienteHTTP(
      proveedor: proveedor(.compatibleOpenAI, "https://x/v1"), clave: "k"
    )
    #expect(
      try openai.leer(Data(#"{"choices":[{"message":{"content":"listo"}}]}"#.utf8)) == "listo"
    )

    let gemini = ClienteHTTP(proveedor: proveedor(.gemini, "https://x"), clave: "k")
    #expect(
      try gemini.leer(
        Data(#"{"candidates":[{"content":{"parts":[{"text":"listo"}]}}]}"#.utf8)
      ) == "listo"
    )

    let anthropic = ClienteHTTP(proveedor: proveedor(.anthropic, "https://x/v1"), clave: "k")
    #expect(
      try anthropic.leer(
        Data(#"{"content":[{"type":"text","text":"listo"}]}"#.utf8)
      ) == "listo"
    )
  }

  @Test func unaRespuestaVaciaNoEsTextoParaPegar() async {
    let cliente = ClienteHTTP(
      proveedor: proveedor(.compatibleOpenAI, "https://x/v1"),
      clave: "k",
      transporte: { peticion in
        (
          Data(#"{"choices":[{"message":{"content":"   "}}]}"#.utf8),
          HTTPURLResponse(
            url: peticion.url!, statusCode: 200, httpVersion: nil, headerFields: nil
          )!
        )
      }
    )
    await #expect(throws: FallaDelProveedor.respuestaVacia) {
      try await cliente.responder(instrucciones: "a", peticion: "b", modelo: "m")
    }
  }

  @Test func unErrorHTTPSeCuentaComoFalla() async {
    let cliente = ClienteHTTP(
      proveedor: proveedor(.compatibleOpenAI, "https://x/v1"),
      clave: "k",
      transporte: { peticion in
        (
          Data(),
          HTTPURLResponse(
            url: peticion.url!, statusCode: 429, httpVersion: nil, headerFields: nil
          )!
        )
      }
    )
    await #expect(throws: FallaDelProveedor.respondioMal(codigo: 429)) {
      try await cliente.responder(instrucciones: "a", peticion: "b", modelo: "m")
    }
  }

  @Test func lasClavesSeGuardanEnElAlmacenYNoEnElModo() throws {
    let almacen = AlmacenEnMemoria()
    let gemini = Proveedor.deFabrica.proveedor("gemini")!
    #expect(!almacen.tieneClave(para: gemini.cuentaEnElLlavero))
    try almacen.guardar("secreta", para: gemini.cuentaEnElLlavero)
    #expect(almacen.tieneClave(para: gemini.cuentaEnElLlavero))

    // Un modo serializado no lleva nunca la clave adentro.
    let modo = Modo(id: "correo", nombre: "Correo", prompt: "", proveedorID: "gemini")
    let json = String(data: try JSONEncoder().encode(modo), encoding: .utf8) ?? ""
    #expect(!json.contains("secreta"))

    try almacen.borrar(gemini.cuentaEnElLlavero)
    #expect(!almacen.tieneClave(para: gemini.cuentaEnElLlavero))
  }
}
