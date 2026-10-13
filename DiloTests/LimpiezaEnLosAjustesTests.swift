import DiloText
import Foundation
import Testing
@testable import Dilo

/// Los dos ajustes nuevos de la capa de reglas: dónde se guardan y que la
/// sesión los congele con el resto.
@MainActor
struct LimpiezaEnLosAjustesTests {
  private func freshDefaults() -> UserDefaults {
    let name = "LimpiezaEnLosAjustesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test func deFabricaLosComandosVienenPrendidosYSinReemplazos() {
    let settings = AppSettings(defaults: freshDefaults())
    #expect(settings.comandosDeFormato)
    #expect(settings.reemplazos.isEmpty)
    #expect(settings.preferenciasDeTexto.comandosDeFormato)
  }

  /// Las claves cargan peso: renombrarlas borra la elección en silencio.
  @Test func seGuardanBajoSusClavesYSobrevivenAUnReinicio() throws {
    let defaults = freshDefaults()
    let settings = AppSettings(defaults: defaults)
    settings.comandosDeFormato = false
    settings.reemplazos = [Reemplazo(dice: "chat ge pe te", escribe: "ChatGPT")]

    #expect(defaults.object(forKey: "diloComandosDeFormato") as? Bool == false)
    let datos = try #require(defaults.data(forKey: "diloReemplazos"))
    let leidos = try JSONDecoder().decode([Reemplazo].self, from: datos)
    #expect(leidos == [Reemplazo(dice: "chat ge pe te", escribe: "ChatGPT")])

    let otraVez = AppSettings(defaults: defaults)
    #expect(!otraVez.comandosDeFormato)
    #expect(otraVez.reemplazos == leidos)
  }

  @Test func unaListaIlegibleVuelveVaciaSinTumbarNada() {
    let defaults = freshDefaults()
    defaults.set(Data("no es json".utf8), forKey: "diloReemplazos")
    #expect(AppSettings(defaults: defaults).reemplazos.isEmpty)
  }

  @Test func laSesionCongelaLosComandosYLosReemplazos() {
    let settings = AppSettings(defaults: freshDefaults())
    settings.reemplazos = [Reemplazo(dice: "sap", escribe: "SAP")]
    let sesion = settings.sessionSettings
    settings.reemplazos = []
    settings.comandosDeFormato = false
    #expect(sesion.textoPreferencias.reemplazos == [Reemplazo(dice: "sap", escribe: "SAP")])
    #expect(sesion.textoPreferencias.comandosDeFormato)
  }
}
