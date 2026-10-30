import CoreAudio
import Foundation
import Testing

@testable import DiloEngines

/// La escucha de nombres tiene el micrófono abierto todo el rato: nunca un
/// Bluetooth que nadie eligió, porque deja los audífonos en el perfil de
/// llamada mientras dure.
struct PlanDeMicrofonoDeLaEscuchaTests {
  let interno = EntradaDeAudio(id: 10, uid: "BuiltInMicrophoneDevice", nombre: "Micrófono del MacBook", transporte: .interno)
  let airpods = EntradaDeAudio(id: 20, uid: "AA-BB:input", nombre: "AirPods", transporte: .bluetooth)
  let usb = EntradaDeAudio(id: 30, uid: "USB-1", nombre: "Shure MV7", transporte: .cableado)

  private func escucha(
    _ entradas: [EntradaDeAudio], sistema: AudioDeviceID?, tapaCerrada: Bool = false,
    eleccion: EleccionDeMicrofono = .automatico
  ) -> PlanDeMicrofono.Decision? {
    PlanDeMicrofono.paraLaEscucha(
      eleccion: eleccion, entradas: entradas, entradaDelSistema: sistema, tapaCerrada: tapaCerrada
    )
  }

  @Test func igualQueElDictadoSiNoHayBluetooth() {
    #expect(escucha([interno, usb], sistema: 10) == .init(fijarA: nil, motivo: .delSistema))
    #expect(escucha([interno, airpods], sistema: 20) == .init(fijarA: interno, motivo: .evitarBluetooth))
  }

  @Test func enAutomaticoNuncaAbreUnBluetooth() {
    #expect(escucha([airpods], sistema: 20) == nil)
    // La tapa cerrada saca al del Mac; sin otro con cable, no se escucha.
    #expect(escucha([interno, airpods], sistema: 20, tapaCerrada: true) == nil)
    #expect(escucha([interno, airpods, usb], sistema: 20, tapaCerrada: true) == .init(fijarA: usb, motivo: .evitarBluetooth))
  }

  @Test func conLaTapaCerradaNoEscuchaElMicDelMac() {
    #expect(escucha([interno], sistema: 10, tapaCerrada: true) == nil)
  }

  @Test func unBluetoothElegidoSeRespeta() {
    let elegido = EleccionDeMicrofono.elegido(uid: airpods.uid, nombre: airpods.nombre)
    #expect(escucha([interno, airpods], sistema: 10, eleccion: elegido) == .init(fijarA: airpods, motivo: .elegido))
    #expect(escucha([interno, airpods], sistema: 20, eleccion: .delSistema) == .init(fijarA: nil, motivo: .delSistema))
  }

  @Test func unElegidoQueNoEstaNoCaeAUnBluetooth() {
    let elegido = EleccionDeMicrofono.elegido(uid: usb.uid, nombre: usb.nombre)
    #expect(escucha([interno, airpods], sistema: 20, eleccion: elegido) == nil)
    #expect(escucha([interno, airpods], sistema: 10, eleccion: elegido) == .init(fijarA: nil, motivo: .elegidoAusente))
  }
}
