import Foundation

/// Las líneas que la persona pega en la configuración de su agente para que
/// avise a la muesca. Ajustes → Datos en la muesca las muestra con «Copiar»
/// y `docs/design/agentes-en-la-muesca.md` las explica; las dos salen de acá
/// para que no digan cosas distintas.
///
/// Todas llaman al mismo script, `dilo-agente.sh`, que viaja dentro del
/// `.app` (`Dilo/Resources/`). El script, y no un `open` pegado en la línea:
/// el nombre de una carpeta con espacios, tildes o un `&` rompe una URL
/// escrita a mano, y el script lo codifica; además no abre Dilo si no está
/// corriendo y nunca hace fallar el *hook* de quien lo llama.
///
/// **Dilo nunca escribe estas líneas por su cuenta** en `~/.claude` ni en
/// `~/.codex`: la configuración de otra herramienta es de la persona.
public enum LineasDeLosHooks {
  public static let nombreDelScript = "dilo-agente.sh"

  /// Qué fase avisa cada evento de Claude Code.
  ///
  /// `PostToolUse` vuelve a «trabajando» después de un permiso: sin él,
  /// «te espera» se quedaba puesto mientras Claude seguía trabajando hasta el
  /// `Stop`. Repetir la fase no mueve la muesca (`RegistroDeAgentes`), y el
  /// script se va al fondo, así que un *hook* por herramienta no frena a
  /// Claude.
  public static let eventosDeClaude: [(evento: String, fase: EventoDeAgente.Fase)] = [
    ("UserPromptSubmit", .trabajando),
    ("PostToolUse", .trabajando),
    ("Notification", .espera),
    ("Stop", .listo),
    ("SessionEnd", .fin),
  ]

  /// Un argumento de shell entre comillas simples, con las simples de
  /// adentro escapadas como `'\''`.
  public static func citar(_ argumento: String) -> String {
    "'" + argumento.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
  }

  /// El comando de un evento: `sh '<script>' claude espera`.
  public static func comando(script: String, agente: EventoDeAgente.Agente, fase: EventoDeAgente.Fase) -> String {
    "sh \(citar(script)) \(agente.rawValue) \(fase.rawValue)"
  }

  /// El bloque `hooks` para `~/.claude/settings.json` (o el
  /// `.claude/settings.json` de un proyecto), como JSON listo para pegar.
  public static func claudeCode(script: String) -> String {
    var hooks: [String: Any] = [:]
    for (evento, fase) in eventosDeClaude {
      hooks[evento] = [["hooks": [["type": "command", "command": comando(script: script, agente: .claude, fase: fase)]]]]
    }
    let objeto: [String: Any] = ["hooks": hooks]
    guard let datos = try? JSONSerialization.data(
      withJSONObject: objeto, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    ) else { return "" }
    return String(decoding: datos, as: UTF8.self)
  }

  /// La línea `notify` de `~/.codex/config.toml`. Codex la llama al final de
  /// cada turno y le agrega un JSON con la conversación como último
  /// argumento: el script lo ignora a propósito.
  public static func codex(script: String) -> String {
    let partes = ["sh", script, EventoDeAgente.Agente.codex.rawValue, EventoDeAgente.Fase.listo.rawValue]
    return "notify = [" + partes.map(cadenaDeTOML).joined(separator: ", ") + "]"
  }

  /// Una cadena básica de TOML: entre comillas dobles, con `\` y `"`
  /// escapados.
  static func cadenaDeTOML(_ texto: String) -> String {
    "\"" + texto.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }

  /// Lo que se escribe en una terminal para probar sin ningún agente.
  public static func prueba(script: String) -> String {
    "DILO_PROYECTO=prueba \(comando(script: script, agente: .claude, fase: .espera))"
  }
}
