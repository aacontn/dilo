import Foundation
import Testing

@testable import DiloEngines

/// Lo puro de la segunda pasada de Tus palabras: qué términos van, cuándo
/// cambia la firma y qué viene de fábrica. Lo que hace el CTC con el audio se
/// mide con `scripts/comparar-motores.sh --tus-palabras`, no acá.
struct RefuerzoDeTusPalabrasTests {
  @Test func losTerminosSonSinRepetidasYDeTresLetrasOMas() {
    let terminos = RefuerzoDeTusPalabras.terminos(de: ["Decameron", "decameron", " Viña ", "IA", "UX", "Blokkit", ""])
    #expect(terminos == ["Decameron", "Viña", "Blokkit"])
  }

  @Test func hayUnTopeDeTerminos() {
    let muchas = (0..<500).map { "termino\($0)" }
    #expect(RefuerzoDeTusPalabras.terminos(de: muchas).count == RefuerzoDeTusPalabras.maximoDeTerminos)
  }

  /// Cambiar el diccionario cambia la firma —y el modelo se recarga en el
  /// próximo dictado—; la misma lista da la misma firma en cada arranque.
  @Test func laFirmaCambiaConLaListaYEsEstable() {
    let una = RefuerzoDeTusPalabras.firma(de: ["Decameron", "Viña"])
    #expect(una == RefuerzoDeTusPalabras.firma(de: ["Decameron", "Viña"]))
    #expect(una != RefuerzoDeTusPalabras.firma(de: ["Decameron"]))
    #expect(una != RefuerzoDeTusPalabras.firma(de: ["Viña", "Decameron"]))
  }

  /// Apagada de fábrica: medida, suma más de 200 ms al soltar y cambia
  /// palabras comunes en español (ver `PreferenciaDeTusPalabrasEnParakeet`).
  @Test func vieneApagadaYSinPalabrasCuandoEstaApagada() throws {
    let suite = "cl.espaciodigital.dilo.tests.tuspalabras"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)

    #expect(!PreferenciaDeTusPalabrasEnParakeet.leer(defaults))
    defaults.set(["Decameron"], forKey: "palabras")
    #expect(PreferenciaDeTusPalabrasEnParakeet.palabras(en: defaults, clave: "palabras") == nil)

    defaults.set(true, forKey: PreferenciaDeTusPalabrasEnParakeet.clave)
    #expect(PreferenciaDeTusPalabrasEnParakeet.palabras(en: defaults, clave: "palabras") == ["Decameron"])

    defaults.removePersistentDomain(forName: suite)
  }

  /// Encendida y sin el CTC en disco, el cargador no pide nada más: la firma
  /// es la de la variante sola y nada se recarga.
  @Test(.enabled(if: !ModeloDeTusPalabras.estaDescargado, "este Mac tiene el CTC: la prueba no aplica"))
  func sinElCTCLaFirmaEsLaDeLaVariante() throws {
    let vacia = FileManager.default.temporaryDirectory
      .appendingPathComponent("dilo-sin-modelos-\(UUID().uuidString)", isDirectory: true)
    let cargador = CargadorDeParakeet(carpeta: vacia, tusPalabras: { ["Decameron"] })
    #expect(cargador.firma == "")
  }
}
