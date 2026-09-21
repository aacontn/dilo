import SwiftUI

/// Tokens shared across the HUD's voice visuals.
enum HUDVisualTokens {
  /// The dead-microphone state's motionless amber (CONTEXT.md: a dead
  /// microphone must look different from silence). The waveform-family
  /// visuals keep their own dimmer orange variants, tuned per visual
  /// during feel tests.
  static let deadMicAmber = Color(red: 1.0, green: 0.6, blue: 0.16)

  /// La onda del micrófono, en los colores de Dilo: menta en el cuerpo y
  /// mango en los extremos.
  ///
  /// Era plata metálica —blanco enfriándose a gris azulado—, que es
  /// exactamente la paleta de los HUD del sistema. Con notch o sin él, una
  /// onda menta y mango no se confunde con ninguno (spec §8, lección 2).
  /// Vertical: el cuerpo de cada barra en menta, las puntas en mango.
  static let wave = LinearGradient(
    colors: [
      DiloBrand.mango.opacity(0.85),
      DiloBrand.menta,
      DiloBrand.mango.opacity(0.85),
    ],
    startPoint: .top,
    endPoint: .bottom
  )

  /// La misma onda para los trazos que corren a lo largo (Chart Line, Siri
  /// Wave): el degradado va de punta a punta en vez de de arriba abajo.
  /// Compartido para que todos los estilos se lean como un solo tratamiento.
  static let chartLineSilver = LinearGradient(
    colors: [
      DiloBrand.mango.opacity(0.85),
      DiloBrand.menta,
      DiloBrand.menta.opacity(0.92),
      DiloBrand.menta,
      DiloBrand.mango.opacity(0.85),
    ],
    startPoint: .leading,
    endPoint: .trailing
  )
}
