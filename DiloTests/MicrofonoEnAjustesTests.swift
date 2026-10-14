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

  /// El motor tibio viene apagado y se guarda bajo su clave.
  @Test func elMotorTibioVieneApagado() {
    let defaults = defaultsNuevos()
    let ajustes = AppSettings(defaults: defaults)
    #expect(!ajustes.motorDeAudioTibio)
    ajustes.motorDeAudioTibio = true
    #expect(defaults.bool(forKey: "diloMotorDeAudioTibio"))
    #expect(AppSettings(defaults: defaults).motorDeAudioTibio)
  }

  /// Apagado, seguir al sistema es no fijar nada —como siempre— y no hay
  /// motor que tomar ni que preparar. Encendido, el motor se fija a la
  /// entrada del sistema si es con cable, para tener a qué dejarlo tibio.
  @Test func sinTibioNoSeFijaNiSePreparaNada() {
    let microfono = MicrofonoDeLaSesion()
    let interno = EntradaDeAudio(id: 10, uid: "BuiltIn", nombre: "Micrófono del MacBook", transporte: .interno)
    let delSistema = PlanDeMicrofono.Decision(fijarA: nil, motivo: .delSistema)

    microfono.empezarSesion(delSistema, entradaDelSistema: interno, tibio: false)
    #expect(microfono.entrada == nil)
    #expect(microfono.motorTibio(para: interno) == nil)

    microfono.empezarSesion(delSistema, entradaDelSistema: interno, tibio: true)
    #expect(microfono.entrada == interno)
    // Nada se preparó todavía: no hay motor que tomar.
    #expect(microfono.motorTibio(para: interno) == nil)
  }

  /// Sin hardware: una reserva vacía no entrega nada, y un Bluetooth nunca
  /// se prepara (no se llega a abrir ningún dispositivo).
  @Test func laReservaNuncaPreparaUnBluetooth() {
    let reserva = ReservaDeMotorTibio()
    let audifonos = EntradaDeAudio(id: 121, uid: "WH", nombre: "WH-CH720N", transporte: .bluetooth)
    reserva.precalentar(para: audifonos)
    #expect(!reserva.hayMotor)
    #expect(reserva.tomar(para: audifonos) == nil)
    reserva.dispositivosCambiaron()
    #expect(!reserva.hayMotor)
  }
}
