import Foundation
import Testing

@testable import DiloReuniones

struct DetectorDeLlamadasTests {
  let zoom = AppDeLlamada(nombre: "Zoom")
  let meet = AppDeLlamada(nombre: "Chrome")
  let inicio = Date(timeIntervalSince1970: 1_000)

  private func en(_ segundos: TimeInterval) -> Date { inicio.addingTimeInterval(segundos) }

  @Test func reconoceElHelperDeSuApp() {
    #expect(AppsDeLlamadas.app(dePaquete: "com.google.Chrome.helper") == AppDeLlamada(nombre: "Chrome"))
    #expect(AppsDeLlamadas.app(dePaquete: "com.microsoft.teams2") == AppDeLlamada(nombre: "Teams"))
    #expect(AppsDeLlamadas.app(dePaquete: "com.apple.avconferenced") == AppDeLlamada(nombre: "FaceTime"))
  }

  @Test func niDiloNiUnaAppParecidaCuentan() {
    #expect(AppsDeLlamadas.app(dePaquete: "cl.espaciodigital.dilo") == nil)
    #expect(AppsDeLlamadas.app(dePaquete: "com.google.Chromefoo") == nil)
    #expect(AppsDeLlamadas.app(dePaquete: "") == nil)
  }

  @Test func esperaQueElMicrofonoSigaAbierto() {
    var detector = DetectorDeLlamadas()
    #expect(detector.observar(activas: [zoom], ahora: inicio, grabando: false, ocupado: false) == .revisarEn(3))
    #expect(detector.observar(activas: [zoom], ahora: en(1), grabando: false, ocupado: false) == .revisarEn(2))
    #expect(detector.observar(activas: [zoom], ahora: en(3), grabando: false, ocupado: false) == .ofrecer(zoom))
  }

  @Test func unaPruebaCortaNoSeOfrece() {
    var detector = DetectorDeLlamadas()
    _ = detector.observar(activas: [zoom], ahora: inicio, grabando: false, ocupado: false)
    #expect(detector.observar(activas: [], ahora: en(2), grabando: false, ocupado: false) == .nada)
    #expect(detector.observar(activas: [zoom], ahora: en(4), grabando: false, ocupado: false) == .revisarEn(3))
  }

  @Test func seOfreceUnaSolaVezPorLlamada() {
    var detector = DetectorDeLlamadas()
    _ = detector.observar(activas: [zoom], ahora: inicio, grabando: false, ocupado: false)
    #expect(detector.observar(activas: [zoom], ahora: en(3), grabando: false, ocupado: false) == .ofrecer(zoom))
    #expect(detector.observar(activas: [zoom], ahora: en(60), grabando: false, ocupado: false) == .nada)
  }

  @Test func silenciarseNoEsOtraLlamada() {
    var detector = DetectorDeLlamadas()
    _ = detector.observar(activas: [meet], ahora: inicio, grabando: false, ocupado: false)
    _ = detector.observar(activas: [meet], ahora: en(3), grabando: false, ocupado: false)
    #expect(detector.observar(activas: [], ahora: en(1_000), grabando: false, ocupado: false) == .nada)
    #expect(detector.observar(activas: [meet], ahora: en(1_200), grabando: false, ocupado: false) == .nada)
    #expect(detector.observar(activas: [meet], ahora: en(1_204), grabando: false, ocupado: false) == .nada)
  }

  @Test func despuesDelDescansoEsOtraLlamada() {
    var detector = DetectorDeLlamadas()
    _ = detector.observar(activas: [zoom], ahora: inicio, grabando: false, ocupado: false)
    _ = detector.observar(activas: [zoom], ahora: en(3), grabando: false, ocupado: false)
    _ = detector.observar(activas: [], ahora: en(100), grabando: false, ocupado: false)
    #expect(detector.observar(activas: [zoom], ahora: en(400), grabando: false, ocupado: false) == .revisarEn(3))
    #expect(detector.observar(activas: [zoom], ahora: en(403), grabando: false, ocupado: false) == .ofrecer(zoom))
  }

  @Test func conLaMuescaOcupadaEspera() {
    var detector = DetectorDeLlamadas()
    _ = detector.observar(activas: [zoom], ahora: inicio, grabando: false, ocupado: true)
    #expect(detector.observar(activas: [zoom], ahora: en(3), grabando: false, ocupado: true) == .revisarEn(1))
    #expect(detector.observar(activas: [zoom], ahora: en(4), grabando: false, ocupado: false) == .ofrecer(zoom))
  }

  @Test func loQueYaSeGrabaNoSeOfrece() {
    var detector = DetectorDeLlamadas()
    #expect(detector.observar(activas: [zoom], ahora: inicio, grabando: true, ocupado: false) == .nada)
    #expect(detector.observar(activas: [zoom], ahora: en(60), grabando: false, ocupado: false) == .nada)
  }

  @Test func dosAppsSeOfrecenPorSeparado() {
    var detector = DetectorDeLlamadas()
    _ = detector.observar(activas: [zoom, meet], ahora: inicio, grabando: false, ocupado: false)
    #expect(detector.observar(activas: [zoom, meet], ahora: en(3), grabando: false, ocupado: false) == .ofrecer(meet))
    #expect(detector.observar(activas: [zoom, meet], ahora: en(3), grabando: false, ocupado: false) == .ofrecer(zoom))
  }
}
