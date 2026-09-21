import Foundation

/// Lo último que dictaste, entero y separado en sus dos mitades.
///
/// Existe porque el dictado tiene un punto donde las palabras pueden
/// perderse: si el pegado falla, o si el modo reescribe algo que no era lo
/// que querías, lo dicho ya no está en ninguna parte. El historial no
/// alcanza: viene apagado de fábrica a propósito, y encenderlo para poder
/// recuperar un dictado sería cambiar la postura de privacidad por una
/// función de rescate.
///
/// Vive en la memoria de la sesión y se va con la app. No se escribe a disco,
/// no se sincroniza y no sobrevive a un cierre. Guarda **uno**: el último.
public struct UltimoDictado: Equatable, Sendable {
  /// Lo que se reconoció, antes de limpiar muletillas y antes de cualquier
  /// modo. Es lo único verdaderamente irrecuperable.
  public var original: String
  /// Lo que salió de las reglas de español: muletillas fuera, tus palabras
  /// corregidas. Es lo que se pega cuando ningún modo transformó.
  public var limpio: String
  /// Lo que el modo devolvió, o nil cuando no corrió ninguno o falló.
  public var transformado: String?
  /// El modo que corrió, por nombre. Nil cuando el dictado salió limpio.
  public var modo: String?
  public var cuando: Date

  public init(
    original: String,
    limpio: String,
    transformado: String? = nil,
    modo: String? = nil,
    cuando: Date = .now
  ) {
    self.original = original
    self.limpio = limpio
    self.transformado = transformado
    self.modo = modo
    self.cuando = cuando
  }

  /// Cuál de las dos mitades se copia.
  public enum Mitad: Equatable, Sendable {
    /// Lo que se entregó: el resultado del modo si hubo, si no el limpio.
    case entregado
    /// Lo que se dijo, tal cual salió del motor.
    case original
  }

  public func texto(_ mitad: Mitad) -> String {
    switch mitad {
    case .entregado: transformado ?? limpio
    case .original: original
    }
  }

  /// Si vale la pena ofrecer las dos mitades por separado. Cuando el modo no
  /// corrió —o devolvió exactamente lo mismo— un menú con dos opciones que
  /// copian el mismo texto es ruido.
  public var tieneDosMitades: Bool {
    texto(.entregado) != texto(.original)
  }

  /// Lo que el menú de la barra muestra como recordatorio de qué se va a
  /// copiar: las primeras palabras, en una línea.
  public func vistazo(_ mitad: Mitad, maximo: Int = 42) -> String {
    let linea = texto(mitad)
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .trimmingCharacters(in: .whitespaces)
    guard linea.count > maximo else { return linea }
    return String(linea.prefix(maximo)).trimmingCharacters(in: .whitespaces) + "…"
  }
}
