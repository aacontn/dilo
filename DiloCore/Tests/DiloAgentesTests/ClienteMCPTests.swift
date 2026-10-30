import Foundation
import Testing

@testable import DiloAgentes

/// El cliente MCP contra un servidor de prueba de verdad: un guion de `sh`
/// que habla JSON-RPC por stdio, sin dependencias. Cada prueba elige cómo se
/// porta con la variable `MODO` —que además prueba que el entorno
/// configurado llega al proceso—.
@Suite(.serialized)
struct ClienteMCPTests {
  /// Contesta por el orden de las claves: el cliente las manda ordenadas, así
  /// que el `id` de arriba es siempre lo primero de la línea.
  static let guion = #"""
    #!/bin/sh
    if [ "$MODO" = "muere" ]; then
      echo "falta la configuración de prueba" >&2
      exit 3
    fi
    while IFS= read -r linea; do
      id=$(printf '%s' "$linea" | sed -n 's/^{"id":\([0-9][0-9]*\),.*/\1/p')
      case "$linea" in
        *'"method":"initialize"'*)
          [ "$MODO" = "mudo" ] && continue
          if [ "$MODO" = "ping" ]; then
            printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info"}}'
            printf '%s\n' '{"jsonrpc":"2.0","id":99,"method":"ping"}'
            IFS= read -r respuesta
            case "$respuesta" in
              *'"id":99'*'"result"'*) ;;
              *) echo "no contestó el ping" >&2; exit 4 ;;
            esac
          fi
          version="2025-06-18"
          [ "$MODO" = "version" ] && version="1999-01-01"
          printf 'esto no es JSON\n'
          printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"%s","capabilities":{"tools":{}},"serverInfo":{"name":"prueba"},"instructions":"Sé breve."}}\n' "$id" "$version"
          ;;
        *'"method":"tools/list"'*)
          case "$linea" in
            *'"cursor":"dos"'*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"borrar","description":"Borra algo.","inputSchema":{"type":"object"},"annotations":{"destructiveHint":true}}]}}\n' "$id" ;;
            *)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"leer","description":"Lee algo.","inputSchema":{"type":"object","properties":{"q":{"type":"string"}}},"annotations":{"readOnlyHint":true}},{"name":"anotar","description":"Anota."}],"nextCursor":"dos"}}\n' "$id" ;;
          esac
          ;;
        *'"method":"tools/call"'*)
          if [ "$MODO" = "error" ]; then
            printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":"No existe esa herramienta."}}\n' "$id"
          elif [ "$MODO" = "lento" ]; then
            :
          else
            case "$linea" in
              *'"q":"hola"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"Dijiste hola."},{"type":"image","data":"xx"}],"isError":false}}\n' "$id" ;;
              *) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"Falta q."}],"isError":true}}\n' "$id" ;;
            esac
          fi
          ;;
      esac
    done
    """#

  static func servidor(_ modo: String) throws -> ServidorMCPConfigurado {
    let carpeta = FileManager.default.temporaryDirectory.appending(path: "dilo-mcp-prueba-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
    let archivo = carpeta.appending(path: "servidor.sh")
    try guion.write(to: archivo, atomically: true, encoding: .utf8)
    return ServidorMCPConfigurado(
      id: "prueba", nombre: "Prueba", comando: "/bin/sh", argumentos: [archivo.path(percentEncoded: false)],
      entorno: ["MODO": modo]
    )
  }

  static func plazosCortos() -> ClienteMCP.Plazos {
    var plazos = ClienteMCP.Plazos()
    plazos.conectar = .seconds(2)
    plazos.listar = .seconds(2)
    plazos.llamar = .seconds(1)
    return plazos
  }

  @Test func conectaListaYLlama() async throws {
    let cliente = ClienteMCP(servidor: try Self.servidor("normal"), plazos: Self.plazosCortos())
    try await cliente.conectar()
    #expect(await cliente.versionNegociada == "2025-06-18")
    #expect(await cliente.instrucciones == "Sé breve.")

    let herramientas = try await cliente.herramientas()
    #expect(herramientas.map(\.nombre) == ["leer", "anotar", "borrar"])
    // Sólo la que dice `readOnlyHint: true` es de lectura; la que no dice
    // nada y la destructiva piden clic.
    #expect(herramientas.map(\.soloLectura) == [true, false, false])
    #expect(herramientas[1].esquema == .objeto(["type": .texto("object"), "properties": .objeto([:])]))

    let bien = try await cliente.llamar("leer", argumentos: .objeto(["q": .texto("hola")]))
    #expect(bien == ResultadoMCP(texto: "Dijiste hola.\n[image omitido]", esError: false))
    let mal = try await cliente.llamar("leer", argumentos: .objeto([:]))
    #expect(mal == ResultadoMCP(texto: "Falta q.", esError: true))
    await cliente.cerrar()
  }

  @Test func contestaElPingDelServidorEIgnoraLasNotificaciones() async throws {
    let cliente = ClienteMCP(servidor: try Self.servidor("ping"), plazos: Self.plazosCortos())
    try await cliente.conectar()
    #expect(await cliente.versionNegociada != nil)
    await cliente.cerrar()
  }

  @Test func unServidorMudoVenceElPlazo() async throws {
    let cliente = ClienteMCP(servidor: try Self.servidor("mudo"), plazos: Self.plazosCortos())
    await #expect(throws: FallaDelClienteMCP.plazo(servidor: "Prueba", metodo: "initialize", segundos: 2)) {
      try await cliente.conectar()
    }
    await cliente.cerrar()
  }

  @Test func unaHerramientaLentaVenceSuPlazo() async throws {
    let cliente = ClienteMCP(servidor: try Self.servidor("lento"), plazos: Self.plazosCortos())
    await #expect(throws: FallaDelClienteMCP.plazo(servidor: "Prueba", metodo: "tools/call", segundos: 1)) {
      _ = try await cliente.llamar("leer", argumentos: .objeto([:]))
    }
    await cliente.cerrar()
  }

  @Test func unServidorQueSeMuereDiceLoQueEscribioEnStderr() async throws {
    let cliente = ClienteMCP(servidor: try Self.servidor("muere"), plazos: Self.plazosCortos())
    do {
      try await cliente.conectar()
      Issue.record("conectó con un servidor que se murió")
    } catch let falla {
      #expect(falla == .seCerro(servidor: "Prueba", stderr: "falta la configuración de prueba"))
      #expect(falla.mensaje == "Prueba se cerró: falta la configuración de prueba")
    }
  }

  @Test func unErrorDeJSONRPCLlegaConSuMensaje() async throws {
    let cliente = ClienteMCP(servidor: try Self.servidor("error"), plazos: Self.plazosCortos())
    await #expect(
      throws: FallaDelClienteMCP.errorDelServidor(servidor: "Prueba", codigo: -32602, mensaje: "No existe esa herramienta.")
    ) {
      _ = try await cliente.llamar("leer", argumentos: .objeto([:]))
    }
    await cliente.cerrar()
  }

  @Test func unaVersionDesconocidaNoSeAcepta() async throws {
    let cliente = ClienteMCP(servidor: try Self.servidor("version"), plazos: Self.plazosCortos())
    await #expect(throws: FallaDelClienteMCP.versionNoSoportada(servidor: "Prueba", version: "1999-01-01")) {
      try await cliente.conectar()
    }
  }

  @Test func unComandoQueNoExisteSeDiceAntesDeLanzar() async {
    let servidor = ServidorMCPConfigurado(id: "x", nombre: "Fantasma", comando: "/no/existe/servidor")
    let cliente = ClienteMCP(servidor: servidor, plazos: Self.plazosCortos())
    await #expect(throws: FallaDelClienteMCP.noSePudoLanzar(servidor: "Fantasma", detalle: "no hay un programa en /no/existe/servidor.")) {
      try await cliente.conectar()
    }
  }

  @Test func cerradoNoSeVuelveAUsar() async throws {
    let cliente = ClienteMCP(servidor: try Self.servidor("normal"), plazos: Self.plazosCortos())
    try await cliente.conectar()
    await cliente.cerrar()
    await #expect(throws: FallaDelClienteMCP.cerrado(servidor: "Prueba")) {
      _ = try await cliente.llamar("leer", argumentos: .objeto([:]))
    }
  }

  @Test func cancelarUnaLlamadaNoEsperaElPlazo() async throws {
    var plazos = Self.plazosCortos()
    plazos.llamar = .seconds(30)
    let cliente = ClienteMCP(servidor: try Self.servidor("lento"), plazos: plazos)
    try await cliente.conectar()
    let inicio = ContinuousClock.now
    let tarea = Task { try await cliente.llamar("leer", argumentos: .objeto([:])) }
    try await Task.sleep(for: .milliseconds(200))
    tarea.cancel()
    _ = await tarea.result
    #expect(ContinuousClock.now - inicio < .seconds(5))
    await cliente.cerrar()
  }
}

/// Lo que Ajustes acepta como variable de entorno de un servidor MCP.
struct ReglaDelEntornoTests {
  @Test(arguments: ["GITHUB_TOKEN", "API_KEY", "OPENAI_API_KEY", "MI_CLAVE", "DB_PASSWORD", "client_secret"])
  func unNombreDeSecretoSeRechaza(nombre: String) {
    #expect(ReglaDelEntorno.reparo(nombre: nombre, valor: "x") != nil)
  }

  @Test(arguments: ["sk-ant-api03-abcdef", "ghp_abcdefghijklmnop", "a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7"])
  func unValorQuePareceClaveSeRechaza(valor: String) {
    #expect(ReglaDelEntorno.reparo(nombre: "CONFIG", valor: valor) != nil)
  }

  @Test func loComunSeAcepta() {
    #expect(ReglaDelEntorno.reparo(nombre: "PROYECTO", valor: "/Volumes/SSD 1/Dilo") == nil)
    #expect(ReglaDelEntorno.reparo(nombre: "NODE_ENV", valor: "production") == nil)
  }

  @Test func unNombreRaroSeRechaza() {
    #expect(ReglaDelEntorno.reparo(nombre: "MI VARIABLE", valor: "x") != nil)
    #expect(ReglaDelEntorno.reparo(nombre: "", valor: "x") != nil)
  }

  @Test func elPathMiraHomebrewYLoConfiguradoGana() {
    let entorno = ReglaDelEntorno.entorno(
      base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/x"], configurado: ["MODO": "a"], casa: "/Users/x"
    )
    #expect(entorno["PATH"] == "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin:/Users/x/.local/bin")
    #expect(entorno["MODO"] == "a")
    #expect(entorno["HOME"] == "/Users/x")
  }

  @Test func switchboardSeDeclaraComoDilo() {
    #expect(ServidorMCPConfigurado.switchboard.argumentos == ["--agent", "dilo"])
    #expect(ServidorMCPConfigurado.switchboard.id == "switchboard")
  }
}

struct LineaDeArgumentosTests {
  @Test func separaPorEspaciosYRespetaLasComillas() {
    #expect(LineaDeArgumentos.partir("--agent dilo") == ["--agent", "dilo"])
    #expect(
      LineaDeArgumentos.partir(#"-y @mcp/servidor "/Volumes/SSD 1" 'otra cosa'"#)
        == ["-y", "@mcp/servidor", "/Volumes/SSD 1", "otra cosa"]
    )
    #expect(LineaDeArgumentos.partir("   ") == [])
    #expect(LineaDeArgumentos.partir(#"a "" b"#) == ["a", "", "b"])
  }

  @Test func juntarYPartirVuelvenAlMismoLugar() {
    let argumentos = ["-y", "@mcp/servidor", "/Volumes/SSD 1", ""]
    #expect(LineaDeArgumentos.partir(LineaDeArgumentos.juntar(argumentos)) == argumentos)
  }
}
