import Foundation
import os

@testable import Dilo

/// Un reloj que avanza sólo cuando alguien duerme sobre él: la ventana de
/// dos segundos del pegado y los ocho de la tarjeta se cumplen sin esperar
/// nada de verdad.
///
/// El plazo de la foto del portapapeles es la excepción: una espera de mil
/// segundos o más duerme de verdad hasta que la cancelan, para que el plazo
/// nunca le gane a un lector que sí está trabajando. Quien use este reloj le
/// da a la foto un plazo así; los tests que prueban ese plazo usan
/// `DrivenClock`.
final class RelojQueAvanzaAlDormir: Sendable {
  private let tiempo = OSAllocatedUnfairLock(initialState: Duration.zero)

  var ahora: Duration { tiempo.withLock { $0 } }

  static let plazoQueNoVence = Duration.seconds(1_000)

  var deadlineClock: DeadlineClock {
    DeadlineClock(
      now: { [tiempo] in tiempo.withLock { $0 } },
      sleep: { [tiempo] duracion in
        if duracion >= Self.plazoQueNoVence {
          try await Task.sleep(for: .seconds(3_600))
          return
        }
        try Task.checkCancellation()
        tiempo.withLock { $0 += duracion }
        await Task.yield()
      }
    )
  }
}
