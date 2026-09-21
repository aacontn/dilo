import Foundation
import Testing

@testable import DiloText

struct NotasDeVersionTests {
  @Test func unTituloDeNivelDosEsUnTitulo() {
    let notas = NotasDeVersion(version: "0.4.0", markdown: "## Gracias")
    #expect(notas.bloques == [.titulo("Gracias")])
  }

  /// Las notas se escriben a 80 columnas para que el diff se lea; ese corte es
  /// del archivo y no del texto, así que el párrafo se vuelve a armar.
  @Test func unParrafoPartidoEnVariasLineasVuelveASerUno() {
    let notas = NotasDeVersion(
      version: "0.4.0",
      markdown: """
        Dilo dejó de ser una app web
        dentro de una ventana.
        """
    )
    #expect(notas.bloques == [.parrafo("Dilo dejó de ser una app web dentro de una ventana.")])
  }

  @Test func lasVinetasSeguidasSonUnaSolaLista() {
    let notas = NotasDeVersion(
      version: "0.4.0",
      markdown: """
        - Uno
        - Dos
          que sigue acá
        """
    )
    #expect(notas.bloques == [.lista(["Uno", "Dos que sigue acá"])])
  }

  @Test func unaLineaEnBlancoCierraElBloque() {
    let notas = NotasDeVersion(
      version: "0.4.0",
      markdown: """
        Un párrafo.

        - Una viñeta

        Otro párrafo.
        """
    )
    #expect(
      notas.bloques == [
        .parrafo("Un párrafo."),
        .lista(["Una viñeta"]),
        .parrafo("Otro párrafo."),
      ]
    )
  }

  /// Lo de adentro de la línea no se toca: lo resuelve `AttributedString` en la
  /// vista, y partirlo acá sería reimplementar Markdown de a pedazos.
  @Test func laNegritaViajaIntacta() {
    let notas = NotasDeVersion(version: "0.4.0", markdown: "- **Ocupa 19 MB** y no se nota.")
    #expect(notas.bloques == [.lista(["**Ocupa 19 MB** y no se nota."])])
  }

  /// El archivo real, el que va dentro del `.app`. Si alguien lo borra o lo
  /// deja vacío, la sección Novedades queda muda y nadie se entera hasta
  /// abrirla.
  @Test func lasNotasDeLa040EstanEscritasYSeParsean() throws {
    let archivo = Self.raiz.appending(path: "Talkify/Resources/NotasDeVersion/0.4.0.md")
    let markdown = try String(contentsOf: archivo, encoding: .utf8)
    let notas = NotasDeVersion(version: "0.4.0", markdown: markdown)

    let titulos = notas.bloques.compactMap { bloque -> String? in
      if case let .titulo(texto) = bloque { return texto }
      return nil
    }
    #expect(titulos.contains("Lo que todavía no está"))
    #expect(titulos.contains("Gracias"))
    // La atribución no se quita (AGENTS.md, licencia y atribución).
    #expect(markdown.contains("Talkify"))
    #expect(markdown.contains("Handy"))
  }

  /// `DiloCore/Tests/DiloTextTests/<archivo>` → la raíz del repo.
  static let raiz = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}
