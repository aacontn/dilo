import SwiftUI

/// La corona de la píldora: la franja de arriba con la que Dilo se firma en
/// una pantalla sin notch.
///
/// En una pantalla con carcasa, esos puntos de arriba son hardware y no se
/// dibuja nada en ellos (la cámara está ahí). En una sin carcasa no hay nada
/// que esquivar y la banda quedaba negra y vacía, que es exactamente como se
/// ve el HUD de volumen del sistema en la misma franja. Así que acá va la
/// marca: glifo de micrófono en mango, una ceja mango que respira con la voz,
/// y la etiqueta de idioma cuando hay dos configurados.
///
/// El mango no es decoración: es lo que hace que la píldora no se lea nunca
/// como una notificación del sistema (spec §8, lección 2).
struct HUDPillCrownView: View {
  let content: DictationHUDContent
  let scale: CGFloat
  /// La etiqueta de idioma, ya medida por el shell para que el texto de abajo
  /// siga centrado. Nil cuando hay un solo idioma configurado.
  var languageTag: String?
  var languageTagWidth: CGFloat = 0

  /// El color de la marca, o el ámbar quieto del micrófono muerto: el
  /// silencio y un micrófono caído tienen que verse distinto (CONTEXT.md), y
  /// la corona es lo primero que se mira.
  private var accent: Color {
    content.isAudioAlive ? DiloBrand.mango : HUDVisualTokens.deadMicAmber
  }

  /// La ceja respira con la voz sin llegar nunca a apagarse: en silencio
  /// sigue visible, porque es la firma, no un medidor.
  private var browOpacity: Double {
    content.isAudioAlive ? 0.45 + 0.55 * min(content.audioLevel, 1) : 0.5
  }

  var body: some View {
    HStack(spacing: 7 * scale) {
      Image(systemName: content.isAudioAlive ? "mic.fill" : "mic.slash.fill")
        .font(.system(size: 9 * scale, weight: .bold))
        .foregroundStyle(accent)
        .contentTransition(.symbolEffect(.replace))
      brow
      if let languageTag {
        Text(languageTag)
          .font(.system(size: 9 * scale, weight: .semibold, design: .rounded))
          .tracking(0.5)
          .foregroundStyle(accent.opacity(0.85))
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(width: languageTagWidth * scale)
      }
    }
    .padding(.horizontal, 16 * scale)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(.linear(duration: 0.08), value: content.audioLevel)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  /// La ceja: un hilo mango que se desvanece hacia el final, para que la
  /// franja tenga dirección y no se lea como una barra de progreso detenida.
  private var brow: some View {
    Capsule(style: .continuous)
      .fill(
        LinearGradient(
          colors: [accent, accent.opacity(0.18)],
          startPoint: .leading,
          endPoint: .trailing
        )
      )
      .frame(height: 2.5 * scale)
      .opacity(browOpacity)
      .frame(maxWidth: .infinity)
  }
}

#Preview("Píldora · sin notch") {
  HUDShellPreviewHarness(
    screen: HUDPreviewScreen.external,
    text: "La píldora vive debajo de la barra de menús",
    visual: .waveform
  )
}

#Preview("Píldora · micrófono muerto") {
  HUDShellPreviewHarness(
    screen: HUDPreviewScreen.external,
    visual: .waveform,
    micAlive: false
  )
}
