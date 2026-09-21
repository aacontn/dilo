import DiloText
import Foundation
import Testing
import os

@testable import DiloEngines

/// Los parciales de Parakeet, que es donde el texto se armaba con `+=`.
///
/// Cada parcial es la transcripción entera de su trozo de dos segundos: llega
/// recortado y con mayúscula al empezar, porque para el modelo ese trozo era
/// el comienzo de todo. Pegarlos a secas dejaba «es rápidoAhora habría».
struct UnionDeParcialesTests {
  private let locale = Locale(identifier: "es-CL")

  @Test func losParcialesSeJuntanConEspacio() async throws {
    let captura = CapturaFalsa()
    let modelo = ModeloPorTrozos(
      trozos: [
        "Igual se ve que es rápido",
        "Ahora habría que ver qué tan.",
        "Qué tan poderoso es",
      ]
    )
    let motor = ParakeetEngine(
      captura: captura, cargador: CargadorDe(modelo: modelo), reposo: nil
    )
    let vistos = Parciales()

    try await motor.start(
      locale: locale,
      handlers: EngineHandlers(parcial: { vistos.agregar($0.texto) })
    )
    let carga = try #require(await motor.cargaDelGatillo)
    await carga.value

    for _ in 0..<3 {
      captura.hablar(segundos: 2.1)
      let cuantos = vistos.todos.count
      try await esperarA("el parcial siguiente") { vistos.todos.count > cuantos }
    }

    #expect(
      vistos.todos.last
        == "Igual se ve que es rápido Ahora habría que ver qué tan. Qué tan poderoso es"
    )
    await motor.cancel()
  }

  /// Lo firme y lo volátil también son dos trozos que alguien pega.
  @Test func loFirmeYLoVolatilNoSePegan() {
    #expect(
      EngineUpdate(finalizado: "no se ve como un notch", volatil: "Tiene una línea").texto
        == "no se ve como un notch Tiene una línea"
    )
    #expect(EngineUpdate(finalizado: "hola", volatil: " mundo").texto == "hola mundo")
    #expect(EngineUpdate(finalizado: "hola", volatil: "").texto == "hola")
    #expect(EngineUpdate(finalizado: "", volatil: "hola").texto == "hola")
  }
}

/// Junta los parciales que llegan desde el hilo del motor.
final class Parciales: Sendable {
  private let estado = OSAllocatedUnfairLock(initialState: [String]())

  var todos: [String] { estado.withLock { $0 } }

  func agregar(_ texto: String) {
    estado.withLock { $0.append(texto) }
  }
}
