import Foundation
import Testing

@testable import DiloModes

/// A qué agente va lo dicho: el nombre adelante, lo que Parakeet oye mal, los
/// cambios sin mensaje y el último agente de la llamada.
struct EnrutadorDeAgentesTests {
  @Test(arguments: [
    ("kami", "kami"), ("cami", "kami"), ("camí", "kami"), ("kammy", "kami"), ("quique", "kike"),
    ("cecilia", "sesilia"), ("zoe", "soe"), ("vale", "bale"), ("hugo", "ugo"), ("guille", "guiye"),
    ("yoli", "yoli"), ("rey", "rei"), ("chelo", "chelo"), ("dilo", "dilo"),
  ])
  func comoSuena(plegada: String, clave: String) {
    #expect(ComoSuena.clave(SenalesDelTurno.plegar(plegada)) == clave)
  }

  @Test(arguments: [
    "Abre Cloud Code", "abrir Claude Code", "¿Puedes abrir Claude Code?", "Quiero abrir Claude Code por favor",
    "Usa Claude Code",
  ])
  func pedirUnAgenteCambiaDeAgente(dicho: String) {
    #expect(EnrutadorDeAgentes(agentes: Agente.deFabrica).enrutar(dicho, ultimo: nil) == .cambiarA(Agente.deFabrica[1]))
  }

  @Test func unNombrePropioSeEnrutaPorComoSuena() {
    let kami = Agente(id: "dilo", nombre: "Kami", tipo: .dilo, seLlamaPorNombre: true)
    let enrutador = EnrutadorDeAgentes(agentes: [kami, Agente.deFabrica[1]])
    #expect(enrutador.enrutar("Cami, ¿qué tengo hoy?", ultimo: Agente.deFabrica[1])
      == .turno(TurnoDeLaPersona(agente: kami, texto: "¿Qué tengo hoy?")))
  }

  let enrutador = EnrutadorDeAgentes(agentes: Agente.deFabrica)
  var dilo: Agente { Agente.deFabrica[0] }
  var claudeCode: Agente { Agente.deFabrica[1] }
  var switchboard: Agente { Agente.deFabrica[2] }

  @Test(arguments: [
    ("Claude Code, revisa los tests", "claude-code", "Revisa los tests"),
    ("claude code revisa los tests", "claude-code", "Revisa los tests"),
    ("Cloud Code, ¿en qué quedó el build?", "claude-code", "¿En qué quedó el build?"),
    ("clod code corre swift test", "claude-code", "Corre swift test"),
    ("Switchboard, ¿qué tengo hoy?", "switchboard", "¿Qué tengo hoy?"),
    ("Suichbord, ¿qué tengo hoy?", "switchboard", "¿Qué tengo hoy?"),
    ("switch board qué tengo hoy", "switchboard", "Qué tengo hoy"),
    ("Dilo: ¿cuántos dictados hice ayer?", "dilo", "¿Cuántos dictados hice ayer?"),
    ("Oye Dilo, ¿qué hora es?", "dilo", "¿Qué hora es?"),
    ("SWITCHBOARD. Anota que llamé a Marta", "switchboard", "Anota que llamé a Marta"),
  ])
  func elNombreAdelanteSeSeparaDeLoDicho(dicho: String, id: String, texto: String) {
    guard case let .turno(turno) = enrutador.enrutar(dicho, ultimo: nil) else {
      Issue.record("\(dicho) no salió como turno")
      return
    }
    #expect(turno.agente.id == id)
    #expect(turno.texto == texto)
  }

  @Test(arguments: [
    ("Revisa Claude Code", "claude-code"),
    ("abre cloud code", "claude-code"),
    ("Pásame con Switchboard", "switchboard"),
    ("pásame con suichbord, por favor", "switchboard"),
    ("Quiero hablar con Dilo", "dilo"),
    ("¿Switchboard?", "switchboard"),
    ("Claude Code.", "claude-code"),
  ])
  func losCambiosNoMandanNada(dicho: String, id: String) {
    #expect(enrutador.enrutar(dicho, ultimo: dilo) == .cambiarA(Agente.deFabrica.first { $0.id == id }!))
  }

  @Test func unCambioConAlgoMasLeMandaEseAlgoAlNombrado() {
    let ruta = enrutador.enrutar("Abre Claude Code y corre los tests de DiloCore", ultimo: dilo)
    #expect(ruta == .turno(TurnoDeLaPersona(agente: claudeCode, texto: "Corre los tests de DiloCore")))
  }

  @Test func sinNombreVaAlUltimoDeLaLlamada() {
    let ruta = enrutador.enrutar("y ahora revisa los tests", ultimo: claudeCode)
    #expect(ruta == .turno(TurnoDeLaPersona(agente: claudeCode, texto: "y ahora revisa los tests")))
  }

  @Test func sinNombreNiUltimoVaADilo() {
    #expect(enrutador.enrutar("¿Qué tengo hoy?", ultimo: nil) == .turno(TurnoDeLaPersona(agente: dilo, texto: "¿Qué tengo hoy?")))
  }

  @Test func unVerboDeCambioSinNombreEsUnTurnoComun() {
    #expect(
      enrutador.enrutar("Revisa mis reuniones de ayer", ultimo: switchboard)
        == .turno(TurnoDeLaPersona(agente: switchboard, texto: "Revisa mis reuniones de ayer"))
    )
  }

  @Test func unNombrePropioRenombradoSeReconoceComoSeEscribio() {
    var renombrado = switchboard
    renombrado.nombre = "Centralita"
    let enrutador = EnrutadorDeAgentes(agentes: [dilo, claudeCode, renombrado])
    #expect(
      enrutador.enrutar("Centralita, ¿qué tengo hoy?", ultimo: nil)
        == .turno(TurnoDeLaPersona(agente: renombrado, texto: "¿Qué tengo hoy?"))
    )
    // El nombre viejo ya no llama a nadie.
    #expect(
      enrutador.enrutar("Switchboard, ¿qué tengo hoy?", ultimo: nil)
        == .turno(TurnoDeLaPersona(agente: dilo, texto: "Switchboard, ¿qué tengo hoy?"))
    )
  }

  @Test func ganaElNombreMasLargo() {
    let claude = Agente(id: "claude", nombre: "Claude", tipo: .dilo, seLlamaPorNombre: false)
    let enrutador = EnrutadorDeAgentes(agentes: [claude, claudeCode])
    guard case let .turno(turno) = enrutador.enrutar("Claude Code, corre los tests", ultimo: nil) else {
      Issue.record("no salió como turno")
      return
    }
    #expect(turno.agente == claudeCode)
  }

  @Test func elNombreSoloAlPrincipio() {
    let ruta = enrutador.enrutar("Dile a Switchboard que anote esto", ultimo: dilo)
    #expect(ruta == .turno(TurnoDeLaPersona(agente: dilo, texto: "Dile a Switchboard que anote esto")))
  }

  @Test func lasVariantesIncluyenElNombre() {
    #expect(EnrutadorDeAgentes.variantes(de: claudeCode).first == "claude code")
    #expect(EnrutadorDeAgentes.variantes(de: claudeCode).contains("cloud code"))
    #expect(EnrutadorDeAgentes.variantes(de: switchboard).contains("suichbord"))
  }

  @Test func sinDiloEnLaListaElPrimeroEsElDeFabrica() {
    let enrutador = EnrutadorDeAgentes(agentes: [switchboard, claudeCode])
    #expect(enrutador.porDefecto == switchboard)
  }
}

/// El registro de destinos: una fábrica por tipo, un destino por agente
/// durante la llamada, y un relleno que lo dice cuando falta la fábrica.
@MainActor
struct RegistroDeDestinosTests {
  final class DestinoDePrueba: DestinoDeConversacion {
    let agente: Agente
    var colgado = false
    init(agente: Agente) { self.agente = agente }
    func responder(_ turno: TurnoDeLaPersona) -> AsyncThrowingStream<EventoDelDestino, any Error> {
      AsyncThrowingStream { $0.finish() }
    }
    func colgar() { colgado = true }
  }

  @Test func sinFabricaContestaElRellenoYLoDice() async throws {
    let registro = RegistroDeDestinos()
    let claudeCode = Agente.deFabrica[1]
    let destino = registro.destino(para: claudeCode)
    #expect(destino is DestinoSinConectar)
    #expect(!registro.estaConectado(.claudeCode))
    var textos: [String] = []
    var termino = false
    for try await evento in destino.responder(TurnoDeLaPersona(agente: claudeCode, texto: "hola")) {
      switch evento {
      case let .texto(texto): textos.append(texto)
      case .fin: termino = true
      default: break
      }
    }
    #expect(textos == ["Claude Code todavía no está conectado a Dilo."])
    #expect(termino)
  }

  @Test func elMismoAgenteGuardaSuDestinoHastaColgar() {
    let registro = RegistroDeDestinos()
    var armados = 0
    registro.registrar(.mcp) { agente in
      armados += 1
      return DestinoDePrueba(agente: agente)
    }
    let switchboard = Agente.deFabrica[2]
    let primero = registro.destino(para: switchboard)
    let segundo = registro.destino(para: switchboard)
    #expect(primero === segundo)
    #expect(armados == 1)
    registro.colgarTodos()
    #expect((primero as? DestinoDePrueba)?.colgado == true)
    _ = registro.destino(para: switchboard)
    #expect(armados == 2)
  }

  @Test func unAgenteRenombradoSeArmaDeNuevo() {
    let registro = RegistroDeDestinos()
    registro.registrar(.dilo) { DestinoDePrueba(agente: $0) }
    var dilo = Agente.deFabrica[0]
    let antes = registro.destino(para: dilo)
    dilo.nombre = "Lola"
    let despues = registro.destino(para: dilo)
    #expect(antes !== despues)
    #expect((antes as? DestinoDePrueba)?.colgado == true)
  }

  @Test func laClaseIgnoraElServidor() {
    #expect(Agente.Tipo.mcp(servidor: "a").clase == Agente.Tipo.mcp(servidor: "b").clase)
    #expect(Agente.Tipo.dilo.clase == .dilo)
  }
}

/// El turno que entra de afuera: lo dicho tras el nombre que despertó a
/// Dilo, o un turno con la llamada en curso.
struct TurnoDeAfueraTests {
  @Test func colgadaLaLlamadaEmpiezaPensando() {
    var maquina = MaquinaDeLaConversacion()
    #expect(maquina.recibir(.turnoDeAfuera) == [.consultar])
    #expect(maquina.estado == .pensando)
    #expect(maquina.recibir(.terminoDeHablar) == [.abrirMicrofono])
    #expect(maquina.estado == .escuchando)
  }

  @Test func escuchandoCierraElMicrofonoSinEntregar() {
    var maquina = MaquinaDeLaConversacion()
    _ = maquina.recibir(.llamar)
    #expect(maquina.recibir(.turnoDeAfuera) == [.cerrarMicrofono(entregar: false), .consultar])
    #expect(maquina.estado == .pensando)
  }

  @Test func hablandoCortaLoDeAntes() {
    var maquina = MaquinaDeLaConversacion()
    _ = maquina.recibir(.llamar)
    _ = maquina.recibir(.terminoTuTurno)
    _ = maquina.recibir(.transcrito(vacio: false))
    _ = maquina.recibir(.empezoAHablar)
    #expect(maquina.recibir(.turnoDeAfuera) == [.cancelarConsulta, .callarLaVoz, .consultar])
    #expect(maquina.estado == .pensando)
  }
}
