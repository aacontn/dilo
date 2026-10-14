import Foundation
import Testing

@testable import DiloEngines

struct DetectorDeMicMuertoTests {
  /// Búferes de 1.024 cuadros a 16 kHz, como los del tap: 64 ms cada uno.
  private func eventos(
    segundosEnCero: Double,
    despuesSuena: Bool = false
  ) -> [DetectorDeMicMuerto.Evento] {
    var detector = DetectorDeMicMuerto()
    var vistos: [DetectorDeMicMuerto.Evento] = []
    for _ in 0..<Int(segundosEnCero * 16_000 / 1_024) {
      if let evento = detector.procesar(cuadros: 1_024, tasa: 16_000, pico: 0) {
        vistos.append(evento)
      }
    }
    if despuesSuena, let evento = detector.procesar(cuadros: 1_024, tasa: 16_000, pico: 0.01) {
      vistos.append(evento)
    }
    return vistos
  }

  @Test func reabreAlSegundoAvisaALosCincoYEscalaALosQuince() {
    #expect(eventos(segundosEnCero: 0.9).isEmpty)
    #expect(eventos(segundosEnCero: 1.1) == [.reabrir])
    #expect(eventos(segundosEnCero: 5.1) == [.reabrir, .avisar])
    #expect(eventos(segundosEnCero: 15.1) == [.reabrir, .avisar, .escalar])
  }

  @Test func elSonidoDespejaElAviso() {
    #expect(eventos(segundosEnCero: 6, despuesSuena: true) == [.reabrir, .avisar, .revivio])
  }

  /// Antes del aviso, que vuelva el sonido no tiene nada que despejar: la
  /// muesca no dijo nada todavía.
  @Test func sinAvisoNoHayNadaQueDespejar() {
    #expect(eventos(segundosEnCero: 2, despuesSuena: true) == [.reabrir])
  }

  /// El piso de ruido de una sala callada no es cero digital: ni reabre ni
  /// avisa, por largo que sea el silencio.
  @Test func unaSalaCalladaNoEsUnMicMuerto() {
    var detector = DetectorDeMicMuerto()
    for _ in 0..<400 {
      #expect(detector.procesar(cuadros: 1_024, tasa: 16_000, pico: 0.000_03) == nil)
    }
    #expect(!detector.avisando)
  }

  @Test func unMicQueSonoYSeCalloNoSeReabre() {
    var detector = DetectorDeMicMuerto()
    _ = detector.procesar(cuadros: 1_024, tasa: 16_000, pico: 0.2)
    var vistos: [DetectorDeMicMuerto.Evento] = []
    for _ in 0..<100 {
      if let evento = detector.procesar(cuadros: 1_024, tasa: 16_000, pico: 0) {
        vistos.append(evento)
      }
    }
    #expect(vistos == [.avisar])
    #expect(detector.avisando)
  }

  /// Se cuenta en audio y no en búferes: un hardware a 48 kHz con búferes de
  /// 3.000 cuadros (62,5 ms, exacto en binario) avisa a los mismos cinco
  /// segundos.
  @Test func cuentaEnSegundosDeAudioYNoEnBuferes() {
    var detector = DetectorDeMicMuerto()
    var vistos: [DetectorDeMicMuerto.Evento] = []
    for _ in 0..<79 {
      if let evento = detector.procesar(cuadros: 3_000, tasa: 48_000, pico: 0) {
        vistos.append(evento)
      }
    }
    #expect(vistos == [.reabrir])
    #expect(detector.procesar(cuadros: 3_000, tasa: 48_000, pico: 0) == .avisar)
  }

  /// Un búfer vacío o con una tasa absurda no cuenta como silencio.
  @Test func unBuferInvalidoNoCuenta() {
    var detector = DetectorDeMicMuerto()
    #expect(detector.procesar(cuadros: 0, tasa: 16_000, pico: 0) == nil)
    #expect(detector.procesar(cuadros: 1_000_000, tasa: 0, pico: 0) == nil)
  }

  @Test func elPicoEsElMaximoAbsoluto() {
    let muestras: [Float] = [0.1, -0.7, 0.3]
    #expect(muestras.withUnsafeBufferPointer { DetectorDeMicMuerto.pico($0) } == 0.7)
    #expect([Float]().withUnsafeBufferPointer { DetectorDeMicMuerto.pico($0) } == 0)
  }
}
