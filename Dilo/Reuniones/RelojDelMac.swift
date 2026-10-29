import Darwin
import DiloReuniones
import Foundation

/// La hora del Mac que comparten las dos pistas: `mach_absolute_time`, la
/// misma que trae `AudioTimeStamp.mHostTime` y `AVAudioTime.hostTime`. Con
/// ella se escriben las anclas de `relojes.jsonl` (spec, «Alineación»).
enum RelojDelMac {
  private static let base: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
  }()

  /// Ticks del host a segundos.
  static func segundos(ticks: UInt64) -> Double {
    Double(ticks) * Double(base.numer) / Double(base.denom) / 1_000_000_000
  }

  static var ahora: Double { segundos(ticks: mach_absolute_time()) }

  /// Este proceso, para que al volver a abrir Dilo se sepa si la reunión que
  /// dice «grabando» sigue viva.
  static var esteProceso: ProcesoQueGraba {
    let pid = ProcessInfo.processInfo.processIdentifier
    return ProcesoQueGraba(pid: pid, arranque: arranque(de: pid) ?? Date())
  }

  /// Si el proceso sigue corriendo y es el mismo: un pid se reusa, la hora de
  /// arranque no.
  static func estaVivo(_ proceso: ProcesoQueGraba) -> Bool {
    guard kill(proceso.pid, 0) == 0 || errno == EPERM else { return false }
    guard let arranque = arranque(de: proceso.pid) else { return false }
    return abs(arranque.timeIntervalSince(proceso.arranque)) < 1
  }

  /// Cuándo arrancó un proceso, por `sysctl` (API pública, sin permisos).
  static func arranque(de pid: Int32) -> Date? {
    var info = kinfo_proc()
    var largo = MemoryLayout<kinfo_proc>.stride
    var nombre: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&nombre, 4, &info, &largo, nil, 0) == 0, largo > 0 else { return nil }
    let t = info.kp_proc.p_starttime
    return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
  }
}
