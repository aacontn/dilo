import SwiftUI

/// El cromo de una ventana de Dilo: fondo tinta con su degradado, esquinas de
/// 16, borde de un pixel, acento mango y esquema oscuro.
///
/// Lo dibujaban Ajustes y Primeros pasos por separado. Dos superficies que
/// deberían ser la misma terminan con dos radios de esquina distintos a la
/// tercera vez que alguien toca una.
struct SuperficieDeDilo: ViewModifier {
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    content
      .background {
        ZStack {
          SettingsTheme.background
          LinearGradient(
            colors: [.white.opacity(0.035), .clear, .black.opacity(0.12)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(.white.opacity(contrast == .increased ? 0.24 : 0.1), lineWidth: 1)
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
