import Foundation

/// Qué forma dibuja Dilo en una pantalla que no tiene notch.
///
/// Es una preferencia y no una propiedad de la pantalla: las dos formas caben
/// en el mismo hueco y elegir entre ellas es gusto, no hardware. Con una
/// carcasa real no aplica —ahí manda el recorte físico—, así que ninguna de
/// las dos ramas toca la geometría de un MacBook.
enum HUDEstiloSinNotch: String, CaseIterable, Sendable {
  /// Lo de siempre: la forma cuelga por debajo de la barra de menús, separada
  /// de ella y cerrada por los cuatro lados. Nunca tapa un status item
  /// (spec §8.2, issue #83). Es el default y lo sigue siendo.
  case pildora = "pildora"

  /// La imitación: la forma se pega al borde de arriba de la pantalla,
  /// centrada, con las esquinas de arriba rectas y las de abajo redondeadas,
  /// como el notch de un MacBook. Se dibuja encima de la franja central de la
  /// barra de menús, que macOS deja vacía —los menús de la app van a la
  /// izquierda y los status items a la derecha—.
  case notchSimulado = "notchSimulado"

  /// El nombre visible; el rawValue es la elección guardada y no se toca.
  var title: String {
    switch self {
    case .pildora: String(localized: "Píldora bajo la barra")
    case .notchSimulado: String(localized: "Notch simulado")
    }
  }
}
