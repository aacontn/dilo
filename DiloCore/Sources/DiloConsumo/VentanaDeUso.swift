import Foundation

/// Cuánto se lleva gastado de una ventana de uso de una herramienta de IA.
///
/// Dos formas de saberlo, y cada proveedor da una u otra: el **porcentaje**
/// del límite del plan cuando la herramienta lo anota (Codex), o los
/// **tokens** gastados en la ventana cuando lo único que queda en disco es
/// cada mensaje con su uso (Claude Code). Un porcentaje inventado a partir de
/// tokens sería un número que se ve exacto y no lo es, así que se guarda lo
/// que hay y la muesca dice cuál de los dos es.
public struct VentanaDeUso: Equatable, Sendable {
  /// Del 0 al 100, o nil si la herramienta no lo dice.
  public var porcentaje: Double?
  /// Tokens gastados en la ventana, o nil si no se contaron.
  public var tokens: Int?
  /// Cuándo se vacía la ventana, o nil si no se sabe.
  public var seReiniciaEn: Date?
  /// Cuánto dura la ventana.
  public var duracion: TimeInterval

  public init(porcentaje: Double? = nil, tokens: Int? = nil, seReiniciaEn: Date?, duracion: TimeInterval) {
    self.porcentaje = porcentaje
    self.tokens = tokens
    self.seReiniciaEn = seReiniciaEn
    self.duracion = duracion
  }

  /// Una ventana que ya se reinició no lleva nada gastado, aunque la última
  /// línea anotada diga otra cosa: la herramienta sólo escribe cuando se usa.
  public func vigente(en ahora: Date) -> VentanaDeUso {
    guard let seReiniciaEn, seReiniciaEn <= ahora else { return self }
    return VentanaDeUso(
      porcentaje: porcentaje == nil ? nil : 0,
      tokens: tokens == nil ? nil : 0,
      seReiniciaEn: nil,
      duracion: duracion
    )
  }
}

/// Lo que se sabe del uso de una herramienta de IA ahora mismo.
public struct ConsumoDeIA: Equatable, Sendable {
  /// La ventana corta: cinco horas en Claude Code y en Codex.
  public var ventanaCorta: VentanaDeUso
  /// La semanal, cuando la herramienta la anota.
  public var ventanaSemanal: VentanaDeUso?
  /// El plan, tal como lo nombra la herramienta («plus», «pro»), si lo dice.
  public var plan: String?

  public init(ventanaCorta: VentanaDeUso, ventanaSemanal: VentanaDeUso? = nil, plan: String? = nil) {
    self.ventanaCorta = ventanaCorta
    self.ventanaSemanal = ventanaSemanal
    self.plan = plan
  }
}
