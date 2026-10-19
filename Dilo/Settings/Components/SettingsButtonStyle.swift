import SwiftUI

/// The capsule button used by Settings preview and action rows.
///
/// `compacto` es el botón de Droppy: once puntos y menos aire, para las
/// filas con dos o tres acciones al lado de un estado.
struct SettingsButtonStyle: ButtonStyle {
  var compacto = false

  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: compacto ? 11 : 12, weight: .semibold))
      // Un botón no se parte en dos líneas: «Restaurar los de fábrica…»
      // partido se leía como dos botones.
      .lineLimit(1)
      .fixedSize()
      .foregroundStyle(.white)
      .padding(.horizontal, compacto ? 10 : 12)
      .padding(.vertical, compacto ? 5 : 8)
      .background(.white.opacity(configuration.isPressed ? 0.18 : 0.1), in: Capsule())
      .overlay {
        Capsule().stroke(.white.opacity(0.12), lineWidth: 1)
      }
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .opacity(isEnabled ? 1 : 0.45)
  }
}
