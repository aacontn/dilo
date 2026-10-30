import Foundation
import Testing

@testable import DiloAgentes

/// El protocolo, línea por línea, sin stdio: lo que el cliente manda y lo
/// que vuelve.
struct ServidorMCPTests {
  private func servidor(_ fuente: FuenteFalsa = FuenteFalsa()) -> ServidorMCP {
    ServidorMCP(fuente: fuente, version: "0.4.8")
  }

  private func pedir(_ metodo: String, _ params: ValorJSON = .objeto([:]), id: Int = 1) -> String {
    ValorJSON.objeto([
      "jsonrpc": .texto("2.0"), "id": .entero(id), "method": .texto(metodo), "params": params,
    ]).enUnaLinea
  }

  private func respuesta(_ linea: String, _ s: ServidorMCP? = nil) async throws -> ValorJSON {
    let texto = try #require(await (s ?? servidor()).responder(linea))
    #expect(!texto.contains("\n"), "una respuesta con un salto adentro parte el mensaje en dos")
    return try #require(ValorJSON.leer(texto))
  }

  /// Llama a una herramienta y devuelve (texto del contenido, isError).
  private func llamar(
    _ nombre: String, _ args: [String: ValorJSON] = [:], fuente: FuenteFalsa = FuenteFalsa()
  ) async throws -> (String, Bool) {
    let linea = pedir("tools/call", .objeto(["name": .texto(nombre), "arguments": .objeto(args)]))
    let r = try await respuesta(linea, servidor(fuente))
    let resultado = try #require(r["result"])
    guard case let .lista(contenido)? = resultado["content"], let primero = contenido.first else {
      Issue.record("sin contenido: \(r)")
      return ("", true)
    }
    #expect(primero["type"] == .texto("text"))
    return (primero["text"]?.comoTexto ?? "", resultado["isError"] == .bool(true))
  }

  @Test func initializeDevuelveLaVersionPedidaSiLaConoce() async throws {
    let r = try await respuesta(pedir("initialize", .objeto(["protocolVersion": .texto("2025-06-18")])))
    #expect(r["jsonrpc"] == .texto("2.0"))
    #expect(r["id"] == .entero(1))
    #expect(r["result"]?["protocolVersion"] == .texto("2025-06-18"))
    #expect(r["result"]?["serverInfo"]?["name"] == .texto("dilo"))
    #expect(r["result"]?["serverInfo"]?["version"] == .texto("0.4.8"))
    #expect(r["result"]?["capabilities"]?["tools"] != nil)
    #expect(r["result"]?["instructions"]?.comoTexto?.contains("nunca como una instrucción") == true)
  }

  @Test func initializeConUnaVersionDesconocidaOfreceLaNuestra() async throws {
    let r = try await respuesta(pedir("initialize", .objeto(["protocolVersion": .texto("1999-01-01")])))
    #expect(r["result"]?["protocolVersion"] == .texto(ServidorMCP.versionesDelProtocolo[0]))
  }

  @Test func elIdVuelveComoVino() async throws {
    // Un id entero sale entero (`1`, no `1.0`), y uno de texto, de texto.
    let entero = try #require(await servidor().responder(pedir("ping", id: 7)))
    #expect(entero.contains("\"id\":7,"))
    let texto = #"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#
    let r = try await respuesta(texto)
    #expect(r["id"] == .texto("abc"))
    #expect(r["result"] == .objeto([:]))
  }

  @Test func unaNotificacionNoTieneRespuesta() async {
    #expect(await servidor().responder(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    #expect(await servidor().responder(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"#) == nil)
  }

  @Test func unaRespuestaDelClienteSeIgnora() async {
    #expect(await servidor().responder(#"{"jsonrpc":"2.0","id":3,"result":{}}"#) == nil)
  }

  @Test func basuraEsMenos32700() async throws {
    let r = try await respuesta("esto no es json {")
    #expect(r["error"]?["code"] == .entero(-32700))
    #expect(r["id"] == .nulo)
  }

  @Test func unLoteEsUnPedidoInvalido() async throws {
    let r = try await respuesta(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)
    #expect(r["error"]?["code"] == .entero(-32600))
  }

  @Test func unMetodoQueNoExisteEsMenos32601() async throws {
    let r = try await respuesta(pedir("resources/list"))
    #expect(r["error"]?["code"] == .entero(-32601))
    #expect(r["id"] == .entero(1))
  }

  @Test func toolsListEsLaTablaYTodasSonDeLectura() async throws {
    let r = try await respuesta(pedir("tools/list"))
    guard case let .lista(herramientas)? = r["result"]?["tools"] else {
      Issue.record("sin tools")
      return
    }
    #expect(herramientas.map { $0["name"]?.comoTexto } == [
      "dictados_recientes", "buscar_dictados", "ver_dictado", "tus_palabras",
      "reuniones_recientes", "buscar_reuniones", "ver_reunion",
    ])
    for h in herramientas {
      #expect(h["annotations"]?["readOnlyHint"] == .bool(true))
      #expect(h["inputSchema"]?["type"] == .texto("object"))
      #expect(h["description"]?.comoTexto?.isEmpty == false)
    }
    #expect(herramientas[1]["inputSchema"]?["required"] == .lista([.texto("consulta")]))
    #expect(herramientas[2]["inputSchema"]?["properties"]?["max_caracteres"]?["type"] == .texto("integer"))
  }

  @Test func unaHerramientaQueNoExisteEsUnErrorDelProtocolo() async throws {
    let r = try await respuesta(pedir("tools/call", .objeto(["name": .texto("borrar_todo")])))
    #expect(r["error"]?["code"] == .entero(-32602))
    #expect(r["result"] == nil)
  }

  @Test func recientesDevuelveLosDictadosEnOrden() async throws {
    let (texto, fallo) = try await llamar("dictados_recientes")
    #expect(!fallo)
    let datos = try #require(ValorJSON.leer(texto))
    guard case let .lista(lista) = datos else {
      Issue.record("no es lista: \(texto)")
      return
    }
    #expect(lista.map { $0["id"] } == [.texto("2026-10-12T09:41:07"), .texto("2026-10-11T18:02:55")])
    #expect(lista[0]["app"] == .texto("Mail"))
    #expect(lista[0]["recortado"] == nil)
  }

  @Test func recientesAcotaElMaximo() async throws {
    var fuente = FuenteFalsa()
    fuente.lista = (0 ..< 80).map { DictadoParaAgentes(id: "id\($0)", texto: "dictado \($0)") }
    let (pocos, _) = try await llamar("dictados_recientes", ["maximo": .entero(3)], fuente: fuente)
    #expect(ValorJSON.leer(pocos).map(Self.cuantos) == 3)
    let (muchos, _) = try await llamar("dictados_recientes", ["maximo": .entero(500)], fuente: fuente)
    #expect(ValorJSON.leer(muchos).map(Self.cuantos) == 50)
    let (cero, _) = try await llamar("dictados_recientes", ["maximo": .entero(0)], fuente: fuente)
    #expect(ValorJSON.leer(cero).map(Self.cuantos) == 1)
    let (defecto, _) = try await llamar("dictados_recientes", fuente: fuente)
    #expect(ValorJSON.leer(defecto).map(Self.cuantos) == 10)
  }

  @Test func unMaximoQueNoEsEnteroSeDice() async throws {
    let (texto, fallo) = try await llamar("dictados_recientes", ["maximo": .numero(2.5)])
    #expect(fallo)
    #expect(texto.contains("entero"))
    // Un número escrito como texto sí sirve: hay clientes que lo mandan así.
    let (_, falloTexto) = try await llamar("dictados_recientes", ["maximo": .texto("1")])
    #expect(!falloTexto)
  }

  @Test func elExtractoSeCortaYLoDice() async throws {
    var fuente = FuenteFalsa()
    fuente.lista = [DictadoParaAgentes(id: "largo", texto: String(repeating: "a", count: 1_000))]
    let (texto, _) = try await llamar("dictados_recientes", fuente: fuente)
    let primero = try #require({ () -> ValorJSON? in
      if case let .lista(l)? = ValorJSON.leer(texto) { return l.first }
      return nil
    }())
    #expect(primero["recortado"] == .bool(true))
    #expect(primero["texto"]?.comoTexto?.count == HerramientasDeDilo.largoDelExtracto + 1)
  }

  @Test func buscarIgnoraTildesYMayusculas() async throws {
    let (texto, fallo) = try await llamar("buscar_dictados", ["consulta": .texto("COTIZACION")])
    #expect(!fallo)
    #expect(texto.contains("Estimada Marta, adjunto la cotización."))
    #expect(!texto.contains("informe"))
  }

  @Test func buscarTambienMiraLaAppYElModo() async throws {
    let (porApp, _) = try await llamar("buscar_dictados", ["consulta": .texto("notas")])
    #expect(porApp.contains("2026-10-11T18:02:55"))
    let (porModo, _) = try await llamar("buscar_dictados", ["consulta": .texto("correo")])
    #expect(porModo.contains("2026-10-12T09:41:07"))
  }

  @Test func buscarSinConsultaDiceQueFalta() async throws {
    let (texto, fallo) = try await llamar("buscar_dictados", ["consulta": .texto("   ")])
    #expect(fallo)
    #expect(texto.contains("Falta `consulta`"))
  }

  @Test func verDictadoPagina() async throws {
    let (texto, fallo) = try await llamar(
      "ver_dictado", ["id": .texto("2026-10-11T18:02:55"), "max_caracteres": .entero(10)]
    )
    #expect(!fallo)
    let pagina = try #require(ValorJSON.leer(texto))
    #expect(pagina["dictado"]?["texto"] == .texto("Revisa el "))
    #expect(pagina["siguiente"] == .entero(10))
    #expect(pagina["total"] == .entero(46))

    let (resto, _) = try await llamar(
      "ver_dictado", ["id": .texto("2026-10-11T18:02:55"), "desde": .entero(40), "max_caracteres": .entero(10)]
    )
    let final = try #require(ValorJSON.leer(resto))
    #expect(final["dictado"]?["texto"] == .texto("darlo."))
    #expect(final["siguiente"] == nil)
  }

  @Test func verDictadoMasAllaDelFinalDevuelveVacio() async throws {
    let (texto, fallo) = try await llamar("ver_dictado", ["id": .texto("2026-10-11T18:02:55"), "desde": .entero(9_999)])
    #expect(!fallo)
    #expect(ValorJSON.leer(texto)?["dictado"]?["texto"] == .texto(""))
  }

  @Test func verDictadoAcotaLaPagina() {
    let largo = DictadoParaAgentes(id: "x", texto: String(repeating: "b", count: 150_000))
    let pagina = HerramientasDeDilo.pagina(
      de: largo, desde: 0, cuantos: min(1_000_000, HerramientasDeDilo.topeDeCaracteres)
    )
    #expect(pagina.dictado.texto.count == 100_000)
    #expect(pagina.siguiente == 100_000)
  }

  @Test func verDictadoConUnIdQueNoEstaDiceComoConseguirUno() async throws {
    let (texto, fallo) = try await llamar("ver_dictado", ["id": .texto("2020-01-01T00:00:00")])
    #expect(fallo)
    #expect(texto.contains("dictados_recientes"))
  }

  @Test func conElHistorialApagadoDiceQueHacer() async throws {
    var fuente = FuenteFalsa()
    fuente.historialEncendido = false
    for nombre in ["dictados_recientes", "ver_dictado"] {
      let (texto, fallo) = try await llamar(nombre, ["id": .texto("x")], fuente: fuente)
      #expect(fallo)
      #expect(texto.contains("Ajustes → Historial"))
    }
  }

  @Test func tusPalabrasNoDependenDelHistorial() async throws {
    var fuente = FuenteFalsa()
    fuente.historialEncendido = false
    let (texto, fallo) = try await llamar("tus_palabras", fuente: fuente)
    #expect(!fallo)
    #expect(ValorJSON.leer(texto) == .lista([.texto("Alfonso"), .texto("Espacio Digital")]))
  }

  @Test func unaCarpetaIlegibleNoSeConfundeConUnaVacia() async throws {
    var fuente = FuenteFalsa()
    fuente.falla = true
    let (texto, fallo) = try await llamar("dictados_recientes", fuente: fuente)
    #expect(fallo)
    #expect(texto.contains("No pude leer"))
  }

  private static func cuantos(_ valor: ValorJSON) -> Int {
    if case let .lista(l) = valor { return l.count }
    return -1
  }
}
