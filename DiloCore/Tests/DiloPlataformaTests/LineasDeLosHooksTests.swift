import Foundation
import Testing

@testable import DiloPlataforma

/// Las líneas que la persona pega en su agente y el script que llaman. El
/// script se corre de verdad con `DILO_SOLO_IMPRIMIR`, que imprime la URL y
/// no abre nada: lo que sale tiene que ser lo que `EnlaceDeDilo` entiende.
@Suite("Líneas de los hooks")
struct LineasDeLosHooksTests {
  /// `Dilo/Resources/dilo-agente.sh`, desde este archivo.
  private static let script = URL(filePath: #filePath)
    .deletingLastPathComponent()  // DiloPlataformaTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // DiloCore
    .deletingLastPathComponent()  // la raíz del repo
    .appending(path: "Dilo/Resources/\(LineasDeLosHooks.nombreDelScript)")

  private func correr(_ argumentos: [String], entorno: [String: String]) throws -> String {
    let proceso = Process()
    proceso.executableURL = URL(filePath: "/bin/sh")
    proceso.arguments = [Self.script.path(percentEncoded: false)] + argumentos
    proceso.environment = ["PATH": "/usr/bin:/bin", "DILO_SOLO_IMPRIMIR": "1"].merging(entorno) { $1 }
    let salida = Pipe()
    proceso.standardOutput = salida
    try proceso.run()
    proceso.waitUntilExit()
    #expect(proceso.terminationStatus == 0)
    let datos = salida.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: datos, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func evento(de url: String) -> EventoDeAgente? {
    guard let url = URL(string: url), case let .success(.agente(e)) = EnlaceDeDilo.leer(url) else { return nil }
    return e
  }

  @Test func elScriptCodificaUnaCarpetaConEspaciosYTildes() throws {
    let url = try correr(["claude", "espera"], entorno: ["DILO_PROYECTO": "/Volumes/SSD 1/Mi café & co"])
    #expect(url.hasPrefix("dilo://agente?de=claude&fase=espera&proyecto="))
    #expect(evento(de: url) == EventoDeAgente(agente: .claude, fase: .espera, proyecto: "Mi café co"))
  }

  /// Claude Code pasa la carpeta en `CLAUDE_PROJECT_DIR`.
  @Test func elScriptTomaLaCarpetaDeClaudeCode() throws {
    let url = try correr(["claude", "trabajando"], entorno: ["CLAUDE_PROJECT_DIR": "/Users/x/dilo-mac"])
    #expect(evento(de: url)?.proyecto == "dilo-mac")
  }

  /// Codex agrega un JSON con la conversación como último argumento: no
  /// puede llegar a la URL.
  @Test func elScriptIgnoraLoQueCodexAgrega() throws {
    let url = try correr(
      ["codex", "listo", #"{"type":"agent-turn-complete","input-messages":["mi secreto"]}"#],
      entorno: ["DILO_PROYECTO": "web"]
    )
    #expect(!url.contains("secreto"))
    #expect(evento(de: url) == EventoDeAgente(agente: .codex, fase: .listo, proyecto: "web"))
  }

  @Test func elBloqueDeClaudeEsJSONConLosCincoEventos() throws {
    let texto = LineasDeLosHooks.claudeCode(script: "/Applications/Dilo.app/Contents/Resources/dilo-agente.sh")
    let objeto = try #require(try JSONSerialization.jsonObject(with: Data(texto.utf8)) as? [String: Any])
    let hooks = try #require(objeto["hooks"] as? [String: Any])
    #expect(Set(hooks.keys) == Set(LineasDeLosHooks.eventosDeClaude.map(\.evento)))
    let stop = try #require((hooks["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: String]])
    #expect(stop.first?["command"] == "sh '/Applications/Dilo.app/Contents/Resources/dilo-agente.sh' claude listo")
    #expect(!texto.contains(#"\/"#))
  }

  /// Una ruta con espacios y una comilla simple sigue siendo un argumento.
  @Test func laRutaSeCitaParaElShell() {
    #expect(LineasDeLosHooks.citar("/Volumes/SSD 1/it's") == #"'/Volumes/SSD 1/it'\''s'"#)
  }

  @Test func laLineaDeCodexEsUnArregloDeTOML() {
    let linea = LineasDeLosHooks.codex(script: #"/Apps/Di"lo\.app/dilo-agente.sh"#)
    #expect(linea == #"notify = ["sh", "/Apps/Di\"lo\\.app/dilo-agente.sh", "codex", "listo"]"#)
  }

  @Test func laPruebaUsaElScript() {
    #expect(LineasDeLosHooks.prueba(script: "/a b/dilo-agente.sh") == "DILO_PROYECTO=prueba sh '/a b/dilo-agente.sh' claude espera")
  }
}

@Suite("Aviso de afuera")
struct AvisoDeAfueraTests {
  private func aviso(_ texto: String, simbolo: String? = nil, segundos: Int? = nil, existe: Bool = true) -> AvisoDeAfuera? {
    AvisoDeAfuera(texto: texto, simbolo: simbolo, segundos: segundos, simboloExiste: { _ in existe })
  }

  @Test func unTextoVacioNoEsAviso() {
    #expect(aviso("") == nil)
    #expect(aviso(" \n\t ") == nil)
  }

  @Test func elTextoQuedaEnUnaLineaYConTope() {
    #expect(aviso("Compilación\nlista ")?.texto == "Compilación lista")
    #expect(aviso(String(repeating: "á", count: 40))?.texto.count == AvisoDeAfuera.largoMaximo)
  }

  @Test func sinCaracteresQueInviertenElTexto() {
    #expect(aviso("hola\u{202E}odnum")?.texto == "hola odnum")
  }

  @Test func unSimboloQueNoExisteVuelveALaCampana() {
    #expect(aviso("x", simbolo: "no.existe", existe: false)?.simbolo == "bell")
    #expect(aviso("x", simbolo: "../../etc")?.simbolo == "bell")
    #expect(aviso("x", simbolo: "checkmark.circle")?.simbolo == "checkmark.circle")
    #expect(aviso("x")?.simbolo == "bell")
  }

  @Test func laDuracionSeAcota() {
    #expect(aviso("x")?.segundos == AvisoDeAfuera.duracionPorDefecto)
    #expect(aviso("x", segundos: 0)?.segundos == 1)
    #expect(aviso("x", segundos: 9999)?.segundos == 120)
  }
}
