import Foundation

/// Lo que oye la **escucha de nombres**: los últimos segundos del micrófono a
/// 16 kHz, en la RAM, pisándose solos.
///
/// Es todo lo que la escucha guarda, y nunca sale de acá: no va a disco, ni a
/// un log, ni al historial, ni fuera del Mac. Lo que no se pidió a tiempo se
/// pisa con lo que sigue; `vaciar()` lo borra con ceros al pausar o apagar.
///
/// Las muestras llevan un índice absoluto desde que se prendió —el mismo de
/// `VentanaDeEscucha`—, y un tramo que ya se pisó no se puede pedir. No es
/// seguro entre hilos: lo usa un solo actor, el que también corre el detector
/// de voz.
public struct BuferDeEscucha: Sendable {
  public let capacidad: Int
  private var muestras: [Float]
  /// Cuántas muestras entraron desde que se prendió o se vació.
  public private(set) var escritas = 0

  /// - Parameter segundos: lo que aguanta. Tiene que caber el llamado más
  ///   largo (`VentanaDeEscucha.Ajustes.maximoDelLlamado`) más lo que se pide
  ///   de antes de la voz.
  public init(segundos: Double = 12, tasa: Double = 16_000) {
    capacidad = max(1, Int(segundos * tasa))
    muestras = [Float](repeating: 0, count: capacidad)
  }

  /// La muestra más vieja que todavía se puede pedir.
  public var desde: Int { max(0, escritas - capacidad) }

  public mutating func agregar(_ nuevas: [Float]) {
    // Si llega más de lo que cabe, sólo importa lo último.
    let utiles = nuevas.count > capacidad ? nuevas.suffix(capacidad) : nuevas[...]
    escritas += nuevas.count - utiles.count
    for muestra in utiles {
      muestras[escritas % capacidad] = muestra
      escritas += 1
    }
  }

  /// El tramo pedido, o la parte que todavía no se pisó. Vacío si ya no
  /// queda nada de él.
  public func tramo(_ rango: Range<Int>) -> [Float] {
    let inicio = max(rango.lowerBound, desde)
    let fin = min(rango.upperBound, escritas)
    guard inicio < fin else { return [] }
    return (inicio..<fin).map { muestras[$0 % capacidad] }
  }

  /// Borra todo con ceros y vuelve a contar desde cero.
  public mutating func vaciar() {
    for indice in muestras.indices { muestras[indice] = 0 }
    escritas = 0
  }
}
