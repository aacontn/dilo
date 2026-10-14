import CoreAudio
import Foundation

// Técnica observada en Ocelli (Ghidra: transporte 'blue'/'blea' de la entrada
// del sistema → micrófono 'bltn' fijado con `AUAudioUnit.setDeviceID`, sin
// tocar la entrada del sistema); implementación propia, que además prefiere un
// micrófono con cable antes que el Bluetooth cuando el Mac no trae uno propio.

/// Un micrófono como lo ve Dilo. `id` cambia entre arranques y entre
/// conexiones; `uid` es estable y es lo que se guarda en Ajustes, con el
/// nombre de respaldo (un USB en otro puerto puede cambiar de UID).
public struct EntradaDeAudio: Sendable, Equatable, Hashable {
  public enum Transporte: Sendable, Equatable, Hashable {
    case interno, bluetooth, cableado, otro
  }

  public let id: AudioDeviceID
  public let uid: String
  public let nombre: String
  public let transporte: Transporte

  public init(id: AudioDeviceID, uid: String, nombre: String, transporte: Transporte) {
    self.id = id
    self.uid = uid
    self.nombre = nombre
    self.transporte = transporte
  }
}

/// Qué pidió la persona en Ajustes → Dictado → Micrófono.
public enum EleccionDeMicrofono: Sendable, Equatable, Hashable {
  /// El de fábrica: la entrada del sistema, salvo que sea Bluetooth y haya
  /// uno con cable —el del Mac primero—, para que los audífonos no caigan al
  /// perfil de llamada mientras dictas.
  case automatico
  /// La entrada del sistema tal cual, aunque sea Bluetooth.
  case delSistema
  /// Uno en particular, por su UID y con su nombre de respaldo.
  case elegido(uid: String, nombre: String)

  /// Cómo se guarda: dos textos en `UserDefaults`. Vacío es automático; la
  /// marca `delSistemaGuardado` es seguir al sistema; cualquier otro UID es
  /// un micrófono elegido.
  public static let delSistemaGuardado = "@sistema"

  public init(uid: String, nombre: String) {
    switch uid {
    case "": self = .automatico
    case Self.delSistemaGuardado: self = .delSistema
    default: self = .elegido(uid: uid, nombre: nombre)
    }
  }

  public var uidGuardado: String {
    switch self {
    case .automatico: ""
    case .delSistema: Self.delSistemaGuardado
    case let .elegido(uid, _): uid
    }
  }

  public var nombreGuardado: String {
    if case let .elegido(_, nombre) = self { return nombre }
    return ""
  }
}

/// Qué micrófono usa este **Dictado** y por qué. Puro: los tests le pasan
/// listas de dispositivos inventadas.
///
/// **Nunca** cambia la entrada del sistema: lo que decide se aplica sólo al
/// motor de audio de Dilo (`AVAudioEngine.fijarEntrada`).
public enum PlanDeMicrofono {
  public enum Motivo: Sendable, Equatable {
    /// El que la persona eligió en Ajustes.
    case elegido
    /// Eligió uno que no está conectado: se usa el del sistema.
    case elegidoAusente
    /// La entrada del sistema es Bluetooth y hay un micrófono con cable (el
    /// del Mac primero; en un Mac mini, el de la cámara o uno USB): los
    /// audífonos siguen en A2DP y la música no se degrada.
    case evitarBluetooth
    /// Lo de siempre: la entrada del sistema, sin fijar nada.
    case delSistema
  }

  public struct Decision: Sendable, Equatable {
    /// `nil` = no fijar nada; el motor sigue la entrada del sistema.
    public let fijarA: EntradaDeAudio?
    public let motivo: Motivo

    public init(fijarA: EntradaDeAudio?, motivo: Motivo) {
      self.fijarA = fijarA
      self.motivo = motivo
    }

    /// Lo que vale la pena decir **antes** de grabar. Hoy, sólo que el
    /// micrófono elegido no está: se dicta igual, con el del sistema.
    ///
    /// Es la costura para los avisos antes de abrir el micrófono: quien los
    /// arme pregunta acá y no repite la regla.
    public var avisoAntesDeGrabar: AvisoAntesDeGrabar? {
      motivo == .elegidoAusente ? .elegidoAusente : nil
    }
  }

  public enum AvisoAntesDeGrabar: Sendable, Equatable {
    case elegidoAusente
  }

  public static func decidir(
    eleccion: EleccionDeMicrofono,
    entradas: [EntradaDeAudio],
    entradaDelSistema: AudioDeviceID?,
    tapaCerrada: Bool
  ) -> Decision {
    switch eleccion {
    case let .elegido(uid, nombre):
      // Por UID primero; por nombre si el UID cambió (otro puerto USB). Un
      // nombre repetido elige el primero, que es mejor que ninguno.
      if let elegido = entradas.first(where: { $0.uid == uid })
        ?? entradas.first(where: { !nombre.isEmpty && $0.nombre == nombre }) {
        return Decision(fijarA: elegido, motivo: .elegido)
      }
      return Decision(fijarA: nil, motivo: .elegidoAusente)
    case .delSistema:
      return Decision(fijarA: nil, motivo: .delSistema)
    case .automatico:
      guard let delSistema = entradas.first(where: { $0.id == entradaDelSistema }),
        delSistema.transporte == .bluetooth,
        let conCable = conCable(en: entradas, tapaCerrada: tapaCerrada)
      else {
        return Decision(fijarA: nil, motivo: .delSistema)
      }
      return Decision(fijarA: conCable, motivo: .evitarBluetooth)
    }
  }

  /// El micrófono propio del Mac primero, después uno con cable. Con la tapa
  /// cerrada el del Mac entrega ceros; uno USB sigue valiendo. El micrófono
  /// de un iPhone por Continuity es `.otro` y nunca se elige solo.
  static func conCable(en entradas: [EntradaDeAudio], tapaCerrada: Bool) -> EntradaDeAudio? {
    (tapaCerrada ? nil : entradas.first(where: { $0.transporte == .interno }))
      ?? entradas.first(where: { $0.transporte == .cableado })
  }
}

/// Lo que el selector de Ajustes ofrece: automático, el del sistema, los
/// conectados, y el elegido aunque no esté —marcado— para que la elección no
/// desaparezca de la lista en silencio cuando se desenchufa.
public enum OpcionesDeMicrofono {
  public static func opciones(
    conectadas: [EntradaDeAudio],
    eleccion: EleccionDeMicrofono
  ) -> [EleccionDeMicrofono] {
    var opciones: [EleccionDeMicrofono] = [.automatico, .delSistema]
    var vistos = Set<String>()
    for entrada in conectadas where vistos.insert(entrada.uid).inserted {
      opciones.append(.elegido(uid: entrada.uid, nombre: entrada.nombre))
    }
    if case let .elegido(uid, _) = eleccion, !vistos.contains(uid) {
      opciones.append(eleccion)
    }
    return opciones
  }

  /// Si una opción elegida está conectada (por UID o por nombre, igual que
  /// `PlanDeMicrofono.decidir`).
  public static func estaConectada(_ eleccion: EleccionDeMicrofono, en conectadas: [EntradaDeAudio]) -> Bool {
    guard case let .elegido(uid, nombre) = eleccion else { return true }
    return conectadas.contains { $0.uid == uid || (!nombre.isEmpty && $0.nombre == nombre) }
  }
}
