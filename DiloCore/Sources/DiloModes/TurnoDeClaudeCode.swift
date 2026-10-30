import Foundation

/// Lo que sale de un turno de Claude Code para la conversación, ya decidido:
/// qué se dice, qué va sólo a la transcripción, qué muestra la barra y qué
/// permiso se pide. Es `EventoDelDestino` sin cierres, para poder probarlo
/// contra transcripciones grabadas; `DestinoClaudeCode` lo pasa al contrato.
public enum SalidaDelTurno: Equatable, Sendable {
  /// Para la voz (`EventoDelDestino.texto`).
  case decir(String)
  /// El texto entero de Claude, sin resumir, para la transcripción.
  case transcribir(String)
  /// Para la barra y la transcripción (`EventoDelDestino.herramienta`).
  case herramienta(String, enCurso: Bool)
  /// Un permiso para la muesca (`EventoDelDestino.pideAprobacion`).
  case pedirPermiso(PedidoDePermiso, descripcion: String, detalle: String)
  /// La CLI ya no espera ese permiso.
  case retirarPermiso(id: String)
  /// Un `control_request` que Dilo no atiende: se contesta con error.
  case contestarError(id: String)
  /// Terminó el turno. `falla` es lo que salió mal, si salió mal; un turno
  /// interrumpido no es falla.
  case fin(falla: FallaDeClaudeCode?, interrumpido: Bool)
}

/// Pasa los mensajes de la CLI a salidas del turno, recordando el id de la
/// sesión y qué herramientas siguen en curso.
public struct TraductorDeClaudeCode: Sendable {
  /// Cómo se llama el agente, para el permiso: «Claude Code quiere…».
  public let agente: String
  /// El id de la sesión, en cuanto la CLI lo dice. Con él se retoma la misma
  /// sesión si hay que relanzar el proceso.
  public private(set) var sesion: String?
  public private(set) var modelo: String?
  /// Las herramientas que empezaron y no terminaron, por id, con cómo se
  /// nombraron en la barra.
  private var enCurso: [(id: String, nombre: String)] = []
  /// El `error` del mensaje sintético del turno, si lo hubo.
  private var errorDeLaAPI: String?

  public init(agente: String) {
    self.agente = agente
  }

  public mutating func traducir(_ mensaje: MensajeDeClaudeCode) -> [SalidaDelTurno] {
    switch mensaje {
    case let .inicio(sesion, modelo):
      self.sesion = sesion
      self.modelo = modelo ?? self.modelo
      return []
    case let .texto(texto):
      var salidas: [SalidaDelTurno] = [.transcribir(texto)]
      if let dicho = VozDeClaudeCode.paraDecir(texto) { salidas.append(.decir(dicho)) }
      return salidas
    case let .usaHerramienta(id, nombre, entrada):
      let enLaBarra = HerramientaDeClaudeCode.enCurso(nombre, entrada)
      enCurso.append((id, enLaBarra))
      return [.herramienta(enLaBarra, enCurso: true)]
    case let .terminoHerramienta(id, _, _):
      guard let indice = enCurso.firstIndex(where: { $0.id == id }) else { return [] }
      return [.herramienta(enCurso.remove(at: indice).nombre, enCurso: false)]
    case let .pidePermiso(pedido):
      return [
        .pedirPermiso(
          pedido,
          descripcion: PermisoDeClaudeCode.descripcion(pedido, agente: agente),
          detalle: PermisoDeClaudeCode.detalle(pedido)
        )
      ]
    case let .retiraPermiso(id):
      return [.retirarPermiso(id: id)]
    case let .pedidoDesconocido(id, _):
      return [.contestarError(id: id)]
    case .respuestaDeControl:
      return []
    case let .errorDeLaAPI(error):
      errorDeLaAPI = error
      return []
    case let .fin(resultado):
      if let sesion = resultado.sesion { self.sesion = sesion }
      let pendientes = enCurso.map { SalidaDelTurno.herramienta($0.nombre, enCurso: false) }
      enCurso = []
      let falla = resultado.falla.map { Self.falla($0, errorDeLaAPI: errorDeLaAPI) }
      errorDeLaAPI = nil
      return pendientes + [.fin(falla: falla, interrumpido: resultado.fueInterrumpido)]
    }
  }

  /// Sin sesión iniciada la CLI igual arranca: dice su `init`, manda un
  /// mensaje sintético con `error: "authentication_failed"` y cierra el
  /// turno con `is_error` (medido con una configuración vacía).
  static func falla(_ detalle: String, errorDeLaAPI: String?) -> FallaDeClaudeCode {
    errorDeLaAPI == "authentication_failed" ? .sinSesion : .turnoFallido(detalle: detalle)
  }
}

/// Lo que puede salir mal con Claude Code, con la frase que se dice.
public enum FallaDeClaudeCode: Error, Equatable, Sendable, LocalizedError {
  /// No hay CLI `claude` en ningún lugar conocido ni en el PATH del shell.
  case noEstaInstalado
  /// `claude auth status` dice que no hay sesión iniciada.
  case sinSesion
  /// La carpeta del proyecto no existe (un disco sin montar, un enlace roto).
  case carpetaNoExiste(proyecto: String)
  /// El proceso terminó antes de decir nada.
  case noArranco(detalle: String)
  /// No dijo nada en el plazo, o no soltó un turno interrumpido.
  case noResponde
  /// El proceso se cortó a medio turno.
  case seCorto(detalle: String)
  /// El turno terminó con un error de Claude Code (API, tope de turnos…).
  case turnoFallido(detalle: String)

  public var errorDescription: String? {
    switch self {
    case .noEstaInstalado:
      "No encontré Claude Code en este Mac. Instálalo, o dime dónde está en Ajustes, en Claude."
    case .sinSesion:
      "Claude Code no tiene una sesión iniciada. Abre una terminal, corre «claude» y entra con tu cuenta."
    case let .carpetaNoExiste(proyecto):
      "No encuentro la carpeta de \(proyecto). ¿Está conectado el disco?"
    case let .noArranco(detalle):
      detalle.isEmpty ? "Claude Code no arrancó." : "Claude Code no arrancó: \(detalle)"
    case .noResponde:
      "Claude Code no responde. Lo cerré; pídemelo de nuevo y retomo la sesión."
    case let .seCorto(detalle):
      detalle.isEmpty ? "Claude Code se cerró a medio camino." : "Claude Code se cerró a medio camino: \(detalle)"
    case let .turnoFallido(detalle):
      "Claude Code tuvo un problema: \(detalle)"
    }
  }

  /// Para el log: un nombre, sin rutas ni texto de nadie.
  public var nombreEnElLog: String {
    switch self {
    case .noEstaInstalado: "noEstaInstalado"
    case .sinSesion: "sinSesion"
    case .carpetaNoExiste: "carpetaNoExiste"
    case .noArranco: "noArranco"
    case .noResponde: "noResponde"
    case .seCorto: "seCorto"
    case .turnoFallido: "turnoFallido"
    }
  }

  /// Lo último que escribió la CLI en stderr, en una línea corta: lo que
  /// sirve para entender una falla sin leer un volcado.
  public static func detalle(deStderr stderr: String, tope: Int = 160) -> String {
    let lineas = stderr.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard let ultima = lineas.last else { return "" }
    return ultima.count > tope ? String(ultima.prefix(tope)) + "…" : ultima
  }
}

/// Dónde buscar la CLI `claude` y cómo leer `claude auth status`, la puerta
/// oficial para saber si hay sesión (sale 0 con sesión y 1 sin ella, y
/// escribe un JSON con `loggedIn`).
public enum UbicacionDeClaude {
  /// Una app abierta desde el Finder no hereda el PATH del terminal: se mira
  /// lo elegido en Ajustes y después donde lo deja cada instalador. Dilo no
  /// mira dentro de `~/.claude`.
  public static func candidatos(home: String, elegida: String) -> [String] {
    var lista: [String] = []
    let elegida = elegida.trimmingCharacters(in: .whitespaces)
    if !elegida.isEmpty {
      lista.append(elegida.hasPrefix("~") ? home + elegida.dropFirst() : elegida)
    }
    lista += [
      home + "/.local/bin/claude",
      "/opt/homebrew/bin/claude",
      "/usr/local/bin/claude",
      home + "/.npm-global/bin/claude",
      home + "/.bun/bin/claude",
    ]
    return lista
  }

  /// Las carpetas que se suman al PATH del proceso, para que lo que Claude
  /// Code corra (`swift`, `git`, `npm`) se encuentre igual que en un terminal.
  public static func path(home: String, actual: String?) -> String {
    let propias = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    let actuales = (actual ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
    let faltan = propias.filter { !actuales.contains($0) }
    return (faltan + actuales).joined(separator: ":")
  }

  /// Variables que no pasan al proceso. `ANTHROPIC_API_KEY` haría que Claude
  /// Code cobre a la API en vez de usar la cuenta de la persona (el diseño
  /// dice la cuenta); `CLAUDECODE` le diría que corre dentro de otro Claude
  /// Code, que es lo que pasa si Dilo se lanzó desde una de sus terminales.
  public static let variablesQueNoPasan: Set<String> = ["ANTHROPIC_API_KEY", "CLAUDECODE"]

  /// Lee la salida de `claude auth status`. Nil si no se entiende.
  public static func haySesion(json: String, codigoDeSalida: Int32) -> Bool? {
    if let datos = json.data(using: .utf8),
      let objeto = (try? JSONSerialization.jsonObject(with: datos)) as? [String: Any],
      let dentro = objeto["loggedIn"] as? Bool
    {
      return dentro
    }
    return codigoDeSalida == 1 ? false : nil
  }
}
