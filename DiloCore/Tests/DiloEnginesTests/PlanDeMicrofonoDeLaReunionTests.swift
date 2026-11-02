import CoreAudio
import Foundation
import Testing

@testable import DiloEngines

/// Una reunión tiene el micrófono abierto por horas: un Bluetooth que nadie
/// eligió sólo se abre si no hay otro, porque deja los audífonos en el perfil
/// de llamada mientras dure.
struct PlanDeMicrofonoDeLaReunionTests {
  let interno = EntradaDeAudio(id: 10, uid: "BuiltInMicrophoneDevice", nombre: "Micrófono del MacBook", transporte: .interno)
  let audifonos = EntradaDeAudio(id: 20, uid: "AA-BB:input", nombre: "WH-CH720N", transporte: .bluetooth)
  let camara = EntradaDeAudio(id: 30, uid: "USB-1", nombre: "Trust QHD Webcam", transporte: .cableado)

  private func reunion(
    _ entradas: [EntradaDeAudio], sistema: AudioDeviceID?, tapaCerrada: Bool = false, uidElegido: String? = nil
  ) -> PlanDeMicrofono.Decision {
    PlanDeMicrofono.paraLaReunion(
      uidElegido: uidElegido, entradas: entradas, entradaDelSistema: sistema, tapaCerrada: tapaCerrada
    )
  }

  @Test func sinBluetoothSigueLaEntradaDelSistema() {
    #expect(reunion([camara], sistema: 30) == .init(fijarA: nil, motivo: .delSistema))
  }

  @Test func enUnMacMiniEvitaLosAudifonosConLaCamara() {
    #expect(reunion([audifonos, camara], sistema: 20) == .init(fijarA: camara, motivo: .evitarBluetooth))
  }

  @Test func elMicrofonoDelMacVaPrimero() {
    #expect(reunion([audifonos, camara, interno], sistema: 20) == .init(fijarA: interno, motivo: .evitarBluetooth))
    #expect(reunion([audifonos, camara, interno], sistema: 20, tapaCerrada: true) == .init(fijarA: camara, motivo: .evitarBluetooth))
  }

  @Test func sinOtroMicrofonoAbreElBluetooth() {
    #expect(reunion([audifonos], sistema: 20) == .init(fijarA: nil, motivo: .delSistema))
  }

  @Test func unBluetoothElegidoSeRespeta() {
    #expect(reunion([audifonos, camara], sistema: 30, uidElegido: audifonos.uid) == .init(fijarA: audifonos, motivo: .elegido))
  }

  @Test func unElegidoQueNoEstaNoCaeAUnBluetooth() {
    #expect(reunion([audifonos, camara], sistema: 20, uidElegido: "USB-2") == .init(fijarA: camara, motivo: .elegidoAusente))
    #expect(reunion([camara], sistema: 30, uidElegido: "USB-2") == .init(fijarA: nil, motivo: .elegidoAusente))
  }
}
