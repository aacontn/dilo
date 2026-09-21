import Charts
import SwiftUI

/// The live waveform strip: levels reduced on the audio side (vDSP in
/// MicrophoneInput) drive whichever style is selected. Newest level on the
/// right. Replaces the draft text while listening.
struct HUDWaveformView: View {
  static let barCount = 56

  let settings: DictationSessionSettings
  let content: DictationHUDContent

  /// Chart Line y Siri Wave corren de borde a borde; los estilos de barras
  /// guardan margen lateral.
  private var runsEdgeToEdge: Bool {
    settings.waveformStyle == .chartLine || settings.waveformStyle == .siriWave
  }

  var body: some View {
    styledWave
      .animation(.linear(duration: 0.05), value: content.levelHistory)
      .padding(.horizontal, runsEdgeToEdge ? 0 : 28)
      .padding(.vertical, 6)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  @ViewBuilder
  private var styledWave: some View {
    Group {
      switch settings.waveformStyle {
      case .article:
        AudioWaveShape(samples: content.levelHistory, spacing: 2, rounded: false, perceptual: false)
          .fill(silver)
      case .silver:
        AudioWaveShape(samples: content.levelHistory, spacing: 3, rounded: true, perceptual: true)
          .fill(silver)
      case .capsules:
        capsules
      case .chartLine:
        ChartLineWaveView(content: content)
      case .chartArea:
        areaChart
      case .dots:
        DotWaveShape(samples: content.levelHistory, dotRadius: 1.6)
          .fill(silver)
      case .curve:
        CurveWaveShape(samples: content.levelHistory)
          .fill(silver)
      case .filled:
        FilledWaveShape(samples: content.levelHistory)
          .fill(silver)
      case .siriWave:
        HUDSiriWaveView(content: content)
      }
    }
  }

  /// Un solo lenguaje de color para todos los estilos: la onda de Dilo,
  /// menta con las puntas mango (`HUDVisualTokens.wave`). Ámbar quieto cuando
  /// el micrófono se muere (CONTEXT.md).
  private var silver: AnyShapeStyle {
    content.isAudioAlive
      ? AnyShapeStyle(HUDVisualTokens.wave)
      : AnyShapeStyle(HUDVisualTokens.deadMicAmber.opacity(0.55))
  }

  /// AudioWaveform's capsule mode: dampened heights, width-derived bars.
  private var capsules: some View {
    GeometryReader { proxy in
      let values = content.levelHistory
      let step = proxy.size.width / CGFloat(values.count)
      let barWidth = max(step * 0.55, 1)
      HStack(alignment: .center, spacing: step - barWidth) {
        ForEach(Array(values.enumerated()), id: \.offset) { _, value in
          Capsule()
            .fill(silver)
            .frame(
              width: barWidth,
              height: max(barWidth, CGFloat(value) * 0.75 * proxy.size.height)
            )
            .frame(maxHeight: .infinity, alignment: .center)
        }
      }
    }
  }

  /// AudioWaveform's area mode, straight from Swift Charts.
  private var areaChart: some View {
    Chart(Array(content.levelHistory.enumerated()), id: \.offset) { index, value in
      AreaMark(x: .value("t", index), y: .value("level", value))
        .interpolationMethod(.catmullRom)
        .foregroundStyle(silver)
    }
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartYScale(domain: 0...1)
  }
}

#Preview("Article") {
  HUDShellPreviewHarness(visual: .waveform, waveformStyle: .article)
}

#Preview("Silver") {
  HUDShellPreviewHarness(visual: .waveform, waveformStyle: .silver)
}

#Preview("Chart Area") {
  HUDShellPreviewHarness(visual: .waveform, waveformStyle: .chartArea)
}

#Preview("Dots") {
  HUDShellPreviewHarness(visual: .waveform, waveformStyle: .dots)
}

#Preview("Curve") {
  HUDShellPreviewHarness(visual: .waveform, waveformStyle: .curve)
}

#Preview("Filled") {
  HUDShellPreviewHarness(visual: .waveform, waveformStyle: .filled)
}
