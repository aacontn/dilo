import DiloEngines
import Foundation
import Testing

@testable import Dilo

/// La elección de micrófono en Ajustes. La regla de qué micrófono se usa es
/// pura y vive en `DiloCore` (`PlanDeMicrofonoTests`); acá, cómo se guarda.
@MainActor
struct MicrofonoEnAjustesTests {
  private func defaultsNuevos() -> UserDefaults {
    let nombre = "MicrofonoEnAjustesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: nombre)!
    defaults.removePersistentDomain(forName: nombre)
    return defaults
  }

  @Test func unaInstalacionNuevaEsAutomatica() {
    #expect(AppSettings(defaults: defaultsNuevos()).microfonoDeDictado == .automatico)
  }

  /// Las claves cargan peso: renombrarlas borra la elección de quien ya la
  /// hizo, en silencio.
  @Test func seGuardaPorUIDYNombreBajoSusClaves() {
    let defaults = defaultsNuevos()
    let ajustes = AppSettings(defaults: defaults)
    ajustes.microfonoDeDictado = .elegido(uid: "AppleUSBAudioEngine:Trust:1", nombre: "Trust QHD Webcam")
    #expect(defaults.string(forKey: "diloMicrofonoElegidoUID") == "AppleUSBAudioEngine:Trust:1")
    #expect(defaults.string(forKey: "diloMicrofonoElegidoNombre") == "Trust QHD Webcam")
    #expect(AppSettings(defaults: defaults).microfonoDeDictado
      == .elegido(uid: "AppleUSBAudioEngine:Trust:1", nombre: "Trust QHD Webcam"))

    ajustes.microfonoDeDictado = .delSistema
    #expect(AppSettings(defaults: defaults).microfonoDeDictado == .delSistema)

    ajustes.microfonoDeDictado = .automatico
    #expect(defaults.string(forKey: "diloMicrofonoElegidoUID") == "")
    #expect(AppSettings(defaults: defaults).microfonoDeDictado == .automatico)
  }

  /// Sin fijar nada, la sesión sigue al sistema y no carga un micrófono de la
  /// anterior.
  @Test func cadaDictadoEmpiezaConSuPropioPlan() {
    let microfono = MicrofonoDeLaSesion()
    let webcam = EntradaDeAudio(id: 81, uid: "Trust", nombre: "Trust QHD Webcam", transporte: .cableado)
    microfono.empezarSesion(.init(fijarA: webcam, motivo: .evitarBluetooth))
    #expect(microfono.entrada == webcam)
    microfono.empezarSesion()
    #expect(microfono.entrada == nil)
  }
}
