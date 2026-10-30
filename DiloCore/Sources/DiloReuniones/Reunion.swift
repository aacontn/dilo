import Foundation

/// De dónde viene el audio de una **Pista**. Son dos y nunca se mezclan: la
/// pista es la primera separación de voces, y es gratis (spec, «Decisiones»).
public enum Pista: String, Codable, Sendable, CaseIterable {
  /// El micrófono. Lo que hay ahí es siempre Yo; no lo decide un modelo.
  case yo
  /// El audio del sistema, por el tap de Core Audio. Es lo que se diariza.
  case ellos

  /// El nombre del WAV de una parte. La primera es `yo.wav`; si el disco se
  /// desmontó a media reunión y la grabación siguió en el interno, la segunda
  /// es `yo-2.wav`, y así.
  public func archivo(parte: Int) -> String {
    parte <= 1 ? "\(rawValue).wav" : "\(rawValue)-\(parte).wav"
  }
}

/// En qué va una **Reunión**, tal como queda escrito en `reunion.json`.
///
/// El `rawValue` se escribe a disco y lo leen el CLI y el MCP sin la app
/// abierta: no se renombra.
public enum EstadoDeLaReunion: String, Codable, Sendable {
  /// Las pistas se están escribiendo. Si la app muere así, al volver a abrir
  /// pasa a `interrumpida` (`ReparacionDeReuniones`).
  case grabando
  /// Terminó de grabar y corre la pasada final: Parakeet por pista y quién
  /// habló en `ellos`.
  case afinando
  /// El guion está escrito.
  case lista
  /// La app murió grabando. Los WAV se reparan y se afina igual: terminar
  /// tarde no pierde nada, el audio ya estaba en disco.
  case interrumpida
}

/// Lo que la lista de reuniones dice de cada una (spec, «Dónde quedan»).
///
/// «Esperando el disco» no es un paso de la grabación sino un lugar: la
/// reunión está en el respaldo interno porque el SSD no estaba montado. Por eso
/// se calcula y no se escribe.
public enum EstadoParaMostrar: String, Codable, Sendable {
  case grabando
  case afinando
  case lista
  case interrumpida
  case esperandoElDisco

  public static func de(_ estado: EstadoDeLaReunion, enElRespaldo: Bool) -> EstadoParaMostrar {
    // Lo que todavía graba se dice «grabando» aunque esté en el interno: es
    // lo que la persona necesita saber mientras dura.
    if estado == .grabando { return .grabando }
    if enElRespaldo { return .esperandoElDisco }
    switch estado {
    case .grabando: return .grabando
    case .afinando: return .afinando
    case .lista: return .lista
    case .interrumpida: return .interrumpida
    }
  }
}

/// Lo que se sabía de la reunión por el calendario al empezar a grabar.
public struct EventoDeLaReunion: Codable, Sendable, Equatable {
  public var titulo: String
  public var empieza: Date?
  public var termina: Date?
  /// Los otros asistentes por nombre, sin quien graba. En 1:1 es lo que da
  /// «Yo / Camila» gratis.
  public var asistentes: [String]

  public init(titulo: String, empieza: Date? = nil, termina: Date? = nil, asistentes: [String] = []) {
    self.titulo = titulo
    self.empieza = empieza
    self.termina = termina
    self.asistentes = asistentes
  }
}

/// Una voz del guion. Yo es siempre Yo, y sale de la pista; los demás entran
/// como «Hablante 2», «Hablante 3»… en el orden en que hablaron hasta que
/// alguien les pone nombre.
public struct Hablante: Codable, Sendable, Equatable, Identifiable {
  /// `yo`, o `h2`, `h3`…: estable dentro de la reunión aunque cambie el
  /// nombre, porque cada palabra de `guion.jsonl` lo nombra.
  public var id: String
  /// El nombre que se le puso, o nil mientras es «Hablante N».
  public var nombre: String?
  public var pista: Pista

  public init(id: String, nombre: String? = nil, pista: Pista) {
    self.id = id
    self.nombre = nombre
    self.pista = pista
  }

  public static let yo = Hablante(id: "yo", pista: .yo)

  /// El id del hablante número `numero` de `ellos`. El 1 es Yo, así que los
  /// demás parten en 2: «Hablante 2 → Camila» (spec, «El guion»).
  public static func id(numero: Int) -> String { "h\(numero)" }

  public var numero: Int? {
    id == Self.yo.id ? 1 : Int(id.dropFirst())
  }

  /// Cómo se dice en el guion. El copy pasa por el catálogo de la app; este
  /// texto es el que va a disco y a los agentes, que no tienen catálogo.
  public var nombreVisible: String {
    if let nombre, !nombre.trimmingCharacters(in: .whitespaces).isEmpty { return nombre }
    if id == Self.yo.id { return "Yo" }
    return "Hablante \(numero ?? 0)"
  }
}

/// Una pista tal como quedó grabada.
public struct PistaGrabada: Codable, Sendable, Equatable {
  public var pista: Pista
  /// Las partes en orden, por nombre de archivo dentro de la carpeta de la
  /// reunión. Casi siempre una.
  public var partes: [String]
  /// Por qué la pista no grabó o se cortó, si pasó. La otra sigue igual: son
  /// dos capturas independientes.
  public var falla: String?
  /// El dispositivo, por nombre, para el log y el banco. Nunca qué se dijo.
  public var dispositivo: String?

  public init(pista: Pista, partes: [String] = [], falla: String? = nil, dispositivo: String? = nil) {
    self.pista = pista
    self.partes = partes
    self.falla = falla
    self.dispositivo = dispositivo
  }
}

/// Qué modelos hicieron el guion, para saber con qué se comparó cuando se
/// vuelva a medir.
public struct VersionesDelGuion: Codable, Sendable, Equatable {
  public var motorDeVoz: String?
  public var diarizador: String?
  public var app: String?

  public init(motorDeVoz: String? = nil, diarizador: String? = nil, app: String? = nil) {
    self.motorDeVoz = motorDeVoz
    self.diarizador = diarizador
    self.app = app
  }
}

/// En qué forma está el audio de la reunión (spec, «Cuánto dura»).
public enum EstadoDelAudio: String, Codable, Sendable {
  case wav
  case aac
  /// Fue a la Papelera: el guion queda para siempre.
  case borrado
}

/// Por dónde salía el audio del Mac al grabar. Con parlantes, el micrófono
/// re-capta a los demás y hace falta el filtro de eco; con audífonos, no.
public enum SalidaDeAudio: String, Codable, Sendable {
  case audifonos
  case parlantes
  case desconocida

  /// Lo que se puede leer de la HAL, sin la HAL. El transporte es el de Core
  /// Audio en palabras (`bluetooth`, `integrado`, `usb`…), la fuente es la
  /// del dispositivo integrado (`hdpn` audífonos por cable, `ispk` parlantes).
  ///
  /// Un Bluetooth se toma por audífonos: en una llamada casi siempre lo son,
  /// y un parlante Bluetooth con el filtro apagado sólo deja pasar eco, que
  /// el guion igual muestra. Lo desconocido se trata como parlantes: el filtro
  /// sólo saca palabras de `yo` que repiten una de `ellos`.
  public static func clasificar(transporte: String, fuente: String?, nombre: String) -> SalidaDeAudio {
    let nombre = nombre.lowercased()
    let deAudifonos = ["airpods", "buds", "headphone", "headset", "audífono", "audifono", "auricular", "wh-", "wf-"]
    if deAudifonos.contains(where: nombre.contains) { return .audifonos }
    switch transporte {
    case "bluetooth", "bluetoothle": return .audifonos
    case "integrado":
      if fuente == "hdpn" { return .audifonos }
      return .parlantes
    case "hdmi", "displayport", "usb", "thunderbolt", "airplay":
      return .parlantes
    default:
      return .desconocida
    }
  }

  /// Si hay que buscar eco en `yo`.
  public var pideFiltroDeEco: Bool { self != .audifonos }
}

/// Un tramo en que la persona dictó durante la reunión, en segundos desde que
/// empezó a grabar. Las palabras de `yo` ahí son del dictado y no van al guion
/// (quedan en el WAV).
public struct TramoDeDictado: Codable, Sendable, Equatable {
  public var desde: Double
  public var hasta: Double

  public init(desde: Double, hasta: Double) {
    self.desde = desde
    self.hasta = hasta
  }
}

/// Quién está escribiendo la reunión: lo que permite saber, al abrir Dilo,
/// si una reunión «grabando» sigue viva o se interrumpió.
public struct ProcesoQueGraba: Codable, Sendable, Equatable {
  public var pid: Int32
  /// Cuándo arrancó ese proceso. Un pid se reusa; un pid con otra hora de
  /// arranque es otro proceso.
  public var arranque: Date

  public init(pid: Int32, arranque: Date) {
    self.pid = pid
    self.arranque = arranque
  }
}

/// `reunion.json`: todo lo que se sabe de una **Reunión** salvo sus
/// palabras, que viven en `guion.jsonl`.
public struct Reunion: Codable, Sendable, Equatable, Identifiable {
  /// La versión del formato, por si cambia.
  public var formato: Int = 1
  /// El inicio al segundo, `2026-10-21T15:30:07`, como los dictados: es lo
  /// que un agente guarda y vuelve a pedir.
  public var id: String
  /// Con tildes, como lo escribió la persona o el calendario. La carpeta va
  /// sin ellas.
  public var titulo: String
  public var inicio: Date
  public var fin: Date?
  public var evento: EventoDeLaReunion?
  public var hablantes: [Hablante]
  public var estado: EstadoDeLaReunion
  /// Si en algún momento quedó interrumpida. Se queda aunque después se afine:
  /// la lista lo puede decir y el banco lo puede contar.
  public var seInterrumpio: Bool
  public var pistas: [PistaGrabada]
  public var versiones: VersionesDelGuion
  public var audio: EstadoDelAudio
  /// Cuándo quedó lista; de ahí cuentan los 30 días del audio.
  public var afinadaEl: Date?
  public var salida: SalidaDeAudio
  public var dictados: [TramoDeDictado]
  public var proceso: ProcesoQueGraba?
  /// Por qué la pasada final no pudo, si no pudo. Una frase con arreglo.
  public var falla: String?

  public init(
    id: String,
    titulo: String,
    inicio: Date,
    evento: EventoDeLaReunion? = nil,
    salida: SalidaDeAudio = .desconocida,
    proceso: ProcesoQueGraba? = nil
  ) {
    self.id = id
    self.titulo = titulo
    self.inicio = inicio
    self.fin = nil
    self.evento = evento
    self.hablantes = [.yo]
    self.estado = .grabando
    self.seInterrumpio = false
    self.pistas = Pista.allCases.map { PistaGrabada(pista: $0, partes: [$0.archivo(parte: 1)]) }
    self.versiones = VersionesDelGuion()
    self.audio = .wav
    self.afinadaEl = nil
    self.salida = salida
    self.dictados = []
    self.proceso = proceso
    self.falla = nil
  }

  public func pista(_ pista: Pista) -> PistaGrabada? {
    pistas.first { $0.pista == pista }
  }

  public func hablante(_ id: String) -> Hablante? {
    hablantes.first { $0.id == id }
  }

  /// Cuánto duró, o cuánto lleva si sigue grabando.
  public func duracion(ahora: Date = Date()) -> TimeInterval {
    max(0, (fin ?? ahora).timeIntervalSince(inicio))
  }

  /// Todos los archivos de audio que la reunión dice tener.
  public var archivosDeAudio: [String] {
    pistas.flatMap(\.partes)
  }

  /// Renombra a un hablante. Un nombre vacío lo devuelve a «Hablante N».
  public mutating func renombrar(_ id: String, a nombre: String?) {
    guard let indice = hablantes.firstIndex(where: { $0.id == id }) else { return }
    let limpio = nombre?.trimmingCharacters(in: .whitespacesAndNewlines)
    hablantes[indice].nombre = (limpio?.isEmpty ?? true) ? nil : limpio
  }

  /// Codificación de disco: fechas ISO 8601 y claves ordenadas, para que un
  /// `diff` entre dos versiones diga sólo lo que cambió.
  public static let codificador: JSONEncoder = {
    let codificador = JSONEncoder()
    codificador.dateEncodingStrategy = .iso8601
    codificador.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return codificador
  }()

  public static let decodificador: JSONDecoder = {
    let decodificador = JSONDecoder()
    decodificador.dateDecodingStrategy = .iso8601
    return decodificador
  }()
}
