import Foundation

/// A quién le habla la **Conversación**: un **Agente** con nombre.
///
/// Dilo es la interfaz de voz; lo que se puede hacer lo ponen conexiones que
/// elige la persona (spec «Dilo como plataforma conversacional abierta»,
/// 2026-07-22, y `docs/design/conversacion-agente.md`). Cada agente tiene un
/// nombre que sirve para llamarlo —«Dilo», «Claude Code», «Switchboard»— y un
/// destino que contesta. Este archivo es el contrato que comparten el
/// controlador de la conversación, los destinos y la escucha de nombres.
public struct Agente: Equatable, Hashable, Sendable, Codable, Identifiable {
  public enum Tipo: Equatable, Hashable, Sendable, Codable {
    /// Claude por la API, con las herramientas de Dilo y los servidores MCP
    /// conectados.
    case dilo
    /// Una sesión de Claude Code en una carpeta, manejada por voz.
    case claudeCode
    /// Un servidor MCP conectado, con su nombre en Ajustes (Switchboard es
    /// el primero).
    case mcp(servidor: String)
  }

  /// Estable entre versiones: es lo que se guarda en `UserDefaults`.
  public var id: String
  /// Cómo se le dice, y la palabra con que se lo llama.
  public var nombre: String
  public var tipo: Tipo
  /// Si su nombre despierta a Dilo cuando la escucha de nombres está prendida.
  public var seLlamaPorNombre: Bool

  /// Si trabaja por detrás: el agente de la llamada le encarga cosas y sigue
  /// conversando, y la persona nunca le habla directo. Codex y Gemini entran
  /// por acá cuando estén instalados.
  public var trabajaDeFondo: Bool { tipo == .claudeCode }

  /// Para qué sirve, en una frase: lo que lee el agente que decide a quién
  /// encargarle algo.
  public var queHace: String {
    switch tipo {
    case .dilo: "conversa y usa las herramientas de Dilo en el Mac"
    case .claudeCode: "programa en los proyectos de la persona, por detrás, en una sesión de Claude Code"
    case .mcp: "contesta con las herramientas de ese servidor conectado"
    }
  }

  public init(id: String, nombre: String, tipo: Tipo, seLlamaPorNombre: Bool) {
    self.id = id
    self.nombre = nombre
    self.tipo = tipo
    self.seLlamaPorNombre = seLlamaPorNombre
  }

  /// Los de fábrica. Sólo «Dilo» se llama por nombre de fábrica: cada palabra
  /// más que escucha es una falsa alarma más, y se suman al medir.
  public static let deFabrica: [Agente] = [
    Agente(id: "dilo", nombre: "Dilo", tipo: .dilo, seLlamaPorNombre: true),
    Agente(id: "claude-code", nombre: "Claude Code", tipo: .claudeCode, seLlamaPorNombre: false),
    Agente(id: "switchboard", nombre: "Switchboard", tipo: .mcp(servidor: "switchboard"), seLlamaPorNombre: false),
  ]
}

/// Lo que dijo la persona en un turno, ya transcrito, con el agente al que se
/// lo dijo.
public struct TurnoDeLaPersona: Equatable, Sendable {
  public var agente: Agente
  /// Lo dicho sin el nombre del agente adelante («Switchboard, ¿qué tengo
  /// hoy?» llega como «¿Qué tengo hoy?»).
  public var texto: String
  /// No lo dijo la persona: Dilo le cuenta al agente cómo va un encargo.
  public var esAviso: Bool

  public init(agente: Agente, texto: String, esAviso: Bool = false) {
    self.agente = agente
    self.texto = texto
    self.esAviso = esAviso
  }
}

/// Algo que el destino quiere hacer y que necesita un **clic** de la persona.
///
/// La voz nunca autoriza nada sensible: escribir, ejecutar, mandar o borrar
/// se muestra en la muesca con «Aprobar» y «No», y sólo el clic decide. Leer y
/// buscar no piden aprobación.
public struct Aprobacion: Identifiable, Sendable {
  public var id: String
  /// Quién la pide, para decirlo en la muesca.
  public var agente: Agente
  /// En una línea y en español: «Claude Code quiere correr `swift test`».
  public var descripcion: String
  /// El detalle completo para la transcripción (comando, archivo, argumentos).
  public var detalle: String
  /// Se llama una sola vez, desde el actor principal, con lo que decidió el
  /// clic. Si la persona cuelga sin decidir, se llama con `false`.
  public var responder: @Sendable (Bool) -> Void

  public init(
    id: String,
    agente: Agente,
    descripcion: String,
    detalle: String,
    responder: @escaping @Sendable (Bool) -> Void
  ) {
    self.id = id
    self.agente = agente
    self.descripcion = descripcion
    self.detalle = detalle
    self.responder = responder
  }
}

/// Lo que va mandando un destino mientras contesta un turno.
public enum EventoDelDestino: Sendable {
  /// Texto para decir, en pedazos a medida que llega. La conversación lo corta
  /// en oraciones para la voz.
  case texto(String)
  /// Una herramienta empezó o terminó, para la barra y la transcripción
  /// («Buscando en tus reuniones…»). No se dice en voz alta.
  case herramienta(nombre: String, enCurso: Bool)
  /// El destino espera un clic antes de seguir.
  case pideAprobacion(Aprobacion)
  /// Terminó el turno. `costoUSD` es lo que costó, si el destino lo sabe
  /// (Claude por la API sí; Claude Code va por la cuenta de la persona).
  case fin(costoUSD: Double?)
}

/// Quien contesta los turnos de un **Agente**.
///
/// Lo implementa cada tipo: Claude con herramientas (`.dilo`), una sesión de
/// Claude Code (`.claudeCode`), un servidor MCP (`.mcp`). La conversación no
/// sabe cuál es: le pasa el turno y va diciendo lo que vuelve.
@MainActor
public protocol DestinoDeConversacion: AnyObject {
  var agente: Agente { get }
  /// Contesta un turno. Cancelar la tarea que consume el stream interrumpe al
  /// destino (la persona apretó el gatillo o colgó).
  func responder(_ turno: TurnoDeLaPersona) -> AsyncThrowingStream<EventoDelDestino, any Error>
  /// La llamada se cortó: suelta procesos y conexiones. Lo conversado se olvida.
  func colgar()
}
