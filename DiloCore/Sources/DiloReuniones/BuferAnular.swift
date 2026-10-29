import Foundation
import Synchronization

/// El búfer entre el hilo de audio y el que escribe a disco: un productor, un
/// consumidor, sin locks y sin pedir memoria del lado del audio.
///
/// El IOProc de Core Audio corre en un hilo de tiempo real: ahí no se escribe
/// a disco, no se toma un lock y no se pide memoria, o el audio se corta. Lo
/// que hace es bajar a mono lo que llega y copiarlo acá; una tarea lo vacía
/// cada segundo, lo remuestrea a 16 kHz y lo escribe (spec, «Nunca perder»).
///
/// Cada bloque lleva su tasa y su hora: si los AirPods cambian el formato a
/// media reunión, cada tramo se remuestrea con la tasa que tenía cuando llegó
/// y nada se estira.
public final class BuferAnular: @unchecked Sendable {
  public struct Bloque {
    public let muestras: UnsafeBufferPointer<Float>
    public let tasa: Double
    /// La hora del Mac de la primera muestra del bloque, en segundos.
    public let host: Double
  }

  public let muestrasPorBloque: Int
  public let bloques: Int

  private let datos: UnsafeMutablePointer<Float>
  private let largos: UnsafeMutablePointer<Int>
  private let tasas: UnsafeMutablePointer<Double>
  private let hosts: UnsafeMutablePointer<Double>
  /// Bloques escritos y leídos desde el principio. El índice del bloque es
  /// el contador módulo `bloques`; la diferencia es cuánto hay pendiente.
  private let escritos = Atomic<Int>(0)
  private let leidos = Atomic<Int>(0)
  private let perdidas = Atomic<Int>(0)

  /// - Parameters:
  ///   - segundos: cuánto aguanta sin que nadie lo vacíe. Se vacía cada
  ///     segundo; diez dan holgura de sobra para un disco lento.
  ///   - tasaMaxima: la tasa más alta que se espera del dispositivo.
  public convenience init(segundos: Double = 10, tasaMaxima: Double = 96_000, muestrasPorBloque: Int = 1_024) {
    let bloques = Int((segundos * tasaMaxima / Double(muestrasPorBloque)).rounded(.up))
    self.init(bloques: max(bloques, 2), muestrasPorBloque: muestrasPorBloque)
  }

  public init(bloques: Int, muestrasPorBloque: Int) {
    precondition(bloques > 1 && muestrasPorBloque > 0)
    self.bloques = bloques
    self.muestrasPorBloque = muestrasPorBloque
    datos = .allocate(capacity: bloques * muestrasPorBloque)
    datos.initialize(repeating: 0, count: bloques * muestrasPorBloque)
    largos = .allocate(capacity: bloques)
    largos.initialize(repeating: 0, count: bloques)
    tasas = .allocate(capacity: bloques)
    tasas.initialize(repeating: 0, count: bloques)
    hosts = .allocate(capacity: bloques)
    hosts.initialize(repeating: 0, count: bloques)
  }

  deinit {
    datos.deallocate()
    largos.deallocate()
    tasas.deallocate()
    hosts.deallocate()
  }

  /// Muestras que no entraron porque el búfer estaba lleno. Si alguna vez
  /// pasa de cero, la escritura se quedó atrás y el log lo tiene que decir.
  public var muestrasPerdidas: Int { perdidas.load(ordering: .relaxed) }

  /// Del lado del audio: `cuadros` cuadros de `canales` canales, bajados a
  /// mono promediando. `muestra(cuadro, canal)` lee del búfer de quien llama
  /// sin copiarlo; no escapa, así que no pide memoria.
  public func escribir(
    cuadros: Int, canales: Int, tasa: Double, host: Double, muestra: (Int, Int) -> Float
  ) {
    guard cuadros > 0, canales > 0, tasa > 0 else { return }
    var hecho = 0
    let escala = 1 / Float(canales)
    while hecho < cuadros {
      let e = escritos.load(ordering: .relaxed)
      let l = leidos.load(ordering: .acquiring)
      guard e - l < bloques else {
        perdidas.add(cuadros - hecho, ordering: .relaxed)
        return
      }
      let indice = e % bloques
      let n = min(muestrasPorBloque, cuadros - hecho)
      let destino = datos + indice * muestrasPorBloque
      for i in 0..<n {
        var suma: Float = 0
        for canal in 0..<canales { suma += muestra(hecho + i, canal) }
        destino[i] = suma * escala
      }
      largos[indice] = n
      tasas[indice] = tasa
      hosts[indice] = host + Double(hecho) / tasa
      escritos.store(e + 1, ordering: .releasing)
      hecho += n
    }
  }

  /// Del lado del disco: entrega cada bloque pendiente, en orden, y lo
  /// libera al volver. Devuelve cuántas muestras entregó.
  @discardableResult
  public func vaciar(_ cuerpo: (Bloque) -> Void) -> Int {
    var entregadas = 0
    var l = leidos.load(ordering: .relaxed)
    let e = escritos.load(ordering: .acquiring)
    while l < e {
      let indice = l % bloques
      let n = largos[indice]
      cuerpo(
        Bloque(
          muestras: UnsafeBufferPointer(start: datos + indice * muestrasPorBloque, count: n),
          tasa: tasas[indice],
          host: hosts[indice]
        )
      )
      entregadas += n
      l += 1
      leidos.store(l, ordering: .releasing)
    }
    return entregadas
  }
}
