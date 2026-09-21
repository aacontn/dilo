import Foundation

/// Dónde y cómo se guarda cuál **Motor de voz** eligió la persona.
///
/// La clave vive acá y no en `AppSettings` para que la regla —qué pasa con un
/// valor guardado que ya no existe, cuál es el default— se pueda probar con
/// `swift test`, sin abrir Xcode. `AppSettings` sigue siendo el único que la
/// lee y la escribe en la app.
public enum EnginePreference {
  /// El `rawValue` guardado. No se renombra nunca (AGENTS.md).
  public static let clave = "speechEngine"

  /// Un valor que no reconocemos —una versión vieja, un disco a medio
  /// escribir— cae al default en vez de dejar a la persona sin motor.
  public static func leer(_ defaults: UserDefaults) -> SpeechEngineKind {
    guard let guardado = defaults.string(forKey: clave),
      let motor = SpeechEngineKind(rawValue: guardado)
    else { return .porDefecto }
    return motor
  }

  public static func guardar(_ motor: SpeechEngineKind, in defaults: UserDefaults) {
    defaults.set(motor.rawValue, forKey: clave)
  }
}
