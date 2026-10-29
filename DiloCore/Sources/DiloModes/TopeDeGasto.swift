import Foundation

/// Lo que la **Conversación** lleva gastado este mes, en dólares.
///
/// Se guarda como texto en `diloConversacionGasto` («2026-10|0.4213»): el mes
/// y la suma, nada de lo conversado. El mes es el del calendario del Mac.
public struct GastoDelMes: Equatable, Sendable {
  /// «2026-10».
  public let mes: String
  public let dolares: Double

  public init(mes: String, dolares: Double) {
    self.mes = mes
    self.dolares = dolares
  }

  public var guardado: String { "\(mes)|\(dolares)" }

  public init?(guardado: String) {
    let partes = guardado.split(separator: "|")
    guard partes.count == 2, let dolares = Double(partes[1]), dolares >= 0 else { return nil }
    self.init(mes: String(partes[0]), dolares: dolares)
  }
}

/// El tope de gasto mensual de la **Conversación**: al llegar, la
/// conversación lo dice y no sigue llamando a Anthropic.
///
/// Alfonso, 2026-10-29: el costo de la sesión se acumula y hay un tope por
/// mes en Ajustes. Se mira **antes** de cada llamada, con lo ya gastado: un
/// turno empezado se termina aunque cruce el tope por unos centavos, porque
/// cortar una respuesta a medias cuesta lo mismo y no sirve de nada.
public enum TopeDeGasto {
  /// Cinco dólares al mes de fábrica: unas cuarenta conversaciones de diez
  /// minutos con Sonnet, que es más de lo que nadie habla con Dilo en un mes
  /// normal, y poco si algo se queda llamando solo.
  public static let deFabrica = 5.0
  /// Lo que ofrece Ajustes.
  public static let opciones: [Double] = [1, 2, 5, 10, 20, 50]

  /// «2026-10» para esta fecha, en el calendario gregoriano local.
  public static func mes(de fecha: Date, calendario: Calendar = .current) -> String {
    let partes = calendario.dateComponents([.year, .month], from: fecha)
    return String(format: "%04d-%02d", partes.year ?? 0, partes.month ?? 0)
  }

  /// Lo gastado este mes: lo guardado si es de este mes, cero si es de otro.
  public static func vigente(_ guardado: GastoDelMes?, ahora: Date, calendario: Calendar = .current) -> GastoDelMes {
    let mes = mes(de: ahora, calendario: calendario)
    guard let guardado, guardado.mes == mes else { return GastoDelMes(mes: mes, dolares: 0) }
    return guardado
  }

  /// Suma un costo al mes en curso.
  public static func sumar(
    _ dolares: Double, a guardado: GastoDelMes?, ahora: Date, calendario: Calendar = .current
  ) -> GastoDelMes {
    let actual = vigente(guardado, ahora: ahora, calendario: calendario)
    return GastoDelMes(mes: actual.mes, dolares: actual.dolares + max(0, dolares))
  }

  /// Si se puede llamar otra vez este mes.
  public static func puedeLlamar(_ guardado: GastoDelMes?, tope: Double, ahora: Date, calendario: Calendar = .current) -> Bool {
    vigente(guardado, ahora: ahora, calendario: calendario).dolares < tope
  }
}
