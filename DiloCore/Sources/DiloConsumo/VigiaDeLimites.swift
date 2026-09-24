import Foundation

/// Un aviso de que una ventana de uso de IA se acerca a su límite.
public struct AvisoDeLimite: Equatable, Sendable {
  public let dato: DatoDeLaMuesca
  /// Qué ventana: la de cinco horas o la semanal.
  public let cual: FilaDelDetalle.Cual
  /// El umbral que se cruzó: 80 o 95.
  public let umbral: Int
  public let porcentaje: Double
  public let seReiniciaEn: Date?

  public init(
    dato: DatoDeLaMuesca,
    cual: FilaDelDetalle.Cual,
    umbral: Int,
    porcentaje: Double,
    seReiniciaEn: Date?
  ) {
    self.dato = dato
    self.cual = cual
    self.umbral = umbral
    self.porcentaje = porcentaje
    self.seReiniciaEn = seReiniciaEn
  }
}

/// Quien decide cuándo avisar que una IA se acerca a su límite.
///
/// Pedido del 2026-09-24: «aviso al acercarse al límite». La muesca se abre
/// un momento al cruzar el **80 %** y otra vez al cruzar el **95 %**, y nunca
/// dos veces por el mismo umbral de la misma ventana: un aviso que se repite
/// cada vez que se refresca el dato se deja de leer al tercero. Cuando la
/// ventana se reinicia, su hora de reinicio cambia y los umbrales vuelven a
/// estar armados.
///
/// Sólo mira porcentajes: los tokens de Claude contados de sus archivos no
/// tienen techo contra el que medirse, y un aviso inventado sobre ellos sería
/// peor que ninguno.
public struct VigiaDeLimites: Sendable {
  public static let umbrales = [80, 95]

  private var avisados: Set<String> = []

  public init() {}

  /// El aviso que toca dar ahora por esta ventana, o nil. No lo marca como
  /// dado: eso lo hace `marcar`, cuando de verdad se mostró —la muesca puede
  /// estar ocupada dictando y el aviso tiene que esperar su turno—.
  public func revisar(
    _ dato: DatoDeLaMuesca,
    _ cual: FilaDelDetalle.Cual,
    _ ventana: VentanaDeUso,
    ahora: Date
  ) -> AvisoDeLimite? {
    let vigente = ventana.vigente(en: ahora)
    guard let porcentaje = vigente.porcentaje,
      let umbral = Self.umbrales.last(where: { porcentaje >= Double($0) }),
      !avisados.contains(Self.clave(dato, cual, umbral, vigente.seReiniciaEn))
    else { return nil }
    return AvisoDeLimite(
      dato: dato,
      cual: cual,
      umbral: umbral,
      porcentaje: porcentaje,
      seReiniciaEn: vigente.seReiniciaEn
    )
  }

  /// Da el aviso por mostrado, y con él los umbrales más bajos de la misma
  /// ventana: saltar de 70 a 96 avisa una vez, la del 95.
  public mutating func marcar(_ aviso: AvisoDeLimite) {
    for umbral in Self.umbrales where umbral <= aviso.umbral {
      avisados.insert(Self.clave(aviso.dato, aviso.cual, umbral, aviso.seReiniciaEn))
    }
  }

  /// La ventana se reconoce por su hora de reinicio, redondeada a un cuarto
  /// de hora: el servidor puede devolverla con unos segundos de diferencia
  /// entre dos consultas y eso no es una ventana nueva.
  static func clave(_ dato: DatoDeLaMuesca, _ cual: FilaDelDetalle.Cual, _ umbral: Int, _ reinicio: Date?) -> String {
    let cuarto = reinicio.map { Int(($0.timeIntervalSince1970 / 900).rounded()) } ?? 0
    return "\(dato.rawValue)|\(cual)|\(umbral)|\(cuarto)"
  }
}
