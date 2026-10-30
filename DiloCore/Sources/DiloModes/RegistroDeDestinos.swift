import Foundation

extension Agente.Tipo {
  /// El tipo sin lo que lo acompaña: es por lo que el registro sabe qué
  /// destino armar (`.mcp(servidor: "switchboard")` y `.mcp(servidor: "x")`
  /// los arma la misma fábrica).
  public enum Clase: String, Hashable, Sendable, CaseIterable {
    case dilo
    case claudeCode
    case mcp
  }

  public var clase: Clase {
    switch self {
    case .dilo: .dilo
    case .claudeCode: .claudeCode
    case .mcp: .mcp
    }
  }
}

/// Quién arma el destino de cada **Agente** durante una llamada.
///
/// Cada tipo de destino se enchufa con su fábrica (`registrar(_:fabrica:)`):
/// la app registra `.dilo` y `.mcp`, y `.claudeCode` lo registra quien lo
/// construye. Un tipo sin fábrica contesta con `DestinoSinConectar`, que dice
/// en voz alta que todavía no está conectado: llamar a un agente nunca falla
/// en silencio.
///
/// El registro guarda el destino de cada agente mientras dura la llamada, para
/// que lo conversado con cada uno siga entero al ir y volver entre ellos, y
/// los suelta todos al colgar.
@MainActor
public final class RegistroDeDestinos {
  public typealias Fabrica = @MainActor (Agente) -> any DestinoDeConversacion

  private var fabricas: [Agente.Tipo.Clase: Fabrica] = [:]
  private var vivos: [String: any DestinoDeConversacion] = [:]

  public init() {}

  /// Enchufa (o reemplaza) la fábrica de un tipo. Lo que ya está vivo sigue
  /// con el destino viejo hasta colgar.
  public func registrar(_ clase: Agente.Tipo.Clase, fabrica: @escaping Fabrica) {
    fabricas[clase] = fabrica
  }

  /// Si el tipo tiene un destino de verdad.
  public func estaConectado(_ clase: Agente.Tipo.Clase) -> Bool {
    fabricas[clase] != nil
  }

  /// El destino de este agente en la llamada, armado la primera vez que se le
  /// habla. Si cambió el nombre o el tipo del agente, se arma de nuevo.
  public func destino(para agente: Agente) -> any DestinoDeConversacion {
    if let vivo = vivos[agente.id], vivo.agente == agente { return vivo }
    vivos[agente.id]?.colgar()
    let nuevo = fabricas[agente.tipo.clase]?(agente) ?? DestinoSinConectar(agente: agente)
    vivos[agente.id] = nuevo
    return nuevo
  }

  /// Si ya hay un destino vivo para el agente, sin armarlo.
  public func vivo(_ agente: Agente) -> (any DestinoDeConversacion)? {
    vivos[agente.id]
  }

  /// La llamada se cortó: cada destino suelta lo suyo y se olvida.
  public func colgarTodos() {
    let todos = vivos.values
    vivos = [:]
    for destino in todos { destino.colgar() }
  }
}

/// El destino de un tipo que todavía no está enchufado: lo dice y termina el
/// turno. Es el lugar que ocupa Claude Code mientras se construye.
@MainActor
public final class DestinoSinConectar: DestinoDeConversacion {
  public let agente: Agente

  public init(agente: Agente) {
    self.agente = agente
  }

  /// Lo que se dice, con el nombre del agente: «Claude Code todavía no está
  /// conectado a Dilo.».
  public var aviso: String {
    "\(agente.nombre) todavía no está conectado a Dilo."
  }

  public func responder(_ turno: TurnoDeLaPersona) -> AsyncThrowingStream<EventoDelDestino, any Error> {
    let aviso = aviso
    return AsyncThrowingStream { continuacion in
      continuacion.yield(.texto(aviso))
      continuacion.yield(.fin(costoUSD: nil))
      continuacion.finish()
    }
  }

  public func colgar() {}
}
