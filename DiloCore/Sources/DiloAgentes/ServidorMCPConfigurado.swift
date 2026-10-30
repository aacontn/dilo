import Foundation

/// Un servidor MCP que la persona conectó en Ajustes → Claude → Conexiones MCP:
/// un programa que Dilo lanza y con el que habla por stdio.
///
/// Dilo **no descubre** servidores leyendo `~/.claude` ni `~/.codex`: la
/// configuración de otra herramienta es de la persona, y un servidor que
/// entra a la **Conversación** lo eligió ella acá. Las variables de entorno
/// van **sin secretos** (`ReglaDelEntorno`): `UserDefaults` no es el Llavero.
public struct ServidorMCPConfigurado: Equatable, Hashable, Sendable, Codable, Identifiable {
  /// Estable: es lo que nombra `Agente.Tipo.mcp(servidor:)`.
  public var id: String
  /// Cómo se dice: «Switchboard».
  public var nombre: String
  /// La ruta del ejecutable, o un nombre que se busca en el `PATH`.
  public var comando: String
  public var argumentos: [String]
  public var entorno: [String: String]
  /// Apagado, ni se lanza ni entra a ningún agente.
  public var encendido: Bool
  /// Si sus herramientas entran también al agente Dilo, además de a su propio
  /// agente `.mcp`.
  public var enDilo: Bool

  public init(
    id: String,
    nombre: String,
    comando: String,
    argumentos: [String] = [],
    entorno: [String: String] = [:],
    encendido: Bool = true,
    enDilo: Bool = true
  ) {
    self.id = id
    self.nombre = nombre
    self.comando = comando
    self.argumentos = argumentos
    self.entorno = entorno
    self.encendido = encendido
    self.enDilo = enDilo
  }

  /// Switchboard, el primero. Su ayudante vive dentro de la app y se declara
  /// con `--agent`: una etiqueta, no una credencial. La primera vez que Dilo
  /// lo lanza, Switchboard muestra una solicitud de emparejamiento que
  /// Alfonso autoriza en su ventana «Agentes»; hasta entonces el ayudante
  /// sólo ofrece `status`.
  public static let switchboard = ServidorMCPConfigurado(
    id: "switchboard",
    nombre: "Switchboard",
    comando: "/Applications/Switchboard OS.app/Contents/Helpers/switchboard-mcp",
    argumentos: ["--agent", "dilo"]
  )

  public static let deFabrica: [ServidorMCPConfigurado] = [switchboard]
}

/// Qué variables de entorno acepta Ajustes para un servidor MCP.
///
/// Un nombre que suena a secreto se rechaza: lo que se escribe en Ajustes
/// queda en `UserDefaults`, que se lee sin permiso y viaja en los respaldos.
/// Un servidor que necesita una clave la lee del Llavero por su cuenta (como
/// Switchboard), o se lanza con un envoltorio que la saca de ahí.
public enum ReglaDelEntorno {
  static let palabrasDeSecreto = [
    "TOKEN", "SECRET", "PASSWORD", "PASSWD", "PASS", "KEY", "CREDENTIAL", "AUTH", "COOKIE", "SESSION", "PRIVATE",
    "CLAVE", "CONTRASENA", "SECRETO",
  ]

  /// Por qué no se acepta esa variable, o nil si se acepta.
  public static func reparo(nombre: String, valor: String) -> String? {
    let limpio = nombre.trimmingCharacters(in: .whitespaces)
    guard !limpio.isEmpty else { return "Falta el nombre de la variable." }
    guard limpio.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
      return "El nombre va con letras, números y guion bajo, sin espacios."
    }
    let mayusculas = limpio.uppercased()
    if palabrasDeSecreto.contains(where: { mayusculas.contains($0) }) {
      return "\(limpio) parece un secreto: Dilo no guarda secretos en Ajustes. Que el servidor lo lea del Llavero."
    }
    if pareceUnSecreto(valor) {
      return "Ese valor parece una clave: Dilo no guarda secretos en Ajustes."
    }
    return nil
  }

  /// Un valor largo, sin espacios y con letras y números mezclados, o con el
  /// prefijo de una clave conocida, es casi seguro una clave.
  static func pareceUnSecreto(_ valor: String) -> Bool {
    let prefijos = ["sk-", "sk_", "ghp_", "gho_", "github_pat_", "xox", "AKIA", "eyJ"]
    if prefijos.contains(where: { valor.hasPrefix($0) }) { return true }
    guard valor.count >= 32, !valor.contains(" "), !valor.contains("/") else { return false }
    let letras = valor.contains { $0.isLetter }
    let numeros = valor.contains { $0.isNumber }
    return letras && numeros
  }

  /// El entorno con que se lanza el servidor: el de Dilo, con un `PATH` que
  /// también mira donde viven los comandos de Homebrew y de `~/.local/bin`
  /// —una app abierta desde el Finder hereda un `PATH` mínimo y `npx` no se
  /// encontraría—, y encima lo que la persona configuró.
  public static func entorno(
    base: [String: String],
    configurado: [String: String],
    casa: String = NSHomeDirectory()
  ) -> [String: String] {
    var entorno = base
    let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(casa)/.local/bin"]
    let actual = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
    entorno["PATH"] = (actual + extra.filter { !actual.contains($0) }).joined(separator: ":")
    for (nombre, valor) in configurado { entorno[nombre] = valor }
    return entorno
  }
}
