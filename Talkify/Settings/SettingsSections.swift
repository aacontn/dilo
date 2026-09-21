/// The Settings navigation model: labeled groups of sections with stable
/// typed IDs (CONTEXT.md: sections are registered in code; no empty or
/// disabled sections render).
enum SettingsSectionGroup: String, CaseIterable, Identifiable {
  case settings

  var id: Self { self }
  var title: String { rawValue.uppercased() }

  var sections: [SettingsSection] {
    SettingsSection.allCases.filter { $0.group == self && $0.isAvailable }
  }
}

enum SettingsSection: String, CaseIterable, Identifiable {
  case general
  case appearance
  case sounds
  case dictation
  case modos
  case palabras
  case historial
  case promptShaping
  case dropTranscription
  case readAloud
  case language
  case shortcuts
  case updates
  case insights
  case about

  var id: Self { self }
  var group: SettingsSectionGroup { .settings }

  /// El target de App Store no trae Sparkle: ahí las actualizaciones las
  /// entrega la tienda y un panel que no puede hacer nada sería una promesa
  /// falsa. Lo que no se puede hacer se esconde, no falla.
  var isAvailable: Bool {
    #if DILO_MAS
      self != .updates
    #else
      true
    #endif
  }

  var title: String {
    switch self {
    case .general: "General"
    case .appearance: "Apariencia"
    case .sounds: "Sonidos"
    case .dictation: "Dictado"
    case .modos: "Modos"
    case .palabras: "Tu español"
    case .historial: "Historial"
    case .promptShaping: "Transformar"
    case .dropTranscription: "Arrastrar archivos"
    case .readAloud: "Leer en voz alta"
    case .language: "Idioma"
    case .shortcuts: "Atajos"
    case .updates: "Actualizaciones"
    case .insights: "Actividad"
    case .about: "Acerca de"
    }
  }

  var subtitle: String {
    switch self {
    case .general: "Cómo arranca Dilo"
    case .appearance: "Cómo se ve la píldora mientras dictas"
    case .sounds: "Los sonidos de empezar y terminar"
    case .dictation: "Dónde aterriza lo que dictaste"
    case .modos: "Cada modo con su tecla y su IA"
    case .palabras: "Tus palabras y las muletillas"
    case .historial: "Lo que dictaste, buscable"
    case .promptShaping: "Reescribe lo que dictas, acá mismo"
    case .dropTranscription: "Transcribe audio y video que le sueltes"
    case .readAloud: "La voz que lee lo que seleccionas"
    case .language: "En qué idiomas dictas"
    case .shortcuts: "Qué teclas hacen qué"
    case .updates: "Mantén Dilo al día"
    case .insights: "Cuánto dictaste, guardado sólo acá"
    case .about: "Qué es Dilo y de quién es lo prestado"
    }
  }

  var icon: String {
    switch self {
    case .general: "gearshape"
    case .appearance: "sparkles"
    case .sounds: "waveform"
    case .dictation: "text.cursor"
    case .modos: "switch.2"
    case .palabras: "character.book.closed"
    case .historial: "clock.arrow.circlepath"
    case .promptShaping: "wand.and.sparkles"
    case .dropTranscription: "square.and.arrow.down"
    case .readAloud: "speaker.wave.2"
    case .language: "globe"
    case .shortcuts: "keyboard"
    case .updates: "arrow.down.circle"
    case .insights: "chart.bar.xaxis"
    case .about: "info.circle"
    }
  }
}
