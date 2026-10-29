import AppKit
import AVFAudio
import Observation

/// The Apple synthesis voices Read Aloud offers: enhanced and premium
/// qualities, plus the user's Personal Voice once authorized. Default-quality
/// voices are excluded — they undersell the feature. Siri voices never appear:
/// Apple does not expose them to third-party apps.
///
/// Medido en macOS 27.0.1 el 2026-10-29: la voz de Siri que la persona tiene
/// instalada (`com.apple.siri.natural.Carmen`, «Voz 2», es-MX) sí aparece en
/// `speechVoices()` y habla a 48 kHz cuando pregunta un proceso firmado por
/// Apple (el intérprete `swift`), pero un binario de terceros no la ve:
/// `AVSpeechSynthesisVoice(identifier:)` devuelve nil y pedir `es-MX` da la
/// Paulina compacta a 22 kHz. El filtro es de macOS, no de este catálogo.
///
/// Dilo cannot download voices (no public API); Settings deep-links the
/// user to System Settings instead, and this catalog refreshes itself the
/// moment a download finishes via `availableVoicesDidChangeNotification`.
@MainActor
@Observable
final class VoiceCatalog {
  /// Una voz, ya leída: lo que el selector necesita y nada más.
  ///
  /// Un valor y no la `AVSpeechSynthesisVoice`, porque la lista se arma en
  /// otro hilo y la voz no es `Sendable`.
  struct Voz: Sendable, Identifiable, Equatable {
    let identifier: String
    let etiqueta: String
    var id: String { identifier }
  }

  private(set) var voices: [Voz] = []
  /// Mientras la primera lectura no vuelve. El selector dice «Buscando
  /// voces…» en vez de «sólo hay voces de calidad normal».
  private(set) var cargando = true

  @ObservationIgnored
  private nonisolated(unsafe) var observer: (any NSObjectProtocol)?

  /// Crearlo no lee nada: la lista llega con `refresh()`, fuera del hilo
  /// principal. `AVSpeechSynthesisVoice.speechVoices()` tarda entre 200 y
  /// 570 ms en este Mac (180 voces, medido el 2026-10-19), **en cada
  /// llamada**, y Ajustes lo llamaba desde el `@State` de Leer en voz alta:
  /// SwiftUI evalúa ese valor inicial cada vez que reconstruye la vista
  /// —aunque el desplegable de General esté cerrado—, así que cada cambio
  /// del padre costaba medio segundo de ventana congelada.
  init() {
    observer = NotificationCenter.default.addObserver(
      forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        await self?.refresh()
      }
    }
  }

  deinit {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  func refresh() async {
    voices = await Task.detached(priority: .userInitiated) { Self.leerVoces() }.value
    cargando = false
  }

  private nonisolated static func leerVoces() -> [Voz] {
    AVSpeechSynthesisVoice.speechVoices()
      .filter { voice in
        voice.quality == .enhanced
          || voice.quality == .premium
          || voice.voiceTraits.contains(.isPersonalVoice)
      }
      .sorted { lhs, rhs in
        if lhs.quality != rhs.quality {
          return lhs.quality.rawValue > rhs.quality.rawValue
        }
        return lhs.name < rhs.name
      }
      .map { Voz(identifier: $0.identifier, etiqueta: label(for: $0)) }
  }

  /// A picker label: "Ava · English (US) · Premium".
  nonisolated static func label(for voice: AVSpeechSynthesisVoice) -> String {
    let language = Locale.current.localizedString(forIdentifier: voice.language)
      ?? voice.language
    return "\(voice.name) · \(language) · \(qualityLabel(for: voice))"
  }

  nonisolated static func qualityLabel(for voice: AVSpeechSynthesisVoice) -> String {
    if voice.voiceTraits.contains(.isPersonalVoice) { return "Personal" }
    switch voice.quality {
    case .premium: return "Premium"
    case .enhanced: return "Enhanced"
    default: return "Default"
    }
  }

  /// Opens the pane where the user downloads voices. There is no API to
  /// download or even enumerate not-yet-installed voices, so the handoff
  /// is the whole story; the legacy anchor is tried first, then the
  /// Accessibility root as a fallback.
  static func openVoiceDownloadSettings() {
    let candidates = [
      "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent",
      "x-apple.systempreferences:com.apple.Accessibility-Settings.extension",
    ]
    for candidate in candidates {
      if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
        return
      }
    }
  }

  /// Opens the Personal Voice pane, where the user creates a voice trained
  /// on their own speech. Creation has no API at all — the recording and
  /// training flow is exclusively Apple's UI — so this link is the entire
  /// integration; Dilo can only request to use the result.
  static func openPersonalVoiceSettings() {
    let candidates = [
      "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?PersonalVoice",
      "x-apple.systempreferences:com.apple.preference.universalaccess?PersonalVoice",
      "x-apple.systempreferences:com.apple.Accessibility-Settings.extension",
    ]
    for candidate in candidates {
      if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
        return
      }
    }
  }

  static func requestPersonalVoiceAccess() async -> AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus {
    await withCheckedContinuation { continuation in
      AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
        continuation.resume(returning: status)
      }
    }
  }
}
