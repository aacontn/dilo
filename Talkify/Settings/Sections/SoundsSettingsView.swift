import SwiftUI

/// The Sounds section: session playback controls and the begin/end preview.
/// Preview disables itself while playing, waits out the Begin sound's real
/// duration, and a preference change stops playback (CONTEXT.md).
struct SoundsSettingsView: View {
  @Bindable var settings: AppSettings
  let sounds: HUDSounds

  @State private var isPreviewing = false
  @State private var previewTask: Task<Void, Never>?

  var body: some View {
    // Acá iba el interruptor "Lower other audio" de Talkify. No vuelve:
    // baja el volumen de salida del sistema y macOS muestra su HUD de volumen
    // encima cada vez. Dilo nunca toca el volumen maestro (spec §8.3). Si
    // algún día se silencia la música al dictar, se pausa la reproducción.
    SettingsCard(title: "Sonidos") {
      SettingsRow(
        title: "Sonar al dictar",
        description: "Un sonido al empezar, otro al terminar y otro cuando el texto aterriza."
      ) {
        Toggle("Sonar al dictar", isOn: $settings.dictationSoundsEnabled)
          .labelsHidden()
          .toggleStyle(.switch)
      }

      SettingsPickerRow(
        title: "Juego de sonidos",
        description: "Cuáles suenan al empezar y al terminar",
        options: DictationSoundSet.settingsCases,
        optionLabel: { $0.rawValue },
        selection: $settings.soundSet
      )
      .disabled(!settings.dictationSoundsEnabled)

      SettingsSliderRow(
        title: "Volumen",
        description: "Qué tan fuerte suena Dilo. No toca el volumen del sistema.",
        value: $settings.dictationSoundVolume,
        range: DictationSoundSettings.volumeRange,
        valueLabel: { "\(Int(($0 * 100).rounded()))%" }
      )
      .disabled(!settings.dictationSoundsEnabled)

      SettingsRow(
        title: "Escuchar",
        description: "Suena el par que elegiste"
      ) {
        Button {
          playPreview()
        } label: {
          Text(isPreviewing ? "Sonando…" : "Escuchar")
        }
        .buttonStyle(SettingsButtonStyle())
        .disabled(
          isPreviewing
            || !settings.dictationSoundsEnabled
            || !sounds.hasPreviewSounds(for: settings.soundSet)
        )
      }
    }
    .onChange(of: settings.soundSet) {
      cancelPreview()
    }
    .onChange(of: settings.dictationSoundsEnabled) {
      cancelPreview()
    }
    .onChange(of: settings.dictationSoundVolume) {
      cancelPreview()
    }
    .onDisappear {
      cancelPreview()
    }
  }

  private func playPreview() {
    let soundSettings = settings.sessionSettings.sounds
    let delay = max(sounds.beginDuration(for: soundSettings.set), 0) + 0.1
    isPreviewing = true
    sounds.playBegin(using: soundSettings)

    previewTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      sounds.playEnd(using: soundSettings)
      isPreviewing = false
      previewTask = nil
    }
  }

  private func cancelPreview() {
    previewTask?.cancel()
    previewTask = nil
    sounds.stopAll()
    isPreviewing = false
  }
}
