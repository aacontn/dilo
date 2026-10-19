import Foundation
import Testing

@testable import DiloModes

/// La consulta con forma que usa el aprendizaje, sin abrir un socket.
struct ConsultaAClaudeTests {
  private func cuerpo(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()))
      as? [String: Any] ?? [:]
  }

  private func responde(_ codigo: Int, _ cuerpo: String) -> ConsultaAClaude.Transporte {
    { peticion in
      (
        Data(cuerpo.utf8),
        HTTPURLResponse(url: peticion.url!, statusCode: codigo, httpVersion: nil, headerFields: nil)!
      )
    }
  }

  private func pedido(modelo: String = "claude-haiku-5-5", plazo: Duration = .seconds(7)) -> ConsultaAClaude.Pedido {
    ConsultaAClaude.Pedido(
      modelo: modelo, esfuerzo: "low", maximoDeTokens: 4_000,
      sistema: "sistema", peticion: "<candidato>x</candidato>",
      esquema: #"{"type":"object","properties":{"a":{"type":"string"}},"required":["a"],"additionalProperties":false}"#,
      plazo: plazo
    )
  }

  @Test(arguments: ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"])
  func elRequestLlevaFormaYEsfuerzoYNadaQueDevuelva400(modelo: String) throws {
    let request = try ConsultaAClaude(clave: "secreta").armar(pedido(modelo: modelo))
    #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "secreta")
    #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    #expect(request.timeoutInterval >= 7)

    let enviado = cuerpo(request)
    #expect(enviado["model"] as? String == modelo)
    #expect(enviado["max_tokens"] as? Int == 4_000)
    #expect(enviado["system"] as? String == "sistema")
    let config = try #require(enviado["output_config"] as? [String: Any])
    #expect(config["effort"] as? String == "low")
    let forma = try #require(config["format"] as? [String: Any])
    #expect(forma["type"] as? String == "json_schema")
    #expect((forma["schema"] as? [String: Any])?["type"] as? String == "object")
    for prohibido in ["temperature", "top_p", "top_k", "thinking", "effort", "output_format"] {
      #expect(enviado[prohibido] == nil, "\(prohibido)")
    }
    let mensajes = try #require(enviado["messages"] as? [[String: Any]])
    #expect(mensajes.count == 1)
    #expect(mensajes.last?["role"] as? String == "user")
    #expect(!(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "").contains("secreta"))
  }

  @Test(arguments: [nil, "", "  "])
  func sinClaveNoSeArmaNada(clave: String?) {
    #expect(throws: FallaDeClaude.faltaLaClave) {
      try ConsultaAClaude(clave: clave).armar(pedido())
    }
  }

  @Test func leeSoloElTexto() async throws {
    let consulta = ConsultaAClaude(
      clave: "k",
      transporte: responde(200, #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"{\"a\":\"b\"}"}],"stop_reason":"end_turn"}"#)
    )
    #expect(try await consulta.pedir(pedido()) == #"{"a":"b"}"#)
  }

  @Test(arguments: [
    (#"{"content":[{"type":"text","text":"{"}],"stop_reason":"max_tokens"}"#, FallaDeClaude.cortada),
    (#"{"content":[],"stop_reason":"refusal"}"#, FallaDeClaude.seNego),
    (#"{"content":[],"stop_reason":"end_turn"}"#, FallaDeClaude.respuestaInutil),
    ("no es json", FallaDeClaude.respuestaInutil),
  ])
  func loQueNoSirveEsUnaFalla(cuerpo: String, falla: FallaDeClaude) async {
    let consulta = ConsultaAClaude(clave: "k", transporte: responde(200, cuerpo))
    await #expect(throws: falla) { try await consulta.pedir(pedido()) }
  }

  @Test func unCodigoMaloEsSuFalla() async {
    let consulta = ConsultaAClaude(clave: "k", transporte: responde(401, "{}"))
    await #expect(throws: FallaDeClaude.claveRechazada) { try await consulta.pedir(pedido()) }
  }

  @Test func unaPeticionColgadaVenceEnElPlazo() async {
    let consulta = ConsultaAClaude(clave: "k", transporte: { _ in
      try await Task.sleep(for: .seconds(3600))
      throw URLError(.unknown)
    })
    let inicio = ContinuousClock.now
    await #expect(throws: FallaDeClaude.tardoDemasiado) {
      try await consulta.pedir(pedido(plazo: .milliseconds(30)))
    }
    #expect(ContinuousClock.now - inicio < .seconds(5))
  }

  @Test func losModelosDelAprendizajeSonHaikuParaRevisarYSonnetParaOrdenar() {
    #expect(ModelosDeAnthropic.deFabricaParaRevisar.id == "claude-haiku-5-5")
    #expect(ModelosDeAnthropic.deFabricaParaOrdenar.id == "claude-sonnet-5-5")
    #expect(ModelosDeAnthropic.esfuerzoParaRevisar == "low")
    #expect(ModelosDeAnthropic.esfuerzoParaOrdenar == "medium")
  }
}
