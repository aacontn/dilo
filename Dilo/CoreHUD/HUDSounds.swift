import AppKit

/// The sound sets a session can use. All of them are shippable: Click is CC0
/// and the rest are original synthesized assets — see
/// Resources/Sounds/LICENSE-SOUNDS.txt. (Pop, CC-BY-NC, was dropped for
/// Dilo 0.4.0 rather than shipped as a placeholder.)
///
/// rawValue is load-bearing twice over: it is the UserDefaults value existing
/// picks are stored under, and it prefixes the bundled asset names
/// (`<rawValue>Begin/End/Paste.wav`). Renaming a case breaks both.
enum DictationSoundSet: String, CaseIterable {
  /// El default desde 0.4.0. Marimba sintetizada en el repo con
  /// `scripts/generar-sonidos-marimba.py`: dos notas ascendentes al empezar,
  /// las mismas al revés al terminar, una sola al pegar. Activo propio.
  case marimba = "Marimba"
  /// Minimal 7ms UI click (freesound #370962, CC0).
  case click = "Click"
  /// Our own synthesized two-note pluck: rising fifth in, falling fifth
  /// out. Original asset, no license constraints.
  case chime = "Chime"
  /// Synthesized double-strike tock-tick with a singing tail, in the style
  /// of a reference app's v3 pair. Original asset.
  case synth3 = "Synth3"
  /// Synthesized single woody tock, tick-then-tock out, in the style of the
  /// reference app's v7 pair. Original asset.
  case synth7 = "Synth7"
  /// Synthesized rising thump-blip-body gesture in, falling body-thump out,
  /// in the style of the reference app's synth8 trio. Original asset.
  case synth8 = "Synth8"

  var isShippable: Bool { true }

  static var settingsCases: [Self] {
#if DEBUG
    allCases
#else
    allCases.filter { $0.isShippable }
#endif
  }
}

struct DictationSoundSettings: Equatable {
  static let volumeRange = 0.0...1.0

  let set: DictationSoundSet
  let isEnabled: Bool
  let volume: Double

  init(set: DictationSoundSet, isEnabled: Bool, volume: Double) {
    self.set = set
    self.isEnabled = isEnabled
    self.volume = Self.normalizedVolume(volume)
  }

  static func normalizedVolume(_ volume: Double) -> Double {
    min(max(volume, volumeRange.lowerBound), volumeRange.upperBound)
  }
}

/// Quién puede reproducir los tres sonidos de una sesión.
///
/// Existe para que el escenario pueda decir «acá suena Begin» en un test sin
/// abrir la tarjeta de sonido de nadie. La regla de este repo —nada que toque
/// el audio del Mac de Alfonso— vale también para la suite: sin esta costura,
/// afirmar que empezar un dictado suena obligaba a reproducirlo de verdad.
@MainActor
protocol ReproductorDeSonidos: AnyObject {
  func playBegin(using settings: DictationSoundSettings)
  func playEnd(using settings: DictationSoundSettings)
  func playPaste(using settings: DictationSoundSettings)
}

/// The sounds that bracket a Direct Dictation session: begin when listening
/// starts, end when the session closes, paste when text lands in the target.
///
/// A Drop Transcription borrows the same three rather than adding a set of its
/// own, because it is the same three moments: the shape takes the file, the
/// transcript is ready, the result is taken. One sound set means the app has
/// one voice, and the user's mute and volume already govern all of it.
///
/// Callers supply captured or live sound settings. Assets reload lazily when
/// the selected set changes.
@MainActor
final class HUDSounds: ReproductorDeSonidos {
  private var loadedSet: DictationSoundSet?
  private var begin: NSSound?
  private var end: NSSound?
  private var paste: NSSound?

  func playBegin(using settings: DictationSoundSettings) {
    play(\.begin, using: settings)
  }

  func playEnd(using settings: DictationSoundSettings) {
    play(\.end, using: settings)
  }

  func playPaste(using settings: DictationSoundSettings) {
    play(\.paste, using: settings)
  }

  func beginDuration(for set: DictationSoundSet) -> TimeInterval {
    loadIfNeeded(set)
    return begin?.duration ?? 0
  }

  func hasPreviewSounds(for set: DictationSoundSet) -> Bool {
    loadIfNeeded(set)
    return begin != nil && end != nil
  }

  func stopAll() {
    begin?.stop()
    end?.stop()
    paste?.stop()
  }

  private func play(
    _ sound: KeyPath<HUDSounds, NSSound?>,
    using settings: DictationSoundSettings
  ) {
    guard settings.isEnabled else { return }
    loadIfNeeded(settings.set)
    guard let sound = self[keyPath: sound] else { return }
    sound.stop()
    sound.volume = Float(settings.volume)
    sound.play()
  }

  private func loadIfNeeded(_ set: DictationSoundSet) {
    guard set != loadedSet else { return }
    stopAll()
    begin = NSSound.bundled("\(set.rawValue)Begin")
    end = NSSound.bundled("\(set.rawValue)End")
    paste = NSSound.bundled("\(set.rawValue)Paste")
    loadedSet = set
  }
}

private extension NSSound {
  static func bundled(_ name: String) -> NSSound? {
    guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
      return nil
    }
    return NSSound(contentsOf: url, byReference: true)
  }
}
