import DiloAgentes
import DiloModes
import Foundation
import os

/// Quién contesta a cada **Agente** de la **Conversación**, armado por la app.
///
/// Enchufa en el registro (`RegistroDeDestinos`) los dos tipos que viven acá:
/// `.dilo` —Claude con las herramientas propias y las de los servidores MCP
/// que la persona dejó entrar a Dilo— y `.mcp` —Claude con las herramientas
/// de un solo servidor—. `.claudeCode` lo enchufa quien lo construye, con
/// `registro.registrar(.claudeCode) { agente in … }`; mientras no esté,
/// contesta el relleno que lo dice.
///
/// Los clientes MCP viven lo que dura la llamada: se lanzan la primera vez
/// que un agente los necesita, los comparten Dilo y el agente del servidor, y
/// se cierran al colgar.
@MainActor
final class DestinosDeLaConversacion {
  /// Cuánto espera el primer turno a que un servidor MCP liste sus
  /// herramientas. El que no alcanza se queda fuera de esta llamada: las
  /// herramientas se fijan en el primer turno y no se agregan después (eso
  /// invalidaría lo que Claude pensó).
  nonisolated static let esperaDeLosServidores: Duration = .seconds(8)

  let registro = RegistroDeDestinos()
  /// Cada turno terminado de un destino con Claude, para el log y la barra.
  var alTerminarElTurno: ((Agente, ResumenDelTurno) -> Void)?
  /// Lo que un destino manda sólo a la transcripción, sin decirlo: el
  /// detalle entero de lo que hizo Claude Code (un diff, una salida larga).
  var alTranscribir: ((Agente, String) -> Void)?

  private let settings: AppSettings
  private let leerClave: @Sendable () async -> String?
  private var clientes: [String: ClienteMCP] = [:]

  init(settings: AppSettings, leerClave: @escaping @Sendable () async -> String?) {
    self.settings = settings
    self.leerClave = leerClave
    registro.registrar(.dilo) { [unowned self] agente in
      destinoConClaude(
        agente,
        propias: true,
        servidores: settings.servidoresMCP.filter { $0.encendido && $0.enDilo }
      )
    }
    registro.registrar(.claudeCode) { [unowned self] agente in
      let destino = DestinoClaudeCode(agente: agente, settings: settings)
      destino.alTranscribir = { [weak self] texto in self?.alTranscribir?(agente, texto) }
      return destino
    }
    registro.registrar(.mcp) { [unowned self] agente in
      guard case let .mcp(id) = agente.tipo else { return DestinoSinConectar(agente: agente) }
      return destinoConClaude(agente, propias: false, servidores: settings.servidoresMCP.filter { $0.id == id })
    }
  }

  /// Si el agente contesta por la API de Anthropic: gasta del tope y pide la
  /// clave. Claude Code va por la cuenta de la persona.
  static func usaLaAPI(_ agente: Agente) -> Bool {
    switch agente.tipo {
    case .dilo, .mcp: true
    case .claudeCode: false
    }
  }

  func destino(para agente: Agente) -> any DestinoDeConversacion {
    registro.destino(para: agente)
  }

  /// La llamada se cortó: cada destino suelta lo suyo y los servidores MCP se
  /// cierran.
  func colgar() {
    registro.colgarTodos()
    let todos = clientes.values
    clientes = [:]
    for cliente in todos { Task { await cliente.cerrar() } }
  }

  private func cliente(_ servidor: ServidorMCPConfigurado) -> ClienteMCP {
    if let cliente = clientes[servidor.id], cliente.servidor == servidor { return cliente }
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    let cliente = ClienteMCP(servidor: servidor, versionDeDilo: version)
    clientes[servidor.id] = cliente
    return cliente
  }

  private func destinoConClaude(
    _ agente: Agente,
    propias: Bool,
    servidores: [ServidorMCPConfigurado]
  ) -> DestinoConClaude {
    let deDilo = propias
      ? HerramientasDeLaConversacion.todas(
        dilo: HerramientasDeDilo(fuente: FuenteDelHistorial(), reuniones: ReunionesEnDisco()), mundo: MundoDelMac()
      ) : []
    let conectados = servidores.map { (servidor: $0, cliente: cliente($0)) }
    let nombreDelServidor = servidores.first?.nombre ?? agente.nombre
    let faltaElServidor = !propias && servidores.isEmpty
    let destino = DestinoConClaude(
      agente: agente,
      preparar: {
        if faltaElServidor {
          return HerramientasDelDestino(instrucciones: [(
            nombreDelServidor,
            "Este agente no tiene un servidor MCP conectado y encendido. Dile a la persona que lo conecte en Dilo → Ajustes → Claude → Conexiones MCP."
          )])
        }
        return await Self.preparar(propias: deDilo, servidores: conectados)
      },
      leerClave: leerClave,
      eleccionDeModelo: { [weak settings] in settings?.conversacionModelo ?? .automatico }
    )
    destino.alTerminarElTurno = { [weak self] resumen in self?.alTerminarElTurno?(agente, resumen) }
    return destino
  }

  /// Las herramientas propias más las de cada servidor que contestó a
  /// tiempo. Un servidor que falló queda dicho en las instrucciones, para que
  /// Claude lo cuente si se lo piden, y en el log.
  nonisolated static func preparar(
    propias: [HerramientaDelAgente],
    servidores: [(servidor: ServidorMCPConfigurado, cliente: ClienteMCP)]
  ) async -> HerramientasDelDestino {
    var resultado = HerramientasDelDestino(herramientas: propias)
    await withTaskGroup(of: (ServidorMCPConfigurado, Result<([HerramientaDelAgente], String?), FallaDelClienteMCP>?).self) { grupo in
      for (servidor, cliente) in servidores {
        grupo.addTask {
          let valor = await conPlazo(esperaDeLosServidores) { () -> Result<([HerramientaDelAgente], String?), FallaDelClienteMCP> in
            do {
              let herramientas = try await cliente.herramientas()
              let instrucciones = await cliente.instrucciones
              return .success((herramientas.map { .mcp($0, de: servidor, cliente: cliente) }, instrucciones))
            } catch let falla as FallaDelClienteMCP {
              return .failure(falla)
            } catch {
              return .failure(.cerrado(servidor: servidor.nombre))
            }
          }
          let segundos = Int(esperaDeLosServidores.components.seconds)
          return (servidor, valor ?? .failure(.plazo(servidor: servidor.nombre, metodo: "tools/list", segundos: segundos)))
        }
      }
      for await (servidor, valor) in grupo {
        switch valor {
        case let .success((herramientas, instrucciones))?:
          AppLog.conversacion.notice(
            "mcp: \(servidor.id, privacy: .public) listo con \(herramientas.count) herramientas"
          )
          resultado.herramientas += herramientas
          if let instrucciones, !instrucciones.isEmpty { resultado.instrucciones.append((servidor.nombre, instrucciones)) }
        case let .failure(falla)?:
          AppLog.conversacion.error("mcp: \(servidor.id, privacy: .public) no está: \(falla.mensaje, privacy: .public)")
          resultado.instrucciones.append((
            servidor.nombre, "Ahora no está disponible (\(falla.mensaje)). Si la persona pide algo de ahí, díselo."
          ))
        case nil:
          break
        }
      }
    }
    return resultado
  }

  /// Lo que devuelve el trabajo, o nil si pasó el plazo (y entonces se
  /// cancela).
  nonisolated static func conPlazo<T: Sendable>(
    _ plazo: Duration,
    _ trabajo: @escaping @Sendable () async -> T
  ) async -> T? {
    await withTaskGroup(of: T?.self) { grupo in
      grupo.addTask { await trabajo() }
      grupo.addTask {
        try? await Task.sleep(for: plazo)
        return nil
      }
      let primero = await grupo.next() ?? nil
      grupo.cancelAll()
      return primero
    }
  }
}
