import Foundation
import Testing

@testable import DiloEngines

struct GuardiaDeReconstruccionTests {
  private let webcam = GuardiaDeReconstruccion.Huella(dispositivo: 122, tasa: 48_000, canales: 2)

  /// El eco del propio fijado: el motor sigue corriendo en la webcam, a la
  /// misma tasa. Reconstruir por esto era el bucle de la 0.4.4.
  @Test func elAvisoConElMotorAndandoIgualNoReconstruye() {
    #expect(!GuardiaDeReconstruccion.hayQueReconstruir(corriendo: true, alArrancar: webcam, ahora: webcam))
  }

  /// El motor se detuvo solo: eso sí es un cambio de ruta.
  @Test func unMotorDetenidoSeReconstruye() {
    #expect(GuardiaDeReconstruccion.hayQueReconstruir(corriendo: false, alArrancar: webcam, ahora: webcam))
  }

  /// Un Bluetooth que pasa al perfil de llamada cambia la tasa; un micrófono
  /// desenchufado, el dispositivo.
  @Test func otroFormatoOOtroDispositivoSeReconstruye() {
    let llamada = GuardiaDeReconstruccion.Huella(dispositivo: 122, tasa: 16_000, canales: 1)
    let otro = GuardiaDeReconstruccion.Huella(dispositivo: 90, tasa: 48_000, canales: 2)
    #expect(GuardiaDeReconstruccion.hayQueReconstruir(corriendo: true, alArrancar: webcam, ahora: llamada))
    #expect(GuardiaDeReconstruccion.hayQueReconstruir(corriendo: true, alArrancar: webcam, ahora: otro))
  }

  /// Sin huella —el motor no llegó a arrancar— no hay con qué comparar.
  @Test func sinHuellaSeReconstruye() {
    #expect(GuardiaDeReconstruccion.hayQueReconstruir(corriendo: true, alArrancar: nil, ahora: webcam))
  }

  /// La cadencia del log de las 18:24:41: una vuelta cada ~300 ms. La quinta
  /// en cinco segundos cruza el tope, una sola vez.
  @Test func elBucleCruzaElTopeUnaSolaVez() {
    var guardia = GuardiaDeReconstruccion()
    let inicio = ContinuousClock.now
    var cruces: [Int] = []
    for vuelta in 0..<10 {
      if guardia.anotar(en: inicio + .milliseconds(300 * vuelta)) { cruces.append(vuelta) }
    }
    #expect(cruces == [GuardiaDeReconstruccion.maximo])
    #expect(guardia.dejoDeFijar)
  }

  /// Un Bluetooth que avisa dos o tres veces al cambiar de perfil, y otro
  /// cambio un rato después, no son un bucle.
  @Test func cambiosDeRutaEspaciadosNoCruzanElTope() {
    var guardia = GuardiaDeReconstruccion()
    let inicio = ContinuousClock.now
    let instantes = [0, 150, 400, 6_000, 6_200, 12_000].map { inicio + .milliseconds($0) }
    #expect(instantes.allSatisfy { !guardia.anotar(en: $0) })
    #expect(!guardia.dejoDeFijar)
    #expect(guardia.enLaVentana == 1)
  }
}
