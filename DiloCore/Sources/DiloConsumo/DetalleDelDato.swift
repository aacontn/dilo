import Foundation

/// Una fila del detalle que abre el hover: qué ventana, cuánto va y cuándo se
/// reinicia.
///
/// El costado de la muesca tiene lugar para un número; el panel del hover,
/// donde el mouse está encima a propósito, tiene lugar para el resto: la
/// ventana semanal de Codex, los tokens del bloque de Claude al lado del
/// porcentaje del plan, y la hora de reinicio de cada una.
///
/// El nombre de la fila (`Cual`) se escribe en la app, que es la que traduce;
/// el valor ya viene escrito, porque son cifras.
public struct FilaDelDetalle: Equatable, Sendable {
  public enum Cual: Equatable, Sendable {
    /// La ventana de cinco horas, en porcentaje (Codex).
    case cincoHoras
    /// La ventana semanal, en porcentaje (Codex, y Claude con el plan).
    case semana
    /// Los tokens del bloque de cinco horas, contados de los archivos (Claude).
    case tokensDelBloque
    /// El porcentaje del plan en la ventana de cinco horas (Claude, opcional).
    case planCincoHoras
    /// Lo que marca ahora mismo (CPU, RAM, GPU).
    case ahora
    /// Lo que baja la red.
    case baja
    /// Lo que sube la red.
    case sube
    /// Lo que queda libre en el disco.
    case libre
  }

  public var cual: Cual
  public var valor: String
  /// Del 0 al 100 cuando es un porcentaje, para el color.
  public var nivel: Double?
  public var seReiniciaEn: Date?

  public init(cual: Cual, valor: String, nivel: Double? = nil, seReiniciaEn: Date? = nil) {
    self.cual = cual
    self.valor = valor
    self.nivel = nivel
    self.seReiniciaEn = seReiniciaEn
  }
}

/// Qué filas lleva el detalle de cada dato. Puro: recibe lo leído y la hora.
public enum DetalleDelDato {
  /// Codex: la ventana de cinco horas y la semanal, cada una con su reinicio.
  public static func codex(_ consumo: ConsumoDeIA?, ahora: Date) -> [FilaDelDetalle] {
    guard let consumo else { return [] }
    var filas = [fila(.cincoHoras, consumo.ventanaCorta, ahora: ahora)]
    if let semanal = consumo.ventanaSemanal {
      filas.append(fila(.semana, semanal, ahora: ahora))
    }
    return filas.compactMap { $0 }
  }

  /// Claude: los tokens del bloque, y el porcentaje del plan si se pidió y
  /// llegó. Con el plan la semanal se deja fuera: dos filas es lo que cabe
  /// en el panel sin volverlo una ventana.
  public static func claude(tokens: ConsumoDeIA?, plan: ConsumoDeIA?, ahora: Date) -> [FilaDelDetalle] {
    var filas: [FilaDelDetalle?] = []
    if let tokens { filas.append(fila(.tokensDelBloque, tokens.ventanaCorta, ahora: ahora)) }
    if let plan { filas.append(fila(.planCincoHoras, plan.ventanaCorta, ahora: ahora)) }
    return filas.compactMap { $0 }
  }

  /// CPU o RAM: lo que marca ahora.
  public static func sistema(_ valor: Double?) -> [FilaDelDetalle] {
    guard let valor else { return [] }
    return [FilaDelDetalle(cual: .ahora, valor: TextoDelDato.porcentaje(valor), nivel: valor)]
  }

  /// La red: lo que baja y lo que sube. Sin nivel: una velocidad no tiene
  /// techo contra el que medirse.
  public static func red(_ velocidad: VelocidadDeRed?) -> [FilaDelDetalle] {
    guard let velocidad else { return [] }
    return [
      FilaDelDetalle(cual: .baja, valor: TextoDelDato.velocidad(velocidad.baja) + "/s"),
      FilaDelDetalle(cual: .sube, valor: TextoDelDato.velocidad(velocidad.sube) + "/s"),
    ]
  }

  /// El disco: cuánto está ocupado y cuánto queda.
  public static func disco(_ espacio: EspacioEnDisco?) -> [FilaDelDetalle] {
    guard let espacio else { return [] }
    return [
      FilaDelDetalle(cual: .ahora, valor: TextoDelDato.porcentaje(espacio.ocupado), nivel: espacio.ocupado),
      FilaDelDetalle(cual: .libre, valor: TextoDelDato.gigas(espacio.libre)),
    ]
  }

  static func fila(_ cual: FilaDelDetalle.Cual, _ ventana: VentanaDeUso, ahora: Date) -> FilaDelDetalle? {
    let vigente = ventana.vigente(en: ahora)
    guard let valor = TextoDelDato.valor(vigente) else { return nil }
    return FilaDelDetalle(
      cual: cual,
      valor: valor,
      nivel: vigente.porcentaje,
      seReiniciaEn: vigente.seReiniciaEn
    )
  }
}
