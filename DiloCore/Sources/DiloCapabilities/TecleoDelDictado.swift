// Técnica observada en Ocelli 2.1 (reintento tecleado en trozos de hasta 16
// unidades UTF-16 cortados en límite de carácter, 6 ms entre trozos) y
// Spokenly 2.31 (saltos de línea como ⇧↩); implementación propia.
import Foundation

/// Cómo se teclea un dictado cuando el ⌘V no entró: en pedazos que los
/// eventos de teclado pueden llevar enteros.
///
/// No es el camino normal —hay editores que truncan o rechazan texto
/// tecleado así— sino el segundo intento, una sola vez, y sólo cuando
/// Accesibilidad probó que el pegado no movió el campo.
public enum TecleoDelDictado {
  /// Un pedazo de lo que se teclea.
  public enum Pedazo: Equatable, Sendable {
    /// Texto sin saltos de línea, de a lo más `unidadesPorEvento` unidades
    /// UTF-16, nunca partiendo un carácter.
    case texto(String)
    /// Un salto de línea, que se teclea como ⇧↩: un ↩ solo, en un chat,
    /// manda el mensaje a medio dictar.
    case saltoDeLinea
  }

  /// Cuánto texto lleva cada evento. Más que esto y algunas apps lo cortan.
  public static let unidadesPorEvento = 16
  /// La pausa entre un pedazo y el siguiente: la app alcanza a procesar
  /// cada uno antes de que llegue el otro.
  public static let pausa = Duration.milliseconds(6)

  /// Corta el texto en pedazos para teclear. Un emoji de dos unidades UTF-16
  /// o una letra con su tilde combinada nunca se parten.
  public static func pedazos(
    de texto: String,
    unidadesPorEvento: Int = unidadesPorEvento
  ) -> [Pedazo] {
    var pedazos: [Pedazo] = []
    var actual = ""
    var unidades = 0
    for caracter in texto {
      if caracter.isNewline {
        if !actual.isEmpty { pedazos.append(.texto(actual)) }
        actual = ""
        unidades = 0
        pedazos.append(.saltoDeLinea)
        continue
      }
      let largo = caracter.utf16.count
      if unidades + largo > unidadesPorEvento, !actual.isEmpty {
        pedazos.append(.texto(actual))
        actual = ""
        unidades = 0
      }
      actual.append(caracter)
      unidades += largo
    }
    if !actual.isEmpty { pedazos.append(.texto(actual)) }
    return pedazos
  }
}
