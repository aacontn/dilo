import Foundation
import Testing
import os

@testable import DiloEngines

/// La promesa del README —"el modelo se descarga solo de la RAM cuando no
/// dictas"— y la del spec §3 —menos de 60 MB en reposo—, probadas donde
/// viven: en el motor, sin micrófono, sin modelo de 469 MB y sin abrir la app.
struct CargaPerezosaTests {
  private let locale = Locale(identifier: "es-CL")

  private func motor(
    captura: CapturaFalsa,
    cargador: CargadorFalso,
    reloj: RelojFalso = RelojFalso(),
    reposo: Duration? = .seconds(300)
  ) -> ParakeetEngine {
    ParakeetEngine(captura: captura, cargador: cargador, reloj: reloj, reposo: reposo)
  }

  @Test func construirElMotorNoCargaNada() async throws {
    let cargador = CargadorFalso()
    let motor = motor(captura: CapturaFalsa(), cargador: cargador)

    #expect(await cargador.cargas == 0)
    #expect(await motor.tieneModeloEnMemoria() == false)
  }

  /// Precalentar corre al arrancar la app y cada vez que cambian los idiomas.
  /// Si cargara el modelo, el reposo de una app que nadie usó esa tarde
  /// pagaría los 469 MB igual (plan, Tarea 9).
  @Test func precalentarNoCargaElModelo() async throws {
    let cargador = CargadorFalso()
    let motor = motor(captura: CapturaFalsa(), cargador: cargador)

    try await motor.prewarm(locale: locale)

    #expect(await cargador.cargas == 0)
    #expect(await motor.tieneModeloEnMemoria() == false)
  }

  @Test func elModeloSeCargaAlEmpezarElDictado() async throws {
    let captura = CapturaFalsa()
    let cargador = CargadorFalso()
    let motor = motor(captura: captura, cargador: cargador)

    try await motor.start(locale: locale, handlers: EngineHandlers { _ in })

    // La captura arranca sin esperar al modelo: grabar desde el primer
    // milisegundo importa más que tenerlo todo listo antes de escuchar.
    #expect(captura.andando)
    try await esperarA("el modelo terminó de cargar") { await motor.tieneModeloEnMemoria() }
    #expect(await cargador.cargas == 1)
  }

  /// Lo que la píldora necesita para decir "Cargando el modelo…" y para
  /// dejar de decirlo.
  @Test func elMotorAvisaMientrasCarga() async throws {
    let cargador = CargadorFalso(abierto: false)
    let motor = motor(captura: CapturaFalsa(), cargador: cargador)
    let avisos = Avisos()

    try await motor.start(
      locale: locale,
      handlers: EngineHandlers(parcial: { _ in }, cargando: { avisos.agregar($0) })
    )

    #expect(avisos.todos == [true])
    await cargador.abrir()
    try await esperarA("el aviso de carga se apagó") { avisos.todos == [true, false] }
  }

  /// El caso que no puede perder palabras: la persona suelta el gatillo
  /// mientras el modelo todavía viene en camino.
  @Test func unDictadoQueTerminaAntesDeQueElModeloCargueSeTranscribeIgual() async throws {
    let captura = CapturaFalsa()
    let cargador = CargadorFalso(texto: "oye, necesito leche", abierto: false)
    let motor = motor(captura: captura, cargador: cargador)

    try await motor.start(locale: locale, handlers: EngineHandlers { _ in })
    captura.hablar(segundos: 0.5)
    try await esperarA("el audio llegó al motor") { await motor.muestrasEnElBuffer > 0 }
    try await esperarA("la carga está esperando") { await cargador.esperandoLaPuerta == 1 }

    let dictado = Task { try await motor.finish() }
    // Soltar no perdió el buffer: la transcripción está esperando al modelo.
    try await Task.sleep(for: .milliseconds(20))
    #expect(await cargador.esperandoLaPuerta == 1)

    await cargador.abrir()
    #expect(try await dictado.value == "oye, necesito leche")
  }

  @Test func elModeloSeSueltaTrasElIntervaloDeReposo() async throws {
    let captura = CapturaFalsa()
    let cargador = CargadorFalso()
    let reloj = RelojFalso()
    let motor = motor(captura: captura, cargador: cargador, reloj: reloj)

    try await motor.start(locale: locale, handlers: EngineHandlers { _ in })
    captura.hablar(segundos: 0.5)
    try await esperarA("el audio llegó al motor") { await motor.muestrasEnElBuffer > 0 }
    _ = try await motor.finish()

    try await esperarA("la cuenta del reposo arrancó") { await reloj.durmiendo }
    #expect(await reloj.esperas == [.seconds(300)])
    #expect(await motor.tieneModeloEnMemoria())

    await reloj.avanzar()
    try await esperarA("el modelo se fue de la RAM") { await motor.tieneModeloEnMemoria() == false }
    let modelo = try #require(await cargador.ultimoModelo)
    #expect(await modelo.liberaciones == 1)

    // Y el dictado siguiente lo vuelve a cargar, en paralelo a la grabación.
    try await motor.start(locale: locale, handlers: EngineHandlers { _ in })
    try await esperarA("el modelo volvió") { await motor.tieneModeloEnMemoria() }
    #expect(await cargador.cargas == 2)
  }

  @Test func conReposoEnNuncaElModeloSeQueda() async throws {
    let captura = CapturaFalsa()
    let cargador = CargadorFalso()
    let reloj = RelojFalso()
    let motor = motor(captura: captura, cargador: cargador, reloj: reloj, reposo: nil)

    try await motor.start(locale: locale, handlers: EngineHandlers { _ in })
    captura.hablar(segundos: 0.5)
    try await esperarA("el audio llegó al motor") { await motor.muestrasEnElBuffer > 0 }
    _ = try await motor.finish()

    try await Task.sleep(for: .milliseconds(50))
    #expect(await reloj.esperas.isEmpty)
    #expect(await motor.tieneModeloEnMemoria())
  }

  /// Cambiar el ajuste a "nunca" con el modelo cargado y sin dictar apaga la
  /// cuenta ahí mismo, en vez de soltar el modelo igual cinco minutos después.
  @Test func pasarANuncaApagaLaCuentaEnCurso() async throws {
    let captura = CapturaFalsa()
    let cargador = CargadorFalso()
    let reloj = RelojFalso()
    let motor = motor(captura: captura, cargador: cargador, reloj: reloj)

    try await motor.start(locale: locale, handlers: EngineHandlers { _ in })
    captura.hablar(segundos: 0.5)
    try await esperarA("el audio llegó al motor") { await motor.muestrasEnElBuffer > 0 }
    _ = try await motor.finish()
    try await esperarA("la cuenta del reposo arrancó") { await reloj.durmiendo }

    await motor.configurarReposo(nil)
    await reloj.avanzar()

    try await Task.sleep(for: .milliseconds(50))
    #expect(await motor.tieneModeloEnMemoria())
  }

  @Test func sinModeloEnDiscoElMotorSeNiegaYNoCarga() async throws {
    let cargador = CargadorFalso(enDisco: false)
    let motor = motor(captura: CapturaFalsa(), cargador: cargador)

    await #expect(throws: EngineError.self) {
      try await motor.start(locale: Locale(identifier: "es-CL"), handlers: EngineHandlers { _ in })
    }
    #expect(await cargador.cargas == 0)
  }
}

/// Los avisos de carga que recibió quien dibuja la píldora.
final class Avisos: Sendable {
  private let estado = OSAllocatedUnfairLock(initialState: [Bool]())

  var todos: [Bool] { estado.withLock { $0 } }

  func agregar(_ cargando: Bool) {
    estado.withLock { $0.append(cargando) }
  }
}
