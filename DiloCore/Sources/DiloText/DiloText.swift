import Foundation

/// Limpieza del texto dictado en español.
///
/// Hoy tiene lo mínimo para que el módulo exista y esté enlazado a los dos
/// targets desde el primer día (Tarea 0 del plan). Las reglas de verdad
/// —muletillas, voseo, spanglish técnico intacto, diccionario personal—
/// llegan en la Tarea 5.
public enum DiloText {
  /// Quita los espacios de los bordes y colapsa los espacios repetidos que
  /// deja el dictado cuando uno duda a mitad de frase.
  ///
  /// No toca los saltos de línea: dictar código y dictar un correo comparten
  /// esta función, y ahí los saltos son contenido.
  public static func limpiarEspacios(_ texto: String) -> String {
    let lineas = texto.split(separator: "\n", omittingEmptySubsequences: false).map { linea in
      linea
        .split(separator: " ", omittingEmptySubsequences: true)
        .joined(separator: " ")
    }
    return lineas.joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
