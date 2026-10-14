import Foundation

/// Un aviso del camino del error que ofrece **una** cosa con un clic.
///
/// La regla de la muesca es que un aviso no toma el mouse porque no tiene
/// nada que ofrecer. Éste sí: «falta el micrófono» se arregla en un panel
/// exacto de Ajustes del Sistema, y en una línea de 184 puntos no cabe
/// también la ruta para llegar a él. Un clic la abre. Es la misma excepción
/// que la tarjeta de un dictado sin pegar, por la misma razón.
struct AvisoConAccion: Equatable, Sendable {
  enum Accion: Equatable, Sendable {
    /// Abre un panel de Ajustes del Sistema (`Permiso.panelDeAjustes`).
    case abrirAjustes(String)
  }

  /// Una línea que cabe en la muesca: qué falta y que el clic lo arregla.
  let texto: String
  let accion: Accion

  /// Más que un aviso, que dura lo que tarda en leerse: éste además hay que
  /// alcanzar a llevarle el puntero. Menos que la tarjeta, que guarda un
  /// dictado; acá no se pierde nada si vence, se vuelve a decir al apretar.
  static let duracion = Duration.seconds(6)
}
