import Darwin
import Foundation
import IOKit

/// Cuánto baja y cuánto sube la red, en bytes por segundo.
public struct VelocidadDeRed: Equatable, Sendable {
  public var baja: Double
  public var sube: Double

  public init(baja: Double, sube: Double) {
    self.baja = baja
    self.sube = sube
  }
}

/// Cuánto del disco de arranque está ocupado.
public struct EspacioEnDisco: Equatable, Sendable {
  /// Del 0 al 100.
  public var ocupado: Double
  public var libre: Int64

  public init(ocupado: Double, libre: Int64) {
    self.ocupado = ocupado
    self.libre = libre
  }
}

/// GPU, red y disco: lo que Atoll y Stats muestran además de CPU y memoria,
/// pedido el 2026-09-24. Todo por APIs públicas —IOKit, `sysctl`, las
/// propiedades del volumen—; la temperatura queda fuera porque en Apple
/// Silicon sólo se lee por el SMC, que no tiene API pública.
extension MuestraDelSistema {
  /// Cuánto trabaja la GPU, de 0 a 100: lo que el propio driver anota en
  /// `PerformanceStatistics` («Device Utilization %»), el mismo número que
  /// usa Monitor de Actividad. Con más de una GPU, la más ocupada.
  public func gpu() -> Double? {
    var iterador: io_iterator_t = 0
    guard IOServiceGetMatchingServices(
      kIOMainPortDefault,
      IOServiceMatching("IOAccelerator"),
      &iterador
    ) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterador) }
    var mayor: Double?
    while true {
      let servicio = IOIteratorNext(iterador)
      guard servicio != 0 else { break }
      defer { IOObjectRelease(servicio) }
      guard
        let propiedad = IORegistryEntryCreateCFProperty(
          servicio, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue(),
        let estadisticas = propiedad as? [String: Any],
        let uso = estadisticas["Device Utilization %"] as? NSNumber
      else { continue }
      mayor = max(mayor ?? 0, uso.doubleValue)
    }
    return mayor.map { min(100, max(0, $0)) }
  }

  /// La velocidad de la red desde la lectura anterior. Como el CPU, es una
  /// diferencia: la primera lectura no tiene contra qué comparar.
  public func red(ahora: Date = Date()) -> VelocidadDeRed? {
    guard let bytes = Self.bytesDeRed() else { return nil }
    return intercambiarRed((bytes.entrada, bytes.salida, ahora))
  }

  /// El disco de arranque: cuánto está ocupado y cuánto queda libre, contando
  /// lo que macOS puede liberar si hace falta —lo mismo que dice Finder—.
  public func disco() -> EspacioEnDisco? {
    let claves: Set<URLResourceKey> = [
      .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
    ]
    guard let valores = try? URL(filePath: "/").resourceValues(forKeys: claves),
      let total = valores.volumeTotalCapacity, total > 0,
      let libre = valores.volumeAvailableCapacityForImportantUsage
    else { return nil }
    let ocupado = Double(Int64(total) - libre) / Double(total) * 100
    return EspacioEnDisco(ocupado: min(100, max(0, ocupado)), libre: libre)
  }

  /// Los bytes que entraron y salieron por todas las interfaces menos la de
  /// loopback, desde que arrancó el Mac. Por `NET_RT_IFLIST2` y no por
  /// `getifaddrs`: los contadores de éste son de 32 bits y se dan vuelta a
  /// los 4 GB, que una descarga grande pasa en minutos.
  static func bytesDeRed() -> (entrada: UInt64, salida: UInt64)? {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var largo = 0
    guard sysctl(&mib, UInt32(mib.count), nil, &largo, nil, 0) == 0, largo > 0 else { return nil }
    var memoria = [UInt8](repeating: 0, count: largo)
    guard sysctl(&mib, UInt32(mib.count), &memoria, &largo, nil, 0) == 0 else { return nil }
    var entrada: UInt64 = 0
    var salida: UInt64 = 0
    return memoria.withUnsafeBytes { crudo -> (UInt64, UInt64) in
      var desplazamiento = 0
      while desplazamiento + MemoryLayout<if_msghdr>.size <= largo {
        let base = crudo.baseAddress!.advanced(by: desplazamiento)
        let encabezado = base.loadUnaligned(as: if_msghdr.self)
        let tamaño = Int(encabezado.ifm_msglen)
        guard tamaño > 0 else { break }
        if Int32(encabezado.ifm_type) == RTM_IFINFO2,
          desplazamiento + MemoryLayout<if_msghdr2>.size <= largo {
          let mensaje = base.loadUnaligned(as: if_msghdr2.self)
          if mensaje.ifm_flags & IFF_LOOPBACK == 0 {
            entrada &+= mensaje.ifm_data.ifi_ibytes
            salida &+= mensaje.ifm_data.ifi_obytes
          }
        }
        desplazamiento += tamaño
      }
      return (entrada, salida)
    }
  }
}
