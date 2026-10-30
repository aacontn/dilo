// Propio de Dilo: el lado cliente de MCP por stdio, escrito a mano como el
// servidor (`ServidorMCP`) y por lo mismo: es `initialize`, `tools/list` y
// `tools/call`, y cabe en unas pocas cientos de líneas sin dependencias.
import Darwin
import Foundation
import Synchronization

/// Una herramienta que ofrece un servidor MCP, como la dijo en `tools/list`.
public struct HerramientaMCP: Equatable, Sendable {
  public let nombre: String
  public let descripcion: String
  /// El `inputSchema` tal cual, para pasárselo a Claude.
  public let esquema: ValorJSON
  /// Sólo `readOnlyHint: true` la vuelve de lectura. Lo que el servidor no
  /// dice se trata como escritura: pide un clic.
  public let soloLectura: Bool

  public init(nombre: String, descripcion: String, esquema: ValorJSON, soloLectura: Bool) {
    self.nombre = nombre
    self.descripcion = descripcion
    self.esquema = esquema
    self.soloLectura = soloLectura
  }

  /// Lee una fila de `tools/list`. Nil si no trae nombre.
  public init?(_ valor: ValorJSON) {
    guard let nombre = valor["name"]?.comoTexto, !nombre.isEmpty else { return nil }
    self.nombre = nombre
    descripcion = valor["description"]?.comoTexto ?? valor["title"]?.comoTexto ?? ""
    esquema = valor["inputSchema"] ?? .objeto(["type": .texto("object"), "properties": .objeto([:])])
    soloLectura = valor["annotations"]?["readOnlyHint"] == .bool(true)
  }
}

/// Lo que devolvió `tools/call`: el texto de su contenido y si es un error de
/// la herramienta (que va al modelo para que se corrija, no a la persona).
public struct ResultadoMCP: Equatable, Sendable {
  public let texto: String
  public let esError: Bool

  public init(texto: String, esError: Bool) {
    self.texto = texto
    self.esError = esError
  }

  /// Junta los bloques `text`; lo que no es texto se nombra y no se manda.
  /// Sin texto, el `structuredContent` en JSON.
  public init(_ resultado: ValorJSON) {
    var partes: [String] = []
    if case let .lista(bloques) = resultado["content"] ?? .nulo {
      for bloque in bloques {
        switch bloque["type"]?.comoTexto {
        case "text": if let texto = bloque["text"]?.comoTexto { partes.append(texto) }
        case "resource":
          if let texto = bloque["resource"]?["text"]?.comoTexto { partes.append(texto) }
        case let tipo?: partes.append("[\(tipo) omitido]")
        case nil: break
        }
      }
    }
    if partes.isEmpty, let estructurado = resultado["structuredContent"] { partes.append(estructurado.enUnaLinea) }
    texto = partes.joined(separator: "\n")
    esError = resultado["isError"] == .bool(true)
  }
}

/// Por qué no se pudo hablar con un servidor MCP, dicho para la persona.
public enum FallaDelClienteMCP: Error, Equatable, Sendable {
  case noSePudoLanzar(servidor: String, detalle: String)
  /// El proceso terminó. `stderr` es lo último que escribió, recortado.
  case seCerro(servidor: String, stderr: String)
  case plazo(servidor: String, metodo: String, segundos: Int)
  /// Un error de JSON-RPC: el servidor entendió y dijo que no.
  case errorDelServidor(servidor: String, codigo: Int, mensaje: String)
  case versionNoSoportada(servidor: String, version: String)
  case cerrado(servidor: String)

  public var mensaje: String {
    switch self {
    case let .noSePudoLanzar(servidor, detalle):
      "No pude lanzar \(servidor): \(detalle)"
    case let .seCerro(servidor, stderr):
      stderr.isEmpty ? "\(servidor) se cerró sin decir por qué." : "\(servidor) se cerró: \(stderr)"
    case let .plazo(servidor, metodo, segundos):
      "\(servidor) no contestó \(metodo) en \(segundos) s."
    case let .errorDelServidor(servidor, codigo, mensaje):
      "\(servidor) respondió con un error (\(codigo)): \(mensaje)"
    case let .versionNoSoportada(servidor, version):
      "\(servidor) habla MCP \(version), que Dilo no conoce."
    case let .cerrado(servidor):
      "La conexión con \(servidor) ya se cerró."
    }
  }
}

/// Habla con un servidor MCP por stdio: lo lanza, negocia la versión, lista
/// sus herramientas y las llama.
///
/// Un mensaje JSON-RPC por línea en cada sentido, como manda el transporte
/// stdio. Lo que el servidor escribe en stderr se guarda —lo último, en
/// RAM— sólo para decir por qué se cerró. Cada pedido tiene plazo: un
/// servidor colgado no deja la **Conversación** colgada. Lo que pide el
/// servidor (un `ping`) se contesta; las notificaciones se ignoran.
public actor ClienteMCP {
  public struct Plazos: Sendable {
    /// Lanzar y `initialize`. Holgado: el ayudante de Switchboard abre la
    /// app si no está y la espera hasta 10 s.
    public var conectar: Duration = .seconds(20)
    public var listar: Duration = .seconds(15)
    public var llamar: Duration = .seconds(60)
    public init() {}
  }

  /// La versión que se pide; el servidor puede contestar otra de
  /// `versionesConocidas`.
  public static let versionPedida = "2025-06-18"
  public static let versionesConocidas = ServidorMCP.versionesDelProtocolo
  /// Cuánto de stderr se guarda para el mensaje de error.
  static let topeDeStderr = 2_000
  /// Páginas de `tools/list` antes de dejar de pedir: un servidor que
  /// devuelve siempre un cursor no puede dejar a Dilo en un bucle.
  static let topeDePaginas = 10

  public nonisolated let servidor: ServidorMCPConfigurado
  public let plazos: Plazos
  let versionDeDilo: String

  private var proceso: Process?
  private var escritura: FileHandle?
  private var lectura: Task<Void, Never>?
  private var pendientes: [Int: CheckedContinuation<ValorJSON, any Error>] = [:]
  private var relojes: [Int: Task<Void, Never>] = [:]
  private var siguiente = 1
  private var conectando: Task<Void, any Error>?
  private var cerrado: FallaDelClienteMCP?
  private let stderr = LoUltimoDeStderr()
  public private(set) var versionNegociada: String?
  public private(set) var instrucciones: String?

  public init(servidor: ServidorMCPConfigurado, plazos: Plazos = Plazos(), versionDeDilo: String = "0") {
    self.servidor = servidor
    self.plazos = plazos
    self.versionDeDilo = versionDeDilo
  }

  private var nombre: String { servidor.nombre }

  /// Lanza el servidor y negocia. Llamarlo dos veces —o dos a la vez: el
  /// destino prepara las herramientas mientras la persona habla— no lanza
  /// dos procesos ni negocia dos veces.
  public func conectar() async throws(FallaDelClienteMCP) {
    if versionNegociada != nil { return }
    if let cerrado { throw cerrado }
    let tarea = conectando ?? Task { try await self.negociar() }
    conectando = tarea
    do {
      try await tarea.value
    } catch let falla as FallaDelClienteMCP {
      throw falla
    } catch {
      throw .cerrado(servidor: nombre)
    }
  }

  private func negociar() async throws(FallaDelClienteMCP) {
    if proceso == nil { try lanzar() }
    let respuesta: ValorJSON
    do {
      respuesta = try await pedir(
        "initialize",
        .objeto([
          "protocolVersion": .texto(Self.versionPedida),
          "capabilities": .objeto([:]),
          "clientInfo": .objeto([
            "name": .texto("dilo"), "title": .texto("Dilo"), "version": .texto(versionDeDilo),
          ]),
        ]),
        plazo: plazos.conectar
      )
    } catch {
      // Un servidor que no negocia no sirve: no se lo deja corriendo.
      cerrar()
      throw error
    }
    let version = respuesta["protocolVersion"]?.comoTexto ?? ""
    guard Self.versionesConocidas.contains(version) else {
      cerrar()
      throw .versionNoSoportada(servidor: nombre, version: version.isEmpty ? "?" : version)
    }
    versionNegociada = version
    instrucciones = respuesta["instructions"]?.comoTexto
    notificar("notifications/initialized")
  }

  /// Todas sus herramientas, siguiendo las páginas.
  public func herramientas() async throws(FallaDelClienteMCP) -> [HerramientaMCP] {
    try await conectar()
    var todas: [HerramientaMCP] = []
    var cursor: String?
    for _ in 0 ..< Self.topeDePaginas {
      let params: ValorJSON = cursor.map { .objeto(["cursor": .texto($0)]) } ?? .objeto([:])
      let respuesta = try await pedir("tools/list", params, plazo: plazos.listar)
      if case let .lista(filas) = respuesta["tools"] ?? .nulo { todas += filas.compactMap(HerramientaMCP.init) }
      cursor = respuesta["nextCursor"]?.comoTexto
      if cursor?.isEmpty ?? true { break }
    }
    return todas
  }

  public func llamar(_ herramienta: String, argumentos: ValorJSON) async throws(FallaDelClienteMCP) -> ResultadoMCP {
    try await conectar()
    let respuesta = try await pedir(
      "tools/call", .objeto(["name": .texto(herramienta), "arguments": argumentos]), plazo: plazos.llamar
    )
    return ResultadoMCP(respuesta)
  }

  /// Corta: cierra la entrada del servidor (así termina un servidor que se
  /// porta bien), lo termina si no se fue, y falla lo que esperaba respuesta.
  public func cerrar() {
    guard cerrado == nil else { return }
    let falla = FallaDelClienteMCP.cerrado(servidor: nombre)
    cerrado = falla
    try? escritura?.close()
    escritura = nil
    if let proceso, proceso.isRunning {
      let pid = proceso.processIdentifier
      Task.detached {
        try? await Task.sleep(for: .seconds(2))
        // Si para entonces sigue vivo, SIGTERM. `kill` a un pid que ya
        // terminó no hace nada: el proceso es hijo nuestro y su pid no se
        // reparte mientras no lo recojamos.
        kill(pid, SIGTERM)
      }
    }
    lectura?.cancel()
    fallarTodo(falla)
  }

  // El proceso

  private func lanzar() throws(FallaDelClienteMCP) {
    let proceso = Process()
    let comando = servidor.comando.trimmingCharacters(in: .whitespaces)
    guard !comando.isEmpty else { throw .noSePudoLanzar(servidor: nombre, detalle: "falta el comando.") }
    if comando.contains("/") {
      let ruta = (comando as NSString).expandingTildeInPath
      guard FileManager.default.isExecutableFile(atPath: ruta) else {
        throw .noSePudoLanzar(servidor: nombre, detalle: "no hay un programa en \(ruta).")
      }
      proceso.executableURL = URL(filePath: ruta)
      proceso.arguments = servidor.argumentos
    } else {
      // Un nombre suelto se busca en el `PATH` del entorno armado, no en el
      // de Dilo, que abierto desde el Finder es mínimo.
      proceso.executableURL = URL(filePath: "/usr/bin/env")
      proceso.arguments = [comando] + servidor.argumentos
    }
    proceso.environment = ReglaDelEntorno.entorno(
      base: ProcessInfo.processInfo.environment, configurado: servidor.entorno
    )
    proceso.currentDirectoryURL = URL(filePath: NSHomeDirectory())
    let entrada = Pipe()
    let salida = Pipe()
    let errores = Pipe()
    proceso.standardInput = entrada
    proceso.standardOutput = salida
    proceso.standardError = errores
    // Escribirle a un servidor que ya se fue no puede matar a Dilo con
    // SIGPIPE: la escritura falla con EPIPE y eso se lee como cierre.
    _ = fcntl(entrada.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

    let guardado = stderr
    errores.fileHandleForReading.readabilityHandler = { handle in
      let datos = handle.availableData
      guard !datos.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      let texto = String(decoding: datos, as: UTF8.self)
      guardado.agregar(texto)
    }

    do {
      try proceso.run()
    } catch {
      throw .noSePudoLanzar(servidor: nombre, detalle: error.localizedDescription)
    }
    self.proceso = proceso
    escritura = entrada.fileHandleForWriting
    let lector = salida.fileHandleForReading
    lectura = Task { [weak self] in
      do {
        for try await linea in lector.bytes.lines {
          await self?.recibir(linea)
        }
      } catch {}
      await self?.seTermino()
    }
  }

  /// stdout llegó al final: el servidor se fue.
  private func seTermino() async {
    guard cerrado == nil else { return }
    // stderr puede llegar un poco después que el fin de stdout.
    try? await Task.sleep(for: .milliseconds(150))
    guard cerrado == nil else { return }
    let ultimo = stderr.texto
      .split(whereSeparator: \.isNewline).suffix(3).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    let falla = FallaDelClienteMCP.seCerro(servidor: nombre, stderr: String(ultimo.suffix(300)))
    cerrado = falla
    escritura = nil
    fallarTodo(falla)
  }

  // JSON-RPC

  private func pedir(_ metodo: String, _ params: ValorJSON, plazo: Duration) async throws(FallaDelClienteMCP) -> ValorJSON {
    if let cerrado { throw cerrado }
    let id = siguiente
    siguiente += 1
    let mensaje = ValorJSON.objeto([
      "jsonrpc": .texto("2.0"), "id": .entero(id), "method": .texto(metodo), "params": params,
    ])
    do {
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuacion: CheckedContinuation<ValorJSON, any Error>) in
          pendientes[id] = continuacion
          let segundos = Int(plazo.components.seconds)
          relojes[id] = Task { [weak self] in
            try? await Task.sleep(for: plazo)
            guard !Task.isCancelled else { return }
            await self?.resolver(id, con: .failure(FallaDelClienteMCP.plazo(
              servidor: self?.servidor.nombre ?? "", metodo: metodo, segundos: segundos
            )))
          }
          if !escribir(mensaje) {
            resolver(id, con: .failure(cerrado ?? .cerrado(servidor: nombre)))
          }
        }
      } onCancel: {
        Task { await self.cancelar(id) }
      }
    } catch let falla as FallaDelClienteMCP {
      throw falla
    } catch {
      throw .cerrado(servidor: nombre)
    }
  }

  /// Quien pidió ya no espera: se le avisa al servidor y se suelta la espera.
  private func cancelar(_ id: Int) {
    guard pendientes[id] != nil else { return }
    notificar("notifications/cancelled", .objeto(["requestId": .entero(id), "reason": .texto("cancelado")]))
    resolver(id, con: .failure(CancellationError()))
  }

  private func notificar(_ metodo: String, _ params: ValorJSON? = nil) {
    var mensaje: [String: ValorJSON] = ["jsonrpc": .texto("2.0"), "method": .texto(metodo)]
    if let params { mensaje["params"] = params }
    _ = escribir(.objeto(mensaje))
  }

  @discardableResult
  private func escribir(_ mensaje: ValorJSON) -> Bool {
    guard let escritura else { return false }
    do {
      try escritura.write(contentsOf: Data((mensaje.enUnaLinea + "\n").utf8))
      return true
    } catch {
      return false
    }
  }

  private func recibir(_ linea: String) {
    guard let mensaje = ValorJSON.leer(linea), case .objeto = mensaje else { return }
    if let metodo = mensaje["method"]?.comoTexto {
      // Un pedido del servidor. Sin `id` es una notificación y no se contesta.
      guard let id = mensaje["id"] else { return }
      if metodo == "ping" {
        _ = escribir(.objeto(["jsonrpc": .texto("2.0"), "id": id, "result": .objeto([:])]))
      } else {
        _ = escribir(.objeto([
          "jsonrpc": .texto("2.0"), "id": id,
          "error": .objeto(["code": .entero(-32601), "message": .texto("Dilo no atiende \(metodo).")]),
        ]))
      }
      return
    }
    guard let id = mensaje["id"]?.comoEntero else { return }
    if let error = mensaje["error"] {
      resolver(id, con: .failure(FallaDelClienteMCP.errorDelServidor(
        servidor: nombre, codigo: error["code"]?.comoEntero ?? 0,
        mensaje: error["message"]?.comoTexto ?? "sin mensaje"
      )))
    } else {
      resolver(id, con: .success(mensaje["result"] ?? .nulo))
    }
  }

  private func resolver(_ id: Int, con resultado: Result<ValorJSON, any Error>) {
    relojes.removeValue(forKey: id)?.cancel()
    pendientes.removeValue(forKey: id)?.resume(with: resultado)
  }

  private func fallarTodo(_ falla: FallaDelClienteMCP) {
    for id in Array(pendientes.keys) { resolver(id, con: .failure(falla)) }
  }
}

/// Lo último que el servidor escribió en stderr, recortado. Lo escribe el
/// manejador de lectura de su tubo, fuera del actor, así que va con candado.
final class LoUltimoDeStderr: Sendable {
  private let candado = Mutex("")

  func agregar(_ texto: String) {
    candado.withLock { $0 = String(($0 + texto).suffix(ClienteMCP.topeDeStderr)) }
  }

  var texto: String { candado.withLock { $0 } }
}
