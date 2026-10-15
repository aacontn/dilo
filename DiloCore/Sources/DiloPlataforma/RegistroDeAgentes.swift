import Foundation

/// Qué sesiones de agentes están vivas y qué tiene que mostrar la muesca de
/// cada una. Puro: entra un evento y la hora, salen los cambios. La app los
/// lleva a los asientos de la muesca (`AsientosDeLaMuesca`), que deciden
/// quién se sienta; esto sólo decide quién existe.
///
/// Una sesión es un agente en un proyecto: dos carpetas con Claude abierto
/// son dos segmentos, y el mismo Claude avisando dos veces es uno.
public struct RegistroDeAgentes: Equatable, Sendable {
  /// Sin noticias en este rato, la sesión se da por terminada: el *hook* de
  /// fin puede no llegar nunca (se cerró la terminal, se mató el proceso).
  public static let olvido: TimeInterval = 15 * 60
  /// «Listo» se queda un momento y se va solo: es un aviso, no un estado.
  public static let duracionDeListo: TimeInterval = 30
  /// Un error dura más que un «listo» —hay que ir a mirarlo— y menos que el
  /// olvido: un error de hace un cuarto de hora ya no es noticia. Número de
  /// partida, sin medir con Alfonso.
  public static let duracionDeError: TimeInterval = 2 * 60
  /// Tope de sesiones a la vez. Una URL la abre cualquiera, y sin tope una
  /// página que la repite con proyectos inventados llena la memoria; con
  /// tope, la más vieja se va.
  public static let maximoDeSesiones = 8

  public struct Sesion: Equatable, Sendable, Identifiable {
    public let id: String
    public let agente: EventoDeAgente.Agente
    public let proyecto: String
    public var fase: EventoDeAgente.Fase
    /// La última noticia de esta sesión, aunque haya repetido la fase.
    public var ultimaNoticia: Date

    public init(
      id: String, agente: EventoDeAgente.Agente, proyecto: String, fase: EventoDeAgente.Fase, ultimaNoticia: Date
    ) {
      self.id = id
      self.agente = agente
      self.proyecto = proyecto
      self.fase = fase
      self.ultimaNoticia = ultimaNoticia
    }

    /// Cuándo se va sola, según su fase.
    public var vence: Date {
      let plazo: TimeInterval = switch fase {
      case .listo: RegistroDeAgentes.duracionDeListo
      case .error: RegistroDeAgentes.duracionDeError
      case .trabajando, .espera, .fin: RegistroDeAgentes.olvido
      }
      return ultimaNoticia.addingTimeInterval(plazo)
    }
  }

  public enum Cambio: Equatable, Sendable {
    /// Apareció o cambió de fase: hay que (volver a) sentarla.
    case publicar(Sesion)
    case retirar(id: String)
  }

  public private(set) var sesiones: [String: Sesion] = [:]

  public init() {}

  /// El id de la actividad en la muesca. Lleva el prefijo para que nunca
  /// choque con las de Dilo (`toma`, `retenido`, `aprender`…).
  public static func id(agente: EventoDeAgente.Agente, proyecto: String) -> String {
    "agente.\(agente.rawValue).\(proyecto)"
  }

  public mutating func recibir(_ evento: EventoDeAgente, ahora: Date) -> [Cambio] {
    let id = Self.id(agente: evento.agente, proyecto: evento.proyecto)
    guard evento.fase != .fin else {
      return sesiones.removeValue(forKey: id) == nil ? [] : [.retirar(id: id)]
    }
    if var sesion = sesiones[id] {
      let cambiaDeFase = sesion.fase != evento.fase
      sesion.fase = evento.fase
      sesion.ultimaNoticia = ahora
      sesiones[id] = sesion
      // La misma fase otra vez sólo estira el plazo: volver a sentarla haría
      // que el segmento dijera su palabra de nuevo con cada herramienta que
      // corre el agente.
      return cambiaDeFase ? [.publicar(sesion)] : []
    }
    var cambios: [Cambio] = []
    if sesiones.count >= Self.maximoDeSesiones,
      let masVieja = sesiones.values.min(by: { $0.ultimaNoticia < $1.ultimaNoticia })
    {
      sesiones[masVieja.id] = nil
      cambios.append(.retirar(id: masVieja.id))
    }
    let sesion = Sesion(
      id: id, agente: evento.agente, proyecto: evento.proyecto, fase: evento.fase, ultimaNoticia: ahora
    )
    sesiones[id] = sesion
    cambios.append(.publicar(sesion))
    return cambios
  }

  /// Lo que venció a esta hora, en orden de id para que el resultado no
  /// dependa del diccionario.
  public mutating func limpiar(ahora: Date) -> [Cambio] {
    let vencidas = sesiones.values.filter { $0.vence <= ahora }.map(\.id).sorted()
    for id in vencidas { sesiones[id] = nil }
    return vencidas.map { .retirar(id: $0) }
  }

  /// La persona la quitó con un clic. Si el agente vuelve a avisar, vuelve.
  public mutating func descartar(id: String) -> [Cambio] {
    sesiones.removeValue(forKey: id) == nil ? [] : [.retirar(id: id)]
  }

  /// Todas fuera: se apagaron los agentes en Ajustes.
  public mutating func vaciar() -> [Cambio] {
    let ids = sesiones.keys.sorted()
    sesiones = [:]
    return ids.map { .retirar(id: $0) }
  }

  /// Cuándo hay que volver a llamar a `limpiar`. La app duerme hasta ahí en
  /// vez de sondear: en reposo Dilo no gasta CPU (spec §3).
  public var proximoVencimiento: Date? {
    sesiones.values.map(\.vence).min()
  }
}
