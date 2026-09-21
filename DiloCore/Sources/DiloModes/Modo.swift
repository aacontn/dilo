import Foundation

/// Un modo: un nombre, un prompt, un proveedor y —si quieres— una tecla.
///
/// Se acabó el "modo activo" (spec 2026-08-05). No hay un desplegable que
/// elige cuál manda: cada modo se invoca por lo suyo, y el dictado normal
/// sigue saliendo limpio sin pasar por ningún LLM.
public struct Modo: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var nombre: String
  /// Qué hacer con lo dictado. Es el prompt del modo, sin el marco que
  /// impide que el modelo conteste la transcripción en vez de reescribirla:
  /// ese marco vive en la app (`ShapingPrompt.instructions`) y no se edita.
  public var prompt: String
  /// El proveedor propio, o nil para heredar el general. Nil es el default y
  /// no exige migrar nada: una configuración vieja se lee igual.
  public var proveedorID: String?
  /// La tecla del modo. Opcional a propósito: de fábrica sólo Limpio trae
  /// una, para que una instalación nueva tenga algo funcionando de inmediato.
  public var gatillo: Gatillo?
  /// Las apps donde este modo es el que corresponde. Es la implementación 0
  /// del `Decider` (spec §7): la app al frente acertó el 100 % del set de
  /// evaluación en 0,013 ms, y cualquier modelo tiene que ganarle a eso.
  public var apps: [String]
  /// Las palabras que desempatan cuando la app no alcanza.
  public var palabrasClave: [String]
  /// Los de fábrica vuelven solos si alguien los borra, y vuelven sin tecla.
  public var esDeFabrica: Bool

  public init(
    id: String,
    nombre: String,
    prompt: String,
    proveedorID: String? = nil,
    gatillo: Gatillo? = nil,
    apps: [String] = [],
    palabrasClave: [String] = [],
    esDeFabrica: Bool = false
  ) {
    self.id = id
    self.nombre = nombre
    self.prompt = prompt
    self.proveedorID = proveedorID
    self.gatillo = gatillo
    self.apps = apps
    self.palabrasClave = palabrasClave
    self.esDeFabrica = esDeFabrica
  }

  /// Los modos de fábrica, con el copy de Dilo. Vienen del locale `es` escrito
  /// a mano del repo Tauri: tuteo, directo, sin relleno.
  public static let deFabrica: [Modo] = [
    Modo(
      id: "limpio",
      nombre: "Limpio",
      prompt: "Saca las muletillas y los arranques en falso, arregla la "
        + "puntuación y las mayúsculas. No cambies las palabras, el sentido "
        + "ni el tono.",
      gatillo: .controlComandoL,
      apps: [],
      palabrasClave: [],
      esDeFabrica: true
    ),
    Modo(
      id: "prompt",
      nombre: "Prompt",
      prompt: "Ordena esto como un prompt: primero el contexto, después la "
        + "instrucción, al final el formato que esperas. No inventes nada que "
        + "no se haya dicho.",
      apps: ["claude", "chatgpt", "cursor", "zed", "perplexity"],
      palabrasClave: ["prompt", "modelo", "contexto", "instrucción"],
      esDeFabrica: true
    ),
    Modo(
      id: "mensaje",
      nombre: "Mensaje",
      prompt: "Déjalo breve, natural y casual, como un mensaje a alguien de "
        + "confianza. Sin fórmulas de correo.",
      apps: ["whatsapp", "telegram", "slack", "discord", "messages", "mensajes"],
      palabrasClave: ["oye", "avísame", "cachái", "dale"],
      esDeFabrica: true
    ),
    Modo(
      id: "correo",
      nombre: "Correo",
      prompt: "Escríbelo como correo: claro, bien estructurado, con saludo y "
        + "cierre si corresponde. Mantén mi tono.",
      apps: ["mail", "spark", "outlook", "superhuman", "gmail"],
      palabrasClave: ["estimado", "estimada", "saludos", "adjunto", "cotización"],
      esDeFabrica: true
    ),
    Modo(
      id: "codigo",
      nombre: "Código",
      prompt: "Respeta rutas, comandos, identificadores y nombres de archivo "
        + "tal cual se dijeron. No traduzcas los términos técnicos.",
      apps: ["terminal", "iterm", "ghostty", "warp", "xcode", "vscode", "code"],
      palabrasClave: ["commit", "branch", "deploy", "endpoint", "build", "merge"],
      esDeFabrica: true
    ),
  ]
}

public extension [Modo] {
  func modo(_ id: String?) -> Modo? {
    guard let id else { return nil }
    return first { $0.id == id }
  }

  /// Los modos que ya tienen tomada esta tecla. Asignar una tecla ocupada
  /// avisa en vez de dejar un atajo muerto en silencio (spec 2026-08-05).
  func modosQueYaUsan(_ gatillo: Gatillo, salvo id: String? = nil) -> [Modo] {
    filter { modo in
      modo.id != id && (modo.gatillo?.disparaLoMismoQue(gatillo) ?? false)
    }
  }
}
