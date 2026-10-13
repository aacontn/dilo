import Foundation

/// Cuánto puede cambiar un modo lo que dictaste. Lo declara el modo, no el
/// modelo: es la vara con que se juzga lo que el modelo devuelve antes de
/// pegarlo.
///
/// Limpio y Correo no se pueden medir igual. Limpio arregla y no reescribe,
/// así que una palabra con contenido que no se dijo es una falla; Correo
/// reescribe a propósito, y ahí lo único intocable son los números, las
/// negaciones, las direcciones y la pregunta.
///
/// El `rawValue` se guarda con el modo en `diloModos`: no se renombra.
public enum Cuidado: String, Codable, CaseIterable, Sendable {
  /// Sólo limpiar: las mismas palabras, en el mismo orden.
  case limpieza
  /// Un poco: puede acortar y cambiar alguna palabra.
  case ligera
  /// Reescribir: otra forma, el mismo contenido.
  case reescritura
  /// Lo que haga falta: traducir, resumir. Sólo se caza la respuesta de
  /// asistente y la basura.
  case libre

  /// El de un modo guardado antes de que existiera el campo, o recién
  /// creado: sale de su id. Los modos propios reescriben, que es lo más
  /// cuidadoso que no rompe un Correo hecho a mano.
  public static func deFabrica(id: String) -> Cuidado {
    switch id {
    case "limpio": .limpieza
    case "mensaje": .ligera
    default: .reescritura
    }
  }
}
