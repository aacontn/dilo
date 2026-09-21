import Foundation

/// What lives inside the Edge Glow's shape while listening, a Settings pick.
enum HUDGlowCenterStyle: String, CaseIterable {
  /// The compute-pipeline particle cloud chasing the beam's sweeping
  /// origin (HUDParticleCloudView).
  case particles = "Particles"
  /// Prototype under feel test: the rotating Siri orb (GetStream artwork,
  /// unlicensed — see LICENSE-ARTWORK.txt) breathing with the voice.
  case siriOrb = "Siri Orb"

  /// El nombre visible; el rawValue es la elección guardada y no se toca.
  var title: String {
    switch self {
    case .particles: String(localized: "Partículas")
    case .siriOrb: String(localized: "Orbe")
    }
  }

  var isShippable: Bool {
    self != .siriOrb
  }

  static var settingsCases: [Self] {
#if DEBUG
    allCases
#else
    allCases.filter { $0.isShippable }
#endif
  }
}
