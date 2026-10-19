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

  /// Con forma: temperatura 0 y la salida `{"texto": …}` en el dialecto de
  /// cada uno, salvo Anthropic. Sin forma, el request de siempre.
  @Test func conFormaPideTemperaturaCeroYElEsquemaDeCadaUno() throws {
    let openai = try ClienteHTTP(
      proveedor: proveedor(.compatibleOpenAI, "https://api.openai.com/v1"), clave: "k"
    ).armar(instrucciones: "a", peticion: "b", modelo: "m", conForma: true)
    #expect(cuerpo(openai)["temperature"] as? Int == 0)
    let formato = try #require(cuerpo(openai)["response_format"] as? [String: Any])
    #expect(formato["type"] as? String == "json_schema")

    let gemini = try ClienteHTTP(
      proveedor: proveedor(.gemini, "https://generativelanguage.googleapis.com/v1beta"), clave: "secreta"
    ).armar(instrucciones: "a", peticion: "b", modelo: "m", conForma: true)
    let config = try #require(cuerpo(gemini)["generationConfig"] as? [String: Any])
    #expect(config["responseMimeType"] as? String == "application/json")
    #expect(!(gemini.url?.absoluteString.contains("secreta") ?? true))

    let anthropic = try ClienteHTTP(
      proveedor: proveedor(.anthropic, "https://api.anthropic.com/v1"), clave: "k"
    ).armar(instrucciones: "a", peticion: "b", modelo: "m", conForma: true)
    #expect(cuerpo(anthropic)["temperature"] == nil)

    let sinForma = try ClienteHTTP(
      proveedor: proveedor(.compatibleOpenAI, "https://api.openai.com/v1"), clave: "k"
    ).armar(instrucciones: "a", peticion: "b", modelo: "m")
    #expect(cuerpo(sinForma)["response_format"] == nil)
    #expect(cuerpo(sinForma)["temperature"] == nil)
  }

  /// La respuesta con forma se desarma; un 400 por las opciones se repite
  /// una vez sin ellas, al mismo proveedor.
  @Test func reescribirDesarmaLaFormaYReintentaSinOpcionesAnteUn400() async throws {
    let pedidos = Pedidos()
    let cliente = ClienteHTTP(
      proveedor: proveedor(.compatibleOpenAI, "https://x/v1"), clave: "k",
      transporte: { request in
        let conFormato = await pedidos.anotar(request)
        let codigo = conFormato ? 400 : 200
        let cuerpo = #"{"choices":[{"message":{"content":"{\"texto\":\"Hola.\"}"}}]}"#
        return (
          Data(cuerpo.utf8),
          HTTPURLResponse(url: request.url!, statusCode: codigo, httpVersion: nil, headerFields: nil)!
        )
      }
    )
    #expect(try await cliente.reescribir(instrucciones: "a", peticion: "b", modelo: "m") == "Hola.")
    #expect(await pedidos.conFormato == [true, false])
  }

  private actor Pedidos {
    var conFormato: [Bool] = []
    func anotar(_ request: URLRequest) -> Bool {
      let cuerpo = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
      let lleva = cuerpo?["response_format"] != nil
      conFormato.append(lleva)
      return lleva
    }
  }

  /// Haiku 5.5, Sonnet 5.5 y Opus 5.5 devuelven 400 ante `temperature`,
  /// `top_p` o `top_k` que no sean los suyos (2026-10-19). Ningún request a
  /// Anthropic los lleva, con forma o sin ella.
  @Test(arguments: [false, true])
  func aAnthropicNuncaVaElMuestreo(conForma: Bool) throws {
    let request = try ClienteHTTP(
      proveedor: proveedor(.anthropic, "https://api.anthropic.com/v1"), clave: "k"
    ).armar(instrucciones: "a", peticion: "b", modelo: "claude-haiku-5-5", conForma: conForma)
    let enviado = cuerpo(request)
    #expect(enviado["temperature"] == nil)
    #expect(enviado["top_p"] == nil)
    #expect(enviado["top_k"] == nil)
  }

  /// Un `refusal` o un `max_tokens` no son texto para pegar, aunque traigan
  /// un bloque de texto; y los bloques `thinking` de delante se ignoran.
  @Test func deAnthropicSeMiraElMotivoDeParada() throws {
    let anthropic = ClienteHTTP(proveedor: proveedor(.anthropic, "https://x/v1"), clave: "k")
    #expect(
      try anthropic.leer(
        Data(#"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"listo"}],"stop_reason":"end_turn"}"#.utf8)
      ) == "listo"
    )
    #expect(throws: FallaDelProveedor.seNego) {
      try anthropic.leer(
        Data(#"{"content":[{"type":"text","text":"No puedo"}],"stop_reason":"refusal"}"#.utf8)
      )
    }
    #expect(throws: FallaDelProveedor.respuestaCortada) {
      try anthropic.leer(
        Data(#"{"content":[{"type":"text","text":"a medi"}],"stop_reason":"max_tokens"}"#.utf8)
      )
    }
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
