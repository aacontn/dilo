import DiloEngines
import Foundation
import os

/// El `ParakeetEngine` del dictado, para que la pasada final de una reunión
/// use el mismo modelo cargado (spec, «Transcripción»: los 469 MB no se cargan
/// dos veces). `DiloSpeechStack` lo anota al armar el motor doble; si por
/// alguna razón no lo hizo, se arma uno propio con el mismo cargador.
enum ParakeetCompartido {
  private static let guardado = OSAllocatedUnfairLock<ParakeetEngine?>(initialState: nil)

  static func anotar(_ motor: ParakeetEngine) {
    guardado.withLock { $0 = motor }
  }

  static var motor: ParakeetEngine {
    guardado.withLock { guardado in
      if let guardado { return guardado }
      let nuevo = ParakeetEngine(captura: MicrophoneCapture())
      guardado = nuevo
      return nuevo
    }
  }
}
