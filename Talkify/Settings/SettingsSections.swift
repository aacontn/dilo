import DiloCapabilities
import Foundation

/// The Settings navigation model: labeled groups of sections with stable
/// typed IDs (CONTEXT.md: sections are registered in code; no empty or
/// disabled sections render).
enum SettingsSectionGroup: String, CaseIterable, Identifiable {
  case settings

  var id: Self { self }
  /// El encabezado de la barra lateral. Salía del `rawValue` en mayúsculas, o
  /// sea "SETTINGS" en una app que habla español.
  var title: String {
    switch self {
    case .settings: String(localized: "AJUSTES")
    }
  }

  var sections: [SettingsSection] {
    SettingsSection.allCases.filter { $0.group == self && $0.isAvailable }
  }
}

enum SettingsSection: String, CaseIterable, Identifiable {
  case general
  case appearance
  case sounds
  case motor
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
  case novedades
  case insights
  case about

  var id: Self { self }
  var group: SettingsSectionGroup { .settings }

  /// El target de App Store no trae Sparkle: ahí las actualizaciones las
  /// entrega la tienda y un panel que no puede hacer nada sería una promesa
  /// falsa. Lo mismo con Leer en voz alta, que es releer la selección de otra
  /// app y el sandbox no lo permite. Lo que no se puede hacer se esconde, no
  /// falla.
  var isAvailable: Bool {
    switch self {
    case .updates:
      #if DILO_MAS
        false
      #else
        true
      #endif
    case .readAloud:
      Anfitrion.actual.admite(.relecturaDelFoco)
    default:
      true
    }
  }

  var title: String {
    switch self {
    case .general: String(localized: "General")
    case .appearance: String(localized: "Apariencia")
    case .sounds: String(localized: "Sonidos")
    case .motor: String(localized: "Motor")
    case .dictation: String(localized: "Dictado")
    case .modos: String(localized: "Modos")
    case .palabras: String(localized: "Tu español")
    case .historial: String(localized: "Historial")
    case .promptShaping: String(localized: "Transformar")
    case .dropTranscription: String(localized: "Arrastrar archivos")
    case .readAloud: String(localized: "Leer en voz alta")
    case .language: String(localized: "Idioma")
    case .shortcuts: String(localized: "Atajos")
    case .updates: String(localized: "Actualizaciones")
    case .insights: String(localized: "Actividad")
    case .novedades: String(localized: "Novedades")
    case .about: String(localized: "Acerca de")
    }
  }

  var subtitle: String {
    switch self {
    case .general: String(localized: "Cómo arranca Dilo")
    case .appearance: String(localized: "Cómo se ve la píldora mientras dictas")
    case .sounds: String(localized: "Los sonidos de empezar y terminar")
    case .motor: String(localized: "Quién convierte tu voz en texto")
    case .dictation: String(localized: "Dónde aterriza lo que dictaste")
    case .modos: String(localized: "Cada modo con su tecla y su IA")
    case .palabras: String(localized: "Tus palabras y las muletillas")
    case .historial: String(localized: "Lo que dictaste, buscable")
    case .promptShaping: String(localized: "Reescribe lo que dictas, acá mismo")
    case .dropTranscription: String(localized: "Transcribe audio y video que le sueltes")
    case .readAloud: String(localized: "La voz que lee lo que seleccionas")
    case .language: String(localized: "En qué idiomas dictas")
    case .shortcuts: String(localized: "Qué teclas hacen qué")
    case .updates: String(localized: "Mantén Dilo al día")
    case .insights: String(localized: "Cuánto dictaste, guardado sólo acá")
    case .novedades: String(localized: "Qué trae la versión que tienes")
    case .about: String(localized: "Qué es Dilo y de quién es lo prestado")
    }
  }

  var icon: String {
    switch self {
    case .general: "gearshape"
    case .appearance: "sparkles"
    case .sounds: "waveform"
    case .motor: "cpu"
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
    case .novedades: "megaphone"
    case .insights: "chart.bar.xaxis"
    case .about: "info.circle"
    }
  }
}
