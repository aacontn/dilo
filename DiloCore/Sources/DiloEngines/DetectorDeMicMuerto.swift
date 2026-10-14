import Accelerate
import Foundation

// Técnica observada en Wispr Flow (aviso a 125 trozos de ceros = 5 s, escalado
// a 375 = 15 s, reabrir el micrófono en caliente si arranca mudo);
// implementación propia.
/// Distingue un micrófono que entrega **ceros exactos** de una sala callada.
///
/// Una sala en silencio nunca da cero digital: siempre hay piso de ruido. Los
/// ceros exactos son un micrófono sin permiso de TCC, una tapa cerrada, un
/// dispositivo virtual colgado o un Bluetooth a medio cambiar de perfil. El
/// watchdog del HUD (sin niveles por 600 ms, o 2,5 s al abrir) cubre el motor
/// que dejó de llamar; éste cubre el que llama con nada adentro.
///
/// Se mide en **audio recibido**, no en reloj: un hilo de audio atrasado no
/// dispara avisos falsos, y los tests no esperan segundos de verdad.
public struct DetectorDeMicMuerto: Sendable, Equatable {
  public enum Evento: Sendable, Equatable {
    /// Arrancó mudo: reabrir el motor en caliente, una vez, sin cortar la
    /// sesión.
    case reabrir
    /// 5 s de ceros: la muesca lo dice.
    case avisar
    /// 15 s de ceros: la muesca manda a elegir otro micrófono.
    case escalar
    /// Volvió el sonido después de un aviso: la muesca se despeja.
    case revivio
  }

  public static let reabrirTras: TimeInterval = 1.0
  public static let avisarTras: TimeInterval = 5.0
  public static let escalarTras: TimeInterval = 15.0

  private var segundosEnCero: TimeInterval = 0
  private var oyoAlgo = false
  private var reabrio = false
  private var aviso = false
  private var escalo = false

  public init() {}

  /// Si ahora mismo hay un aviso a la vista (avisó o escaló, y no revivió).
  public var avisando: Bool { aviso }

  /// Un búfer del tap. `pico` es el máximo absoluto de sus muestras.
  public mutating func procesar(cuadros: Int, tasa: Double, pico: Float) -> Evento? {
    guard tasa > 0, cuadros > 0 else { return nil }
    if pico > 0 {
      oyoAlgo = true
      segundosEnCero = 0
      defer {
        aviso = false
        escalo = false
      }
      return aviso ? .revivio : nil
    }
    segundosEnCero += Double(cuadros) / tasa
    // Reabrir sólo al principio: un micrófono que sonó y se calló a media
    // frase no se arregla reabriendo, y reabrir dos veces es pelear con el
    // hardware.
    if !oyoAlgo, !reabrio, segundosEnCero >= Self.reabrirTras {
      reabrio = true
      return .reabrir
    }
    if !escalo, segundosEnCero >= Self.escalarTras {
      escalo = true
      aviso = true
      return .escalar
    }
    if !aviso, segundosEnCero >= Self.avisarTras {
      aviso = true
      return .avisar
    }
    return nil
  }

  /// El pico de un búfer, con vDSP para que el hilo de audio ni lo note.
  public static func pico(_ muestras: UnsafeBufferPointer<Float>) -> Float {
    muestras.isEmpty ? 0 : vDSP.maximumMagnitude(muestras)
  }
}
