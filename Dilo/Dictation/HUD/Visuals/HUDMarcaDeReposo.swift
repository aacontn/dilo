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
  /// Si con ese contexto hay algo que copiar. Lo que convierte el panel del
  /// hover en una acción: desde el 2026-09-22 «copiar el último dictado» vive
  /// acá y en el menú de la barra, y no en un estado Resultado de 400×50.
  var puedeCopiar = false
  /// El nombre del modo activo, o nil —que es lo de fábrica—. El único dato
  /// que la muesca dice sin que nadie se acerque, y sólo si se pidió
  /// (`AppSettings.hudModoEnReposo`).
  var modo: String?
  var scale: CGFloat = 1
  /// El alto exacto de la silueta que esta marca llena: el de la muesca en
  /// reposo, o el del panel que abre el hover.
  ///
  /// Llega de afuera y no se deduce acá porque quien lo sabe es la forma
  /// (`HUDNotchGeometry.reposoSize`), y un segundo lugar que lo calcule es un
  /// lugar del que se va a desviar.
  let alto: CGFloat
  /// Los datos de cada costado (`DatosDeLaMuesca`), y cuánto mide cada
  /// costado. Con el panel del hover abierto no se dibujan: ahí manda el
  /// contexto, a lo ancho.
  var izquierdo: LadoDeLaMuesca?
  var derecho: LadoDeLaMuesca?
  var anchoDeLado: CGFloat = 0

  var body: some View {
    HStack(spacing: 0) {
      if contexto == nil, anchoDeLado > 0 {
        costado(izquierdo)
      }
      centro
      if contexto == nil, anchoDeLado > 0 {
        costado(derecho)
      }
    }
    .frame(height: alto)
    .accessibilityElement()
    .accessibilityLabel(Text("Dilo"))
    .accessibilityValue(Text(paraVoiceOver))
  }

  private var paraVoiceOver: String {
    let base = contexto ?? modo ?? String(localized: "En reposo")
    let datos = [izquierdo, derecho].compactMap { $0 }.map { "\($0.etiqueta) \($0.valor)" }
    return ([base] + datos).joined(separator: ", ")
  }

  /// Un dato a un costado: la etiqueta apagada y el valor claro, centrados en
  /// el alto de la barra. Cifras de ancho fijo para que el número no baile
  /// cada vez que cambia, y el valor se entibia cerca del límite: mango desde
  /// el 75 %, rojo desde el 90 %.
  @ViewBuilder
  private func costado(_ lado: LadoDeLaMuesca?) -> some View {
    HStack(spacing: 3 * scale) {
      if let lado {
        Text(lado.etiqueta)
          .font(.system(size: 9 * scale, weight: .medium, design: .rounded))
          .foregroundStyle(.white.opacity(0.5))
        Text(lado.valor)
          .font(.system(size: 10.5 * scale, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(Self.color(para: lado.nivel))
      }
    }
    .lineLimit(1)
    .frame(width: anchoDeLado, height: alto)
  }

  static func color(para nivel: Double?) -> Color {
    guard let nivel else { return .white.opacity(0.85) }
    if nivel >= 90 { return Color(red: 1, green: 0.38, blue: 0.32) }
    if nivel >= 75 { return DiloBrand.mango }
    return .white.opacity(0.85)
  }

  /// Lo de siempre: el contexto del hover, el modo, o el punto.
  private var centro: some View {
    VStack(spacing: 2 * scale) {
      // Uno solo, y en este orden: lo que el hover reveló manda sobre el modo,
      // y el punto es lo que queda cuando no hay nada que decir. Dos datos a
      // la vez no caben en una silueta del alto de la barra, y apilarlos
      // volvería a hacer de la muesca una etiqueta.
      if let contexto {
        HStack(spacing: 8 * scale) {
          Text(contexto)
            .font(.system(size: 10 * scale, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.78))
            .lineLimit(1)
            .truncationMode(.tail)
          if puedeCopiar {
            Text("Copiar")
              .font(.system(size: 10 * scale, weight: .semibold, design: .rounded))
              .foregroundStyle(DiloBrand.mango)
              .lineLimit(1)
          }
        }
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
    .padding(.bottom, 5 * scale)
    .frame(maxWidth: .infinity, alignment: .bottom)
    // Un alto exacto, y **nunca** `maxHeight: .infinity`. Con infinito la
    // marca se quedaba con el alto entero de la ventana anfitriona —que está
    // dimensionada para el estado más alto— y el fondo negro de `HUDSurface`
    // se estiraba detrás de ella: en un 1080p externo la muesca de 160×24
    // salía como un bloque de 160×196 colgando de la barra, con el punto
    // mango abajo del todo. El aire de abajo va adentro del alto, no sumado
    // encima, o la silueta mide cinco puntos de más.
    .frame(height: alto, alignment: .bottom)
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
