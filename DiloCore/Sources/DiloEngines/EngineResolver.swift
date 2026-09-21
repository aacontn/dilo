import Foundation

/// Qué motor va a correr de verdad, y por qué si no es el que la persona
/// eligió.
public struct EngineSelection: Sendable, Equatable {
  /// Lo que la persona eligió en Ajustes.
  public let elegido: SpeechEngineKind
  /// El que realmente va a dictar.
  public let efectivo: SpeechEngineKind
  /// Por qué son distintos, en una frase para mostrar. Nil cuando coinciden.
  public let aviso: String?

  public init(elegido: SpeechEngineKind, efectivo: SpeechEngineKind, aviso: String?) {
    self.elegido = elegido
    self.efectivo = efectivo
    self.aviso = aviso
  }

  public var cayoAApple: Bool { elegido != efectivo }
}

/// La regla de caída, pura y por eso testeable sin disco ni micrófono.
///
/// Apple no se puede caer: viene con el sistema. Parakeet sí, mientras su
/// modelo no esté en disco — y ahí dictar igual con Apple es mejor que no
/// dictar, siempre que se diga.
public enum EngineResolver {
  public static func resolver(
    elegido: SpeechEngineKind,
    parakeetDescargado: Bool
  ) -> EngineSelection {
    switch elegido {
    case .apple:
      return EngineSelection(elegido: .apple, efectivo: .apple, aviso: nil)
    case .parakeet where parakeetDescargado:
      return EngineSelection(elegido: .parakeet, efectivo: .parakeet, aviso: nil)
    case .parakeet:
      return EngineSelection(
        elegido: .parakeet,
        efectivo: .apple,
        aviso: "Parakeet todavía no está descargado. Dilo está dictando con Apple mientras tanto."
      )
    }
  }
}
