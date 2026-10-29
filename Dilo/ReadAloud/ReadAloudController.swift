import AppKit
import AVFAudio
import DiloCapabilities
import DiloEngines

/// Read Aloud: speaks the focused application's selected text with the
/// Settings-picked engine. Phonon 40m (neural, on this Mac) is the factory
/// pick since 2026-10-29; Apple's voices read while Phonon is not installed,
/// read whatever is not Spanish, and stay electable. Playback is on-device and
/// offline. Errors surface through the HUD message surface, matching Direct
/// Dictation.
///
/// It reads the selection through Accessibility where it can, and by copying
/// it where it cannot: no browser answers the Accessibility question, and a
/// read-aloud feature that cannot read a web page is broken.
@MainActor
final class ReadAloudController: NSObject {
  /// Follows the synthesizer's actual state; the status menu mirrors it.
  var onSpeakingStateChange: ((Bool) -> Void)?

  private let settings: AppSettings
  private let hudController: DictationHUDController
  private let selectionReader = FocusedSelectionReader()
  private let synthesizer = AVSpeechSynthesizer()
  private let phonon = PhononEnDilo.compartido
  private lazy var lector: LectorPhonon = {
    let lector = LectorPhonon(instalacion: phonon.instalacion)
    lector.alCambiarDeEstado = { [weak self] hablando in
      self?.onSpeakingStateChange?(hablando)
    }
    return lector
  }()
  /// Lo que falta de Phonon se dice una vez por sesión, no en cada «Leer».
  private var faltaDePhononDicha = false
  /// Only reached while the translate setting is on. Read Aloud does not own
  /// translation and does not configure it; it borrows the same coordinator
  /// dictation uses.
  private let translation: TranslationCoordinator
  /// Borrowed for its clipboard, not for insertion. Shared with dictation so
  /// one read lease covers both.
  private let textInsertion: TextInsertionService

  init(
    settings: AppSettings,
    hudController: DictationHUDController,
    translation: TranslationCoordinator,
    textInsertion: TextInsertionService
  ) {
    self.settings = settings
    self.hudController = hudController
    self.translation = translation
    self.textInsertion = textInsertion
    super.init()
    synthesizer.delegate = self
  }

  func toggle() {
    // La función está escondida donde no se puede releer el foco. El atajo
    // igual podría venir guardado de otra instalación: acá no hace nada, en
    // vez de avisar de algo que no se puede arreglar.
    guard Anfitrion.actual.admite(.relecturaDelFoco) else { return }
    if synthesizer.isSpeaking || lector.leyendo {
      stop()
    } else {
      speakSelection()
    }
  }

  func stop() {
    lector.detener()
    synthesizer.stopSpeaking(at: .immediate)
  }

  private func speakSelection() {
    guard PermissionService.hasAccessibilityAccess else {
      hudController.showMessage("Accessibility permission required")
      return
    }

    switch selectionReader.selection() {
    case let .text(selected):
      speak(selection: selected)
    case .secureField:
      // Speaking a password out loud is a worse leak than pasting one, so
      // Read Aloud refuses the same fields Direct Dictation does.
      hudController.showMessage("Secure field")
    case .none:
      // Accessibility had no answer, which every browser gives. Copy instead.
      Task { [weak self] in
        guard let self else { return }
        guard let copied = await textInsertion.copySelection(),
          !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          hudController.showMessage("No text selected")
          return
        }
        speak(selection: copied)
      }
    }
  }

  private var motorElegido: MotorDeLectura { MotorDeLectura(guardado: settings.readAloudMotor) }

  /// Speaks one selection, translated first when that is switched on.
  ///
  /// The target is the reader's language: Spanish for Phonon, the voice's
  /// own for Apple.
  private func speak(selection text: String) {
    let source = SelectionLanguage.detect(in: text)
    let target: Locale.Language? = motorElegido == .phonon
      ? Locale.Language(identifier: "es")
      : chosenVoice.map { Locale.Language(identifier: $0.language) } ?? Self.systemVoiceLanguage
    guard settings.readAloudTranslates,
      let target,
      let source,
      SelectionLanguage.needsTranslation(from: source, to: target)
    else {
      // Nothing to translate, nothing confident enough to translate, or it is
      // already the reader's language. Read it as it was written, which is
      // what Read Aloud did before this setting existed.
      leer(text, idioma: source)
      return
    }

    speakTranslated(text, from: source, to: target)
  }

  /// Translates first, then reads in the target language.
  ///
  /// The model is checked first. Read Aloud cannot install one, because Apple
  /// only installs from a View modifier and this gesture has no window, and
  /// reading Japanese aloud in an English voice is a worse answer than saying
  /// why nothing happened.
  private func speakTranslated(
    _ text: String,
    from source: Locale.Language,
    to target: Locale.Language
  ) {
    let pair = TranslationPair(source: source, target: target)
    Task { [weak self] in
      guard let self else { return }
      guard await translation.canTranslate(pair) else {
        hudController.showMessage("No \(Self.name(of: source)) to \(Self.name(of: target))")
        return
      }
      guard let translated = try? await translation.translate(text, with: pair) else {
        hudController.showMessage("Couldn't translate")
        return
      }
      leer(translated, idioma: target)
    }
  }

  /// Decide quién lee (`DecisionDeLectura`) y lee. El disco se mira fuera
  /// del hilo principal: son seis `stat`, pero «Leer» no espera a nadie.
  private func leer(_ text: String, idioma: Locale.Language?) {
    let elegido = motorElegido
    guard elegido == .phonon else {
      speak(text, with: chosenVoice)
      return
    }
    let voz = VocesDePhonon.voz(settings.readAloudVozPhonon)
    let codigo = idioma?.languageCode?.identifier
    Task { [weak self] in
      let estado = await Task.detached { InstalacionDePhonon.estado(voz: voz) }.value
      guard let self else { return }
      switch DecisionDeLectura.decidir(elegido: elegido, estado: estado, idioma: codigo) {
      case .phonon:
        lector.leer(text, voz: voz) { [weak self] _ in
          self?.hudController.showMessage(String(localized: "Phonon falló: lee Apple"))
          self?.speak(text, with: self?.vozDeApple(para: idioma))
        }
      case .apple(.bajandoPhonon):
        speak(text, with: vozDeApple(para: idioma))
        hudController.showMessage(String(localized: "Bajando Phonon: por ahora lee Apple"))
        Task { await phonon.preparar(voz: voz) }
      case .apple(.faltaElModelo):
        speak(text, with: vozDeApple(para: idioma))
        if !faltaDePhononDicha {
          faltaDePhononDicha = true
          hudController.showMessage(String(localized: "Falta instalar Phonon: lee Apple"))
        }
      case .apple(.otroIdioma), .apple(nil):
        speak(text, with: vozDeApple(para: idioma))
      }
    }
  }

  /// La voz de Apple cuando lee en lugar de Phonon: la elegida si habla ese
  /// idioma, si no la del sistema para ese idioma. Una voz en español leyendo
  /// inglés es lo que no hay que hacer.
  private func vozDeApple(para idioma: Locale.Language?) -> AVSpeechSynthesisVoice? {
    let elegida = chosenVoice
    guard let codigo = idioma?.languageCode?.identifier else { return elegida }
    if let elegida, elegida.language.hasPrefix(codigo) { return elegida }
    return AVSpeechSynthesisVoice(language: codigo) ?? elegida
  }

  private func speak(_ text: String, with voice: AVSpeechSynthesisVoice?) {
    lector.detener()
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = voice
    synthesizer.speak(utterance)
  }

  private var chosenVoice: AVSpeechSynthesisVoice? {
    guard !settings.readAloudVoiceID.isEmpty else { return nil }
    return AVSpeechSynthesisVoice(identifier: settings.readAloudVoiceID)
  }

  /// The language the synthesizer speaks when no voice is chosen, so the
  /// target is known even then.
  private static var systemVoiceLanguage: Locale.Language? {
    Locale.Language(identifier: AVSpeechSynthesisVoice.currentLanguageCode())
  }

  private static func name(of language: Locale.Language) -> String {
    guard let code = language.languageCode?.identifier else { return "that" }
    return SpeechLanguageCatalog.shortName(for: Locale(identifier: code))
  }
}

extension ReadAloudController: AVSpeechSynthesizerDelegate {
  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didStart utterance: AVSpeechUtterance
  ) {
    Task { @MainActor [weak self] in
      self?.onSpeakingStateChange?(true)
    }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didFinish utterance: AVSpeechUtterance
  ) {
    Task { @MainActor [weak self] in
      self?.onSpeakingStateChange?(false)
    }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didCancel utterance: AVSpeechUtterance
  ) {
    Task { @MainActor [weak self] in
      self?.onSpeakingStateChange?(false)
    }
  }
}
