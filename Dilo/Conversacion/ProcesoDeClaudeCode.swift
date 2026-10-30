import DiloModes
import Foundation

/// Un proceso `claude` vivo en la carpeta de un proyecto, manejado por
/// stdin y stdout en stream-json (`ArgumentosDeClaudeCode`).
///
/// Todo pasa en una cola propia, nunca en el hilo principal: leer stdout,
/// juntar las líneas, escribir en stdin y vigilar que termine. Lo que dice la
/// CLI sale por `sucesos`, ya leído (`LectorDeClaudeCode`), en el orden en
/// que llegó. Escribir en un pipe cerrado no tumba la app: el descriptor
/// lleva `F_SETNOSIGPIPE`.
final class ProcesoDeClaudeCode: @unchecked Sendable {
  enum Suceso: Sendable {
    case mensaje(MensajeDeClaudeCode)
    /// El proceso terminó. `stderr` son sus últimas líneas, para explicar
    /// una falla.
    case termino(codigo: Int32, stderr: String)
  }

  /// Tras cerrar stdin, cuánto se espera a que salga solo antes de un
  /// SIGTERM, y cuánto más antes de un SIGKILL. Con stdin cerrado la CLI
  /// espera a sus tareas de fondo hasta diez minutos: colgar no puede
  /// esperar eso.
  static let esperaAlCerrar: Duration = .seconds(3)
  static let esperaAntesDeMatar: Duration = .seconds(2)
  /// Lo que se guarda de stderr: alcanza para la última línea de un error.
  static let topeDeStderr = 8_192

  let sucesos: AsyncStream<Suceso>
  let ejecutable: URL
  private let continuacion: AsyncStream<Suceso>.Continuation
  private let proceso = Process()
  private let entrada = Pipe()
  private let salida = Pipe()
  private let errores = Pipe()
  private let cola = DispatchQueue(label: "cl.espaciodigital.dilo.claude-code")

  // Todo lo de abajo se toca sólo desde `cola`.
  private var pendiente = Data()
  private var stderr = Data()
  private var salidaCerrada = false
  private var codigo: Int32?
  private var entradaCerrada = false
  private var avisado = false

  /// Lanza el proceso. Falla si el ejecutable no se puede abrir.
  init(ejecutable: URL, carpeta: URL, argumentos: [String], entorno: [String: String]) throws {
    self.ejecutable = ejecutable
    (sucesos, continuacion) = AsyncStream.makeStream(of: Suceso.self)
    proceso.executableURL = ejecutable
    proceso.currentDirectoryURL = carpeta
    proceso.arguments = argumentos
    proceso.environment = entorno
    proceso.standardInput = entrada
    proceso.standardOutput = salida
    proceso.standardError = errores
    _ = fcntl(entrada.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

    salida.fileHandleForReading.readabilityHandler = { [weak self] archivo in
      let datos = archivo.availableData
      if datos.isEmpty { archivo.readabilityHandler = nil }
      guard let self else { return }
      cola.async { self.recibir(datos) }
    }
    errores.fileHandleForReading.readabilityHandler = { [weak self] archivo in
      let datos = archivo.availableData
      if datos.isEmpty { archivo.readabilityHandler = nil }
      guard let self else { return }
      cola.async { self.anotarError(datos) }
    }
    proceso.terminationHandler = { [weak self] proceso in
      let codigo = proceso.terminationStatus
      guard let self else { return }
      cola.async { self.termino(codigo) }
    }
    try proceso.run()
  }

  deinit {
    if proceso.isRunning { proceso.terminate() }
  }

  /// Escribe una línea en stdin (`EntradaParaClaudeCode`).
  func mandar(_ linea: String) {
    cola.async { [self] in
      guard !entradaCerrada, codigo == nil else { return }
      try? entrada.fileHandleForWriting.write(contentsOf: Data((linea + "\n").utf8))
    }
  }

  /// Cierra stdin para que la CLI termine sola; si no sale, SIGTERM y
  /// después SIGKILL.
  func cerrar() {
    cola.async { [self] in
      cerrarEntrada()
      cola.asyncAfter(deadline: .now() + Self.esperaAlCerrar.enSegundos) { [self] in
        guard codigo == nil, proceso.isRunning else { return }
        proceso.terminate()
        cola.asyncAfter(deadline: .now() + Self.esperaAntesDeMatar.enSegundos) { [self] in
          guard codigo == nil, proceso.isRunning else { return }
          kill(proceso.processIdentifier, SIGKILL)
        }
      }
    }
  }

  /// No contesta: SIGKILL ya.
  func matar() {
    cola.async { [self] in
      cerrarEntrada()
      guard codigo == nil, proceso.isRunning else { return }
      kill(proceso.processIdentifier, SIGKILL)
    }
  }

  private func cerrarEntrada() {
    guard !entradaCerrada else { return }
    entradaCerrada = true
    try? entrada.fileHandleForWriting.close()
  }

  private func recibir(_ datos: Data) {
    guard !datos.isEmpty else {
      salidaCerrada = true
      if !pendiente.isEmpty { leer(pendiente) }
      pendiente.removeAll()
      avisarSiTermino()
      return
    }
    pendiente.append(datos)
    while let salto = pendiente.firstIndex(of: 0x0A) {
      let linea = pendiente[pendiente.startIndex..<salto]
      pendiente.removeSubrange(pendiente.startIndex...salto)
      leer(linea)
    }
  }

  private func leer(_ linea: Data) {
    for mensaje in LectorDeClaudeCode.leer(String(decoding: linea, as: UTF8.self)) {
      continuacion.yield(.mensaje(mensaje))
    }
  }

  private func anotarError(_ datos: Data) {
    stderr.append(datos)
    if stderr.count > Self.topeDeStderr { stderr = stderr.suffix(Self.topeDeStderr) }
  }

  private func termino(_ codigo: Int32) {
    self.codigo = codigo
    entradaCerrada = true
    avisarSiTermino()
    // Si un nieto se quedó con stdout abierto, no se espera para siempre.
    cola.asyncAfter(deadline: .now() + 1) { [self] in
      salidaCerrada = true
      avisarSiTermino()
    }
  }

  /// El fin se avisa cuando terminó el proceso y se leyó todo stdout: así el
  /// `result` del último turno llega antes que el fin.
  private func avisarSiTermino() {
    guard !avisado, salidaCerrada, let codigo else { return }
    avisado = true
    continuacion.yield(.termino(codigo: codigo, stderr: String(decoding: stderr, as: UTF8.self)))
    continuacion.finish()
  }
}

extension Duration {
  fileprivate var enSegundos: Double {
    Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}
