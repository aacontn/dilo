import Foundation
import Testing
@testable import Dilo

/// «Escuchar mi nombre»: apagada de fábrica, guardada con su clave y
/// encontrable en Ajustes por cómo se le dice.
@MainActor
struct EscuchaDeNombresAjustesTests {
  private func defaultsNuevos() -> UserDefaults {
    let nombre = "EscuchaDeNombresAjustesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: nombre)!
    defaults.removePersistentDomain(forName: nombre)
    return defaults
  }

  @Test func apagadaDeFabricaYSeGuarda() {
    let defaults = defaultsNuevos()
    let settings = AppSettings(defaults: defaults)
    #expect(settings.escucharMiNombre == false)
    settings.escucharMiNombre = true
    // La clave carga peso: renombrarla apaga la escucha de quien la prendió.
    #expect(defaults.bool(forKey: "diloEscucharMiNombre"))
    #expect(AppSettings(defaults: defaults).escucharMiNombre)
  }

  @Test func seEncuentraEnAjustes() {
    #expect(IndiceDeAjustes.buscar("escuchar mi nombre").first == .escucharMiNombre)
    #expect(IndiceDeAjustes.buscar("wake word").contains(.escucharMiNombre))
    #expect(AjusteID.escucharMiNombre.seccion == .claude)
  }
}
