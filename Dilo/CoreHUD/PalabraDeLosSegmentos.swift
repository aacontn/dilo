import Foundation

/// Cuándo un segmento al costado de la muesca dice su palabra y cuándo queda
/// en el ícono solo.
///
/// Un ícono solo es mudo: un ↻ al lado del notch no dice que es un dictado
/// que se puede reintentar. Así que el segmento **entra con la palabra**
/// («Reintentar», «No se pegó») y a los tres segundos se encoge al ícono,
/// como las actividades compactas de la Dynamic Island; y con el puntero
/// encima vuelve a decirla, para que nunca haya que adivinar.
///
/// Puro y con turno, como `MaquinaDelNotch`: entra un evento, sale cuándo
/// encoger cada lado. `HUDStage` duerme esos plazos con su reloj. Un plazo
/// viejo no encoge una palabra que volvió a abrirse después.
struct PalabraDeLosSegmentos: Equatable, Sendable {
  /// Lo que dura la palabra al aparecer: lo que tarda en leerse una palabra
  /// de reojo mientras se hace otra cosa.
  static let alAparecer = Duration.seconds(3)
  /// Lo que se queda la palabra después de que el puntero se va del
  /// segmento: pasar de largo por encima no la hace parpadear.
  static let alIrseElPuntero = Duration.milliseconds(600)

  enum Evento: Equatable, Sendable {
    /// Apareció un segmento en este lado, o cambió quién lo ocupa.
    case aparecio(LadoDelAsiento)
    case seFue(LadoDelAsiento)
    /// El puntero está sobre el segmento de este lado, o sobre ninguno.
    case punteroEncima(LadoDelAsiento?)
    /// Venció el plazo número `turno` de este lado.
    case vencio(LadoDelAsiento, turno: Int)
    /// Sólo para el arnés: la palabra se queda en todos los lados, o se va
    /// de todos ya.
    case fijar(Bool)
  }

  enum Efecto: Equatable, Sendable {
    case encogerEn(LadoDelAsiento, Duration, turno: Int)
  }

  private(set) var presentes: Set<LadoDelAsiento> = []
  private(set) var conPalabra: Set<LadoDelAsiento> = []
  private(set) var bajoElPuntero: LadoDelAsiento?
  private(set) var fijada = false
  private var turnos: [LadoDelAsiento: Int] = [:]

  func turno(de lado: LadoDelAsiento) -> Int { turnos[lado] ?? 0 }

  mutating func recibir(_ evento: Evento) -> [Efecto] {
    switch evento {
    case let .aparecio(lado):
      presentes.insert(lado)
      return abrir(lado, por: Self.alAparecer)

    case let .seFue(lado):
      presentes.remove(lado)
      conPalabra.remove(lado)
      avanzar(lado)
      if bajoElPuntero == lado { bajoElPuntero = nil }
      return []

    case let .punteroEncima(lado):
      let antes = bajoElPuntero
      bajoElPuntero = lado.flatMap { presentes.contains($0) ? $0 : nil }
      guard antes != bajoElPuntero else { return [] }
      var efectos: [Efecto] = []
      if let antes, presentes.contains(antes) {
        avanzar(antes)
        efectos.append(.encogerEn(antes, Self.alIrseElPuntero, turno: turno(de: antes)))
      }
      if let ahora = bajoElPuntero {
        // Mientras está encima no se programa nada: se encoge al irse.
        conPalabra.insert(ahora)
        avanzar(ahora)
      }
      return efectos

    case let .vencio(lado, vencido):
      guard vencido == turno(de: lado), bajoElPuntero != lado, !fijada else { return [] }
      conPalabra.remove(lado)
      return []

    case let .fijar(valor):
      fijada = valor
      if valor {
        conPalabra = presentes
      } else {
        conPalabra = bajoElPuntero.map { [$0] } ?? []
      }
      for lado in presentes { avanzar(lado) }
      return []
    }
  }

  private mutating func abrir(_ lado: LadoDelAsiento, por plazo: Duration) -> [Efecto] {
    conPalabra.insert(lado)
    avanzar(lado)
    return [.encogerEn(lado, plazo, turno: turno(de: lado))]
  }

  private mutating func avanzar(_ lado: LadoDelAsiento) {
    turnos[lado, default: 0] += 1
  }
}
