import SwiftUI

/// Lo que se ve cuando nadie está dictando: la presencia discreta y
/// permanente del contrato del notch.
///
/// **No anima.** Ni `TimelineView`, ni shader, ni un pulso que respire: el
/// reposo tiene que costar lo que cuesta una ventana quieta (spec §3, ~0 % de
/// CPU). Un punto que late es lo primero que se nota y lo último que se deja
/// de pagar.
///
/// Con carcasa real no dibuja nada: ahí el notch ya está y la marca caería
/// detrás de la cámara. En una pantalla sin carcasa la marca es lo único que
/// distingue la silueta de una franja negra cualquiera.
struct HUDMarcaDeReposo: View {
  /// False contra hardware real, donde el recorte físico es la presencia.
  let dibujaMarca: Bool
  /// El contexto que el hover reveló: el modo activo o lo último dictado.
  /// Nil mientras el puntero está en otra parte.
  var contexto: String?
  var scale: CGFloat = 1

  var body: some View {
    VStack(spacing: 4 * scale) {
      if dibujaMarca {
        marca
      }
      if let contexto {
        Text(contexto)
          .font(.system(size: 10 * scale, weight: .medium, design: .rounded))
          .foregroundStyle(.white.opacity(0.78))
          .lineLimit(1)
          .truncationMode(.tail)
          .padding(.horizontal, 12 * scale)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement()
    .accessibilityLabel(Text("Dilo"))
    .accessibilityValue(Text(contexto ?? String(localized: "En reposo")))
  }

  /// Una raya mango corta y quieta. No es un micrófono: un glifo de
  /// micrófono permanente dice «te estoy escuchando», que es exactamente lo
  /// que el reposo **no** hace.
  private var marca: some View {
    Capsule(style: .continuous)
      .fill(DiloBrand.mango.opacity(0.85))
      .frame(width: 18 * scale, height: 3 * scale)
  }
}

#Preview("Reposo · notch simulado") {
  HUDShellPreviewHarness(screen: HUDPreviewScreen.externalNotchSimulado, enReposo: true)
}

#Preview("Reposo · con contexto") {
  HUDShellPreviewHarness(
    screen: HUDPreviewScreen.externalNotchSimulado,
    enReposo: true,
    contexto: "Correo"
  )
}
