import DiloCapabilities
import Foundation

/// The Settings navigation model: labeled groups of sections with stable
/// typed IDs (CONTEXT.md: sections are registered in code; no empty or
/// disabled sections render).
enum SettingsSectionGroup: String, CaseIterable, Identifiable {
  /// Inicio, sola y sin rótulo arriba de todo: es la portada, no un ajuste.
  case portada
  case voz
  case settings
  case dilo

  var id: Self { self }
  /// El encabezado de la barra lateral. Salía del `rawValue` en mayúsculas, o
  /// sea "SETTINGS" en una app que habla español.
  var title: String {
    switch self {
    case .portada: ""
    case .voz: String(localized: "TU VOZ")
    case .settings: String(localized: "AJUSTES")
    case .dilo: String(localized: "DILO")
    }
  }

  var sections: [SettingsSection] {
    let orden: [SettingsSection]
    switch self {
    case .portada: orden = [.inicio]
    case .voz: orden = [.dictation, .modos, .palabras, .historial, .dropTranscription]
    case .settings: orden = [.claude, .motor, .shortcuts, .appearance, .datosDeLaMuesca, .general]
    case .dilo: orden = [.novedades, .about]
    }
    return orden.filter(\.isAvailable)
  }
}

enum SettingsSection: String, CaseIterable, Identifiable {
  case inicio
  case claude
  case general
  case appearance
  case datosDeLaMuesca
  case sounds
  case motor
  case dictation
  case modos
  case palabras
  case historial
  case dropTranscription
  case readAloud
  case language
  case shortcuts
  case updates
  case novedades
  case insights
  case about

  var id: Self { self }
  var group: SettingsSectionGroup {
    switch self {
    case .inicio: .portada
    case .claude: .settings
    case .dictation, .modos, .palabras, .historial, .dropTranscription, .insights: .voz
    case .general, .appearance, .datosDeLaMuesca, .sounds, .motor, .readAloud, .language,
      .shortcuts: .settings
    case .updates, .novedades, .about: .dilo
    }
  }

  /// Leer en voz alta es releer la selección de otra app, y en sandbox no
  /// se puede: lo que no se puede hacer se esconde, no falla.
  var isAvailable: Bool {
    switch self {
    case .readAloud:
      Anfitrion.actual.admite(.relecturaDelFoco)
    default:
      true
    }
  }

  var title: String {
    switch self {
    case .inicio: String(localized: "Inicio")
    case .claude: String(localized: "Claude")
    case .general: String(localized: "General")
    case .appearance: String(localized: "Apariencia")
    case .datosDeLaMuesca: String(localized: "Datos en la muesca")
    case .sounds: String(localized: "Sonidos")
    case .motor: String(localized: "Motor de voz")
    case .dictation: String(localized: "Dictado")
    case .modos: String(localized: "Modos")
    case .palabras: String(localized: "Tus palabras")
    case .historial: String(localized: "Historial")
    case .dropTranscription: String(localized: "Transcripciones")
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
    case .inicio: String(localized: "Cómo está Dilo, y lo que más se toca")
    case .claude: String(localized: "Tu clave de Anthropic y lo que Claude hace en Dilo")
    case .general: String(localized: "Cómo arranca Dilo y la voz que te lee")
    case .appearance: String(localized: "Cómo se ve la muesca, y cómo suena")
    case .datosDeLaMuesca: String(localized: "Qué se ve a los costados de la muesca")
    case .sounds: String(localized: "Los sonidos de empezar y terminar")
    case .motor: String(localized: "Quién convierte tu voz en texto")
    case .dictation: String(localized: "El micrófono, dónde aterriza el texto y en qué idioma")
    case .modos: String(localized: "Cada modo con su tecla y su IA")
    case .palabras: String(localized: "Tus palabras y las muletillas")
    case .historial: String(localized: "Lo que dictaste, buscable, y cuánto dictas")
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

  /// La sección con que abre la ventana cuando nadie pide otra y no se
  /// cerró hace poco (`SeccionAlAbrir`).
  static var portada: SettingsSection { .inicio }

  /// El color del ícono en la barra lateral: el de su familia.
  var colorDelIcono: Tono {
    let iconos = PaletaDeDilo.actual.iconosDeAjustes
    if self == .claude { return iconos.claude }
    switch group {
    case .portada: return iconos.portada
    case .voz: return iconos.voz
    case .settings: return iconos.sistema
    case .dilo: return iconos.dilo
    }
  }

  var icon: String {
    switch self {
    case .inicio: "house.fill"
    case .claude: "sparkle"
    case .general: "gearshape.fill"
    case .appearance: "paintpalette.fill"
    case .datosDeLaMuesca: "gauge.with.dots.needle.33percent"
    case .sounds: "waveform"
    case .motor: "cpu.fill"
    case .dictation: "mic.fill"
    case .modos: "wand.and.stars"
    case .palabras: "character.book.closed.fill"
    case .historial: "clock.arrow.circlepath"
    case .dropTranscription: "doc.text.fill"
    case .readAloud: "speaker.wave.2.fill"
    case .language: "globe"
    case .shortcuts: "keyboard.fill"
    case .updates: "arrow.down.circle.fill"
    case .novedades: "sparkles"
    case .insights: "chart.bar.xaxis"
    case .about: "info.circle.fill"
    }
  }
}
