import CoreAudio
import Foundation

/// Qué hacer con un aviso de cambio de ruta (`AVAudioEngineConfigurationChange`)
/// y cuándo dejar de fijar el micrófono, puro para probarlo sin hardware.
///
/// El bucle de la 0.4.4 (14-oct, 18:24:41, la webcam USB): fijar un motor nuevo
/// con `setDeviceID` y arrancarlo hace que ese mismo motor avise un cambio de
/// ruta, ~200 ms después, **todavía corriendo** en el micrófono fijado y con el
/// mismo formato. Reconstruir por ese aviso fijaba otro motor, que volvía a
/// avisar: una vuelta cada ~300 ms, ningún búfer y «0 words in 10.7s».
/// Reproducido con `taller/pruebas/bucle-del-microfono`.
public struct GuardiaDeReconstruccion: Sendable {
  /// Lo que identifica al motor que arrancó: en qué dispositivo y con qué
  /// formato de entrada. Si un aviso llega con el motor andando y la misma
  /// huella, nada cambió debajo de él.
  public struct Huella: Sendable, Equatable {
    public let dispositivo: AudioDeviceID
    public let tasa: Double
    public let canales: UInt32

    public init(dispositivo: AudioDeviceID, tasa: Double, canales: UInt32) {
      self.dispositivo = dispositivo
      self.tasa = tasa
      self.canales = canales
    }
  }

  /// Más reconstrucciones que esto dentro de `ventana` es un bucle, sea quien
  /// sea que lo cause. Unos audífonos Bluetooth que cambian de perfil avisan
  /// dos veces, a lo sumo tres; cuatro en cinco segundos ya no es un cambio
  /// de ruta. Propio.
  public static let maximo = 4
  public static let ventana: Duration = .seconds(5)

  private var recientes: [ContinuousClock.Instant] = []
  /// Se alcanzó el tope: lo que queda de la sesión sigue la entrada del
  /// sistema, sin fijar nada.
  public private(set) var dejoDeFijar = false

  public init() {}

  /// Si un aviso de cambio de ruta pide reconstruir. No, si el motor sigue
  /// corriendo con la misma huella con que arrancó: ése es el eco de nuestro
  /// propio fijado y el motor está entregando audio. Un cambio de verdad —un
  /// Bluetooth que pasa al perfil de llamada, un micrófono que se
  /// desenchufa— detiene el motor o le cambia el dispositivo o el formato.
  public static func hayQueReconstruir(corriendo: Bool, alArrancar: Huella?, ahora: Huella) -> Bool {
    guard corriendo, let alArrancar else { return true }
    return alArrancar != ahora
  }

  /// Anota una reconstrucción. Devuelve true la vez que se cruza el tope:
  /// desde ahí no se fija más y quien llama lo anota en el log.
  public mutating func anotar(en instante: ContinuousClock.Instant) -> Bool {
    recientes = recientes.filter { $0.duration(to: instante) < Self.ventana } + [instante]
    guard !dejoDeFijar, recientes.count > Self.maximo else { return false }
    dejoDeFijar = true
    return true
  }

  /// Cuántas reconstrucciones hubo dentro de la ventana, para el log.
  public var enLaVentana: Int { recientes.count }
}
