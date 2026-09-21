import SwiftUI

/// Compiles the HUD's Metal shaders before a session needs them.
///
/// SwiftUI compiles a shader the first time it is drawn, and that lands on the
/// first frames of a dictation — exactly when the HUD is descending and the
/// visual is ramping in, so the whole reveal stutters. Doing it at launch moves
/// the cost somewhere nobody is looking.
///
/// The arguments are placeholders: what is compiled is the function, and the
/// values it happens to be handed here never reach a screen.
///
/// `WaveformSheen.metal` ya no está en esta lista: la onda de Dilo dejó de
/// pasar por él. Su fringing cromático estaba afinado para una onda blanca y
/// sobre menta la volvía un arcoíris — el color de la marca desaparecía, que
/// es justo lo que la onda tiene que decir. El `.metal` se conserva por si
/// vuelve con otra afinación; calentar un shader que nadie dibuja no.
enum HUDShaderWarmUp {
  static let shaders: [(Shader, Shader.UsageType)] = [
    (
      ShaderLibrary.edgeGlow(.float2(CGPoint.zero), .float2(CGSize(width: 1, height: 1)), .float(0), .float(0)),
      .colorEffect
    ),
    (
      ShaderLibrary.shapingSheen(
        .float2(CGSize(width: 1, height: 1)),
        .float(0),
        .float(0),
        .color(.white),
        .color(.white),
        .color(.white)
      ),
      .layerEffect
    ),
    (
      ShaderLibrary.ripple(
        .float2(CGPoint.zero), .float(0), .float(3), .float(6), .float(6), .float(1200)
      ),
      .layerEffect
    ),
  ]

  /// Exposed so a test can prove every name and argument list still matches
  /// the Metal source.
  static var shadersForTesting: [(Shader, Shader.UsageType)] { shaders }

  /// Fire and forget. A failure here costs nothing but the stutter this exists
  /// to avoid, so it is never surfaced.
  @MainActor
  static func start() {
    // The particle cloud is its own Metal pipeline rather than a SwiftUI
    // shader, and its two compute kernels compile the same way.
    ParticleRenderer.warmUp()

    Task.detached(priority: .utility) {
      for (shader, usage) in shaders {
        try? await shader.compile(as: usage)
      }
    }
  }
}
