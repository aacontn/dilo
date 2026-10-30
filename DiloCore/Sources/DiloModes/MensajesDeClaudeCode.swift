import Foundation

/// Lo que dice la CLI `claude` en modo de control por programa, una línea a la
/// vez.
///
/// Es la puerta oficial que usa el Agent SDK: `claude -p --input-format
/// stream-json --output-format stream-json --verbose --permission-prompt-tool
/// stdio`. Cada línea de stdout es un JSON con `type`: `system` (el `init` de
/// cada turno con el id de la sesión), `assistant` (un bloque de texto,
/// pensamiento o uso de herramienta), `user` (el resultado de una
/// herramienta), `result` (fin del turno), `control_request` (la CLI pide
/// permiso para una herramienta) y `control_response` (la CLI contesta un
/// pedido nuestro, como interrumpir). Lo demás —`rate_limit_event`,
/// `stream_event`, los `system` de resumen o de pensamiento— no le importa a
/// la voz. Verificado contra la CLI 2.1.309 el 2026-10-30 con las corridas que
/// están grabadas en `GrabacionesDeClaudeCode`.
public enum MensajeDeClaudeCode: Equatable, Sendable {
  /// El `system/init`: llega al empezar cada turno, con el id de la sesión.
  /// Con `--continue --fork-session` el id es el de la copia nueva.
  case inicio(sesion: String, modelo: String?)
  /// Un bloque `text` de Claude, entero. Sin `--include-partial-messages`
  /// cada bloque llega de una vez.
  case texto(String)
  /// Claude pidió usar una herramienta. Llega antes del permiso, si lo pide.
  case usaHerramienta(id: String, nombre: String, entrada: EntradaDeHerramienta)
  /// El resultado de una herramienta, en un mensaje `user`.
  case terminoHerramienta(id: String, conError: Bool, contenido: String)
  /// `control_request` con `subtype: "can_use_tool"`: la CLI espera un sí o
  /// un no antes de seguir.
  case pidePermiso(PedidoDePermiso)
  /// `control_cancel_request`: la CLI ya no espera ese permiso (el turno se
  /// interrumpió).
  case retiraPermiso(id: String)
  /// Cualquier otro `control_request` (un hook o un MCP del SDK). Dilo no
  /// registra ninguno, pero si llega hay que contestarlo con un error para
  /// que la CLI no se quede esperando.
  case pedidoDesconocido(id: String, tipo: String)
  /// `control_response`: la CLI contestó un pedido nuestro.
  case respuestaDeControl(id: String, error: String?)
  /// `result`: terminó el turno, bien, con error o interrumpido.
  case fin(ResultadoDeClaudeCode)
}

/// Lo que Claude le pasa a una herramienta. Se guarda el JSON tal cual para
/// devolverlo en `updatedInput` al aprobar, y aparte los campos de texto
/// de primer nivel, que es lo que se necesita para describirlo en español.
public struct EntradaDeHerramienta: Equatable, Sendable {
  /// El objeto `input` en una línea, con las claves ordenadas.
  public var json: String
  /// Los campos de texto de primer nivel: `command`, `file_path`, `url`…
  public var campos: [String: String]

  public init(json: String, campos: [String: String]) {
    self.json = json
    self.campos = campos
  }

  public init(objeto: [String: Any]) {
    json = SerializacionDeClaudeCode.enUnaLinea(objeto)
    campos = objeto.compactMapValues { $0 as? String }
  }

  public subscript(_ campo: String) -> String? { campos[campo] }

  public static let vacia = EntradaDeHerramienta(json: "{}", campos: [:])
}

/// Un pedido de permiso de la CLI, como llega en `can_use_tool`.
public struct PedidoDePermiso: Equatable, Sendable, Identifiable {
  /// El `request_id` que hay que devolver en la respuesta.
  public var id: String
  public var herramienta: String
  public var entrada: EntradaDeHerramienta
  public var usoID: String?
  /// La ruta que disparó el pedido, cuando es un archivo.
  public var rutaBloqueada: String?
  /// Lo que la CLI dice de la acción («Create empty file…»), en inglés.
  public var descripcionDeLaCLI: String?

  public init(
    id: String,
    herramienta: String,
    entrada: EntradaDeHerramienta,
    usoID: String? = nil,
    rutaBloqueada: String? = nil,
    descripcionDeLaCLI: String? = nil
  ) {
    self.id = id
    self.herramienta = herramienta
    self.entrada = entrada
    self.usoID = usoID
    self.rutaBloqueada = rutaBloqueada
    self.descripcionDeLaCLI = descripcionDeLaCLI
  }
}

/// El `result` de un turno.
public struct ResultadoDeClaudeCode: Equatable, Sendable {
  /// `success`, `error_during_execution`, `error_max_turns`…
  public var tipo: String
  public var conError: Bool
  /// El texto final: el mismo del último bloque `text`, que ya se dijo.
  public var texto: String?
  public var errores: [String]
  /// `completed`, `aborted_streaming`, `aborted_tools`…
  public var motivoDeTermino: String?
  public var sesion: String?

  public init(
    tipo: String,
    conError: Bool,
    texto: String? = nil,
    errores: [String] = [],
    motivoDeTermino: String? = nil,
    sesion: String? = nil
  ) {
    self.tipo = tipo
    self.conError = conError
    self.texto = texto
    self.errores = errores
    self.motivoDeTermino = motivoDeTermino
    self.sesion = sesion
  }

  /// Interrumpir un turno lo cierra con `error_during_execution` y
  /// `terminal_reason: "aborted_streaming"` (o `aborted_tools` si estaba en
  /// una herramienta): no es una falla, lo pidió la persona.
  public var fueInterrumpido: Bool {
    motivoDeTermino?.hasPrefix("aborted") == true
  }

  /// Qué salió mal, si salió mal: los `errors` o el texto. Un error de la API
  /// puede venir como `success` con `is_error`, así que se mira `is_error`.
  public var falla: String? {
    guard conError, !fueInterrumpido else { return nil }
    let errores = errores.filter { !$0.hasPrefix("[ede_diagnostic]") }
    if !errores.isEmpty { return errores.joined(separator: " ") }
    if let texto, !texto.isEmpty { return texto }
    return tipo
  }
}

/// Lee una línea de stdout de la CLI.
public enum LectorDeClaudeCode {
  /// Lo que dice una línea. Un mensaje `assistant` o `user` puede traer
  /// varios bloques; una línea que no es JSON o no interesa no dice nada.
  public static func leer(_ linea: String) -> [MensajeDeClaudeCode] {
    guard
      let datos = linea.data(using: .utf8),
      let objeto = (try? JSONSerialization.jsonObject(with: datos)) as? [String: Any],
      let tipo = objeto["type"] as? String
    else { return [] }

    switch tipo {
    case "system":
      guard objeto["subtype"] as? String == "init", let sesion = objeto["session_id"] as? String else { return [] }
      return [.inicio(sesion: sesion, modelo: objeto["model"] as? String)]
    case "assistant":
      // Lo de un subagente trae `parent_tool_use_id`: es trabajo interno, la
      // voz sólo sigue al agente principal.
      guard objeto["parent_tool_use_id"] == nil || objeto["parent_tool_use_id"] is NSNull else { return [] }
      return bloques(objeto).compactMap(deAsistente)
    case "user":
      guard objeto["parent_tool_use_id"] == nil || objeto["parent_tool_use_id"] is NSNull else { return [] }
      return bloques(objeto).compactMap(deResultado)
    case "result":
      return [.fin(resultado(objeto))]
    case "control_request":
      return pedido(objeto).map { [$0] } ?? []
    case "control_cancel_request":
      guard let id = objeto["request_id"] as? String else { return [] }
      return [.retiraPermiso(id: id)]
    case "control_response":
      guard
        let respuesta = objeto["response"] as? [String: Any],
        let id = respuesta["request_id"] as? String
      else { return [] }
      let error = respuesta["subtype"] as? String == "error" ? (respuesta["error"] as? String ?? "error") : nil
      return [.respuestaDeControl(id: id, error: error)]
    default:
      return []
    }
  }

  private static func bloques(_ objeto: [String: Any]) -> [[String: Any]] {
    let mensaje = objeto["message"] as? [String: Any]
    return mensaje?["content"] as? [[String: Any]] ?? []
  }

  private static func deAsistente(_ bloque: [String: Any]) -> MensajeDeClaudeCode? {
    switch bloque["type"] as? String {
    case "text":
      guard let texto = bloque["text"] as? String, !texto.isEmpty else { return nil }
      return .texto(texto)
    case "tool_use":
      guard let id = bloque["id"] as? String, let nombre = bloque["name"] as? String else { return nil }
      let entrada = (bloque["input"] as? [String: Any]).map(EntradaDeHerramienta.init(objeto:)) ?? .vacia
      return .usaHerramienta(id: id, nombre: nombre, entrada: entrada)
    default:
      // `thinking` no se dice; viene vacío en los modelos 5.5.
      return nil
    }
  }

  private static func deResultado(_ bloque: [String: Any]) -> MensajeDeClaudeCode? {
    guard bloque["type"] as? String == "tool_result", let id = bloque["tool_use_id"] as? String else { return nil }
    let conError = bloque["is_error"] as? Bool ?? false
    return .terminoHerramienta(id: id, conError: conError, contenido: textoDeResultado(bloque["content"]))
  }

  /// El contenido de un `tool_result` es un texto o una lista de bloques.
  private static func textoDeResultado(_ contenido: Any?) -> String {
    if let texto = contenido as? String { return texto }
    let bloques = contenido as? [[String: Any]] ?? []
    return bloques.compactMap { $0["text"] as? String }.joined(separator: "\n")
  }

  private static func resultado(_ objeto: [String: Any]) -> ResultadoDeClaudeCode {
    ResultadoDeClaudeCode(
      tipo: objeto["subtype"] as? String ?? "",
      conError: objeto["is_error"] as? Bool ?? false,
      texto: objeto["result"] as? String,
      errores: objeto["errors"] as? [String] ?? [],
      motivoDeTermino: objeto["terminal_reason"] as? String,
      sesion: objeto["session_id"] as? String
    )
  }

  private static func pedido(_ objeto: [String: Any]) -> MensajeDeClaudeCode? {
    guard
      let id = objeto["request_id"] as? String,
      let pedido = objeto["request"] as? [String: Any],
      let tipo = pedido["subtype"] as? String
    else { return nil }
    guard tipo == "can_use_tool", let herramienta = pedido["tool_name"] as? String else {
      return .pedidoDesconocido(id: id, tipo: tipo)
    }
    return .pidePermiso(
      PedidoDePermiso(
        id: id,
        herramienta: herramienta,
        entrada: (pedido["input"] as? [String: Any]).map(EntradaDeHerramienta.init(objeto:)) ?? .vacia,
        usoID: pedido["tool_use_id"] as? String,
        rutaBloqueada: pedido["blocked_path"] as? String,
        descripcionDeLaCLI: pedido["description"] as? String
      )
    )
  }
}

/// JSON en una línea, como lo quiere stdin de la CLI: un salto adentro
/// partiría el mensaje en dos. Las claves van ordenadas para que un test
/// pueda comparar la salida.
enum SerializacionDeClaudeCode {
  static func enUnaLinea(_ objeto: Any) -> String {
    guard
      JSONSerialization.isValidJSONObject(objeto),
      let datos = try? JSONSerialization.data(withJSONObject: objeto, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return "{}" }
    return String(decoding: datos, as: UTF8.self)
  }

  static func objeto(_ json: String) -> Any {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [String: Any]()
  }
}
