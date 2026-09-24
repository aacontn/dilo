import SwiftUI

/// The chrome the Settings previews share: a titled card holding a dark
/// display with a simulated menu bar strip, so whatever HUD surface is placed
/// in it reads as hanging from the notch at the top of a screen rather than
/// floating in a box.
///
/// Both previews use the fixed notched reference geometry (CONTEXT.md), which
/// is why the stage can own the strip's dimensions: they are the same picture
/// with a different shape inside it.
struct SettingsPreviewStage<HUD: View>: View {
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let title: LocalizedStringKey
  let subtitle: LocalizedStringKey
  /// A qué escala se dibuja el HUD. Las formas abiertas se muestran a menos
  /// de la mitad para que quepan; la muesca en reposo de «Datos en la
  /// muesca» va a tamaño real, porque lo que se viene a mirar son cifras de
  /// diez puntos.
  var escala: CGFloat = 0.48
  /// El alto de la pantalla simulada.
  var altoDeLaPantalla: CGFloat = 118
  @ViewBuilder let hud: HUD

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.system(size: 14, weight: .semibold))
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.white.opacity(contrast == .increased ? 0.72 : 0.48))
        }
        Spacer()
        Circle()
          .fill(SettingsTheme.accent)
          .frame(width: 7, height: 7)
          .shadow(color: SettingsTheme.accent, radius: reduceMotion ? 0 : 7)
      }

      ZStack(alignment: .top) {
        LinearGradient(
          colors: [Color(red: 0.055, green: 0.065, blue: 0.09), .black],
          startPoint: .top,
          endPoint: .bottom
        )

        simulatedMenuBar

        hud
          .scaleEffect(escala, anchor: .top)
          .frame(
            width: min(300 / 0.48 * escala, 520),
            height: altoDeLaPantalla - 13,
            alignment: .top
          )
          .clipped()
      }
      .frame(height: altoDeLaPantalla)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(.white.opacity(contrast == .increased ? 0.2 : 0.07), lineWidth: 1)
      }
    }
    .padding(16)
    .background(SettingsTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(.white.opacity(contrast == .increased ? 0.22 : 0.1), lineWidth: 1)
    }
  }

  /// La letra de la barra simulada: la de siempre a la escala de siempre, y
  /// la de una barra de verdad cuando el HUD va a tamaño real.
  private var letraDeLaBarra: CGFloat {
    max(8.5, 12.5 * escala)
  }

  /// A simulated menu bar strip so the shape reads as a notch at the top
  /// of a display: matches the housing strip's scaled height, with the
  /// Dilo ghost among the status items. The shell's black housing
  /// draws over its center.
  private var simulatedMenuBar: some View {
    HStack(spacing: 0) {
      HStack(spacing: 7) {
        Image(systemName: "apple.logo")
          .font(.system(size: letraDeLaBarra - 0.5))
        Text(verbatim: "Finder")
          .font(.system(size: letraDeLaBarra, weight: .semibold))
      }
      Spacer()
      HStack(spacing: 8) {
        Image("MenuBarIcon")
          .renderingMode(.template)
          .resizable()
          .scaledToFit()
          .frame(height: letraDeLaBarra)
        Image(systemName: "wifi")
          .font(.system(size: letraDeLaBarra - 0.5))
        Text(verbatim: "11:41")
          .font(.system(size: letraDeLaBarra, weight: .medium))
      }
    }
    .foregroundStyle(.white.opacity(0.55))
    .padding(.horizontal, 10)
    .frame(height: 32 * escala)
    .background(.white.opacity(0.05))
  }
}
