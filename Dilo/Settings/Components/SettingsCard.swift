import SwiftUI

/// A labeled group of related Settings rows on one rounded card
/// (CONTEXT.md: related rows share rounded cards with subtle separators).
///
/// Con jerarquía desde el 2026-10-19, al estilo del panel de la muesca: el
/// título se lee primero —12,5 semibold, casi blanco— y no como un rótulo
/// gris en mayúsculas de once puntos, con un ícono opcional y una línea
/// gris debajo que dice para qué es la tarjeta. Sobre el vidrio, la tarjeta
/// es una capa apenas más clara con un filo de luz arriba.
struct SettingsCard<Content: View>: View {
  let title: LocalizedStringKey
  var icono: String?
  var detalle: LocalizedStringKey?
  @ViewBuilder let content: Content

  @Environment(\.colorSchemeContrast) private var contrast

  init(
    title: LocalizedStringKey,
    icono: String? = nil,
    detalle: LocalizedStringKey? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.icono = icono
    self.detalle = detalle
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        if let icono {
          Image(systemName: icono)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(SettingsTheme.accent)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white.opacity(contrast == .increased ? 1 : 0.9))
          if let detalle {
            Text(detalle)
              .font(.system(size: 11))
              .foregroundStyle(.white.opacity(contrast == .increased ? 0.72 : 0.48))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 13)
      .padding(.bottom, 3)

      VStack(spacing: 0) {
        content
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 6)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(FondoDeTarjeta())
  }
}

/// La capa de una tarjeta sobre el vidrio: un poco más clara que el fondo,
/// con un filo de luz arriba que se apaga hacia abajo (el canto del panel de
/// la barra). La comparten las tarjetas, la vista previa y Actividad.
struct FondoDeTarjeta: View {
  var radio: CGFloat = 14

  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let forma = RoundedRectangle(cornerRadius: radio, style: .continuous)
    forma
      .fill(.white.opacity(contrast == .increased ? 0.09 : 0.055))
      .overlay {
        forma.strokeBorder(
          LinearGradient(
            colors: [
              .white.opacity(contrast == .increased ? 0.3 : 0.13),
              .white.opacity(contrast == .increased ? 0.2 : 0.06),
            ],
            startPoint: .top,
            endPoint: .bottom
          ),
          lineWidth: 1
        )
      }
  }
}
