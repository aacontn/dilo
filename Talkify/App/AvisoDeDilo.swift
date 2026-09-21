import SwiftUI

/// El recuadro de una frase con un ícono al lado: lo que Dilo te dice sin
/// interrumpirte. Mango cuando avisa algo, menta cuando confirma.
///
/// Estaba escrito dentro de la sección Motor y el onboarding lo necesitaba
/// igual. Dos avisos con dos radios de esquina distintos es exactamente lo que
/// este archivo evita.
struct AvisoDeDilo: View {
  let icono: String
  let color: Color
  let texto: String

  init(icono: String = "info.circle.fill", color: Color = SettingsTheme.accent, texto: String) {
    self.icono = icono
    self.color = color
    self.texto = texto
  }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: icono)
        .foregroundStyle(color)
      Text(texto)
        .font(.caption)
        .foregroundStyle(.white.opacity(0.62))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(14)
    .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
  }
}
