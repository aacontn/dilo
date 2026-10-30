import DiloModes
import Foundation
import os

/// El destino **Claude Code** de la Conversación: una sesión de Claude Code
/// en la carpeta de un proyecto, manejada por voz.
///
/// Alfonso, 2026-10-30: «si te digo "revisa Claude Code", la puede abrir y
/// controlar esa sesión por voz desde Dilo» (`docs/design/conversacion-agente.md`,
/// «Claude Code por voz»). Por la puerta oficial: la CLI `claude` en modo de
/// control por programa, con la cuenta de Claude Code de la persona y no con
/// la clave de la API. Lo que se decide —qué se dice, qué permiso se pide, a
/// qué proyecto va— es puro y está probado en `DiloModes`
/// (`TraductorDeClaudeCode`, `PedidoAClaudeCode`); acá sólo se lanza el
/// proceso y se pasa lo que dice al contrato.
///
/// - «Claude Code, en Dilo, revisa los tests»: abre una sesión nueva en la
///   carpeta de Dilo, o sigue en la que ya está abierta en esta llamada.
/// - «Retoma la sesión de Dilo», «revisa Claude Code»: abre la más reciente
///   de ese proyecto según la CLI (`--continue --fork-session`) y pide que
///   cuente en qué quedó.
/// - Sin proyecto nombrado: el de la sesión abierta, el último usado, o
///   pregunta por voz cuál.
/// - Cada permiso que pide Claude Code es una `Aprobacion`; sólo el clic
///   contesta.
///
/// Dilo no lee `~/.claude`: qué sesiones hay y cómo retomarlas lo decide la
/// CLI.
@MainActor
final class DestinoClaudeCode: DestinoDeConversacion {
  let agente: Agente

  /// El texto entero de cada bloque de Claude, sin resumir, para la
  /// transcripción. El contrato sólo tiene texto para decir: lo que no se
  /// lee en voz alta (un diff, un bloque de código) llega por acá.
  var alTranscribir: ((String) -> Void)?

  /// Cuánto se espera el primer `init` después de mandar un turno.
  static let plazoParaArrancar: Duration = .seconds(30)
  /// Cuánto se espera que la CLI cierre un turno interrumpido antes de
  /// matarla.
  static let plazoParaInterrumpir: Duration = .seconds(10)

  private let settings: AppSettings
  private var sesion: SesionViva?
  /// Dilo preguntó «¿en qué proyecto?» y espera la respuesta.
  private var esperandoProyecto = false
  /// Lo pedido antes de saber el proyecto: se manda cuando se sabe.
  private var tareaPendiente: String?
  /// El id de la última sesión de esta llamada, por carpeta: si hay que
  /// relanzar el proceso, se retoma la misma (`--resume`). Se olvida al
  /// colgar.
  private var ultimaSesion: [String: String] = [:]

  init(agente: Agente, settings: AppSettings) {
    self.agente = agente
    self.settings = settings
  }

  func responder(_ turno: TurnoDeLaPersona) -> AsyncThrowingStream<EventoDelDestino, any Error> {
    let (stream, continuacion) = AsyncThrowingStream.makeStream(of: EventoDelDestino.self)
    let tarea = Task { [weak self] in
      guard let self else {
        continuacion.finish()
        return
      }
      await self.atender(turno.texto, continuacion)
    }
    continuacion.onTermination = { [weak self] motivo in
      guard case .cancelled = motivo else { return }
      tarea.cancel()
      Task { @MainActor in self?.interrumpir() }
    }
    return stream
  }

  func colgar() {
    if let viva = sesion {
      viva.turno?.finish()
      viva.turno = nil
      cerrarSesion()
    }
    esperandoProyecto = false
    tareaPendiente = nil
    ultimaSesion = [:]
  }

  private typealias Continuacion = AsyncThrowingStream<EventoDelDestino, any Error>.Continuation

  private func atender(_ texto: String, _ continuacion: Continuacion) async {
    // Un turno nuevo con otro abierto: el controlador debió cancelarlo; si
    // no, se interrumpe acá para que lo de antes no se mezcle.
    if sesion?.turno != nil { interrumpir() }

    let catalogo = await proyectosConocidos()
    let pedido = PedidoAClaudeCode.entender(texto, proyectos: catalogo, esperandoProyecto: esperandoProyecto)
    var tarea = pedido.tarea
    if pedido.proyecto != nil, tarea.isEmpty, !pedido.retomar, let pendiente = tareaPendiente {
      tarea = pendiente
    }

    guard let proyecto = pedido.proyecto ?? sesion?.proyecto ?? ultimoProyecto(en: catalogo) else {
      esperandoProyecto = true
      if !tarea.isEmpty { tareaPendiente = tarea }
      continuacion.yield(.texto(PreguntaDeProyecto.texto(proyectos: catalogo)))
      continuacion.yield(.fin(costoUSD: nil))
      continuacion.finish()
      return
    }
    esperandoProyecto = false
    tareaPendiente = nil
    settings.claudeCodeUltimoProyecto = proyecto.carpeta

    if let viva = sesion, viva.proyecto.carpeta != proyecto.carpeta { cerrarSesion() }

    let mensaje = tarea.isEmpty ? (pedido.retomar ? PromptDeClaudeCodePorVoz.alRetomar : nil) : tarea
    guard let mensaje else {
      continuacion.yield(.texto(PreguntaDeProyecto.listo(en: proyecto)))
      continuacion.yield(.fin(costoUSD: nil))
      continuacion.finish()
      return
    }

    if sesion == nil {
      do {
        try await abrir(proyecto, retomar: pedido.retomar)
      } catch {
        AppLog.conversacion.error(
          "claude code: no abrió (\((error as? FallaDeClaudeCode)?.nombreEnElLog ?? "otra", privacy: .public))"
        )
        continuacion.finish(throwing: error)
        return
      }
    }
    guard !Task.isCancelled, let viva = sesion else {
      continuacion.finish()
      return
    }

    viva.enviados += 1
    viva.numeroDelTurno = viva.enviados
    viva.turno = continuacion
    viva.inicioDelTurno = .now
    viva.proceso.mandar(EntradaParaClaudeCode.turno(mensaje))
    if !viva.arranco { vigilarArranque(viva) }
  }

  // Sesión

  private func abrir(_ proyecto: ProyectoDeClaudeCode, retomar: Bool) async throws {
    let inicio: OpcionesDeClaudeCode.Inicio =
      ultimaSesion[proyecto.carpeta].map { .retomar(sesion: $0) } ?? (retomar ? .laUltima : .nueva)
    let modelo = settings.claudeCodeModelo
    let opciones = OpcionesDeClaudeCode(inicio: inicio, modelo: modelo.isEmpty ? nil : modelo)
    let ruta = settings.claudeCodeRuta
    let nombre = NombreHablado.normalizado(proyecto.nombre)
    let carpeta = proyecto.carpeta

    let proceso = try await Task.detached(priority: .userInitiated) {
      try DestinoClaudeCode.lanzar(carpeta: carpeta, nombre: nombre, ruta: ruta, argumentos: ArgumentosDeClaudeCode.para(opciones))
    }.value

    let viva = SesionViva(proyecto: proyecto, proceso: proceso, agente: agente.nombre)
    sesion = viva
    viva.consumo = Task { [weak self] in
      for await suceso in proceso.sucesos {
        self?.recibir(suceso, de: viva)
      }
    }
    let como: String =
      switch inicio {
      case .nueva: "nueva"
      case .laUltima: "la-ultima"
      case .retomar: "retomada"
      }
    AppLog.conversacion.info(
      "claude code: sesión abierta (\(como, privacy: .public), modelo \(modelo.isEmpty ? "de la CLI" : modelo, privacy: .public)) en \(carpeta, privacy: .private)"
    )
  }

  private func cerrarSesion(matar: Bool = false) {
    guard let viva = sesion else { return }
    sesion = nil
    viva.vigias.forEach { $0.cancel() }
    if matar { viva.proceso.matar() } else { viva.proceso.cerrar() }
    AppLog.conversacion.info(
      "claude code: sesión cerrada (\(viva.recibidos, privacy: .public) turnos, \(viva.permisos, privacy: .public) permisos, \(viva.aprobados, privacy: .public) aprobados)"
    )
  }

  private func interrumpir() {
    guard let viva = sesion, let numero = viva.numeroDelTurno else { return }
    viva.numeroDelTurno = nil
    viva.turno = nil
    viva.proceso.mandar(EntradaParaClaudeCode.interrumpir(id: "dilo-interrumpir-\(numero)"))
    AppLog.conversacion.info("claude code: turno \(numero, privacy: .public) interrumpido")
    viva.vigias.append(
      Task { [weak self] in
        try? await Task.sleep(for: Self.plazoParaInterrumpir)
        guard !Task.isCancelled, let self, self.sesion === viva, viva.recibidos < numero else { return }
        AppLog.conversacion.error("claude code: no soltó el turno interrumpido; se mata")
        self.cerrarSesion(matar: true)
      }
    )
  }

  private func vigilarArranque(_ viva: SesionViva) {
    viva.vigias.append(
      Task { [weak self] in
        try? await Task.sleep(for: Self.plazoParaArrancar)
        guard !Task.isCancelled, let self, self.sesion === viva, !viva.arranco else { return }
        AppLog.conversacion.error("claude code: no dijo nada en el plazo; se mata")
        viva.motivoDeCierre = .noResponde
        viva.proceso.matar()
      }
    )
  }

  // Lo que dice la CLI

  private func recibir(_ suceso: ProcesoDeClaudeCode.Suceso, de viva: SesionViva) {
    guard sesion === viva else { return }
    switch suceso {
    case let .mensaje(mensaje):
      if case .inicio = mensaje { viva.arranco = true }
      for salida in viva.traductor.traducir(mensaje) { aplicar(salida, viva) }
      if let id = viva.traductor.sesion { ultimaSesion[viva.proyecto.carpeta] = id }
    case let .termino(codigo, stderr):
      sesion = nil
      viva.vigias.forEach { $0.cancel() }
      AppLog.conversacion.info("claude code: el proceso terminó con \(codigo, privacy: .public)")
      guard let turno = viva.turno else { return }
      viva.turno = nil
      if let motivo = viva.motivoDeCierre {
        turno.finish(throwing: motivo)
        return
      }
      let detalle = FallaDeClaudeCode.detalle(deStderr: stderr)
      guard !viva.arranco else {
        turno.finish(throwing: FallaDeClaudeCode.seCorto(detalle: detalle))
        return
      }
      // No arrancó: puede ser que no haya sesión iniciada en la CLI. Se le
      // pregunta a ella (`claude auth status`), no al disco.
      let ejecutable = viva.proceso.ejecutable
      Task {
        let hay = await Task.detached { DestinoClaudeCode.haySesionEnLaCLI(ejecutable) }.value
        turno.finish(throwing: hay == false ? FallaDeClaudeCode.sinSesion : FallaDeClaudeCode.noArranco(detalle: detalle))
      }
    }
  }

  private func aplicar(_ salida: SalidaDelTurno, _ viva: SesionViva) {
    // Los eventos son del turno que la CLI está contestando: el siguiente a
    // los que ya cerraron. Si ése no es el que espera la persona (se
    // interrumpió), se descartan, y un permiso de ahí se niega.
    let deEsteTurno = viva.numeroDelTurno == viva.recibidos + 1
    switch salida {
    case let .decir(texto):
      if deEsteTurno { viva.turno?.yield(.texto(texto)) }
    case let .transcribir(texto):
      if deEsteTurno { alTranscribir?(texto) }
    case let .herramienta(nombre, enCurso):
      if deEsteTurno { viva.turno?.yield(.herramienta(nombre: nombre, enCurso: enCurso)) }
    case let .pedirPermiso(pedido, descripcion, detalle):
      guard deEsteTurno, let turno = viva.turno else {
        viva.proceso.mandar(EntradaParaClaudeCode.negar(pedido))
        return
      }
      viva.permisos += 1
      let proceso = viva.proceso
      let unaVez = UnaVez()
      let aprobacion = Aprobacion(id: pedido.id, agente: agente, descripcion: descripcion, detalle: detalle) {
        [weak viva] permitir in
        guard unaVez.primera() else { return }
        proceso.mandar(permitir ? EntradaParaClaudeCode.permitir(pedido) : EntradaParaClaudeCode.negar(pedido))
        if permitir { Task { @MainActor in viva?.aprobados += 1 } }
      }
      turno.yield(.pideAprobacion(aprobacion))
    case .retirarPermiso:
      // El contrato no tiene cómo quitar una aprobación de la muesca: si la
      // persona hace clic después, la CLI ignora la respuesta.
      break
    case let .contestarError(id):
      viva.proceso.mandar(EntradaParaClaudeCode.errorDeControl(id: id, mensaje: "Dilo no atiende este pedido."))
    case let .fin(falla, interrumpido):
      viva.recibidos += 1
      guard deEsteTurno, let turno = viva.turno else { return }
      viva.turno = nil
      viva.numeroDelTurno = nil
      let segundos = viva.inicioDelTurno.map { Date.now.timeIntervalSince($0) } ?? 0
      AppLog.conversacion.info(
        "claude code: turno \(viva.recibidos, privacy: .public) en \(segundos, format: .fixed(precision: 1), privacy: .public) s (\(falla == nil ? (interrumpido ? "interrumpido" : "bien") : "falla", privacy: .public))"
      )
      if let falla {
        turno.finish(throwing: falla)
      } else {
        turno.yield(.fin(costoUSD: nil))
        turno.finish()
      }
    }
  }

  // Proyectos

  /// Los de Ajustes y, si está prendido, los de `~/Developer`. Listar el
  /// disco va fuera del hilo principal.
  private func proyectosConocidos() async -> [ProyectoDeClaudeCode] {
    let propios = settings.claudeCodeProyectos
    let incluir = settings.claudeCodeIncluirDeveloper
    let deDeveloper = incluir ? await Task.detached { DestinoClaudeCode.proyectosDeDeveloper() }.value : []
    return CatalogoDeProyectos.todos(propios: propios, deDeveloper: deDeveloper)
  }

  private func ultimoProyecto(en catalogo: [ProyectoDeClaudeCode]) -> ProyectoDeClaudeCode? {
    let carpeta = settings.claudeCodeUltimoProyecto
    guard !carpeta.isEmpty else { return nil }
    return catalogo.first { $0.carpeta == carpeta }
      ?? ProyectoDeClaudeCode(nombre: (carpeta as NSString).lastPathComponent, carpeta: carpeta)
  }

  nonisolated static func proyectosDeDeveloper() -> [ProyectoDeClaudeCode] {
    let raiz = (NSHomeDirectory() as NSString).appendingPathComponent("Developer")
    let nombres = (try? FileManager.default.contentsOfDirectory(atPath: raiz)) ?? []
    let carpetas = nombres.filter { nombre in
      var esCarpeta: ObjCBool = false
      // `fileExists` sigue el enlace: un enlace a un repo cuenta, uno roto no.
      return FileManager.default.fileExists(atPath: (raiz as NSString).appendingPathComponent(nombre), isDirectory: &esCarpeta)
        && esCarpeta.boolValue
    }
    return CatalogoDeProyectos.deDeveloper(carpetas: carpetas, raiz: raiz)
  }

  // La CLI

  /// Busca la CLI, revisa la carpeta y lanza el proceso. Corre fuera del
  /// hilo principal.
  nonisolated static func lanzar(carpeta: String, nombre: String, ruta: String, argumentos: [String]) throws -> ProcesoDeClaudeCode {
    var esCarpeta: ObjCBool = false
    guard FileManager.default.fileExists(atPath: carpeta, isDirectory: &esCarpeta), esCarpeta.boolValue else {
      throw FallaDeClaudeCode.carpetaNoExiste(proyecto: nombre)
    }
    guard let ejecutable = ubicar(ruta: ruta) else { throw FallaDeClaudeCode.noEstaInstalado }
    do {
      return try ProcesoDeClaudeCode(
        ejecutable: ejecutable,
        carpeta: URL(filePath: carpeta, directoryHint: .isDirectory),
        argumentos: argumentos,
        entorno: entorno()
      )
    } catch {
      throw FallaDeClaudeCode.noArranco(detalle: error.localizedDescription)
    }
  }

  /// Dónde está `claude`: lo elegido en Ajustes, donde lo dejan los
  /// instaladores y, si no, lo que diga el shell de la persona.
  nonisolated static func ubicar(ruta: String) -> URL? {
    let candidatos = UbicacionDeClaude.candidatos(home: NSHomeDirectory(), elegida: ruta)
    if let encontrado = candidatos.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
      return URL(filePath: encontrado)
    }
    return delShell()
  }

  /// `command -v claude` en un shell interactivo de la persona, que es
  /// donde vive su PATH. Con plazo: un `.zshrc` que pregunta algo no puede
  /// colgar la llamada.
  nonisolated private static func delShell() -> URL? {
    let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    guard let salida = correr(URL(filePath: shell), ["-lic", "command -v claude"], plazo: 5) else { return nil }
    let ruta = salida.texto.components(separatedBy: .newlines).last { $0.hasPrefix("/") }
    guard let ruta, FileManager.default.isExecutableFile(atPath: ruta) else { return nil }
    return URL(filePath: ruta)
  }

  /// `claude auth status`: sale 0 con sesión y 1 sin ella.
  nonisolated static func haySesionEnLaCLI(_ ejecutable: URL) -> Bool? {
    guard let salida = correr(ejecutable, ["auth", "status"], plazo: 10, entorno: entorno()) else { return nil }
    return UbicacionDeClaude.haySesion(json: salida.texto, codigoDeSalida: salida.codigo)
  }

  /// El entorno de la app, con el PATH de un terminal y sin lo que haría
  /// que Claude Code cobre a la API o se crea anidado.
  nonisolated static func entorno() -> [String: String] {
    var entorno = ProcessInfo.processInfo.environment
    for variable in UbicacionDeClaude.variablesQueNoPasan { entorno[variable] = nil }
    entorno["PATH"] = UbicacionDeClaude.path(home: NSHomeDirectory(), actual: entorno["PATH"])
    return entorno
  }

  /// Corre un comando corto y devuelve su stdout, o nil si no terminó en el
  /// plazo.
  nonisolated private static func correr(
    _ ejecutable: URL, _ argumentos: [String], plazo: Double, entorno: [String: String]? = nil
  ) -> (texto: String, codigo: Int32)? {
    let proceso = Process()
    proceso.executableURL = ejecutable
    proceso.arguments = argumentos
    if let entorno { proceso.environment = entorno }
    let salida = Pipe()
    proceso.standardOutput = salida
    proceso.standardError = FileHandle.nullDevice
    proceso.standardInput = FileHandle.nullDevice
    let termino = DispatchSemaphore(value: 0)
    proceso.terminationHandler = { _ in termino.signal() }
    do { try proceso.run() } catch { return nil }
    // Se lee en otro hilo mientras corre: un stdout lleno bloquearía al
    // proceso, y leer hasta el final acá no respetaría el plazo.
    let leido = LecturaHastaElFinal(salida.fileHandleForReading)
    guard termino.wait(timeout: .now() + plazo) == .success else {
      proceso.terminate()
      return nil
    }
    return (String(decoding: leido.esperar(plazo: 1), as: UTF8.self), proceso.terminationStatus)
  }
}

/// Una sesión de Claude Code abierta en esta llamada.
@MainActor
private final class SesionViva {
  let proyecto: ProyectoDeClaudeCode
  let proceso: ProcesoDeClaudeCode
  var traductor: TraductorDeClaudeCode
  /// El stream del turno que espera la persona, y su número.
  var turno: AsyncThrowingStream<EventoDelDestino, any Error>.Continuation?
  var numeroDelTurno: Int?
  var inicioDelTurno: Date?
  /// Turnos mandados y `result` recibidos: cada turno mandado termina con
  /// un `result`, también el interrumpido, y así se sabe de quién es cada
  /// evento.
  var enviados = 0
  var recibidos = 0
  /// Si la CLI ya dijo su `init`.
  var arranco = false
  /// Por qué se mató el proceso, si lo mató Dilo.
  var motivoDeCierre: FallaDeClaudeCode?
  var consumo: Task<Void, Never>?
  var vigias: [Task<Void, Never>] = []
  var permisos = 0
  var aprobados = 0

  init(proyecto: ProyectoDeClaudeCode, proceso: ProcesoDeClaudeCode, agente: String) {
    self.proyecto = proyecto
    self.proceso = proceso
    traductor = TraductorDeClaudeCode(agente: agente)
  }
}

/// Que el clic de una aprobación cuente una sola vez.
private final class UnaVez: Sendable {
  private let usada = OSAllocatedUnfairLock(initialState: false)

  func primera() -> Bool {
    usada.withLock { usada in
      defer { usada = true }
      return !usada
    }
  }
}

/// Lee un pipe hasta el final en un hilo aparte.
private final class LecturaHastaElFinal: @unchecked Sendable {
  private let listo = DispatchSemaphore(value: 0)
  private var datos = Data()

  init(_ archivo: FileHandle) {
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      datos = archivo.readDataToEndOfFile()
      listo.signal()
    }
  }

  /// Lo leído, si terminó de leer en el plazo; si no, nada.
  func esperar(plazo: Double) -> Data {
    listo.wait(timeout: .now() + plazo) == .success ? datos : Data()
  }
}
