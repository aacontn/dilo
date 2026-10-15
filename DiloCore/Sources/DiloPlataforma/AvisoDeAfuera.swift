import Foundation

/// Lo que «Mostrar en la muesca» (App Intents, `Dilo/Atajos/`) pide poner en
/// un segmento al costado: una palabra corta, un símbolo y cuánto dura.
///
/// Es el conector más barato que tiene Dilo (plan, cap. 5 §6): un atajo, un
/// `shortcuts run` desde un script o un *hook* ponen un aviso sin escribir
/// un `.appex`. Lo que llega lo escribió otro, así que se limpia acá, puro y
/// con tests, antes de que la muesca lo dibuje.
public struct AvisoDeAfuera: Equatable, Sendable {
  /// Lo que cabe en un segmento: mide a lo más 100 puntos con el ícono, y
  /// el texto entero va además en el tooltip.
  public static let largoMaximo = 24
  /// Lo que dura si nadie dice otra cosa.
  public static let duracionPorDefecto = 8
  /// Entre un segundo y dos minutos: un aviso que se queda más es un estado,
  /// y los estados de otros no viven en la muesca de Dilo.
  public static let duraciones = 1...120
  /// El ícono cuando el pedido no trae uno o trae uno que no existe.
  public static let simboloPorDefecto = "bell"

  public let texto: String
  public let simbolo: String
  public let segundos: Int

  /// - Parameter simboloExiste: si el nombre es un SF Symbol de verdad. Lo
  ///   pregunta la app (`NSImage(systemSymbolName:)`); acá se inyecta.
  public init?(texto: String, simbolo: String?, segundos: Int?, simboloExiste: (String) -> Bool) {
    let limpio = Self.limpiar(texto)
    guard !limpio.isEmpty else { return nil }
    self.texto = limpio
    let pedido = (simbolo ?? "").trimmingCharacters(in: .whitespaces)
    self.simbolo = !pedido.isEmpty && Self.pareceSimbolo(pedido) && simboloExiste(pedido)
      ? pedido : Self.simboloPorDefecto
    let s = segundos ?? Self.duracionPorDefecto
    self.segundos = min(max(s, Self.duraciones.lowerBound), Self.duraciones.upperBound)
  }

  /// Una línea, sin caracteres de control ni los que invierten la dirección
  /// del texto, con los espacios juntados y con tope. Corta por carácter,
  /// nunca a mitad de una letra con tilde.
  public static func limpiar(_ texto: String) -> String {
    let invisibles = CharacterSet.controlCharacters
      .union(.illegalCharacters)
      .union(CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"))
    let sinInvisibles = String(String.UnicodeScalarView(
      texto.unicodeScalars.map { invisibles.contains($0) ? " " : $0 }
    ))
    let unaLinea = sinInvisibles
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    return String(unaLinea.prefix(largoMaximo)).trimmingCharacters(in: .whitespaces)
  }

  /// Los SF Symbols se llaman con minúsculas, números y puntos
  /// (`bell.fill`, `01.circle`). Cualquier otra cosa ni se le pregunta a
  /// AppKit.
  static func pareceSimbolo(_ nombre: String) -> Bool {
    nombre.count <= 64 && nombre.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == ".") }
  }
}
