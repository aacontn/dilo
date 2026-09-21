import AppKit
import Testing
@testable import Dilo

@MainActor
struct SettingsWindowTests {
  @Test func controllerBuildsAFixedBorderlessWindow() throws {
    let settings = AppSettings.previewStore()
    let controller = SettingsWindowController(
      settings: settings,
      sounds: HUDSounds(),
      runtimeState: SettingsRuntimeState(),
      usageTracker: UsageTracker(store: UsageStore(
        fileURL: FileManager.default.temporaryDirectory
          .appending(path: "TalkifySettingsWindowTests-" + UUID().uuidString + ".json")
      )),
      updater: SparkleUpdaterService(),
      launchAtLogin: LaunchAtLoginService()
    )
    let window = try #require(controller.window)
    #expect(window.title == "Ajustes de Dilo")
    #expect(window.styleMask.contains(.borderless))
    #expect(!window.styleMask.contains(.resizable))
    #expect(window.level == .normal)
    #expect(!window.isOpaque)
    #expect(!window.isReleasedWhenClosed)
    #expect(window.contentRect(forFrameRect: window.frame).size == NSSize(width: 860, height: 600))
    #expect(window.minSize == window.maxSize)
  }

  @Test func settingsSectionsStayFocusedOnImplementedFeatures() {
    let expected: [SettingsSection] = [
      .general, .appearance, .sounds, .motor, .dictation, .modos, .palabras,
      .historial, .promptShaping, .dropTranscription, .readAloud, .language,
      .shortcuts, .updates, .novedades, .insights, .about,
    ]
    #expect(SettingsSection.allCases == expected)
    // La navegación muestra lo mismo menos lo que el anfitrión esconde: el
    // sandbox de App Store se queda sin Sparkle ni relectura del foco.
    let navegables = SettingsSectionGroup.allCases.flatMap(\.sections)
    let principales: [SettingsSection] = [
      .dictation, .modos, .palabras, .historial, .dropTranscription,
      .motor, .shortcuts, .appearance, .general, .novedades, .about,
    ]
    #expect(navegables == principales.filter(\.isAvailable))
    #expect(Set(navegables).count == navegables.count)
    #expect(!navegables.contains(.readAloud)) // Se accede desde General, respetando capacidades.
  }

  @Test func deletingThePickedShapingPromptFallsBackToTheFirst() {
    let prompts = ShapingPrompt.defaults
    let picked = prompts[1].id
    #expect(
      PromptShapingSettingsView.resolvedSelection(picked: picked, in: prompts) == picked
    )
    let remaining = prompts.filter { $0.id != picked }
    #expect(
      PromptShapingSettingsView.resolvedSelection(picked: picked, in: remaining)
        == remaining[0].id
    )
    #expect(PromptShapingSettingsView.resolvedSelection(picked: picked, in: []) == "")
  }

  @Test func appearanceOptionsFollowTheSelectedVisual() {
    #expect(AppearanceSettingsView.showsWaveformOptions(for: .waveform))
    #expect(!AppearanceSettingsView.showsWaveformOptions(for: .glow))
    #expect(!AppearanceSettingsView.showsWaveformOptions(for: .compact))
    #expect(!AppearanceSettingsView.showsWaveformOptions(for: .glowDraft))
    #expect(AppearanceSettingsView.showsGlowPalette(for: .glow))
    #expect(AppearanceSettingsView.showsGlowPalette(for: .glowDraft))
    #expect(!AppearanceSettingsView.showsGlowPalette(for: .waveform))
    #expect(!AppearanceSettingsView.showsGlowPalette(for: .compact))
    #expect(AppearanceSettingsView.showsGlowCenter(for: .glow))
    #expect(!AppearanceSettingsView.showsGlowCenter(for: .glowDraft))
    #expect(!AppearanceSettingsView.showsGlowCenter(for: .waveform))
    #expect(!AppearanceSettingsView.showsLongDraftBehavior(
      for: .glowDraft, reduceMotion: false))
    #expect(AppearanceSettingsView.showsLongDraftBehavior(
      for: .glowDraft, reduceMotion: true))
    #expect(AppearanceSettingsView.showsLongDraftBehavior(
      for: .compact, reduceMotion: false))
  }

  @Test func releaseMetadataExcludesUnlicensedOptions() {
    #expect(DictationSoundSet.synth8.isShippable)
    #expect(DictationSoundSet.allCases.allSatisfy { $0.isShippable })
    #expect(HUDGlowCenterStyle.particles.isShippable)
    #expect(HUDGlowCenterStyle.allCases.allSatisfy { $0.isShippable })
  }
}
