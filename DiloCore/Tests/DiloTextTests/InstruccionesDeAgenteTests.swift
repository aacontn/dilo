import Foundation
import Testing

/// `AGENTS.md` es la fuente de verdad del proyecto y `CLAUDE.md` es su copia
/// byte a byte: existen dos archivos porque cada familia de herramientas busca
/// un nombre distinto. Son copias completas y no un puntero `@AGENTS.md`
/// porque no toda herramienta resuelve esa referencia, y la que no la resuelve
/// se queda sin ninguna instrucción. Este test es la guardia: si editas uno y
/// olvidas el otro, falla acá y no a mitad de una sesión con el asistente
/// desalineado. Equivale a `tests/unit/agentInstructions.test.ts` del repo
/// Tauri, en Swift.
struct InstruccionesDeAgenteTests {
  /// `DiloCore/Tests/DiloTextTests/<archivo>` → la raíz del repo.
  static let raiz = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

  static func leer(_ nombre: String) throws -> String {
    try String(contentsOf: raiz.appending(path: nombre), encoding: .utf8)
  }

  @Test func claudeYAgentsSonIdenticos() throws {
    let agents = try Self.leer("AGENTS.md")
    let claude = try Self.leer("CLAUDE.md")
    #expect(
      agents == claude,
      "AGENTS.md y CLAUDE.md se separaron: edita AGENTS.md y cópialo sobre CLAUDE.md"
    )
  }

  @Test func ningunoEsUnPunteroVacio() throws {
    for nombre in ["AGENTS.md", "CLAUDE.md"] {
      let contenido = try Self.leer(nombre)
      #expect(contenido.split(separator: "\n").count > 10, "\(nombre) quedó demasiado corto")
      #expect(!contenido.hasPrefix("@"), "\(nombre) es un puntero, no el contenido")
    }
  }
}
