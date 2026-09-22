import Foundation

/// The waveform looks the user can choose, each mimicking a reference
/// implementation, all fed by the same live level history:
/// - Article: "Writing a High-Performance Audio Wave in SwiftUI" — the
///   original bar architecture.
/// - Silver: our styling of the same bars.
/// - Capsules / Chart Line / Chart Area: jonathanjr3/AudioWaveform's chart
///   types (Chart Line carries its own conveyor renderer and treatment).
/// - Dots / Curve: lkora/WaveformScrubber's DotDrawer and BezierCurveDrawer.
/// - Filled: AudioKit/Waveform's min/max region.
/// - Siri Wave: alfianlosari/SiriWaveView's classic Siri 9 multi-wave (MIT,
///   © 2019 Noah Chalifour; carries its own colors and treatment).
/// - Brasas: la onda del overlay de Dilo-Tauri, traducida a SwiftUI
///   (`HUDOndaDeBrasas`). Activo propio y el juego de fábrica desde el
///   2026-09-21: es la onda que Dilo ya tenía, y la que Alfonso reconoce.
///
/// rawValue is the UserDefaults value existing picks are stored under —
/// renaming a case silently resets that preference.
enum HUDWaveformStyle: String, CaseIterable {
  case article = "Article"
  case silver = "Silver"
  case capsules = "Capsules"
  case chartLine = "Chart Line"
  case chartArea = "Chart Area"
  case dots = "Dots"
  case curve = "Curve"
  case filled = "Filled"
  case siriWave = "Siri Wave"
  case brasas = "Brasas"

  /// El nombre visible; el rawValue es la elección guardada y no se toca.
  var title: String {
    switch self {
    case .article: String(localized: "Barras")
    case .silver: String(localized: "Plata")
    case .capsules: String(localized: "Cápsulas")
    case .chartLine: String(localized: "Línea")
    case .chartArea: String(localized: "Área")
    case .dots: String(localized: "Puntos")
    case .curve: String(localized: "Curva")
    case .filled: String(localized: "Relleno")
    case .siriWave: String(localized: "Ola")
    case .brasas: String(localized: "Brasas")
    }
  }
}
