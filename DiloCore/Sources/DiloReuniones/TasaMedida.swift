import Foundation

/// A qué tasa llegan de verdad los cuadros de una **Pista**, medido con la hora
/// del Mac.
///
/// Lo que dice Core Audio no alcanza: el tap declara 48 kHz aunque el agregado
/// corra a la tasa de la salida, y unos audífonos Bluetooth bajan a 16 kHz en
/// llamada y vuelven a 44,1 sin que cambie el dispositivo. Medido en la reunión
/// del 2026-10-31: 16.000 cuadros por segundo leídos como 48.000 dejaron 5.333
/// muestras por segundo en el WAV, y 44.100 dejaron 14.700. La pista quedaba
/// corta, con los relojes intactos y sin ningún error.
///
/// Se cuentan los cuadros de una ventana de bloques seguidos y el resultado se
/// lleva a la tasa conocida más cercana: lo que el hardware entrega es una de
/// ésas, y el ruido de la hora de cada bloque no debe mover el remuestreo.
public struct TasaMedida: Sendable, Equatable {
  public static let conocidas: [Double] = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000]
  /// Cuánto audio seguido hace falta para creerle a la medida. Un ciclo de
  /// E/S más largo que el bloque del búfer anular reparte su hora a ojo, así
  /// que una ventana corta se equivocaría en ese caso.
  public static let ventana: Double = 2
  /// Más lejos que esto de toda tasa conocida es un tramo raro: no se usa.
  public static let holgura = 0.04
  /// Un salto así de la hora entre dos bloques es un hueco, no audio seguido.
  public static let hueco: Double = 0.2

  public private(set) var tasa: Double
  private var declarada: Double
  private var inicio: Double?
  private var anterior: Double?
  private var cuadros = 0

  public init(tasa: Double) {
    self.tasa = tasa
    declarada = tasa
  }

  /// Un bloque más. Devuelve la tasa con que leerlo. Si la declarada cambia
  /// (el tap se rearmó sobre otra salida), manda la nueva y se vuelve a medir.
  public mutating func bloque(cuadros n: Int, host: Double, declarada nueva: Double) -> Double {
    if nueva != declarada {
      declarada = nueva
      tasa = nueva
      reiniciar()
    }
    if let anterior, host - anterior > Self.hueco { reiniciar() }
    anterior = host
    if let inicio {
      let transcurrido = host - inicio
      if transcurrido >= Self.ventana {
        if let conocida = Self.conocida(cerca: Double(cuadros) / transcurrido) { tasa = conocida }
        self.inicio = host
        cuadros = 0
      }
    } else {
      inicio = host
    }
    cuadros += n
    return tasa
  }

  private mutating func reiniciar() {
    inicio = nil
    anterior = nil
    cuadros = 0
  }

  static func conocida(cerca medida: Double) -> Double? {
    guard let cercana = conocidas.min(by: { abs($0 - medida) < abs($1 - medida) }),
      abs(cercana - medida) / cercana <= holgura
    else { return nil }
    return cercana
  }
}
