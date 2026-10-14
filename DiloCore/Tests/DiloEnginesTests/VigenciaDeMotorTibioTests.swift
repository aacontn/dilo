import CoreAudio
import Foundation
import Testing

@testable import DiloEngines

struct VigenciaDeMotorTibioTests {
  @Test func venceConLaEdadConLaEpocaYConOtroDispositivo() {
    let t0 = ContinuousClock.now
    let sirve = { (pedido: AudioDeviceID, epoca: Int, minutos: Int64) in
      VigenciaDeMotorTibio.sirve(
        guardadoPara: 10, epocaGuardada: 3, creado: t0,
        pedido: pedido, epocaActual: epoca, ahora: t0.advanced(by: .seconds(minutos * 60)))
    }
    #expect(sirve(10, 3, 29))
    #expect(!sirve(10, 3, 30))
    #expect(!sirve(10, 3, 31))
    #expect(!sirve(10, 4, 1))
    #expect(!sirve(20, 3, 1))
  }

  @Test func soloSeDejaTibioUnMicrofonoConCableOElDelMac() {
    #expect(VigenciaDeMotorTibio.vale(transporte: .interno))
    #expect(VigenciaDeMotorTibio.vale(transporte: .cableado))
    #expect(!VigenciaDeMotorTibio.vale(transporte: .bluetooth))
    #expect(!VigenciaDeMotorTibio.vale(transporte: .otro))
  }

  @Test func elMotorSeFijaAlPlanYSoloConTibioAlDelSistema() {
    let webcam = EntradaDeAudio(id: 81, uid: "Trust", nombre: "Trust QHD Webcam", transporte: .cableado)
    let interno = EntradaDeAudio(id: 10, uid: "BuiltIn", nombre: "Micrófono del MacBook", transporte: .interno)
    let audifonos = EntradaDeAudio(id: 121, uid: "WH", nombre: "WH-CH720N", transporte: .bluetooth)
    let delSistema = PlanDeMicrofono.Decision(fijarA: nil, motivo: .delSistema)
    let conCable = PlanDeMicrofono.Decision(fijarA: webcam, motivo: .evitarBluetooth)

    #expect(VigenciaDeMotorTibio.entradaDelMotor(plan: conCable, entradaDelSistema: audifonos, tibio: false) == webcam)
    #expect(VigenciaDeMotorTibio.entradaDelMotor(plan: delSistema, entradaDelSistema: interno, tibio: false) == nil)
    #expect(VigenciaDeMotorTibio.entradaDelMotor(plan: delSistema, entradaDelSistema: interno, tibio: true) == interno)
    // Un Bluetooth nunca se fija para dejarlo tibio.
    #expect(VigenciaDeMotorTibio.entradaDelMotor(plan: delSistema, entradaDelSistema: audifonos, tibio: true) == nil)
  }
}
