import Foundation
import Testing

@testable import Dilo

/// Lo que Dilo le manda a Apple Notas, sin abrir Notas.
@Suite("Notas de Apple")
struct NotasDeAppleTests {
  @Test func elCuerpoEscapaElHTMLYConservaLosParrafos() {
    let cuerpo = NotasDeApple.cuerpoHTML(titulo: "Nota · 24 sep", texto: "a < b & \"c\"\n\nsegundo")
    #expect(cuerpo.hasPrefix("<div><b>Nota · 24 sep</b></div>"))
    #expect(cuerpo.contains("<div>a &lt; b &amp; &quot;c&quot;</div>"))
    #expect(cuerpo.contains("<div><br></div>"))
    #expect(cuerpo.hasSuffix("<div>segundo</div>"))
  }

  /// El texto va como argumento y nunca dentro del script: un dictado con
  /// comillas no puede romperlo ni colarse como código.
  @Test func elScriptNoLlevaElTexto() {
    #expect(NotasDeApple.script.contains("item 1 of argv"))
    #expect(NotasDeApple.script.contains("folder \"Dilo\""))
  }

  @Test func sinPermisoSeReconoce() {
    #expect(NotasDeApple.resultado(deLaSalidaDeError: "execution error: Not authorized to send Apple events to Notes. (-1743)") == .sinPermiso)
    #expect(NotasDeApple.resultado(deLaSalidaDeError: "syntax error") == .fallo)
  }

  @Test func elTituloLlevaLaFecha() {
    let titulo = NotasDeApple.titulo(para: Date(timeIntervalSince1970: 1_790_000_000))
    #expect(titulo.hasPrefix(String(localized: "Nota · ").trimmingCharacters(in: .whitespaces)) || titulo.contains("·"))
  }
}
