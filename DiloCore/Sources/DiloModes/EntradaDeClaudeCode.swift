import Foundation

/// Lo que Dilo le escribe a la CLI `claude` por stdin, una línea por mensaje.
///
/// Las formas son las del Agent SDK (`claude-agent-sdk-python`,
/// `_internal/query.py` y `client.py`) y se probaron contra la CLI 2.1.309:
/// el turno es un mensaje `user`; el permiso, un `control_response` al
/// `request_id` que mandó la CLI; interrumpir, un `control_request` con
/// `subtype: "interrupt"`. El `initialize` del SDK no hace falta sin hooks
/// ni MCP propios: medido, la sesión anda igual sin él.
public enum EntradaParaClaudeCode {
  /// Lo que dijo la persona, como un turno nuevo.
  public static func turno(_ texto: String) -> String {
    SerializacionDeClaudeCode.enUnaLinea([
      "type": "user",
      "message": ["role": "user", "content": texto],
      "parent_tool_use_id": NSNull(),
      "session_id": "",
    ])
  }

  /// Sí al permiso. `updatedInput` va siempre, con la entrada tal como la
  /// pidió Claude: el SDK lo manda siempre y la persona aprobó eso, no otra
  /// cosa.
  public static func permitir(_ pedido: PedidoDePermiso) -> String {
    respuesta(
      id: pedido.id,
      ["behavior": "allow", "updatedInput": SerializacionDeClaudeCode.objeto(pedido.entrada.json)]
    )
  }

  /// No al permiso. El motivo lo lee Claude como resultado de la herramienta.
  public static func negar(_ pedido: PedidoDePermiso, motivo: String = motivoAlNegar) -> String {
    respuesta(id: pedido.id, ["behavior": "deny", "message": motivo])
  }

  public static let motivoAlNegar = "La persona dijo que no desde Dilo. No lo intentes de otra forma; pregúntale qué prefiere."

  /// Corta el turno en curso. La CLI contesta con un `control_response` y
  /// cierra el turno con un `result` `error_during_execution` /
  /// `aborted_streaming`; la sesión sigue viva para el turno siguiente.
  public static func interrumpir(id: String) -> String {
    SerializacionDeClaudeCode.enUnaLinea([
      "type": "control_request",
      "request_id": id,
      "request": ["subtype": "interrupt"],
    ])
  }

  /// Para un `control_request` que Dilo no sabe atender.
  public static func errorDeControl(id: String, mensaje: String) -> String {
    SerializacionDeClaudeCode.enUnaLinea([
      "type": "control_response",
      "response": ["subtype": "error", "request_id": id, "error": mensaje],
    ])
  }

  private static func respuesta(id: String, _ cuerpo: [String: Any]) -> String {
    SerializacionDeClaudeCode.enUnaLinea([
      "type": "control_response",
      "response": ["subtype": "success", "request_id": id, "response": cuerpo],
    ])
  }
}

/// Con qué se abre una sesión de Claude Code.
public struct OpcionesDeClaudeCode: Equatable, Sendable {
  public enum Inicio: Equatable, Sendable {
    /// Una sesión nueva en la carpeta.
    case nueva
    /// La más reciente de la carpeta, según la CLI (`--continue`), en una
    /// copia propia (`--fork-session`): si la persona la tiene abierta en un
    /// terminal, las dos no escriben en la misma.
    case laUltima
    /// Una sesión que Dilo abrió antes y cuyo id le dijo la CLI.
    case retomar(sesion: String)
  }

  public var inicio: Inicio
  /// Un alias de la CLI (`sonnet`, `opus`, `haiku`) o un id. Nil: el que
  /// tenga configurado la persona en su Claude Code.
  public var modelo: String?
  public var carpetasExtra: [String]
  public var instrucciones: String?

  public init(
    inicio: Inicio = .nueva,
    modelo: String? = nil,
    carpetasExtra: [String] = [],
    instrucciones: String? = PromptDeClaudeCodePorVoz.instrucciones
  ) {
    self.inicio = inicio
    self.modelo = modelo
    self.carpetasExtra = carpetasExtra
    self.instrucciones = instrucciones
  }
}

/// Los argumentos de la CLI para una sesión manejada por voz.
public enum ArgumentosDeClaudeCode {
  /// Lo que va siempre. `--permission-mode manual` explícito porque la
  /// persona puede tener otro modo de fábrica en su configuración, y por voz
  /// todo lo que pide permiso tiene que llegar a la muesca: nunca
  /// `bypassPermissions`, `dontAsk`, `acceptEdits` ni `auto`, y nunca
  /// `--dangerously-skip-permissions`. `AskUserQuestion` se apaga porque sus
  /// opciones no se contestan con un clic de sí o no: sin ella, Claude
  /// pregunta en texto y la pregunta se oye.
  public static let fijos = [
    "-p",
    "--input-format", "stream-json",
    "--output-format", "stream-json",
    "--verbose",
    "--permission-prompt-tool", "stdio",
    "--permission-mode", "manual",
    "--disallowedTools", "AskUserQuestion",
  ]

  public static func para(_ opciones: OpcionesDeClaudeCode) -> [String] {
    var argumentos = fijos
    switch opciones.inicio {
    case .nueva: break
    case .laUltima: argumentos += ["--continue", "--fork-session"]
    case let .retomar(sesion): argumentos += ["--resume", sesion]
    }
    if let modelo = opciones.modelo?.trimmingCharacters(in: .whitespaces), !modelo.isEmpty {
      argumentos += ["--model", modelo]
    }
    for carpeta in opciones.carpetasExtra where !carpeta.isEmpty {
      argumentos += ["--add-dir", carpeta]
    }
    if let instrucciones = opciones.instrucciones, !instrucciones.isEmpty {
      argumentos += ["--append-system-prompt", instrucciones]
    }
    return argumentos
  }

  /// Lo que nunca puede aparecer: aprobaría solo lo que la persona tiene que
  /// aprobar con un clic.
  public static let prohibidos: Set<String> = [
    "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions",
    "bypassPermissions", "dontAsk", "acceptEdits", "auto",
  ]
}

/// Lo que se agrega al prompt de sistema de Claude Code cuando lo maneja la
/// voz, versionado. Quien cambie una línea sube `version`.
///
/// Con `--system-prompt-snapshot` (de fábrica) el prompt se graba con la
/// primera petición de la conversación: al retomar una sesión que no nació
/// en Dilo, esto no se agrega. Por eso el resumen para la voz
/// (`VozDeClaudeCode`) no confía en que Claude lo siga.
public enum PromptDeClaudeCodePorVoz {
  public static let version = 1

  public static let instrucciones = """
    La persona te está hablando por voz desde Dilo: lo que escribes se lee en voz alta y lo \
    que dice te llega transcrito, a veces con una palabra mal oída. Contesta en español de \
    Chile, con tuteo y frases cortas. Antes de una tarea larga, di en una frase qué vas a \
    hacer; al terminar, di en una o dos frases qué hiciste y qué falta. No repitas en el texto \
    código, diffs, tablas ni salidas largas: la persona los ve en la transcripción. Si \
    necesitas que elija algo, pregúntalo en una frase. Los permisos los aprueba con un clic.
    """

  /// Lo que se manda al retomar sin una tarea («revisa Claude Code»): que
  /// cuente en qué quedó, para oírlo.
  public static let alRetomar =
    "Retomo esta sesión por voz desde Dilo. En dos frases: ¿en qué quedamos y qué falta?"
}
