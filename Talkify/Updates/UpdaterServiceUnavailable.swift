#if DILO_MAS

import AppKit
import Observation

/// El mismo `SparkleUpdaterService` para el target de App Store, sin Sparkle
/// ni red: ahí las actualizaciones las entrega la tienda. Existe para que la
/// raíz de composición y Ajustes no tengan que saber en qué build corren —
/// la sección Actualizaciones simplemente no se registra (SettingsSections).
@MainActor
@Observable
final class SparkleUpdaterService {
  let canCheckForUpdates = false
  let availableVersion: String? = nil
  let lastCheckedAt: Date? = nil

  var isBusy: (() -> Bool)?

  var automaticallyChecksForUpdates: Bool {
    get { false }
    set {}
  }

  var automaticallyDownloadsUpdates: Bool {
    get { false }
    set {}
  }

  func start() {}
  func checkForUpdates() {}
}

#endif
