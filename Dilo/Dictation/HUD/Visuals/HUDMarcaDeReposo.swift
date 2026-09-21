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
  /// El nombre del modo activo, o nil —que es lo de fábrica—. El único dato
  /// que la muesca dice sin que nadie se acerque, y sólo si se pidió
  /// (`AppSettings.hudModoEnReposo`).
  var modo: String?
  var scale: CGFloat = 1

  var body: some View {
    VStack(spacing: 2 * scale) {
      // Uno solo, y en este orden: lo que el hover reveló manda sobre el modo,
      // y el punto es lo que queda cuando no hay nada que decir. Dos datos a
      // la vez no caben en una silueta del alto de la barra, y apilarlos
      // volvería a hacer de la muesca una etiqueta.
      if let contexto {
        Text(contexto)
          .font(.system(size: 10 * scale, weight: .medium, design: .rounded))
          .foregroundStyle(.white.opacity(0.78))
          .lineLimit(1)
          .truncationMode(.tail)
          .padding(.horizontal, 12 * scale)
      } else if let modo, !modo.isEmpty {
        Text(modo)
          .font(.system(size: 9 * scale, weight: .medium, design: .rounded))
          .foregroundStyle(.white.opacity(0.45))
          .lineLimit(1)
          .truncationMode(.tail)
          .padding(.horizontal, 10 * scale)
      } else if dibujaMarca {
        punto
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    .padding(.bottom, 5 * scale)
    .accessibilityElement()
    .accessibilityLabel(Text("Dilo"))
    .accessibilityValue(Text(contexto ?? modo ?? String(localized: "En reposo")))
  }

  /// Un punto mango de tres puntos, abajo y al centro. Lo único que la muesca
  /// dice en reposo.
  ///
  /// Era una raya de 18×3 centrada en la silueta, y con la silueta del alto de
  /// la barra ocupaba media muesca: se leía como una etiqueta, no como una
  /// luz de encendido. Tampoco es un micrófono — un glifo de micrófono
  /// permanente dice «te estoy escuchando», que es exactamente lo que el
  /// reposo **no** hace.
  private var punto: some View {
    Circle()
      .fill(DiloBrand.mango.opacity(0.9))
      .frame(width: 3 * scale, height: 3 * scale)
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
