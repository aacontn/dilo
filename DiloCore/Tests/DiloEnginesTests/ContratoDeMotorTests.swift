import Foundation
import Testing

@testable import DiloEngines

/// El contrato que cumplen los dos motores, probado contra uno falso: si esto
/// pasa, la sesión de dictado no tiene por qué saber cuál corre.
struct ContratoDeMotorTests {
  private func router(
    apple: MotorFalso,
    parakeet: MotorFalso,
    elegido: SpeechEngineKind,
    descargado: Bool,
    avisar: @escaping @Sendable (EngineSelection) -> Void = { _ in }
  ) -> SpeechEngineRouter {
    SpeechEngineRouter(
      apple: apple,
      parakeet: parakeet,
      elegido: elegido,
      parakeetDescargado: { descargado },
      avisar: avisar
    )
  }

  @Test func arrancarYTerminarDevuelveElTextoDelMotorQueEscucho() async throws {
    let apple = MotorFalso(texto: "de Apple")
    let parakeet = MotorFalso(texto: "de Parakeet")
    let motor = router(apple: apple, parakeet: parakeet, elegido: .parakeet, descargado: true)

    try await motor.start(locale: Locale(identifier: "es-CL"), handlers: EngineHandlers { _ in })
    let texto = try await motor.finish()

    #expect(texto == "de Parakeet")
    #expect(await parakeet.arranques == 1)
    #expect(await apple.arranques == 0)
  }

  @Test func elFlujoDeParcialesLlegaAQuienEscucha() async throws {
    let parakeet = MotorFalso()
    let motor = router(
      apple: MotorFalso(), parakeet: parakeet, elegido: .parakeet, descargado: true
    )

    let recibidos = Recolector()
    try await motor.start(
      locale: Locale(identifier: "es-CL"),
      handlers: EngineHandlers { recibidos.agregar($0) }
    )
    await parakeet.emitir(EngineUpdate(finalizado: "oye ", volatil: "necesito"))
    _ = try await motor.finish()

    #expect(recibidos.todos == [EngineUpdate(finalizado: "oye ", volatil: "necesito")])
    #expect(recibidos.todos.first?.texto == "oye necesito")
  }

  @Test func dosArranquesSeguidosNoAbrenDosSesiones() async throws {
    let parakeet = MotorFalso()
    let motor = router(
      apple: MotorFalso(), parakeet: parakeet, elegido: .parakeet, descargado: true
    )

    try await motor.start(locale: .current, handlers: EngineHandlers { _ in })
    await #expect(throws: EngineError.self) {
      try await motor.start(locale: .current, handlers: EngineHandlers { _ in })
    }
    #expect(await parakeet.arranques == 1)
  }

  @Test func terminarSinSesionEsUnError() async throws {
    let motor = router(
      apple: MotorFalso(), parakeet: MotorFalso(), elegido: .apple, descargado: true
    )
    await #expect(throws: EngineError.self) { _ = try await motor.finish() }
  }

  @Test func cancelarDejaLaSesionCerradaYPermiteOtra() async throws {
    let parakeet = MotorFalso()
    let motor = router(
      apple: MotorFalso(), parakeet: parakeet, elegido: .parakeet, descargado: true
    )

    try await motor.start(locale: .current, handlers: EngineHandlers { _ in })
    await motor.cancel()
    try await motor.start(locale: .current, handlers: EngineHandlers { _ in })

    #expect(await parakeet.cancelaciones == 1)
    #expect(await parakeet.arranques == 2)
  }

  /// La foto de los ajustes se congela al apretar el gatillo: cambiar de
  /// motor a media frase no puede hacer que el texto salga de un motor que
  /// nunca escuchó.
  @Test func cambiarDeMotorAMediaSesionNoCambiaQuienEntregaElTexto() async throws {
    let apple = MotorFalso(texto: "de Apple")
    let parakeet = MotorFalso(texto: "de Parakeet")
    let motor = router(apple: apple, parakeet: parakeet, elegido: .parakeet, descargado: true)

    try await motor.start(locale: .current, handlers: EngineHandlers { _ in })
    await motor.elegir(.apple)
    let texto = try await motor.finish()

    #expect(texto == "de Parakeet")
    #expect(await apple.cierres == 0)
  }
}

/// Junta los parciales que llegan desde el hilo del motor.
private final class Recolector: @unchecked Sendable {
  private let candado = NSLock()
  private var guardados: [EngineUpdate] = []

  func agregar(_ update: EngineUpdate) {
    candado.withLock { guardados.append(update) }
  }

  var todos: [EngineUpdate] { candado.withLock { guardados } }
}
