import Foundation
import Testing

@testable import DiloModes

/// «Probar conexión», sin abrir un socket.
struct PruebaDeConexionTests {
  private func responde(_ codigo: Int, _ cuerpo: String = "{}") -> PruebaDeConexion.Transporte {
    { peticion in
      (
        Data(cuerpo.utf8),
        HTTPURLResponse(url: peticion.url!, statusCode: codigo, httpVersion: nil, headerFields: nil)!
      )
    }
  }

  @Test func esUnGetAlModeloSinCuerpoNiTokens() throws {
    let request = try PruebaDeConexion(clave: " secreta \n").armar()
    #expect(request.httpMethod == "GET")
    #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/models/claude-haiku-5-5")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "secreta")
    #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    #expect(request.httpBody == nil)
  }

  @Test func conRespuestaBuenaDiceElModelo() async {
    let prueba = PruebaDeConexion(clave: "k", transporte: responde(200, #"{"id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5"}"#))
    #expect(await prueba.probar() == .lista(modelo: "claude-haiku-5-5"))
  }

  @Test func sinClaveNoLlamaANadie() async {
    let prueba = PruebaDeConexion(clave: "  ", transporte: { _ in
      Issue.record("sin clave no se llama")
      throw URLError(.notConnectedToInternet)
    })
    #expect(await prueba.probar() == .falla(.faltaLaClave))
  }

  @Test(arguments: [
    (401, FallaDeClaude.claveRechazada), (403, .claveRechazada), (429, .demasiadosPedidos),
    (529, .anthropicNoResponde(codigo: 529)), (404, .pedidoRechazado(codigo: 404)),
  ])
  func cadaCodigoEsSuFalla(codigo: Int, falla: FallaDeClaude) async {
    let prueba = PruebaDeConexion(clave: "k", transporte: responde(codigo))
    #expect(await prueba.probar() == .falla(falla))
  }

  @Test func sinRedEsSinConexion() async {
    let prueba = PruebaDeConexion(clave: "k", transporte: { _ in throw URLError(.notConnectedToInternet) })
    #expect(await prueba.probar() == .falla(.sinConexion))
  }

  /// Lo que Anthropic explica viaja junto a la falla, para que Ajustes diga
  /// por qué y no sólo «rechazó el pedido».
  @Test func elPorQueDeAnthropicViajaConLaFalla() async {
    let cuerpo = #"{"type":"error","error":{"type":"not_found_error","message":"model: claude-haiku-5-5"}}"#
    let prueba = PruebaDeConexion(clave: "k", transporte: responde(404, cuerpo))
    #expect(
      await prueba.probar()
        == .falla(.pedidoRechazado(codigo: 404), detalle: "404 · not_found_error: model: claude-haiku-5-5")
    )
  }

  @Test func unaRespuestaSinIdNoEsUnaConexionBuena() async {
    let prueba = PruebaDeConexion(clave: "k", transporte: responde(200, #"{"type":"error"}"#))
    #expect(await prueba.probar() == .falla(.respuestaInutil))
  }
}

/// Los costos de referencia de Ajustes → Claude.
struct CostosDeClaudeTests {
  @Test func losPreciosSonLosDeLista() {
    #expect(CostosDeClaude.precio("claude-haiku-5-5") == .init(entrada: 0.10, salida: 0.50))
    #expect(CostosDeClaude.precio("claude-sonnet-5-5") == .init(entrada: 2, salida: 10))
    #expect(CostosDeClaude.precio("claude-opus-5-5") == .init(entrada: 4, salida: 20))
    #expect(CostosDeClaude.precio("claude-haiku-4-5") == nil)
  }

  @Test func unModoConHaikuCuestaUnaFraccionDeCentavo() throws {
    let porUso = try #require(CostosDeClaude.porUso(.modo, modelo: "claude-haiku-5-5"))
    #expect(abs(porUso - 0.00029) < 0.000001)
    let porMil = try #require(CostosDeClaude.referencia(.modo, modelo: "claude-haiku-5-5"))
    #expect(abs(porMil - 0.29) < 0.0001)
  }

  @Test func ordenarSeCuentaPorVezYEsUnosCentavos() throws {
    let vez = try #require(CostosDeClaude.referencia(.ordenar, modelo: "claude-sonnet-5-5"))
    #expect(abs(vez - 0.052) < 0.0001)
    #expect(!CostosDeClaude.Tarea.ordenar.porMil)
  }

  @Test func elOrdenDeLosModelosEsElDeSuPrecio() throws {
    for tarea in CostosDeClaude.Tarea.allCases {
      let h = try #require(CostosDeClaude.porUso(tarea, modelo: "claude-haiku-5-5"))
      let s = try #require(CostosDeClaude.porUso(tarea, modelo: "claude-sonnet-5-5"))
      let o = try #require(CostosDeClaude.porUso(tarea, modelo: "claude-opus-5-5"))
      #expect(h < s && s < o)
    }
  }
}
