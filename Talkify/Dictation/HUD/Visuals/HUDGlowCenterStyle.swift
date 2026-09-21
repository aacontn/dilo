import Foundation

/// What lives inside the Edge Glow's shape while listening, a Settings pick.
enum HUDGlowCenterStyle: String, CaseIterable {
  /// The compute-pipeline particle cloud chasing the beam's sweeping
  /// origin (HUDParticleCloudView).
  case particles = "Particles"

  /// El nombre visible; el rawValue es la elección guardada y no se toca.
  var title: String {
    switch self {
    case .particles: String(localized: "Partículas")
    }
  }

  var isShippable: Bool { true }

  static var settingsCases: [Self] {
#if DEBUG
    allCases
#else
    allCases.filter { $0.isShippable }
#endif
  }
}
