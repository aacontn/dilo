import AppKit
import DiloEngines
import DiloModes
import DiloText
import Foundation
import Observation

/// The application settings: every user-facing preference in one observable,
/// UserDefaults-backed store. Settings binds to it, the HUD observes it, and
/// nothing else touches UserDefaults for these keys.
///
/// The key strings predate this module and must not change — they are what
/// existing users' picks are stored under (and, for sounds, the rawValue also
/// prefixes the bundled asset names).
@MainActor
@Observable
final class AppSettings {
  private enum Keys {
    static let soundSet = "dictationSoundSet"
    static let soundsEnabled = "dictationSoundsEnabled"
    static let duckOtherAudio = "duckOtherAudioWhileDictating"
    static let soundVolume = "dictationSoundVolume"
    static let voiceVisual = "hudVoiceVisual"
    static let waveformStyle = "hudWaveformStyle"
    static let revealStyle = "hudRevealStyle"
    static let longDraftStyle = "hudLongDraftStyle"
    static let glowPalette = "hudGlowPalette"
    static let glowCenter = "hudGlowCenter"
    static let hudScale = "hudScale"
    static let readAloudVoice = "readAloudVoice"
    static let readAloudTranslates = "readAloudTranslates"
    static let dictationTriggerBinding = "dictationTriggerBinding"
    static let readAloudBinding = "readAloudBinding"
    static let recognitionLocale = "recognitionLocale"
    static let secondaryRecognitionLocale = "recognitionLocaleSecondary"
    static let secondaryTriggerBinding = "dictationTriggerBindingSecondary"
    static let translateTriggerBinding = "dictationTriggerBindingTranslate"
    static let translationTarget = "translationTargetLanguage"
    static let transcriptDestination = "transcriptDestination"
    static let transcriptFolder = "transcriptFolder"
    static let insertionDestination = "dictationInsertionDestination"
    /// La clave vieja, de cuando esto era un interruptor. Se lee una sola
    /// vez para no borrarle la elección a quien ya la había cambiado.
    static let hudClearsMenuBar = "hudClearsMenuBar"
    static let hudEstiloSinNotch = "hudEstiloSinNotch"
    static let historyEnabled = "dictationHistoryEnabled"
    static let historyFolder = "dictationHistoryFolder"
    // Las tres claves de "Transformar", el sistema heredado del árbol de origen. Ya no
    // se escriben: se leen una vez para migrar a modos y se dejan en disco una
    // versión más, por si hay que reconstruir a mano la biblioteca de alguien.
    static let promptShapingEnabled = "dictationPromptShapingEnabled"
    static let promptShapingPrompt = "dictationPromptShapingPrompt"
    static let shapingPrompts = "dictationShapingPrompts"
    static let migracionDeModos = "diloMigracionDeModos"
    static let modos = "diloModos"
    static let proveedores = "diloProveedores"
    static let proveedorGeneral = "diloProveedorGeneral"
    static let unAtajoDiloDecide = "diloUnAtajoDiloDecide"
    static let palabrasPropias = "diloPalabrasPropias"
    static let limpiarMuletillas = "diloLimpiarMuletillas"
    static let muletillasPropias = "diloMuletillasPropias"
    static let onboardingVisto = "diloOnboardingVisto"
    static let versionVista = "diloVersionVista"
  }

  @ObservationIgnored
  private let defaults: UserDefaults

  var soundSet: DictationSoundSet {
    didSet { defaults.set(soundSet.rawValue, forKey: Keys.soundSet) }
  }

  /// Lowers the system output while a session listens. Off by default: it
  /// moves a system-wide control, which is not something to start doing to
  /// someone who did not ask for it.
  var duckOtherAudioWhileDictating: Bool {
    didSet { defaults.set(duckOtherAudioWhileDictating, forKey: Keys.duckOtherAudio) }
  }

  var dictationSoundsEnabled: Bool {
    didSet { defaults.set(dictationSoundsEnabled, forKey: Keys.soundsEnabled) }
  }

  private var storedDictationSoundVolume: Double

  var dictationSoundVolume: Double {
    get { storedDictationSoundVolume }
    set {
      storedDictationSoundVolume = DictationSoundSettings.normalizedVolume(newValue)
      defaults.set(storedDictationSoundVolume, forKey: Keys.soundVolume)
    }
  }

  /// Where a Drop Transcription writes its transcript. The chosen folder is
  /// kept even while the pick is `besideSource`, so switching back and forth
  /// does not lose it.
  var transcriptDestination: TranscriptDestination.Preference {
    didSet { defaults.set(transcriptDestination.rawValue, forKey: Keys.transcriptDestination) }
  }

  var transcriptFolder: URL? {
    didSet { defaults.set(transcriptFolder?.path(percentEncoded: false), forKey: Keys.transcriptFolder) }
  }

  /// Where a finished Direct Dictation session's text goes: the paste that
  /// always happened, the clipboard alone, or both.
  var insertionDestination: InsertionDestination {
    didSet { defaults.set(insertionDestination.rawValue, forKey: Keys.insertionDestination) }
  }

  /// Whether finished dictation text is saved to the history folder. Off by
  /// default: persisting no recognized text is the standing privacy stance,
  /// and only the user turns this on.
  var dictationHistoryEnabled: Bool {
    didSet { defaults.set(dictationHistoryEnabled, forKey: Keys.historyEnabled) }
  }

  /// The history folder, kept even while history is off so turning it back
  /// on returns to the same place. Nil means the default `~/Documents/Dilo/`.
  var dictationHistoryFolder: URL? {
    didSet { defaults.set(dictationHistoryFolder?.path(percentEncoded: false), forKey: Keys.historyFolder) }
  }

  /// The folder history writes to right now: the user's pick, or the default.
  var resolvedHistoryFolder: URL {
    dictationHistoryFolder ?? DictationHistoryStore.defaultFolderURL
  }

  /// La versión de migración que ya corrió sobre estos ajustes. Cero en una
  /// instalación que nunca la vio.
  @ObservationIgnored
  private(set) var versionDeMigracionDeModos: Int

  /// Los modos de Dilo: nombre, prompt, proveedor y —si quieres— una tecla.
  /// Se guardan enteros como JSON; un valor ilegible vuelve a los de fábrica
  /// en vez de dejar la lista vacía.
  var modos: [Modo] {
    didSet {
      if let data = try? JSONEncoder().encode(modos) {
        defaults.set(data, forKey: Keys.modos)
      }
    }
  }

  /// El catálogo de proveedores, con la URL base y el modelo que cada quien
  /// configuró. **Las claves de API no están acá**: viven en el Llavero, y
  /// este valor se serializa a `UserDefaults`, que es texto plano.
  var proveedores: [Proveedor] {
    didSet {
      if let data = try? JSONEncoder().encode(proveedores) {
        defaults.set(data, forKey: Keys.proveedores)
      }
    }
  }

  /// El proveedor que usan los modos que no eligieron uno propio.
  var proveedorGeneralID: String {
    didSet { defaults.set(proveedorGeneralID, forKey: Keys.proveedorGeneral) }
  }

  /// "Un atajo, Dilo decide": el modo se elige por la app al frente y el
  /// contenido, sin tecla propia. Apagada de fábrica (spec §7): quien no la
  /// prende tiene exactamente el comportamiento de siempre.
  var unAtajoDiloDecide: Bool {
    didSet { defaults.set(unAtajoDiloDecide, forKey: Keys.unAtajoDiloDecide) }
  }

  /// Los modos de fábrica vuelven, y vuelven sin tecla los que no la traían.
  func restaurarModosDeFabrica() {
    modos = Modo.deFabrica
  }

  /// Tus palabras: nombres, proyectos, siglas y términos técnicos que el
  /// motor no conoce. Se le pasan al motor como contexto **y** se corrigen
  /// después, porque el contexto ayuda pero no garantiza.
  var palabrasPropias: [String] {
    didSet { defaults.set(palabrasPropias, forKey: Keys.palabrasPropias) }
  }

  /// Si se limpian las muletillas del español. Prendido de fábrica: es lo que
  /// hace que el dictado salga listo para pegar sin pasar por ninguna IA.
  var limpiarMuletillas: Bool {
    didSet { defaults.set(limpiarMuletillas, forKey: Keys.limpiarMuletillas) }
  }

  /// Tu lista de muletillas. Vacía usa las de fábrica; con algo adentro
  /// reemplaza a las de fábrica enteras, que es lo que alguien quiere cuando
  /// se toma el trabajo de escribir una.
  var muletillasPropias: [String] {
    didSet { defaults.set(muletillasPropias, forKey: Keys.muletillasPropias) }
  }

  /// Lo que `DiloText` necesita saber, armado en un solo lugar.
  var preferenciasDeTexto: DiloText.Preferencias {
    DiloText.Preferencias(
      muletillasPropias: limpiarMuletillas ? (muletillasPropias.isEmpty ? nil : muletillasPropias) : [],
      palabrasPropias: palabrasPropias
    )
  }

  var voiceVisual: HUDVoiceVisualStyle {
    didSet { defaults.set(voiceVisual.rawValue, forKey: Keys.voiceVisual) }
  }

  var waveformStyle: HUDWaveformStyle {
    didSet { defaults.set(waveformStyle.rawValue, forKey: Keys.waveformStyle) }
  }

  var revealStyle: HUDRevealStyle {
    didSet { defaults.set(revealStyle.rawValue, forKey: Keys.revealStyle) }
  }

  var longDraftStyle: HUDLongDraftStyle {
    didSet { defaults.set(longDraftStyle.rawValue, forKey: Keys.longDraftStyle) }
  }

  var glowPalette: HUDGlowPalette {
    didSet { defaults.set(glowPalette.rawValue, forKey: Keys.glowPalette) }
  }

  var glowCenter: HUDGlowCenterStyle {
    didSet { defaults.set(glowCenter.rawValue, forKey: Keys.glowCenter) }
  }

  /// How large the HUD shape is, as a fraction of the standard size.
  /// `HUDMetrics` clamps it to its supported range; a stored value outside
  /// that range comes back clamped rather than refused.
  var hudScale: Double {
    didSet { defaults.set(hudScale, forKey: Keys.hudScale) }
  }

  /// The Read Aloud voice's `AVSpeechSynthesisVoice` identifier; empty
  /// means the system default voice.
  /// Whether Read Aloud translates a selection into the voice's own language
  /// before speaking it. Off by default: Read Aloud has always read what was
  /// written, and translating without being asked would change what a shortcut
  /// someone already uses does.
  var readAloudTranslates: Bool {
    didSet { defaults.set(readAloudTranslates, forKey: Keys.readAloudTranslates) }
  }

  /// Qué forma se dibuja en una pantalla sin notch: la imitación del notch
  /// pegada al borde de arriba (el default desde el 2026-09-21) o la píldora
  /// que cuelga debajo de la barra de menús. Con notch real no se mira.
  var hudEstiloSinNotch: HUDEstiloSinNotch {
    didSet { defaults.set(hudEstiloSinNotch.rawValue, forKey: Keys.hudEstiloSinNotch) }
  }

  var readAloudVoiceID: String {
    didSet { defaults.set(readAloudVoiceID, forKey: Keys.readAloudVoice) }
  }

  var dictationTriggerBinding: KeyBinding {
    didSet { Self.store(dictationTriggerBinding, in: defaults, key: Keys.dictationTriggerBinding) }
  }

  var readAloudBinding: KeyBinding {
    didSet { Self.store(readAloudBinding, in: defaults, key: Keys.readAloudBinding) }
  }

  /// The dictation language, as a locale identifier; empty means follow the
  /// Mac's own language, which is what every session did before the Language
  /// section existed.
  /// Si los Primeros pasos ya se mostraron alguna vez. Sólo lo escribe la
  /// app al abrirlos; volver a abrirlos desde el menú no lo cambia, porque
  /// para eso está el menú.
  var onboardingVisto: Bool {
    didSet { defaults.set(onboardingVisto, forKey: Keys.onboardingVisto) }
  }

  /// La última versión cuyas novedades se mostraron. Vacía en una instalación
  /// nueva: ahí lo que corresponde es el onboarding, no un changelog de algo
  /// que la persona nunca usó.
  var versionVista: String {
    didSet { defaults.set(versionVista, forKey: Keys.versionVista) }
  }

  /// Cuál **Motor de voz** dicta. La clave y el default viven en
  /// `EnginePreference` para poder probar la regla con `swift test`; acá
  /// sigue estando el único lugar de la app que la lee y la escribe.
  var motorDeVoz: SpeechEngineKind {
    didSet { EnginePreference.guardar(motorDeVoz, in: defaults) }
  }

  /// Cuánto aguanta el modelo de Parakeet en la RAM sin que dictes. La clave
  /// y el default viven en `PreferenciaDeReposo`, por lo mismo que el motor.
  var descargarModeloTras: DescargaPorReposo {
    didSet { PreferenciaDeReposo.guardar(descargarModeloTras, in: defaults) }
  }

  var recognitionLocaleIdentifier: String {
    didSet {
      defaults.set(recognitionLocaleIdentifier, forKey: Keys.recognitionLocale)
      // Choosing the second language as the first leaves one language behind
      // two keys, so the second turns off rather than becoming a duplicate.
      if !recognitionLocaleIdentifier.isEmpty,
       recognitionLocaleIdentifier == secondaryRecognitionLocaleIdentifier {
        secondaryRecognitionLocaleIdentifier = ""
      }
    }
  }

  /// The second language, with its own trigger. Empty means off, which is the
  /// default: one trigger, one language, exactly as before.
  var secondaryRecognitionLocaleIdentifier: String {
    didSet {
      defaults.set(
        secondaryRecognitionLocaleIdentifier,
        forKey: Keys.secondaryRecognitionLocale
      )
    }
  }

  var secondaryTriggerBinding: KeyBinding {
    didSet { Self.store(secondaryTriggerBinding, in: defaults, key: Keys.secondaryTriggerBinding) }
  }

  /// The trigger that dictates in the primary language and inserts a
  /// translation. Defaults to right command, which shares no key with fn:
  /// any fn combination would end a held plain session the moment its
  /// modifier arrived, because fn alone is already a trigger.
  var translateTriggerBinding: KeyBinding {
    didSet { Self.store(translateTriggerBinding, in: defaults, key: Keys.translateTriggerBinding) }
  }

  /// The language Dictate and Translate translates into, as a language code.
  /// Empty means off, which is the default: the trigger is not installed at
  /// all until a target is chosen, so an unconfigured key swallows nothing.
  var translationTargetIdentifier: String {
    didSet { defaults.set(translationTargetIdentifier, forKey: Keys.translationTarget) }
  }

  var isTranslationEnabled: Bool {
    !translationTargetIdentifier.isEmpty
  }

  /// The pair a session would translate, or nil when translation is off or
  /// would translate a language into itself.
  func translationPair(from source: Locale) -> TranslationPair? {
    guard isTranslationEnabled else { return nil }
    let target = Locale.Language(identifier: translationTargetIdentifier)
    guard let sourceCode = source.language.languageCode?.identifier,
       let targetCode = target.languageCode?.identifier,
       sourceCode != targetCode
    else {
      return nil
    }
    return TranslationPair(source: source.language, target: target)
  }

  /// True once a second language is chosen. The second trigger is ignored
  /// while this is false, so an unused binding cannot start a session.
  /// The labels a split Drop Target shows, or empty when one language is
  /// configured and the target stays whole.
  var languageTagsForDrop: [String] {
    guard isSecondLanguageEnabled else { return [] }
    let primary = recognitionLocaleIdentifier.isEmpty
      ? Locale.current.identifier
      : recognitionLocaleIdentifier
    return [primary, secondaryRecognitionLocaleIdentifier]
      .map { SpeechLanguageCatalog.tag(for: Locale(identifier: $0)) }
  }

  /// Which language a drop chose. Index 1 is the second language and only
  /// exists while the target is split; anything else is the primary.
  func localeIdentifierForDrop(languageIndex: Int) -> String {
    guard languageIndex == 1, isSecondLanguageEnabled else {
      return recognitionLocaleIdentifier
    }
    return secondaryRecognitionLocaleIdentifier
  }

  var isSecondLanguageEnabled: Bool {
    !secondaryRecognitionLocaleIdentifier.isEmpty
  }

  /// Transient, never persisted: true while a Shortcuts input recorder is
  /// armed, so global trigger handling pauses and the rebind input cannot
  /// start a session.
  var isRecordingKeybind = false

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // Marimba es el default desde 0.4.0: Synth8 sonaba a alarma sintética.
    // Quien ya eligió otro juego lo conserva — el valor guardado manda.
    soundSet = Self.stored(in: defaults, key: Keys.soundSet) ?? .marimba
    dictationSoundsEnabled = defaults.object(forKey: Keys.soundsEnabled) as? Bool ?? true
    // Apagado y sin interruptor. "Duck other audio" baja el volumen de
    // salida del sistema por Core Audio, y macOS muestra su propio HUD de
    // volumen cada vez. Dilo nunca toca el volumen maestro: si algún día
    // se silencia la música al dictar, se pausa la reproducción (spec §8.3).
    // El mecanismo (AudioDucker) queda con sus tests por si ese día llega.
    duckOtherAudioWhileDictating = false
    let storedSoundVolume = defaults.object(forKey: Keys.soundVolume) as? Double ?? 0.5
    storedDictationSoundVolume = DictationSoundSettings.normalizedVolume(storedSoundVolume)
    transcriptDestination = Self.stored(in: defaults, key: Keys.transcriptDestination) ?? .besideSource
    transcriptFolder = (defaults.string(forKey: Keys.transcriptFolder)).map { URL(filePath: $0) }
    insertionDestination = Self.stored(in: defaults, key: Keys.insertionDestination) ?? .insert
    dictationHistoryEnabled = defaults.object(forKey: Keys.historyEnabled) as? Bool ?? false
    dictationHistoryFolder = (defaults.string(forKey: Keys.historyFolder)).map { URL(filePath: $0) }
    proveedores = Self.guardado([Proveedor].self, Keys.proveedores, in: defaults)
      ?? Proveedor.deFabrica
    proveedorGeneralID = defaults.string(forKey: Keys.proveedorGeneral)
      ?? Proveedor.deFabrica[0].id

    // Las dos bibliotecas se juntan acá, una sola vez. La migración es pura y
    // vive en `DiloModes` con sus tests; este bloque sólo le pasa lo que hay
    // guardado y anota lo que devuelve.
    let migracion = MigracionDeModos.migrar(
      heredados: Self.guardado(
        [PromptHeredado].self, Keys.shapingPrompts, in: defaults
      ) ?? [],
      transformarEstabaPrendido: defaults.object(
        forKey: Keys.promptShapingEnabled
      ) as? Bool ?? false,
      modosGuardados: Self.guardado([Modo].self, Keys.modos, in: defaults),
      unAtajoDiloDecide: defaults.object(forKey: Keys.unAtajoDiloDecide) as? Bool ?? false,
      marca: defaults.integer(forKey: Keys.migracionDeModos)
    )
    modos = migracion.modos
    unAtajoDiloDecide = migracion.unAtajoDiloDecide
    versionDeMigracionDeModos = migracion.version
    if migracion.seMigro {
      // Los `didSet` no corren durante `init`, así que lo que la migración
      // decidió se escribe a mano. La marca va **última**: si el proceso
      // muere en el medio, la próxima vez vuelve a migrar sobre lo mismo y
      // el resultado es idéntico, que es lo que idempotente quiere decir.
      if let datos = try? JSONEncoder().encode(migracion.modos) {
        defaults.set(datos, forKey: Keys.modos)
      }
      defaults.set(migracion.unAtajoDiloDecide, forKey: Keys.unAtajoDiloDecide)
      defaults.set(migracion.version, forKey: Keys.migracionDeModos)
    }
    palabrasPropias = defaults.stringArray(forKey: Keys.palabrasPropias) ?? []
    limpiarMuletillas = defaults.object(forKey: Keys.limpiarMuletillas) as? Bool ?? true
    muletillasPropias = defaults.stringArray(forKey: Keys.muletillasPropias) ?? []
    voiceVisual = Self.stored(in: defaults, key: Keys.voiceVisual) ?? .waveform
    // Siri Wave de fábrica: lo eligió Alfonso al ver la píldora (2026-09-21).
    waveformStyle = Self.stored(in: defaults, key: Keys.waveformStyle) ?? .siriWave
    revealStyle = Self.stored(in: defaults, key: Keys.revealStyle) ?? .slide
    longDraftStyle = Self.stored(in: defaults, key: Keys.longDraftStyle) ?? .growDown
    glowPalette = Self.stored(in: defaults, key: Keys.glowPalette) ?? .spectrum
    glowCenter = Self.stored(in: defaults, key: Keys.glowCenter) ?? .particles
    // `double(forKey:)` reads a missing key as zero, which would start every
    // existing user at the smallest HUD, so absence is checked directly.
    hudScale = defaults.object(forKey: Keys.hudScale) as? Double
      ?? Double(HUDMetrics.maximumScale)
    // Sin nada guardado manda el notch simulado (2026-09-21): el escenario de
    // Dilo es el notch, y en una pantalla sin carcasa la imitación es lo que
    // más se le parece. Ocupa sólo la franja del centro de la barra de menús,
    // que macOS deja vacía, así que sigue sin tapar un status item.
    //
    // Quien eligió a mano conserva su elección, y quien había **encendido**
    // el interruptor viejo pedía justamente que la forma despejara la barra:
    // esa elección vale como haber elegido la píldora. El interruptor apagado
    // quería la forma donde iría el notch, que es el default de hoy.
    hudEstiloSinNotch = Self.stored(in: defaults, key: Keys.hudEstiloSinNotch)
      ?? (defaults.object(forKey: Keys.hudClearsMenuBar) as? Bool == true ? .pildora : .notchSimulado)
    readAloudVoiceID = defaults.string(forKey: Keys.readAloudVoice) ?? ""
    readAloudTranslates = defaults.bool(forKey: Keys.readAloudTranslates)
    dictationTriggerBinding = Self.storedBinding(
      in: defaults,
      key: Keys.dictationTriggerBinding,
      allowsMouseButton: true
    ) ?? .fnTrigger
    readAloudBinding = Self.storedBinding(
      in: defaults,
      key: Keys.readAloudBinding,
      allowsMouseButton: false
    ) ?? .optionEscape
    onboardingVisto = defaults.bool(forKey: Keys.onboardingVisto)
    versionVista = defaults.string(forKey: Keys.versionVista) ?? ""
    motorDeVoz = EnginePreference.leer(defaults)
    descargarModeloTras = PreferenciaDeReposo.leer(defaults)
    recognitionLocaleIdentifier = defaults.string(forKey: Keys.recognitionLocale) ?? ""
    secondaryRecognitionLocaleIdentifier =
      defaults.string(forKey: Keys.secondaryRecognitionLocale) ?? ""
    secondaryTriggerBinding = Self.storedBinding(
      in: defaults,
      key: Keys.secondaryTriggerBinding,
      allowsMouseButton: true
    ) ?? .controlOptionSpace
    translateTriggerBinding = Self.storedBinding(
      in: defaults,
      key: Keys.translateTriggerBinding,
      allowsMouseButton: true
    ) ?? .rightCommandTrigger
    translationTargetIdentifier = defaults.string(forKey: Keys.translationTarget) ?? ""
  }

  private static func stored<Value: RawRepresentable<String>>(
    in defaults: UserDefaults,
    key: String
  ) -> Value? {
    defaults.string(forKey: key).flatMap { Value(rawValue: $0) }
  }

  /// `allowsMouseButton` is false for Read Aloud, which fires from keyDown
  /// and so has no mouse path at all: a stored mouse binding there could only
  /// ever be dead.
  private static func storedBinding(
    in defaults: UserDefaults,
    key: String,
    allowsMouseButton: Bool
  ) -> KeyBinding? {
    guard let data = defaults.data(forKey: key),
       let binding = try? JSONDecoder().decode(KeyBinding.self, from: data),
       allowsMouseButton || !binding.isMouseButton
    else { return nil }
    return binding
  }

  /// Un valor de Dilo guardado como JSON, o nil si no está o no se puede
  /// leer. Un JSON roto vale lo mismo que uno ausente: se reseminan los de
  /// fábrica, que es mejor que una pantalla vacía sin explicación.
  private static func guardado<T: Decodable>(
    _: T.Type, _ clave: String, in defaults: UserDefaults
  ) -> T? {
    guard let data = defaults.data(forKey: clave) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }

  private static func store(_ binding: KeyBinding, in defaults: UserDefaults, key: String) {
    if let data = try? JSONEncoder().encode(binding) {
      defaults.set(data, forKey: key)
    }
  }

  func binding(for role: BindingRole) -> KeyBinding {
    switch role {
    case .dictation: dictationTriggerBinding
    case .secondLanguage: secondaryTriggerBinding
    case .translate: translateTriggerBinding
    case .readAloud: readAloudBinding
    }
  }

  func setBinding(_ binding: KeyBinding, for role: BindingRole) {
    switch role {
    case .dictation: dictationTriggerBinding = binding
    case .secondLanguage: secondaryTriggerBinding = binding
    case .translate: translateTriggerBinding = binding
    case .readAloud: readAloudBinding = binding
    }
  }

  /// The role already using this exact input and modifiers, if any.
  ///
  /// One rule in one place: the recorders, the Language section and
  /// `setBindings` would otherwise each decide for themselves what clashes.
  /// A second language that is off holds no binding, so it clashes with
  /// nothing. Only the input matters — the same binding recorded and clicked
  /// carries a different label, and comparing whole values would miss it.
  func roleUsing(_ candidate: KeyBinding, excluding role: BindingRole) -> BindingRole? {
    BindingRole.allCases.first { other in
      guard other != role else { return false }
      guard other != .secondLanguage || isSecondLanguageEnabled else { return false }
      // A translate trigger that has no target holds no binding, so an
      // unconfigured one must not report a clash with a real binding.
      guard other != .translate || isTranslationEnabled else { return false }
      return binding(for: other).hasSameInputAndModifiers(as: candidate)
    }
  }

  /// El id con que un rol aparece entre los atajos ocupados. Con prefijo para
  /// que nunca choque con el id de un modo.
  static func idDeRol(_ role: BindingRole) -> String { "rol.\(role)" }

  /// **Todos** los atajos que hoy tienen tecla en Dilo: los cuatro roles y
  /// cada modo, con el nombre que se le muestra a la persona.
  ///
  /// Es la lista que `ValidadorDeGatillos` necesita para que una tecla no se
  /// pueda asignar dos veces. Antes cada pantalla revisaba lo suyo —Modos
  /// contra los otros modos, Atajos contra los cuatro roles— y así la tecla
  /// del dictado y la de un modo podían quedar iguales: el modo no disparaba
  /// nunca y nada lo decía.
  var gatillosEnUso: [ValidadorDeGatillos.GatilloEnUso] {
    var ocupados = BindingRole.allCases.compactMap { rol -> ValidadorDeGatillos.GatilloEnUso? in
      // Un segundo idioma apagado o un traducir sin destino no tienen tecla
      // instalada, así que no le quitan nada a nadie.
      if rol == .secondLanguage, !isSecondLanguageEnabled { return nil }
      if rol == .translate, !isTranslationEnabled { return nil }
      return ValidadorDeGatillos.GatilloEnUso(
        id: Self.idDeRol(rol), nombre: rol.title, gatillo: binding(for: rol).gatillo
      )
    }
    ocupados += modos.compactMap { modo in
      modo.gatillo.map {
        ValidadorDeGatillos.GatilloEnUso(id: modo.id, nombre: modo.nombre, gatillo: $0)
      }
    }
    return ocupados
  }

  /// Quién más usa esta tecla, por nombre. Cubre roles y modos, que es lo que
  /// `roleUsing` no alcanza a ver.
  func quienUsa(_ candidato: KeyBinding, salvo id: String) -> String? {
    let gatillo = candidato.gatillo
    return gatillosEnUso
      .first { $0.id != id && $0.gatillo.disparaLoMismoQue(gatillo) }?
      .nombre
  }
}

/// Which recorded binding is being talked about. Shared so the Shortcuts
/// section, the Language section and the event tap all name the same three
/// roles.
enum BindingRole: Hashable, CaseIterable {
  case dictation
  case secondLanguage
  case translate
  case readAloud

  var title: String {
    switch self {
    case .dictation: String(localized: "Dictado")
    case .secondLanguage: String(localized: "Segundo idioma")
    case .translate: String(localized: "Traducir")
    case .readAloud: String(localized: "Leer en voz alta")
    }
  }
}

/// The preferences captured when Direct Dictation starts. A session keeps
/// this value until its end and paste sounds have played.
struct DictationSessionSettings: Equatable {
  let sounds: DictationSoundSettings
  let insertionDestination: InsertionDestination
  /// The translation this session performs, or nil when it inserts the words
  /// as spoken. Captured with everything else: changing the target
  /// mid-session must not redirect the session already under way (ADR-0004).
  let translation: TranslationPair?
  let historyEnabled: Bool
  let historyFolder: URL
  /// Captured with everything else: a session that started while ducking was
  /// on has to restore the volume even if the toggle flips mid-session.
  let ducksOtherAudio: Bool
  /// La biblioteca de modos entera, congelada al empezar: es lo que las
  /// flechas recorren mientras hablas, y leerla de Ajustes a mitad de camino
  /// dejaría la lista cambiando debajo de la persona.
  let modos: [Modo]
  /// Si el atajo principal puede elegir modo por reglas en esta sesión.
  let unAtajoDiloDecide: Bool
  /// El catálogo de proveedores y el general, también congelados. Con esto y
  /// `proveedoresConClave` la sesión resuelve **su** proveedor al terminar sin
  /// volver a mirar Ajustes: cambiarlos a mitad de dictado aplica al
  /// siguiente (ADR-0004), y eso es lo que impide que un modo que empezó
  /// local termine saliendo a una nube.
  let proveedores: [Proveedor]
  let proveedorGeneralID: String
  /// Qué proveedores tenían clave cuando esto empezó. Se pregunta al Llavero
  /// una vez por sesión y sólo por los que la necesitan.
  let proveedoresConClave: Set<String>
  /// Las reglas de español que aplican a esta sesión: muletillas y tus
  /// palabras. Se capturan como todo lo demás, para que editar el
  /// diccionario a mitad de dictado no cambie el dictado en vuelo (ADR-0004).
  let textoPreferencias: DiloText.Preferencias
  let voiceVisual: HUDVoiceVisualStyle
  let waveformStyle: HUDWaveformStyle
  let revealStyle: HUDRevealStyle
  let longDraftStyle: HUDLongDraftStyle
  let glowPalette: HUDGlowPalette
  let glowCenter: HUDGlowCenterStyle
  let hudMetrics: HUDMetrics

  /// The colour a Drop Transcription wears — on the HUD's target and card, and
  /// on the status ghost while a file job fills it. Edge Glow and Edge Glow +
  /// Draft lend the palette's own hue; every other visual keeps the HUD's own blue.
  /// One definition, so the shape and the menu bar can never drift apart
  /// (CONTEXT.md).
  var dropAccent: NSColor {
    voiceVisual.usesEdgeGlow ? glowPalette.statusAccent : SettingsTheme.accentColor
  }

  /// Sólo los proveedores que esta sesión podría llegar a usar **y** que
  /// piden clave: el general y los que algún modo eligió.
  ///
  /// Preguntarle al Llavero por el modelo del chip sería una consulta al
  /// sistema para nada, y esto corre al empezar cada dictado, donde los
  /// milisegundos se cuentan (spec §3). Y hay una razón más fuerte: leer un
  /// ítem del Llavero desde un binario firmado distinto abre un diálogo que
  /// espera a un humano, y eso colgaría la suite igual que lo hacía TCC. Con
  /// los ajustes de fábrica —todo en el chip— no se consulta nada.
  private static func conClave(
    _ proveedores: [Proveedor],
    general: String,
    modos: [Modo],
    en claves: some AlmacenDeClaves
  ) -> Set<String> {
    let alcanzables = Set([general] + modos.compactMap(\.proveedorID))
    return Set(
      proveedores
        .filter { alcanzables.contains($0.id) && $0.necesitaClave }
        .filter { claves.tieneClave(para: $0.cuentaEnElLlavero) }
        .map(\.id)
    )
  }

  /// El proveedor con que este modo corre en **esta** sesión, resuelto contra
  /// la foto que se tomó al empezar. No hay respaldo: si falla, se dice.
  func proveedorDeSesion(para modo: Modo) -> ResolucionDeProveedor.DeSesion {
    ResolucionDeProveedor.deSesion(
      para: modo,
      general: proveedorGeneralID,
      catalogo: proveedores,
      tieneClave: { proveedoresConClave.contains($0.id) }
    )
  }

  /// El modo cuya tecla es ésta, dentro de la biblioteca congelada.
  func modo(delGatillo gatillo: Gatillo?) -> Modo? {
    guard let gatillo else { return nil }
    return ResolucionDeModo.porAtajo(gatillo, entre: modos)
  }

  /// - Parameter claves: el Llavero, o uno de mentira en los tests. Se
  ///   consulta una vez por sesión y sólo por los proveedores que piden clave.
  @MainActor
  init(
    settings: AppSettings,
    translation: TranslationPair? = nil,
    claves: some AlmacenDeClaves = Llavero()
  ) {
    self.translation = translation
    sounds = DictationSoundSettings(
      set: settings.soundSet,
      isEnabled: settings.dictationSoundsEnabled,
      volume: settings.dictationSoundVolume
    )
    insertionDestination = settings.insertionDestination
    historyEnabled = settings.dictationHistoryEnabled
    historyFolder = settings.resolvedHistoryFolder
    ducksOtherAudio = settings.duckOtherAudioWhileDictating
    modos = settings.modos
    unAtajoDiloDecide = settings.unAtajoDiloDecide
    proveedores = settings.proveedores
    proveedorGeneralID = settings.proveedorGeneralID
    proveedoresConClave = Self.conClave(
      settings.proveedores,
      general: settings.proveedorGeneralID,
      modos: settings.modos,
      en: claves
    )
    textoPreferencias = settings.preferenciasDeTexto
    voiceVisual = settings.voiceVisual
    waveformStyle = settings.waveformStyle
    revealStyle = settings.revealStyle
    longDraftStyle = settings.longDraftStyle
    glowPalette = settings.glowPalette
    glowCenter = settings.glowCenter
    hudMetrics = HUDMetrics(scale: CGFloat(settings.hudScale))
  }
}

extension AppSettings {
  var sessionSettings: DictationSessionSettings {
    DictationSessionSettings(settings: self)
  }
}
