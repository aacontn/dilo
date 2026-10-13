import Foundation

/// Cuánto le importa a la persona que una actividad se vea.
///
/// Tres niveles y no un número: con un `Int` libre, cada fuente que llegue
/// después —un conector, un agente— se pone 99 y la prioridad deja de decir
/// nada.
enum PrioridadDeActividad: Int, Comparable, Sendable {
  case baja, normal, alta
  static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

enum LadoDePildora: String, Sendable {
  case derecha, izquierda
}

/// Dónde está sentada una actividad.
enum AsientoDeLaMuesca: Equatable, Sendable {
  case ninguno
  /// La muesca entera: lo que se dibuja dentro de la forma.
  case principal
  /// Una píldora al costado, pegada a la forma.
  case pildora(LadoDePildora)
}

/// Por qué una actividad se quedó sin asiento. Se le dice a quien la publicó
/// para que no insista ni se crea dibujada.
enum MotivoDeCesion: String, Sendable {
  /// Otra más importante se quedó con el lugar.
  case superada
  /// Las dos píldoras están ocupadas por iguales que llegaron antes.
  case sinLugar
  /// Esta pantalla no tiene lugar para píldoras (notch real, píldora bajo la
  /// barra) y la actividad no puede ser la forma entera.
  case pantallaSinLugar
  /// Pantalla completa: sólo se ve lo que la persona está mirando o grabando.
  case suprimida
  /// La persona la apagó en Ajustes.
  case apagada
  /// Quien la publicó dice que por ahora no hay nada que mostrar.
  case inactiva
}

/// Algo que quiere estar en la muesca: hoy la sesión del contrato, la toma
/// guardada para reintentar y un dictado que no se pegó; mañana una reunión
/// grabando o un agente que te espera.
struct ActividadDeLaMuesca: Identifiable, Equatable, Sendable {
  let id: String
  var prioridad: PrioridadDeActividad
  /// Delata un micrófono o el audio del sistema abierto. **Nunca se queda sin
  /// asiento**: esconder una grabación está prohibido por el contrato del
  /// notch («Reunión … Qué no debe pasar: esconder la grabación»).
  var abreElMicrofono = false
  /// Se lleva la forma aunque haya otra igual de importante sentada ahí: la
  /// sesión de dictado. Quien habla está mirando la muesca.
  var exigeElPrincipal = false
  /// Puede ocupar la forma entera; si no, sólo una píldora.
  var puedeSerPrincipal = true
  var ladoPreferido: LadoDePildora?
  /// Falsa cuando quien la publicó dice que no hay nada que mostrar por ahora.
  var activa = true

  /// Lo que ni la pantalla completa ni un ajuste esconden: lo que se está
  /// grabando y lo que la persona está mirando porque acaba de hablar.
  var nuncaSeEsconde: Bool { abreElMicrofono || exigeElPrincipal }
}

/// Quién se sienta dónde: una actividad principal —la forma— y hasta dos
/// píldoras al costado. Un reductor puro, como `MaquinaDelNotch` (ADR-0005):
/// entra un evento, sale la lista de cambios de asiento. Lo que se dibuja lo
/// decide `HUDStage` con `principal` y `pildora(_:)`.
///
/// **`MaquinaDelNotch` no cambia**: sigue siendo el ciclo de vida del
/// dictado. Esto va un nivel arriba y decide quién tiene la forma y quién se
/// corre a un costado.
///
/// Reglas, en orden:
/// 1. Quien exige el principal lo toma (la sesión de dictado).
/// 2. Quien abre el micrófono nunca se queda fuera: si no le toca el
///    principal, se lleva una píldora aunque la pantalla no tenga lugar.
/// 3. Lo que la persona llevó al centro con un toque.
/// 4. Después, la prioridad.
/// 5. A igual prioridad **se queda quien ya estaba** (histéresis): sin esto,
///    dos fuentes que se actualizan se turnan la píldora en cada evento.
/// 6. A igual todo, la más reciente.
///
/// La idea de asientos con prioridad y motivo de cesión es la de las
/// actividades en vivo de las islas de notch; las reglas y la implementación
/// son propias.
struct AsientosDeLaMuesca: Equatable, Sendable {
  static let maximoDePildoras = 2

  enum Evento: Equatable, Sendable {
    case publicar(ActividadDeLaMuesca)
    case retirar(id: String)
    /// Cuántas píldoras caben en esta pantalla (0…2)
    /// (`HUDNotchGeometry.lugaresParaPildoras`).
    case lugaresParaPildoras(Int)
    /// Pantalla completa: sólo queda lo que nunca se esconde.
    case suprimir(Bool)
    /// La persona apagó (o encendió) esta fuente en Ajustes.
    case apagar(id: String, Bool)
    /// La persona tocó una píldora para llevarla al centro: gana la forma
    /// aunque no pueda ser principal por sí sola, hasta que se suelte o se
    /// retire. Nunca le quita la forma a la sesión ni a una grabación.
    case llevarAlCentro(id: String)
    case soltarDelCentro
  }

  struct Cambio: Equatable, Sendable {
    let id: String
    let antes: AsientoDeLaMuesca
    let ahora: AsientoDeLaMuesca
    /// Sólo cuando `ahora == .ninguno`.
    let motivo: MotivoDeCesion?
  }

  private(set) var actividades: [String: ActividadDeLaMuesca] = [:]
  private(set) var asientos: [String: AsientoDeLaMuesca] = [:]
  private(set) var lugares = maximoDePildoras
  private(set) var suprimida = false
  private(set) var apagadas: Set<String> = []
  private(set) var alCentro: String?
  /// Por qué cada actividad publicada está sin asiento, si lo está.
  private(set) var motivos: [String: MotivoDeCesion] = [:]
  private var llegada: [String: Int] = [:]
  private var reloj = 0

  /// Quién tiene la forma ahora.
  var principal: ActividadDeLaMuesca? {
    asientos.first { $0.value == .principal }.flatMap { actividades[$0.key] }
  }

  func pildora(_ lado: LadoDePildora) -> ActividadDeLaMuesca? {
    asientos.first { $0.value == .pildora(lado) }.flatMap { actividades[$0.key] }
  }

  func asiento(de id: String) -> AsientoDeLaMuesca { asientos[id] ?? .ninguno }

  @discardableResult
  mutating func recibir(_ evento: Evento) -> [Cambio] {
    switch evento {
    case let .publicar(actividad):
      if actividades[actividad.id] == nil {
        reloj += 1
        llegada[actividad.id] = reloj
      }
      actividades[actividad.id] = actividad
    case let .retirar(id):
      actividades[id] = nil
      llegada[id] = nil
      motivos[id] = nil
      if alCentro == id { alCentro = nil }
    case let .lugaresParaPildoras(n):
      lugares = min(max(n, 0), Self.maximoDePildoras)
    case let .suprimir(valor):
      suprimida = valor
    case let .apagar(id, apagada):
      if apagada { apagadas.insert(id) } else { apagadas.remove(id) }
    case let .llevarAlCentro(id):
      // Un id que no está publicado no hace nada: tampoco suelta al que ya
      // estaba en el centro.
      if actividades[id] != nil { alCentro = id }
    case .soltarDelCentro:
      alCentro = nil
    }
    return reasignar()
  }

  /// Mayor es mejor. La tupla es el orden de las reglas del encabezado.
  private func rango(_ a: ActividadDeLaMuesca) -> (Int, Int, Int, Int, Int, Int) {
    (
      a.exigeElPrincipal ? 1 : 0,
      a.abreElMicrofono ? 1 : 0,
      alCentro == a.id ? 1 : 0,
      a.prioridad.rawValue,
      asiento(de: a.id) == .ninguno ? 0 : 1,
      llegada[a.id] ?? 0
    )
  }

  private mutating func reasignar() -> [Cambio] {
    let antes = asientos
    var motivos: [String: MotivoDeCesion] = [:]
    var candidatas: [ActividadDeLaMuesca] = []

    for actividad in actividades.values {
      if apagadas.contains(actividad.id) && !actividad.nuncaSeEsconde {
        motivos[actividad.id] = .apagada
      } else if !actividad.activa && !actividad.nuncaSeEsconde {
        motivos[actividad.id] = .inactiva
      } else if suprimida && !actividad.nuncaSeEsconde {
        motivos[actividad.id] = .suprimida
      } else {
        candidatas.append(actividad)
      }
    }
    candidatas.sort { rango($0) > rango($1) }

    var nuevos: [String: AsientoDeLaMuesca] = [:]
    var restantes = candidatas
    if let i = restantes.firstIndex(where: { $0.puedeSerPrincipal || $0.id == alCentro }) {
      nuevos[restantes.remove(at: i).id] = .principal
    }

    // Píldoras: las del micrófono primero y sin tope de pantalla.
    let conMicrofono = restantes.filter(\.abreElMicrofono)
    let lugaresEfectivos = max(lugares, min(conMicrofono.count, Self.maximoDePildoras))
    var sentadas = Array(restantes.prefix(lugaresEfectivos))
    for faltante in conMicrofono where !sentadas.contains(where: { $0.id == faltante.id }) {
      // Más de dos grabaciones a la vez no cabe; la de menor rango cede a la
      // grabación, nunca al revés.
      if let i = sentadas.lastIndex(where: { !$0.abreElMicrofono }) {
        sentadas[i] = faltante
      }
    }

    var libres: [LadoDePildora] = [.derecha, .izquierda]
    // Primero quien ya tenía lado, para que nadie salte de costado.
    let ordenDeLado = sentadas.sorted { a, b in
      Self.ladoDe(antes[a.id]) != nil && Self.ladoDe(antes[b.id]) == nil
    }
    for actividad in ordenDeLado {
      let deseado = Self.ladoDe(antes[actividad.id]) ?? actividad.ladoPreferido
      let lado = deseado.flatMap { libres.contains($0) ? $0 : nil } ?? libres.first
      guard let lado else { break }
      libres.removeAll { $0 == lado }
      nuevos[actividad.id] = .pildora(lado)
    }

    // Por qué se quedó fuera cada candidata sin asiento.
    let mejorSentada = candidatas.filter { nuevos[$0.id] != nil }.map(\.prioridad).max()
    for actividad in candidatas where nuevos[actividad.id] == nil {
      if lugares < Self.maximoDePildoras && !actividad.puedeSerPrincipal {
        motivos[actividad.id] = .pantallaSinLugar
      } else if let mejorSentada, mejorSentada > actividad.prioridad {
        motivos[actividad.id] = .superada
      } else {
        motivos[actividad.id] = .sinLugar
      }
    }

    asientos = nuevos
    self.motivos = motivos
    let ids = Set(antes.keys).union(nuevos.keys).union(motivos.keys)
    return ids.sorted().compactMap { id in
      let a = antes[id] ?? .ninguno
      let b = nuevos[id] ?? .ninguno
      guard a != b else { return nil }
      return Cambio(id: id, antes: a, ahora: b, motivo: b == .ninguno ? motivos[id] : nil)
    }
  }

  private static func ladoDe(_ asiento: AsientoDeLaMuesca?) -> LadoDePildora? {
    if case let .pildora(lado)? = asiento { return lado }
    return nil
  }
}

extension ActividadDeLaMuesca {
  /// La sesión del contrato del notch: preparando, dictando, procesando y lo
  /// que la forma dice al terminar. Exige la forma; abre el micrófono sólo
  /// mientras escucha.
  static func sesion(escuchando: Bool) -> ActividadDeLaMuesca {
    ActividadDeLaMuesca(
      id: "sesion", prioridad: .alta, abreElMicrofono: escuchando, exigeElPrincipal: true
    )
  }

  /// La toma que quedó en RAM cuando un dictado no sacó texto: dura diez
  /// minutos (`PoliticaDeGrabacion`) y un clic la reintenta. Sólo píldora, a
  /// la derecha, donde la barra deja los status items.
  static let tomaGuardada = ActividadDeLaMuesca(
    id: "toma", prioridad: .normal, puedeSerPrincipal: false, ladoPreferido: .derecha
  )

  /// Un dictado que no se pegó y al que otra sesión le tapó la tarjeta. Alta:
  /// son palabras que todavía no llegaron a ninguna parte. Sólo píldora, a la
  /// izquierda.
  static let retenido = ActividadDeLaMuesca(
    id: "retenido", prioridad: .alta, puedeSerPrincipal: false, ladoPreferido: .izquierda
  )
}
