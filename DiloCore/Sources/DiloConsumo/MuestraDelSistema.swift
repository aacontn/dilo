import Darwin
import Foundation

/// Cuánto CPU y cuánta memoria está usando el Mac entero.
///
/// Lo mismo que lee Monitor de Actividad, por las mismas llamadas de Mach: no
/// pide permisos y funciona igual dentro del sandbox. El CPU es una
/// diferencia entre dos lecturas —el sistema cuenta ticks desde que arrancó—,
/// así que la primera muestra no tiene CPU y las siguientes sí.
public final class MuestraDelSistema: @unchecked Sendable {
  private var ticksAnteriores: (ocupados: UInt64, total: UInt64)?
  private var redAnterior: (entrada: UInt64, salida: UInt64, cuando: Date)?
  private let candado = NSLock()

  /// Guarda la lectura nueva de la red y devuelve la velocidad contra la
  /// anterior. Un contador que retrocede —una interfaz que se fue— no da una
  /// velocidad negativa: esa vuelta se salta.
  func intercambiarRed(_ nueva: (entrada: UInt64, salida: UInt64, cuando: Date)) -> VelocidadDeRed? {
    candado.lock()
    defer { candado.unlock() }
    defer { redAnterior = nueva }
    guard let antes = redAnterior else { return nil }
    let segundos = nueva.cuando.timeIntervalSince(antes.cuando)
    guard segundos > 0, nueva.entrada >= antes.entrada, nueva.salida >= antes.salida else { return nil }
    return VelocidadDeRed(
      baja: Double(nueva.entrada - antes.entrada) / segundos,
      sube: Double(nueva.salida - antes.salida) / segundos
    )
  }

  public init() {}

  /// El CPU usado desde la lectura anterior, de 0 a 100.
  public func cpu() -> Double? {
    guard let ahora = Self.ticks() else { return nil }
    candado.lock()
    defer { candado.unlock() }
    defer { ticksAnteriores = ahora }
    guard let antes = ticksAnteriores, ahora.total > antes.total else { return nil }
    let ocupados = Double(ahora.ocupados &- antes.ocupados)
    let total = Double(ahora.total - antes.total)
    return min(100, max(0, ocupados / total * 100))
  }

  /// La memoria ocupada, de 0 a 100: activa, fija y comprimida, que es lo que
  /// Monitor de Actividad llama «memoria usada» menos la caché de archivos.
  public func ram() -> Double? {
    var info = vm_statistics64()
    var cuenta = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
    )
    let resultado = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(cuenta)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &cuenta)
      }
    }
    guard resultado == KERN_SUCCESS else { return nil }
    let pagina = Double(getpagesize())
    let usada = Double(UInt64(info.active_count) + UInt64(info.wire_count)
      + UInt64(info.compressor_page_count)) * pagina
    let total = Double(ProcessInfo.processInfo.physicalMemory)
    guard total > 0 else { return nil }
    return min(100, max(0, usada / total * 100))
  }

  private static func ticks() -> (ocupados: UInt64, total: UInt64)? {
    var carga = host_cpu_load_info()
    var cuenta = mach_msg_type_number_t(
      MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let resultado = withUnsafeMutablePointer(to: &carga) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(cuenta)) {
        host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &cuenta)
      }
    }
    guard resultado == KERN_SUCCESS else { return nil }
    let usuario = UInt64(carga.cpu_ticks.0)
    let sistema = UInt64(carga.cpu_ticks.1)
    let ocioso = UInt64(carga.cpu_ticks.2)
    let amable = UInt64(carga.cpu_ticks.3)
    let ocupados = usuario + sistema + amable
    return (ocupados, ocupados + ocioso)
  }
}
