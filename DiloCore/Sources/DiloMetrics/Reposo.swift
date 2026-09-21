import Darwin
import Foundation

/// RAM y CPU de una app que está arriba y no está haciendo nada.
public enum Reposo {
  /// Memoria real del proceso, en MB.
  ///
  /// **Se usa `footprint`, no `ps`, y la diferencia no es de detalle.** En la
  /// primera medición de Dilo, `ps -o rss` dijo 58 MB y `phys_footprint` dijo
  /// 17 MB para el mismo proceso en el mismo segundo. `rss` cuenta todas las
  /// páginas residentes, incluidas las limpias y compartidas de los frameworks
  /// del sistema, que están en memoria igual aunque Dilo no exista, y no cuenta
  /// lo que el compresor se llevó. `phys_footprint` es lo que el kernel le
  /// cobra al proceso: dirty + comprimido + mapeos de IOKit, el número que usa
  /// jetsam para decidir a quién mata y el que el Monitor de Actividad muestra
  /// como "Memoria". Con `rss` Dilo reprobaría un umbral que en realidad cumple
  /// con holgura.
  ///
  /// `vmmap --summary` da el mismo `phys_footprint`, pero redondeado a 0,1 MB y
  /// después de recorrer el espacio de direcciones completo. `footprint -f
  /// bytes --noCategories` da el byte exacto y casi no cuesta.
  public static func ramEnMB(pid: pid_t) throws -> Double {
    let resultado = try Concha.correr(
      "/usr/bin/footprint", ["-f", "bytes", "--noCategories", "-p", "\(pid)"]
    )
    guard resultado.codigo == 0 else {
      throw ErrorDeMedicion("footprint falló (\(resultado.codigo)): \(resultado.error)")
    }
    guard let bytes = primerNumero(en: resultado.salida, tras: "phys_footprint:") else {
      throw ErrorDeMedicion("no encontré phys_footprint en la salida de footprint")
    }
    return bytes / Umbrales.bytesPorMB
  }

  /// Segundos de CPU (usuario + sistema) consumidos por el proceso hasta ahora.
  ///
  /// Sale de `proc_pid_rusage`, que es la contabilidad del kernel en
  /// nanosegundos. Se mide el consumo acumulado en dos instantes y se divide la
  /// diferencia por el tiempo transcurrido: eso es el promedio verdadero de la
  /// ventana. `ps -o %cpu` no sirve acá porque es un promedio con decaimiento
  /// desde que el proceso nació, no de la ventana que pedimos.
  public static func segundosDeCPU(pid: pid_t) throws -> Double {
    var info = rusage_info_v4()
    let codigo = withUnsafeMutablePointer(to: &info) { puntero in
      puntero.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { crudo in
        proc_pid_rusage(pid, RUSAGE_INFO_V4, crudo)
      }
    }
    guard codigo == 0 else {
      throw ErrorDeMedicion("proc_pid_rusage falló para el pid \(pid) (errno \(errno))")
    }
    return Double(info.ri_user_time + info.ri_system_time) / 1_000_000_000
  }

  /// Porcentaje promedio de un núcleo durante `ventana` segundos.
  public static func cpuEnPorcentaje(pid: pid_t, ventana: TimeInterval) throws -> Double {
    let antesDeCPU = try segundosDeCPU(pid: pid)
    let antes = Date()
    dormir(ventana)
    let despuesDeCPU = try segundosDeCPU(pid: pid)
    let transcurrido = Date().timeIntervalSince(antes)
    guard transcurrido > 0 else { return 0 }
    return max(0, (despuesDeCPU - antesDeCPU) / transcurrido * 100)
  }

  static func primerNumero(en texto: String, tras etiqueta: String) -> Double? {
    guard let rango = texto.range(of: etiqueta) else { return nil }
    let resto = texto[rango.upperBound...]
    let digitos = resto.drop(while: { $0 == " " }).prefix(while: { $0.isNumber || $0 == "." })
    return Double(digitos)
  }
}
