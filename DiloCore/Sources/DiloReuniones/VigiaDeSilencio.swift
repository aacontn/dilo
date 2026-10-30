import Foundation

/// La vigía de una pista: el silencio y una pista muerta tienen que verse
/// distinto (lección 1 del Tauri: en la reunión 27 la voz de Alfonso nunca
/// entró y nadie lo vio).
///
/// Cuenta segundos de ceros exactos —una sala callada nunca es cero digital—
/// como `DetectorDeMicMuerto` en el dictado: a los 5 s la marca de la pista
/// pasa a ámbar, a los 15 s se dice con su arreglo (spec, «Mientras graba»).
public struct VigiaDeSilencio: Sendable, Equatable {
  public static let segundosParaAmbar = 5
  public static let segundosParaAviso = 15

  public enum Estado: String, Sendable, Equatable {
    /// Hubo señal en el último segundo, o silencio de verdad (no ceros).
    case bien
    /// 5 s de ceros: la marca en ámbar.
    case ambar
    /// 15 s de ceros: la muesca lo dice.
    case sinAudio
  }

  public private(set) var segundosEnCeros = 0
  /// Si alguna vez llegó algo que no era cero. Una pista que sonó y después
  /// calla es una llamada en silencio; una que nunca sonó es un permiso o un
  /// dispositivo.
  public private(set) var yaSono = false
  /// El último nivel, en dBFS, para las marcas de la muesca.
  public private(set) var nivel: Float = -160

  /// Si un segundo sin búferes cuenta como ceros. Para el micrófono sí: un
  /// motor que no entrega nada está muerto. Para el tap no: con
  /// `TapAutoStart` el agregado no corre hasta que alguna app suena, y un Mac
  /// callado no es una falla.
  public let sinBuferesSonCeros: Bool

  public init(sinBuferesSonCeros: Bool) {
    self.sinBuferesSonCeros = sinBuferesSonCeros
  }

  /// Un segundo más de la pista: cuántas muestras llegaron, si eran todas
  /// cero y el pico en dBFS.
  public mutating func segundo(muestras: Int, todasCero: Bool, pico: Float) {
    if muestras == 0 {
      if sinBuferesSonCeros { segundosEnCeros += 1 }
      nivel = -160
      return
    }
    nivel = pico
    if todasCero {
      segundosEnCeros += 1
    } else {
      segundosEnCeros = 0
      yaSono = true
    }
  }

  public var estado: Estado {
    if segundosEnCeros >= Self.segundosParaAviso { return .sinAudio }
    if segundosEnCeros >= Self.segundosParaAmbar { return .ambar }
    return .bien
  }

  /// Si el aviso es el del permiso: `ellos` en ceros y nunca sonó. Sin API
  /// pública para preguntar por el permiso del audio del sistema
  /// (`system-audio-capture.md`), esto es lo que se infiere.
  public var pareceFaltarPermiso: Bool { estado == .sinAudio && !yaSono }

  /// Si un bloque de muestras es entero cero exacto, y su pico en dBFS.
  public static func medir(_ muestras: UnsafeBufferPointer<Float>) -> (todasCero: Bool, pico: Float) {
    var pico: Float = 0
    for m in muestras { pico = max(pico, abs(m)) }
    return (pico == 0, pico > 0 ? 20 * log10(pico) : -160)
  }
}
