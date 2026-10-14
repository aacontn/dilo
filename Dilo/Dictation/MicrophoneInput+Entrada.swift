import AVFAudio
import DiloEngines
import Foundation
import IOKit

extension AVAudioEngine {
  /// Fija **este** motor a un micrófono. No toca la entrada del sistema: los
  /// audífonos Bluetooth no caen al perfil de llamada porque nadie abre su
  /// micrófono, y la música sigue sonando bien.
  ///
  /// Va antes de leer el formato del bus y antes de `installTap`/`prepare`:
  /// después, el formato ya es el del otro dispositivo.
  func fijarEntrada(_ entrada: EntradaDeAudio) throws {
    try inputNode.auAudioUnit.setDeviceID(entrada.id)
  }
}

/// Si la tapa del portátil está cerrada (modo clamshell): con la tapa abajo
/// el micrófono del Mac entrega ceros. Lectura del registro de IOKit, API
/// pública; un Mac de escritorio no tiene la propiedad y da falso. Si en
/// sandbox no se puede leer, también da falso, y el detector de micrófono
/// muerto atrapa el interno mudo.
enum Tapa {
  static var estaCerrada: Bool {
    let raiz = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard raiz != 0 else { return false }
    defer { IOObjectRelease(raiz) }
    let valor = IORegistryEntryCreateCFProperty(
      raiz, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
    )
    return (valor?.takeRetainedValue() as? Bool) ?? false
  }
}
