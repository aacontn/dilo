import Foundation

/// Cada cuánto Dilo suelta el modelo de la RAM cuando no dictas.
///
/// El modelo de Parakeet ocupa decenas de MB cargado y el spec §3 pide menos
/// de 60 MB en reposo; el README promete que "el modelo se descarga solo de la
/// RAM cuando no dictas". Esto es esa promesa, con el mismo gesto que el
/// *Unload Model* de Handy.
///
/// El `rawValue` se guarda en `UserDefaults` y no se renombra nunca
/// (AGENTS.md). El nombre visible va en `title`.
public enum DescargaPorReposo: String, CaseIterable, Sendable {
  case unMinuto
  case cincoMinutos
  case quinceMinutos
  case nunca

  /// **Cinco minutos.** Corto no sirve: una pausa entre dos frases pagaría
  /// otra carga de veinte segundos. Largo tampoco: la app que quedó abierta
  /// toda la tarde se queda con la RAM tomada para nada.
  public static let porDefecto: DescargaPorReposo = .cincoMinutos

  /// Cuánto se espera sin dictar. `nil` es "nunca": el modelo se queda.
  public var intervalo: Duration? {
    switch self {
    case .unMinuto: .seconds(60)
    case .cincoMinutos: .seconds(300)
    case .quinceMinutos: .seconds(900)
    case .nunca: nil
    }
  }

  public var title: String {
    switch self {
    case .unMinuto: "Tras 1 minuto"
    case .cincoMinutos: "Tras 5 minutos"
    case .quinceMinutos: "Tras 15 minutos"
    case .nunca: "Nunca"
    }
  }
}

/// Dónde y cómo se guarda cada cuánto se suelta el modelo.
///
/// Igual que `EnginePreference`: la clave y la regla del valor desconocido
/// viven acá para poder probarlas con `swift test`, y `AppSettings` sigue
/// siendo el único que las lee y las escribe en la app.
public enum PreferenciaDeReposo {
  /// El `rawValue` guardado. No se renombra nunca (AGENTS.md).
  public static let clave = "descargarModeloTras"

  /// Un valor que no reconocemos —una versión vieja, un disco a medio
  /// escribir— cae al default en vez de dejar el modelo pegado en la RAM.
  public static func leer(_ defaults: UserDefaults) -> DescargaPorReposo {
    guard let guardado = defaults.string(forKey: clave),
      let elegido = DescargaPorReposo(rawValue: guardado)
    else { return .porDefecto }
    return elegido
  }

  public static func guardar(_ elegido: DescargaPorReposo, in defaults: UserDefaults) {
    defaults.set(elegido.rawValue, forKey: clave)
  }
}
