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

  /// Las opciones del picker de pantalla: la automática —el string vacío, que
  /// es lo que se guarda— y el nombre de cada pantalla conectada.
  ///
  /// La elección guardada se agrega aunque su pantalla no esté: un picker que
  /// no contiene su selección la pisa con la primera opción, y desenchufar un
  /// monitor para trabajar en el sofá borraría la preferencia en silencio.
  static func pantallas(conectadas: [String], elegida: String) -> [String] {
    var opciones = [""]
    for nombre in conectadas where !nombre.isEmpty && !opciones.contains(nombre) {
      opciones.append(nombre)
    }
    if !elegida.isEmpty && !opciones.contains(elegida) { opciones.append(elegida) }
    return opciones
  }

  private var pantallas: [String] {
    Self.pantallas(
      conectadas: NSScreen.screens.map(\.localizedName),
      elegida: settings.hudPantalla
    )
  }

  /// Cero no es «medio segundo redondeado a cero»: es otra cosa, y se dice
  /// con palabras.
  static func etiquetaDelRetardo(_ segundos: Double) -> String {
    guard segundos >= 0.05 else { return String(localized: "Al instante") }
    return "\(segundos.formatted(.number.precision(.fractionLength(1)))) s"
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
          title: "Tamaño del notch",
          description: "Cuánta pantalla se toma la forma abierta",
          value: $settings.hudScale,
          range: Double(
            HUDMetrics.minimumScale(for: settings.voiceVisual, reduceMotion: reduceMotion)
          )...Double(HUDMetrics.maximumScale),
          valueLabel: { "\(Int(($0 * 100).rounded()))%" }
        )

        SettingsPickerRow(
          title: "En pantallas sin notch",
          description: "El notch simulado se pega al borde de arriba, sobre el centro vacío de la barra, y se ve como el de un MacBook: es lo que trae Dilo. La píldora cuelga debajo de la barra de menús, separada de ella.",
          options: HUDEstiloSinNotch.allCases,
          optionLabel: { $0.title },
          selection: $settings.hudEstiloSinNotch,
          controlWidth: 190
        )

        SettingsPickerRow(
          title: "En qué pantalla",
          description: "Automática la pone donde está el cursor, o en la principal. Elegir una la deja siempre ahí; si desconectas esa pantalla, vuelve a la automática.",
          options: pantallas,
          optionLabel: { $0.isEmpty ? String(localized: "Automática") : $0 },
          selection: $settings.hudPantalla,
          controlWidth: 190
        )

        SettingsSliderRow(
          title: "Cuánto esperar con el mouse encima",
          description: "Antes de que la muesca se abra a mostrar contexto. Pasar el mouse nunca empieza a dictar.",
          value: $settings.hudRetardoDeHover,
          range: 0...1.5,
          step: 0.1,
          valueLabel: Self.etiquetaDelRetardo
        )

        SettingsRow(
          title: "Decir el modo en reposo",
          description: "En reposo la muesca no dice nada. Con esto muestra el nombre del modo activo, en chico y en gris."
        ) {
          Toggle("", isOn: $settings.hudModoEnReposo)
            .labelsHidden()
            .toggleStyle(.switch)
        }

        SettingsPickerRow(
          title: "Cómo aparece",
          description: "Cómo entra el contenido cuando el notch se abre a dictar",
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
            description: "Qué hace el notch con un dictado largo",
            options: HUDLongDraftStyle.allCases,
            optionLabel: { $0.title },
            selection: $settings.longDraftStyle
          )
        }
      }
    }
  }
}
