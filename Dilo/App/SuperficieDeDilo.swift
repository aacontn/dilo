import SwiftUI

/// El cromo de una ventana de Dilo: el fondo, esquinas de 16, borde de un
/// pixel, el acento de la paleta y esquema oscuro.
///
/// Lo dibujaban Ajustes y Primeros pasos por separado. Dos superficies que
/// deberían ser la misma terminan con dos radios de esquina distintos a la
/// tercera vez que alguien toca una.
///
/// **Desde el 2026-10-19 el fondo es el vidrio ahumado de la muesca**: la
/// receta del panel del hover (`PanelDeVidrio.tinte` y `negroEncima`), que
/// queda en un carbón parejo sobre cualquier escritorio. Alfonso pidió una
/// ventana «más bonita» y que se viera como el resto de Dilo. Con «Reducir
/// transparencia», el fondo sólido de la paleta de antes; en los PNG, el gris
/// medido del vidrio (`MaterialDeAjustes.imitacion`).
struct SuperficieDeDilo: ViewModifier {
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceTransparency) private var reducirTransparencia
  @Environment(\.materialDeAjustes) private var material

  static let radio: CGFloat = 16

  func body(content: Content) -> some View {
    let forma = RoundedRectangle(cornerRadius: Self.radio, style: .continuous)
    content
      .background {
        ZStack {
          switch reducirTransparencia ? .solido : material {
          case .vidrio:
            Color.clear
              .glassEffect(.regular.tint(.black.opacity(PanelDeVidrio.tinte)), in: forma)
            Color.black.opacity(PanelDeVidrio.negroEncima)
          case .imitacion:
            Color(white: PanelDeVidrio.grisDeLaLamina)
          case .solido:
            SettingsTheme.background
          }
          LinearGradient(
            colors: [.white.opacity(0.035), .clear, .black.opacity(0.12)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        }
      }
      .clipShape(forma)
      .overlay {
        forma.strokeBorder(
          LinearGradient(
            colors: [
              .white.opacity(contrast == .increased ? 0.32 : 0.16),
              .white.opacity(contrast == .increased ? 0.24 : 0.07),
            ],
            startPoint: .top,
            endPoint: .bottom
          ),
          lineWidth: 1
        )
      }
      .tint(SettingsTheme.accent)
      .preferredColorScheme(.dark)
  }
}

extension View {
  func superficieDeDilo() -> some View {
    modifier(SuperficieDeDilo())
  }
}
