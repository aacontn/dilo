import CoreAudio
import Foundation
import Testing

@testable import DiloEngines

struct PlanDeMicrofonoTests {
  let interno = EntradaDeAudio(id: 10, uid: "BuiltInMicrophoneDevice", nombre: "Micrófono del MacBook", transporte: .interno)
  let airpods = EntradaDeAudio(id: 20, uid: "AA-BB:input", nombre: "AirPods", transporte: .bluetooth)
  let usb = EntradaDeAudio(id: 30, uid: "USB-1", nombre: "Shure MV7", transporte: .cableado)
  let iphone = EntradaDeAudio(id: 40, uid: "IPHONE", nombre: "Micrófono de iPhone", transporte: .otro)

  private func automatico(
    _ entradas: [EntradaDeAudio], sistema: AudioDeviceID?, tapaCerrada: Bool = false
  ) -> PlanDeMicrofono.Decision {
    PlanDeMicrofono.decidir(
      eleccion: .automatico, entradas: entradas, entradaDelSistema: sistema, tapaCerrada: tapaCerrada)
  }

  @Test func conAudifonosBluetoothUsaElInterno() {
    #expect(automatico([interno, airpods, usb], sistema: 20) == .init(fijarA: interno, motivo: .evitarBluetooth))
  }

  @Test func conLaTapaCerradaPasaAlConCableONoFijaNada() {
    #expect(automatico([interno, airpods], sistema: 20, tapaCerrada: true) == .init(fijarA: nil, motivo: .delSistema))
    #expect(automatico([interno, airpods, usb], sistema: 20, tapaCerrada: true) == .init(fijarA: usb, motivo: .evitarBluetooth))
  }

  /// El caso de este Mac mini el 2026-10-12: audífonos WH-CH720N como
  /// entrada del sistema, el micrófono de una webcam USB al lado y dos
  /// iPhone por Continuity que nunca se eligen solos.
  @Test func unMacMiniUsaElMicConCableAntesQueElBluetooth() {
    let webcam = EntradaDeAudio(id: 81, uid: "Trust", nombre: "Trust QHD Webcam", transporte: .cableado)
    let audifonos = EntradaDeAudio(id: 121, uid: "WH", nombre: "WH-CH720N", transporte: .bluetooth)
    #expect(automatico([iphone, audifonos, webcam], sistema: 121) == .init(fijarA: webcam, motivo: .evitarBluetooth))
  }

  @Test func sinMicConCableSigueConElBluetooth() {
    #expect(automatico([airpods, iphone], sistema: 20) == .init(fijarA: nil, motivo: .delSistema))
  }

  /// Si la entrada del sistema no es Bluetooth, automático no fija nada:
  /// sigue al sistema como siempre.
  @Test func sinBluetoothNoSeFijaNada() {
    #expect(automatico([interno, usb], sistema: 30) == .init(fijarA: nil, motivo: .delSistema))
    #expect(automatico([interno, airpods], sistema: nil) == .init(fijarA: nil, motivo: .delSistema))
  }

  @Test func delSistemaNuncaEsquivaElBluetooth() {
    let plan = PlanDeMicrofono.decidir(
      eleccion: .delSistema, entradas: [interno, airpods], entradaDelSistema: 20, tapaCerrada: false)
    #expect(plan == .init(fijarA: nil, motivo: .delSistema))
  }

  @Test func loElegidoGanaYSiNoEstaSeAvisaAntesDeGrabar() {
    let elegido = PlanDeMicrofono.decidir(
      eleccion: .elegido(uid: "USB-1", nombre: "Shure MV7"), entradas: [interno, airpods, usb],
      entradaDelSistema: 20, tapaCerrada: false)
    #expect(elegido == .init(fijarA: usb, motivo: .elegido))
    #expect(elegido.avisoAntesDeGrabar == nil)

    let ausente = PlanDeMicrofono.decidir(
      eleccion: .elegido(uid: "USB-1", nombre: "Shure MV7"), entradas: [interno, airpods],
      entradaDelSistema: 20, tapaCerrada: false)
    #expect(ausente == .init(fijarA: nil, motivo: .elegidoAusente))
    #expect(ausente.avisoAntesDeGrabar == .elegidoAusente)
  }

  /// Un USB enchufado en otro puerto cambia de UID: se lo reconoce por el
  /// nombre guardado.
  @Test func loElegidoSeReconocePorNombreSiCambioElUID() {
    let enOtroPuerto = EntradaDeAudio(id: 31, uid: "USB-2", nombre: "Shure MV7", transporte: .cableado)
    let plan = PlanDeMicrofono.decidir(
      eleccion: .elegido(uid: "USB-1", nombre: "Shure MV7"), entradas: [airpods, enOtroPuerto],
      entradaDelSistema: 20, tapaCerrada: false)
    #expect(plan == .init(fijarA: enOtroPuerto, motivo: .elegido))
  }

  /// Lo guardado son dos textos; ida y vuelta sin perder nada, y lo vacío
  /// —una instalación nueva— es automático.
  @Test func laEleccionSeGuardaYSeLee() {
    for eleccion in [EleccionDeMicrofono.automatico, .delSistema, .elegido(uid: "USB-1", nombre: "Shure MV7")] {
      #expect(EleccionDeMicrofono(uid: eleccion.uidGuardado, nombre: eleccion.nombreGuardado) == eleccion)
    }
    #expect(EleccionDeMicrofono(uid: "", nombre: "") == .automatico)
  }

  @Test func elSelectorConservaLoElegidoAunqueNoEste() {
    let ausente = EleccionDeMicrofono.elegido(uid: "VIEJO", nombre: "Blue Yeti")
    let opciones = OpcionesDeMicrofono.opciones(conectadas: [airpods, usb], eleccion: ausente)
    #expect(opciones == [
      .automatico, .delSistema,
      .elegido(uid: "AA-BB:input", nombre: "AirPods"),
      .elegido(uid: "USB-1", nombre: "Shure MV7"),
      ausente,
    ])
    #expect(!OpcionesDeMicrofono.estaConectada(ausente, en: [airpods, usb]))
    #expect(OpcionesDeMicrofono.estaConectada(.automatico, en: []))
  }

  @Test func elTransporteDeLaHAL() {
    #expect(DispositivosDeAudio.transporte(tipo: kAudioDeviceTransportTypeBuiltIn) == .interno)
    #expect(DispositivosDeAudio.transporte(tipo: kAudioDeviceTransportTypeBluetoothLE) == .bluetooth)
    #expect(DispositivosDeAudio.transporte(tipo: kAudioDeviceTransportTypeUSB) == .cableado)
    #expect(DispositivosDeAudio.transporte(tipo: kAudioDeviceTransportTypeContinuityCaptureWired) == .otro)
    #expect(DispositivosDeAudio.transporte(tipo: kAudioDeviceTransportTypeVirtual) == .otro)
  }
}
