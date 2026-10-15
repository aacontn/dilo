import DiloAgentes
import Foundation
import Testing
@testable import Dilo

/// El binario de verdad en modo MCP y CLI: se lanza como lo lanzaría un
/// cliente, sin ventanas, y se mira lo que sale por stdout.
///
/// Es la guardia contra el riesgo grande del servidor: un `print` perdido en
/// el camino rompe el protocolo, y ningún test puro lo ve. Por eso cada línea
/// de stdout tiene que ser JSON.
@Suite(.serialized)
struct ServidorMCPDelBinarioTests {
  struct Corrida {
    var lineas: [String]
    var codigo: Int32
  }

  /// Lanza el ejecutable de esta misma app con esos argumentos y esa entrada.
  ///
  /// Sin las variables con que Xcode inyecta XCTest en el host: el hijo no
  /// es un host de tests, y heredarlas haría que intentara cargar la suite.
  /// Los ajustes se pisan por la línea de comandos (`-clave valor`,
  /// `NSArgumentDomain`), así que no se escribe nada en `UserDefaults`.
  private func correr(_ argumentos: [String], entrada: String = "") throws -> Corrida {
    let proceso = Process()
    proceso.executableURL = Bundle.main.executableURL
    proceso.arguments = argumentos
    proceso.environment = ProcessInfo.processInfo.environment.filter { clave, _ in
      !(clave.hasPrefix("XCTest") || clave.hasPrefix("XCInject") || clave.contains("DYLD_INSERT_LIBRARIES"))
    }
    let stdin = Pipe()
    let stdout = Pipe()
    proceso.standardInput = stdin
    proceso.standardOutput = stdout
    proceso.standardError = FileHandle.nullDevice
    try proceso.run()

    // Un servidor que no termina al cerrarse stdin es un bug, pero no puede
    // colgar la suite entera.
    DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
      if proceso.isRunning { proceso.terminate() }
    }
    try stdin.fileHandleForWriting.write(contentsOf: Data(entrada.utf8))
    try stdin.fileHandleForWriting.close()
    let datos = stdout.fileHandleForReading.readDataToEndOfFile()
    proceso.waitUntilExit()
    let texto = String(decoding: datos, as: UTF8.self)
    return Corrida(lineas: texto.split(separator: "\n").map(String.init), codigo: proceso.terminationStatus)
  }

  private func pedido(_ id: Int, _ metodo: String, _ params: ValorJSON = .objeto([:])) -> String {
    ValorJSON.objeto([
      "jsonrpc": .texto("2.0"), "id": .entero(id), "method": .texto(metodo), "params": params,
    ]).enUnaLinea
  }

  @Test func elServidorRespondeYCadaLineaEsJSON() throws {
    let carpeta = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: carpeta) }
    try FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
    // Dos dictados en el mismo segundo: el segundo lleva `#2`.
    try Data("[09:41:07] Mail · Correo ◆ Parakeet\nadjunto la cotización\n\n[09:41:07] Notas\nla segunda\n\n".utf8)
      .write(to: carpeta.appending(path: "2026-10-12.txt"))

    let entrada = [
      pedido(1, "initialize", .objeto(["protocolVersion": .texto("2025-06-18")])),
      #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
      pedido(2, "tools/list"),
      pedido(3, "tools/call", .objeto(["name": .texto("tus_palabras")])),
      pedido(4, "tools/call", .objeto(["name": .texto("dictados_recientes")])),
    ].joined(separator: "\n") + "\n"

    let corrida = try correr(
      [
        "--mcp",
        "-dictationHistoryEnabled", "YES",
        "-dictationHistoryFolder", carpeta.path(percentEncoded: false),
        "-diloPalabrasPropias", #"("Marta")"#,
      ],
      entrada: entrada
    )

    #expect(corrida.codigo == 0, "el servidor sale limpio cuando se cierra stdin")
    let respuestas = corrida.lineas.map(ValorJSON.leer)
    #expect(!respuestas.contains(nil), "una línea de stdout no es JSON: \(corrida.lineas)")
    #expect(respuestas.map { $0?["id"] } == [.entero(1), .entero(2), .entero(3), .entero(4)])
    #expect(respuestas.first??["result"]?["protocolVersion"] == .texto("2025-06-18"))

    let palabras = respuestas[2]?["result"]?["content"]
    #expect(palabras == .lista([.objeto(["type": .texto("text"), "text": .texto(#"["Marta"]"#)])]))

    guard case let .lista(contenido)? = respuestas[3]?["result"]?["content"],
      let texto = contenido.first?["text"]?.comoTexto,
      case let .lista(dictados)? = ValorJSON.leer(texto)
    else {
      Issue.record("dictados_recientes no devolvió una lista: \(corrida.lineas)")
      return
    }
    #expect(dictados.map { $0["id"] } == [.texto("2026-10-12T09:41:07#2"), .texto("2026-10-12T09:41:07")])
    #expect(dictados[1]["app"] == .texto("Mail"))
    #expect(dictados[1]["modo"] == .texto("Correo"))
    #expect(dictados[1]["motor"] == .texto("Parakeet"))
  }

  @Test func conElHistorialApagadoNoLeeNadaYLoDice() throws {
    let entrada = pedido(1, "tools/call", .objeto(["name": .texto("dictados_recientes")])) + "\n"
    let corrida = try correr(["--mcp", "-dictationHistoryEnabled", "NO"], entrada: entrada)
    #expect(corrida.lineas.count == 1)
    let respuesta = try #require(corrida.lineas.first.flatMap(ValorJSON.leer))
    #expect(respuesta["result"]?["isError"] == .bool(true))
  }

  @Test func elCLIRespondeConSobreYCodigo() throws {
    let spec = try correr(["spec"])
    #expect(spec.codigo == 0)
    let sobre = ValorJSON.leer(spec.lineas.joined(separator: "\n"))
    #expect(sobre?["ok"] == .bool(true))
    #expect(sobre?["comando"] == .texto("dilo spec"))

    let malo = try correr(["dictados", "borrar"])
    #expect(malo.codigo == CLIDeDilo.CodigoDeSalida.uso.rawValue)
    #expect(ValorJSON.leer(malo.lineas.joined(separator: "\n"))?["ok"] == .bool(false))

    let ayuda = try correr(["--help"])
    #expect(ayuda.codigo == 0)
    #expect(ayuda.lineas.first?.hasPrefix("Dilo ") == true)
  }

  @Test func lasIdsDelHistorialSonEstables() {
    let entradas = [
      DictationHistoryStore.Entrada(dia: "2026-10-12", hora: "[09:41:07]", fuente: nil, modo: nil, texto: "b"),
      DictationHistoryStore.Entrada(dia: "2026-10-12", hora: "[09:41:07]", fuente: "Mail", modo: nil, texto: "a"),
      DictationHistoryStore.Entrada(dia: "2026-10-11", hora: "[09:41:07]", fuente: nil, modo: nil, texto: "c"),
    ]
    #expect(FuenteDelHistorial.paraAgentes(entradas).map(\.id) == [
      "2026-10-12T09:41:07#2", "2026-10-12T09:41:07", "2026-10-11T09:41:07",
    ])
  }
}
