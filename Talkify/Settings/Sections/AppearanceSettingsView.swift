import SwiftUI

/// The Appearance section: the live preview first, then the Voice visual
/// and Motion and layout groups (CONTEXT.md). Waveform, palette, and glow
/// center rows are conditional on the selected visual; hidden values stay
/// persisted.
struct AppearanceSettingsView: View {
  @Bindable var settings: AppSettings

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Which conditional rows the selected visual exposes; hidden values
  /// stay persisted (CONTEXT.md). Edge Glow + Draft takes the glow palette
  /// (beam, shaping caption, status ghost) but not a center or the concert
  /// waveform styles.
  static func showsWaveformOptions(for visual: HUDVoiceVisualStyle) -> Bool {
    visual == .waveform
  }

  static func showsGlowPalette(for visual: HUDVoiceVisualStyle) -> Bool {
    visual.usesEdgeGlow
  }

  static func showsGlowCenter(for visual: HUDVoiceVisualStyle) -> Bool {
    visual == .glow
  }

  /// Edge Glow + Draft uses a recent-word line instead of the global long
  /// draft behaviors. Reduce Motion restores the plain band, where the
  /// existing pick still applies.
  static func showsLongDraftBehavior(
    for visual: HUDVoiceVisualStyle,
    reduceMotion: Bool
  ) -> Bool {
    !(visual == .glowDraft && !reduceMotion)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsPreviewCard(settings: settings)

      SettingsCard(title: "Mientras hablas") {
        SettingsPickerRow(
          title: "Qué se ve",
          description: "Lo que dibuja la píldora mientras te escucha",
          options: HUDVoiceVisualStyle.allCases,
          optionLabel: { $0.title },
          selection: $settings.voiceVisual
        )

        if Self.showsWaveformOptions(for: settings.voiceVisual) {
          SettingsPickerRow(
            title: "Estilo de la onda",
            description: "La forma y el movimiento de la onda",
            options: HUDWaveformStyle.allCases,
            optionLabel: { $0.title },
            selection: $settings.waveformStyle
          )
        }

        if Self.showsGlowPalette(for: settings.voiceVisual) {
          SettingsPickerRow(
            title: "Paleta del halo",
            description: "Los colores del borde que respira",
            options: HUDGlowPalette.allCases,
            optionLabel: { $0.title },
            selection: $settings.glowPalette
          )
        }

        if Self.showsGlowCenter(for: settings.voiceVisual) {
          SettingsPickerRow(
            title: "Centro del halo",
            description: "Lo que va dentro del halo",
            options: HUDGlowCenterStyle.settingsCases,
            optionLabel: { $0.title },
            selection: $settings.glowCenter
          )
        }
      }

      SettingsCard(title: "Movimiento y tamaño") {
        SettingsSliderRow(
          title: "Tamaño de la píldora",
          description: "Cuánta pantalla se toma la píldora",
          value: $settings.hudScale,
          range: Double(
            HUDMetrics.minimumScale(for: settings.voiceVisual, reduceMotion: reduceMotion)
          )...Double(HUDMetrics.maximumScale),
          valueLabel: { "\(Int(($0 * 100).rounded()))%" }
        )

        SettingsRow(
          title: "Dejar libre la barra de menús",
          description: "En una pantalla sin notch, la píldora se cuelga debajo de la barra de menús para no tapar tus íconos. Apágalo sólo si prefieres que se ponga donde iría el notch."
        ) {
          Toggle("Dejar libre la barra de menús", isOn: $settings.hudClearsMenuBar)
            .labelsHidden()
            .toggleStyle(.switch)
        }

        SettingsPickerRow(
          title: "Cómo aparece",
          description: "La entrada de la píldora cuando arrancas a dictar",
          options: HUDRevealStyle.allCases,
          optionLabel: { $0.title },
          selection: $settings.revealStyle
        )

        if Self.showsLongDraftBehavior(
          for: settings.voiceVisual,
          reduceMotion: reduceMotion
        ) {
          SettingsPickerRow(
            title: "Si el texto se pasa de largo",
            description: "Qué hace la píldora con un dictado largo",
            options: HUDLongDraftStyle.allCases,
            optionLabel: { $0.title },
            selection: $settings.longDraftStyle
          )
        }
      }
    }
  }
}
