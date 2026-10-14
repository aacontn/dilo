import Foundation

/// Los dos gestos de un mismo **Gatillo** y lo que pasa con un Esc.
///
/// Mantener es hablar; un toque corto traba el dictado hasta el siguiente
/// toque (manos libres). Lo único que separa un gesto del otro es cuánto
/// duró el apretón, y ese número es de la persona: hay quien toca rápido y
/// hay quien empieza a hablar antes de terminar de apretar. Por eso vive
/// acá, con nombre, origen y rango, y Ajustes → Atajos lo mueve.
enum GestoDelGatillo {
  /// El umbral de fábrica, en milisegundos: soltar antes cuenta como toque
  /// corto. Es el de `CONTEXT.md` («Soltar antes de 250 ms cuenta como toque
  /// corto»), heredado del árbol de origen y el que Dilo usó siempre. Otras
  /// apps de dictado lo ponen entre 300 y 400; se queda en 250 hasta que
  /// Alfonso lo mida con su propia mano, y ahora lo puede mover sin un
  /// build.
  static let umbralDeFabricaMs = 250

  /// Por debajo de 150 ms un toque decidido se lee como sostenido —el
  /// apretón de un dedo rápido ya dura unos 100—; por arriba de 600, decir
  /// «sí» sosteniendo la tecla traba la sesión en vez de terminarla.
  static let rangoDelUmbralMs = 150...600

  /// Cuánto se puede deshacer un Esc: cinco segundos, lo que tarda alguien
  /// en darse cuenta de que el Esc era para la app y no para Dilo. Lo dicho
  /// vive en RAM ese rato y nunca en el historial.
  static let ventanaParaDeshacer = Duration.seconds(5)

  /// Las claves de `UserDefaults`. No se renombran: renombrar una borra la
  /// preferencia de quien ya la tiene, en silencio.
  static let claveDelUmbral = "diloUmbralDeToqueMs"
  static let claveDeDeshacer = "diloDeshacerCancelacion"

  /// El umbral guardado, dentro del rango. Un valor fuera —de una versión que
  /// dejaba otro rango— se acerca al borde en vez de perderse.
  static func umbralMs(en defaults: UserDefaults) -> Int {
    guard defaults.object(forKey: claveDelUmbral) != nil else { return umbralDeFabricaMs }
    return min(max(defaults.integer(forKey: claveDelUmbral), rangoDelUmbralMs.lowerBound), rangoDelUmbralMs.upperBound)
  }

  /// Deshacer un Esc viene encendido: sin él, un Esc que iba para la app
  /// se lleva el dictado entero.
  static func deshacer(en defaults: UserDefaults) -> Bool {
    defaults.object(forKey: claveDeDeshacer) == nil ? true : defaults.bool(forKey: claveDeDeshacer)
  }
}
