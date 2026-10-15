import Foundation
import Testing

@testable import DiloAgentes

/// `argv` → herramienta, el sobre y los códigos de salida.
struct CLIDeDiloTests {
  private let herramientas = HerramientasDeDilo(fuente: FuenteFalsa())
  private let ahora = Date(timeIntervalSince1970: 1_792_000_000)

  private func correr(_ argumentos: [String], fuente: FuenteFalsa = FuenteFalsa()) async -> (ValorJSON?, Int32) {
    let salida = await CLIDeDilo.correr(
      argumentos, herramientas: HerramientasDeDilo(fuente: fuente), version: "0.4.8", ahora: ahora
    )
    return (ValorJSON.leer(salida.texto), salida.codigo)
  }

  @Test func elPosicionalPuedeSerDeVariasPalabras() {
    #expect(
      CLIDeDilo.interpretar(["dictados", "buscar", "la", "cotización", "--maximo", "3"])
        == .herramienta("buscar_dictados", .objeto(["consulta": .texto("la cotización"), "maximo": .entero(3)]))
    )
  }

  @Test func lasOpcionesAceptanIgual() {
    #expect(
      CLIDeDilo.interpretar(["dictados", "ver", "2026-10-12T09:41:07", "--desde=5", "--max_caracteres", "10"])
        == .herramienta(
          "ver_dictado",
          .objeto(["id": .texto("2026-10-12T09:41:07"), "desde": .entero(5), "max_caracteres": .entero(10)])
        )
    )
  }

  @Test func sinPosicionalNoLoInventa() {
    #expect(CLIDeDilo.interpretar(["dictados", "recientes"]) == .herramienta("dictados_recientes", .objeto([:])))
    #expect(CLIDeDilo.interpretar(["palabras"]) == .herramienta("tus_palabras", .objeto([:])))
  }

  @Test func lasOpcionesSeValidanContraElEsquema() {
    guard case let .invalido(f) = CLIDeDilo.interpretar(["dictados", "recientes", "--desde", "3"]) else {
      Issue.record("una opción que la herramienta no tiene pasó")
      return
    }
    #expect(f.codigo == .argumentoInvalido)
    guard case let .invalido(g) = CLIDeDilo.interpretar(["dictados", "recientes", "--maximo", "muchos"]) else {
      Issue.record("un entero que no es número pasó")
      return
    }
    #expect(g.codigo == .argumentoInvalido)
    guard case let .invalido(h) = CLIDeDilo.interpretar(["dictados", "recientes", "--maximo"]) else {
      Issue.record("una opción sin valor pasó")
      return
    }
    #expect(h.codigo == .faltaArgumento)
    guard case .invalido = CLIDeDilo.interpretar(["dictados", "recientes", "de", "mas"]) else {
      Issue.record("palabras de más en un comando sin posicional")
      return
    }
  }

  @Test func losArgumentosDeAppKitNoSonComandos() {
    // Los pone Xcode o quien pisa un ajuste por `NSArgumentDomain`.
    #expect(
      CLIDeDilo.interpretar(["-NSDocumentRevisionsDebugMode", "YES", "palabras", "-dictationHistoryEnabled", "YES"])
        == .herramienta("tus_palabras", .objeto([:]))
    )
  }

  @Test func ayudaYSpec() {
    #expect(CLIDeDilo.interpretar([]) == .ayuda)
    #expect(CLIDeDilo.interpretar(["--help"]) == .ayuda)
    #expect(CLIDeDilo.interpretar(["-h"]) == .ayuda)
    #expect(CLIDeDilo.interpretar(["ayuda"]) == .ayuda)
    #expect(CLIDeDilo.interpretar(["spec"]) == .spec)
  }

  @Test func laAyudaNombraCadaComando() {
    let ayuda = CLIDeDilo.ayuda(version: "0.4.8")
    for comando in CLIDeDilo.comandos { #expect(ayuda.contains(comando.uso)) }
    #expect(ayuda.contains("Dilo --mcp"))
    #expect(CLIDeDilo.comandos[1].uso == "dilo dictados buscar <consulta> [--maximo N]")
  }

  @Test func specEsLaTablaDelServidor() async {
    let (sobre, codigo) = await correr(["spec"])
    #expect(codigo == 0)
    #expect(sobre?["ok"] == .bool(true))
    #expect(sobre?["datos"]?["herramientas"] == .lista(HerramientasDeDilo.todas.map(\.comoJSON)))
    guard case let .lista(comandos)? = sobre?["datos"]?["comandos"] else {
      Issue.record("spec sin comandos")
      return
    }
    #expect(comandos.count == CLIDeDilo.comandos.count)
  }

  @Test func unComandoBuenoDevuelveElSobreConDatos() async {
    let (sobre, codigo) = await correr(["dictados", "buscar", "cotizacion"])
    #expect(codigo == 0)
    #expect(sobre?["ok"] == .bool(true))
    #expect(sobre?["comando"] == .texto("dilo dictados buscar cotizacion"))
    #expect(sobre?["error"] == nil)
    #expect(sobre?["meta"]?["version_del_esquema"] == .entero(1))
    #expect(sobre?["meta"]?["version_de_dilo"] == .texto("0.4.8"))
    #expect(sobre?["meta"]?["generado"] == .texto(ahora.formatted(.iso8601)))
    guard case let .lista(datos)? = sobre?["datos"] else {
      Issue.record("datos no es una lista de JSON: \(String(describing: sobre))")
      return
    }
    #expect(datos.first?["app"] == .texto("Mail"))
  }

  @Test func cadaCausaSaleConSuCodigo() async {
    let (uso, codigoDeUso) = await correr(["dictados", "borrar"])
    #expect(codigoDeUso == CLIDeDilo.CodigoDeSalida.uso.rawValue)
    #expect(uso?["ok"] == .bool(false))
    #expect(uso?["error"]?["codigo"] == .texto("herramienta_desconocida"))
    #expect(uso?["error"]?["arreglo"]?.comoTexto?.contains("dilo --help") == true)
    #expect(uso?["datos"] == nil)

    var apagado = FuenteFalsa()
    apagado.historialEncendido = false
    let (sinHistorial, codigoSinHistorial) = await correr(["dictados", "recientes"], fuente: apagado)
    #expect(codigoSinHistorial == CLIDeDilo.CodigoDeSalida.noDisponible.rawValue)
    #expect(sinHistorial?["error"]?["codigo"] == .texto("historial_apagado"))

    let (_, codigoNoEsta) = await correr(["dictados", "ver", "no-existe"])
    #expect(codigoNoEsta == CLIDeDilo.CodigoDeSalida.noEncontrado.rawValue)

    let (_, codigoSinConsulta) = await correr(["dictados", "buscar"])
    #expect(codigoSinConsulta == CLIDeDilo.CodigoDeSalida.uso.rawValue)
  }

  @Test func laAyudaNoEsJSONYSaleConCero() async {
    let salida = await CLIDeDilo.correr([], herramientas: herramientas, version: "0.4.8")
    #expect(salida.codigo == 0)
    #expect(salida.texto.hasPrefix("Dilo 0.4.8"))
  }
}

/// Qué modo elige el binario. Equivocarse acá es grave en las dos
/// direcciones: un arranque normal que se vuelve CLI deja a la persona sin
/// Dilo, y un CLI que se vuelve app abre la muesca desde un terminal.
struct ModoDeArranqueTests {
  private let app = "/Applications/Dilo.app/Contents/MacOS/Dilo"

  @Test func elArranqueNormalEsLaApp() {
    #expect(ModoDeArranque.decidir([app]) == .app)
    #expect(ModoDeArranque.decidir([app, "-NSDocumentRevisionsDebugMode", "YES"]) == .app)
    #expect(ModoDeArranque.decidir([app, "-psn_0_12345"]) == .app)
    #expect(ModoDeArranque.decidir([]) == .app)
  }

  @Test func elEjecutableDelBundleNoEsElCLIPorSuNombre() {
    // `Dilo` con mayúscula es la app; sólo `dilo` exacto es el comando.
    #expect(ModoDeArranque.decidir(["Dilo"]) == .app)
    #expect(ModoDeArranque.decidir(["/x/DILO"]) == .app)
  }

  @Test func mcpEnCualquierLugar() {
    #expect(ModoDeArranque.decidir([app, "--mcp"]) == .servidorMCP)
    #expect(ModoDeArranque.decidir([app, "-AppleLanguages", "(es)", "--mcp"]) == .servidorMCP)
    #expect(ModoDeArranque.decidir(["/Users/x/.local/bin/dilo", "--mcp"]) == .servidorMCP)
  }

  @Test func elEnlaceDiloEsElCLI() {
    #expect(ModoDeArranque.decidir(["/Users/x/.local/bin/dilo"]) == .cli([]))
    #expect(ModoDeArranque.decidir(["dilo", "dictados", "recientes"]) == .cli(["dictados", "recientes"]))
  }

  @Test func laAppConUnComandoEsElCLI() {
    #expect(ModoDeArranque.decidir([app, "spec"]) == .cli(["spec"]))
    #expect(ModoDeArranque.decidir([app, "--help"]) == .cli(["--help"]))
    #expect(ModoDeArranque.decidir([app, "palabras"]) == .cli(["palabras"]))
    #expect(ModoDeArranque.decidir([app, "abrir"]) == .app)
  }
}

struct IdsDeDictadosTests {
  @Test func laBaseEsDiaYHoraSinCorchetes() {
    #expect(IdsDeDictados.base(dia: "2026-10-12", hora: "[09:41:07]") == "2026-10-12T09:41:07")
  }

  @Test func elSegundoDelMismoSegundoLlevaNumero() {
    // Del más nuevo al más viejo, como los entrega el historial: el más
    // viejo de los empatados se queda con el id sin número.
    let ids = IdsDeDictados.asignar(["a", "b", "b", "b", "c"])
    #expect(ids == ["a", "b#3", "b#2", "b", "c"])
  }

  @Test func unDictadoNuevoNoLeCambiaElIdAUnoViejo() {
    let antes = IdsDeDictados.asignar(["b", "b"])
    let despues = IdsDeDictados.asignar(["b", "b", "b"])
    #expect(Array(despues.suffix(2)) == antes)
  }
}

struct ValorJSONTests {
  @Test func idaYVuelta() {
    let texto = #"{"a":[1,2.5,true,null,"x"],"b":{"c":false}}"#
    let valor = ValorJSON.leer(texto)
    #expect(valor?["a"] == .lista([.entero(1), .numero(2.5), .bool(true), .nulo, .texto("x")]))
    #expect(valor?.enUnaLinea == texto)
  }

  @Test func soloLosEnterosSonEnteros() {
    #expect(ValorJSON.numero(3).comoEntero == 3)
    #expect(ValorJSON.numero(3.2).comoEntero == nil)
    #expect(ValorJSON.texto("3").comoEntero == nil)
  }

  @Test func elTextoConSaltosSaleEnUnaLinea() {
    #expect(!ValorJSON.texto("uno\ndos").enUnaLinea.contains("\n"))
  }
}
