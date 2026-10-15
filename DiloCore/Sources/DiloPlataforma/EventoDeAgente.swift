import Foundation

/// Lo que un agente de código le avisa a Dilo desde su propio *hook*:
///
///     dilo://agente?de=claude&fase=espera&proyecto=dilo-mac
///
/// Al revés de como lo hacen otras islas de notch, que siguen a los agentes
/// **leyendo lo que escriben en disco** —los JSONL de `~/.claude`, los
/// rollouts de Codex, la base de Cursor— y sacan sus límites con el token de
/// cada CLI. Acá el agente **avisa**: la persona pega una línea en la
/// configuración de su herramienta, Dilo no abre archivos ajenos ni toca una
/// credencial, y la píldora que importa —«Claude te espera»— llega en el
/// instante y no en el próximo sondeo (plan, cap. 5 §7; 2026-10-15).
public struct EventoDeAgente: Equatable, Sendable {
  public enum Agente: String, CaseIterable, Sendable {
    case claude, codex, cursor, cowork
    /// Un `de=` que Dilo no conoce. Se muestra igual, como «Agente»: la
    /// línea pegada en una herramienta nueva no tiene por qué esperar a que
    /// Dilo la nombre.
    case otro

    /// Nombres propios: no se traducen.
    public var nombre: String {
      switch self {
      case .claude: "Claude"
      case .codex: "Codex"
      case .cursor: "Cursor"
      case .cowork: "Cowork"
      case .otro: "Agente"
      }
    }
  }

  public enum Fase: String, CaseIterable, Sendable {
    /// Trabajando: un segmento quieto, prioridad baja.
    case trabajando
    /// Te espera: un permiso, una pregunta. Lo único que sube de prioridad,
    /// porque es lo único que se atasca sin ti.
    case espera
    /// Terminó el turno.
    case listo
    case error
    /// Cerró la sesión: se retira.
    case fin

    /// Cuánto importa que se vea. La app la traduce a la prioridad de los
    /// asientos de la muesca; acá vive para que la regla se pruebe con
    /// `swift test`.
    public var urgencia: Urgencia {
      switch self {
      case .espera: .alta
      case .listo, .error: .normal
      case .trabajando, .fin: .baja
      }
    }
  }

  /// Tres niveles, como los asientos de la muesca: un número libre termina
  /// con cada fuente pidiendo 99.
  public enum Urgencia: Int, Comparable, Sendable {
    case baja, normal, alta
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
  }

  /// Lo más largo que se acepta de nombre de proyecto. El segmento mide a lo
  /// más 100 puntos y el nombre va en el tooltip; un nombre de 200
  /// caracteres sólo sirve para ensuciar.
  public static let largoMaximoDelProyecto = 32

  public let agente: Agente
  public let fase: Fase
  /// El nombre de la carpeta del proyecto, limpio: lo único que se muestra
  /// además del agente. **Ni el prompt ni la herramienta**: eso es de la
  /// persona y de su terminal, y una URL abierta con `open` queda en el
  /// registro de LaunchServices.
  public let proyecto: String

  public init(agente: Agente, fase: Fase, proyecto: String) {
    self.agente = agente
    self.fase = fase
    self.proyecto = Self.limpiar(proyecto)
  }

  /// Deja sólo letras, números y `-_. `, sin espacios en las puntas y con
  /// tope. Lo que llega por URL lo escribe cualquiera —un *hook*, pero
  /// también una página que abre `dilo://`—, y esto se dibuja en la muesca:
  /// fuera saltos de línea, `<>`, comillas, emojis y los caracteres que
  /// invierten la dirección del texto.
  public static func limpiar(_ proyecto: String) -> String {
    // Compuesto antes de filtrar: una carpeta «café» que llega como «e» más
    // el acento suelto (así la escribe el Finder) perdería la tilde, que no
    // es una letra por sí sola.
    let filtrado = proyecto.precomposedStringWithCanonicalMapping.unicodeScalars.filter { escalar in
      escalar.properties.isAlphabetic
        || escalar.properties.numericType != nil
        || "-_. ".unicodeScalars.contains(escalar)
    }
    // Lo que se sacó del medio deja espacios juntos: «Mi café & co» es
    // «Mi café co», no «Mi café  co».
    let texto = String(String.UnicodeScalarView(filtrado))
      .split(separator: " ", omittingEmptySubsequences: true)
      .joined(separator: " ")
    return String(texto.prefix(largoMaximoDelProyecto))
      .trimmingCharacters(in: .whitespaces)
  }
}
