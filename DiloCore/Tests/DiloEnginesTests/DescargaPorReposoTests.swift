import Foundation
import Testing

@testable import DiloEngines

/// La regla del ajuste "descargar el modelo tras…": qué se guarda, qué pasa
/// con un valor que ya no existe y cuánto dura cada opción.
struct DescargaPorReposoTests {
  private func defaults(_ nombre: String = UUID().uuidString) -> UserDefaults {
    UserDefaults(suiteName: nombre)!
  }

  @Test func sinNadaGuardadoSonCincoMinutos() {
    #expect(PreferenciaDeReposo.leer(defaults()) == .cincoMinutos)
    #expect(DescargaPorReposo.porDefecto.intervalo == .seconds(300))
  }

  @Test func loGuardadoVuelveIgual() {
    let defaults = defaults()
    PreferenciaDeReposo.guardar(.quinceMinutos, in: defaults)

    #expect(PreferenciaDeReposo.leer(defaults) == .quinceMinutos)
  }

  /// Un valor de una versión que ya no existe cae al default en vez de dejar
  /// el modelo pegado en la RAM para siempre.
  @Test func unValorDesconocidoCaeAlDefault() {
    let defaults = defaults()
    defaults.set("dosSemanas", forKey: PreferenciaDeReposo.clave)

    #expect(PreferenciaDeReposo.leer(defaults) == .porDefecto)
  }

  @Test func nuncaNoTieneIntervalo() {
    #expect(DescargaPorReposo.nunca.intervalo == nil)
    #expect(DescargaPorReposo.allCases.filter { $0.intervalo == nil } == [.nunca])
  }
}
