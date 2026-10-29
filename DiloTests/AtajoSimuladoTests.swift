import ApplicationServices
import Testing
@testable import Dilo

/// El ⌘V y el ⌘C que Dilo simula, capturados en vez de publicados.
///
/// La regresión: se mandaba sólo la V con el flag de ⌘, sin que ⌘ bajara ni
/// subiera. El sistema podía quedarse con ⌘ marcada y el siguiente espacio
/// abría Spotlight.
@MainActor
struct AtajoSimuladoTests {
  /// Un evento capturado, reducido a lo que la secuencia decide.
  private struct Capturado: Equatable {
    let tecla: Int64
    let tipo: CGEventType
    let modificadores: UInt64

    init(_ evento: CGEvent) {
      tecla = evento.getIntegerValueField(.keyboardEventKeycode)
      tipo = evento.type
      modificadores = evento.flags.intersection(AtajoSimulado.bitsDeModificador).rawValue
    }

    init(_ tecla: Int64, _ tipo: CGEventType, _ modificadores: CGEventFlags) {
      self.tecla = tecla
      self.tipo = tipo
      self.modificadores = modificadores.rawValue
    }
  }

  /// ⌘ izquierda tal como la marca un teclado real: el flag compartido más
  /// el bit de su lado.
  private let comandoIzquierda = CGEventFlags(
    rawValue: CGEventFlags.maskCommand.rawValue | 0x0008
  )

  private func capturar(
    _ tecla: CGKeyCode,
    apretadas: AtajoSimulado.TeclasApretadas = .ninguna
  ) -> (publicado: Bool, eventos: [CGEvent]) {
    var eventos: [CGEvent] = []
    let publicado = TextInsertionService.postShortcut(
      virtualKey: tecla,
      apretadas: apretadas,
      publicar: { eventos.append($0) }
    )
    return (publicado, eventos)
  }

  @Test func pegarAprietaYSueltaComandoAlrededorDeLaV() {
    let (publicado, eventos) = capturar(9)

    #expect(publicado)
    #expect(eventos.map(Capturado.init) == [
      Capturado(55, .flagsChanged, comandoIzquierda),
      Capturado(9, .keyDown, comandoIzquierda),
      Capturado(9, .keyUp, comandoIzquierda),
      Capturado(55, .flagsChanged, []),
    ])
  }

  @Test func copiarAprietaYSueltaComandoAlrededorDeLaC() {
    let (publicado, eventos) = capturar(8)

    #expect(publicado)
    #expect(eventos.map(Capturado.init) == [
      Capturado(55, .flagsChanged, comandoIzquierda),
      Capturado(8, .keyDown, comandoIzquierda),
      Capturado(8, .keyUp, comandoIzquierda),
      Capturado(55, .flagsChanged, []),
    ])
  }

  /// Lo que abría Spotlight: después del último evento no puede quedar
  /// ningún modificador marcado, ni el compartido ni el de un lado.
  @Test func elUltimoEventoDejaLosModificadoresLimpios() throws {
    for tecla: CGKeyCode in [8, 9] {
      let ultimo = try #require(capturar(tecla).eventos.last)
      #expect(ultimo.flags.intersection(AtajoSimulado.bitsDeModificador).isEmpty)
      #expect(ultimo.getIntegerValueField(.keyboardEventKeycode) == 55)
    }
  }

  /// Sin la marca, el tap de Dilo leería su propio ⌘ como la persona.
  @Test func cadaEventoLlevaLaMarcaDeDilo() {
    let eventos = capturar(9).eventos
    #expect(!eventos.isEmpty)
    #expect(eventos.allSatisfy(AtajoSimulado.esDeDilo))
  }

  /// Quien ya sostiene ⌘ la sigue sosteniendo: Dilo no la aprieta ni la
  /// suelta por esa persona.
  @Test func conComandoYaApretadaNoLaTocaNiLaSuelta() {
    let (publicado, eventos) = capturar(9, apretadas: .init(modificadores: [55]))

    #expect(publicado)
    #expect(eventos.map(Capturado.init) == [
      Capturado(9, .keyDown, comandoIzquierda),
      Capturado(9, .keyUp, comandoIzquierda),
    ])
  }

  /// ⌘ derecha sostenida se respeta con su propio lado, no con el izquierdo.
  @Test func comandoDerechaDeLaPersonaConservaSuLado() {
    let derecha = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x0010)
    let eventos = capturar(9, apretadas: .init(modificadores: [54])).eventos

    #expect(eventos.map(Capturado.init) == [
      Capturado(9, .keyDown, derecha),
      Capturado(9, .keyUp, derecha),
    ])
  }

  /// ⇧ y fn sostenidos —fn es el gatillo de fábrica— no viajan en la V,
  /// que se volvería otro comando, pero el último evento los devuelve:
  /// Dilo no los suelta por la persona y nunca manda eventos de esas teclas.
  @Test func losModificadoresDeLaPersonaVuelvenAlFinal() throws {
    let shiftIzquierda = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x0002)
    let deLaPersona = shiftIzquierda.union(.maskSecondaryFn)
    let eventos = capturar(9, apretadas: .init(modificadores: [56, 63])).eventos

    #expect(eventos.map(Capturado.init) == [
      Capturado(55, .flagsChanged, comandoIzquierda),
      Capturado(9, .keyDown, comandoIzquierda),
      Capturado(9, .keyUp, comandoIzquierda),
      Capturado(55, .flagsChanged, deLaPersona),
    ])
  }

  /// Un gatillo que no es modificador —F19, por ejemplo— no aparece nunca:
  /// la secuencia sólo toca ⌘ y la tecla del atajo.
  @Test func nuncaTocaOtraTeclaQueComandoYLaDelAtajo() {
    let teclas = Set(capturar(9, apretadas: .init(modificadores: [63])).eventos.map {
      $0.getIntegerValueField(.keyboardEventKeycode)
    })
    #expect(teclas == [55, 9])
  }

  @Test func bloqMayusViajaEnTodosLosEventos() {
    let eventos = capturar(9, apretadas: .init(bloqMayus: true)).eventos

    #expect(eventos.count == 4)
    #expect(eventos.allSatisfy { $0.flags.contains(.maskAlphaShift) })
    #expect(eventos.last.map {
      $0.flags.intersection(AtajoSimulado.bitsDeModificador) == .maskAlphaShift
    } == true)
  }

  /// Si un evento no se puede crear a mitad de camino, no sale ninguno: un ⌘
  /// que baja sin su subida es el bug entero.
  @Test func siUnEventoNoSePuedeCrearNoSePublicaNinguno() {
    var creados = 0
    var publicados: [CGEvent] = []
    let publicado = TextInsertionService.postShortcut(
      virtualKey: 9,
      apretadas: .ninguna,
      crear: { pulsacion in
        creados += 1
        guard creados < 3 else { return nil }
        return AtajoSimulado.evento(pulsacion, fuente: nil)
      },
      publicar: { publicados.append($0) }
    )

    #expect(!publicado)
    #expect(creados == 3)
    #expect(publicados.isEmpty)
  }

  /// Con ⌘ izquierda sola de gatillo y ⌘ derecha para traducir —la de
  /// fábrica—, pegar no arranca ninguna sesión y todo pasa a la app.
  @Test func elTapDeDiloDejaPasarSuPropioAtajo() {
    let log = EventLog()
    let monitor = GlobalKeyEventMonitor(handler: log.append)
    let comandoSola = KeyBinding(
      keyCode: 55, modifierFlags: 0, isModifierKey: true,
      label: "⌘", keyEquivalent: ""
    )
    monitor.setBindings(
      trigger: comandoSola,
      secondaryTrigger: nil,
      readAloud: .optionEscape,
      translateTrigger: .rightCommandTrigger
    )

    for evento in capturar(9).eventos {
      #expect(monitor.process(type: evento.type, event: evento) != nil)
    }
    #expect(log.events.isEmpty)
  }

  /// Aun sin la marca, el bit del lado izquierdo es lo que impide que el ⌘
  /// simulado se lea como ⌘ derecha, el gatillo de fábrica de traducir.
  @Test func elComandoSimuladoNoSeLeeComoComandoDerecha() throws {
    let abajo = try #require(capturar(9).eventos.first)
    #expect(!GlobalKeyEventMonitor.isModifierKeyDown(
      .rightCommandTrigger, flags: abajo.flags
    ))
  }
}

/// El ↩ de «envía»: solo, sin modificadores, y nunca encima de uno.
@MainActor
struct IntroDelEnvioTests {
  @Test func elIntroVaSoloYSinModificadores() throws {
    let pulsaciones = try #require(AtajoSimulado.pulsacionesDeIntro(con: .ninguna))
    #expect(pulsaciones.map(\.tecla) == [AtajoSimulado.intro, AtajoSimulado.intro])
    #expect(pulsaciones.map(\.abajo) == [true, false])
    #expect(pulsaciones.allSatisfy { $0.modificadores.isEmpty })
  }

  /// ⇧↩ es un salto de línea y ⌘↩ manda distinto: con un modificador
  /// apretado no hay ↩.
  @Test func conUnModificadorApretadoNoHayIntro() {
    for tecla: CGKeyCode in [55, 56, 58, 59, 63] {
      let apretadas = AtajoSimulado.TeclasApretadas(modificadores: [tecla])
      #expect(AtajoSimulado.pulsacionesDeIntro(con: apretadas) == nil, "tecla \(tecla)")
    }
  }

  /// Bloq Mayús es un estado, no una tecla sostenida: el ↩ sale y lo lleva.
  @Test func bloqMayusNoBloqueaYViaja() throws {
    let pulsaciones = try #require(
      AtajoSimulado.pulsacionesDeIntro(con: AtajoSimulado.TeclasApretadas(bloqMayus: true))
    )
    #expect(pulsaciones.allSatisfy { $0.modificadores == .maskAlphaShift })
  }

  /// Si la persona suelta la tecla mientras se la espera, se manda.
  @Test func esperaAQueSuelteYManda() async {
    var lecturas = 0
    var dormido = Duration.zero
    var publicados = 0
    let mandado = await EnvioDelMensaje.apretarIntro(
      por: .alSistema,
      apretadas: {
        lecturas += 1
        return lecturas < 4 ? AtajoSimulado.TeclasApretadas(modificadores: [59]) : .ninguna
      },
      crear: { _ in CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true) },
      publicar: { _ in publicados += 1 },
      dormir: { dormido += $0 }
    )
    #expect(mandado)
    #expect(publicados == 2)
    #expect(dormido < EnvioDelMensaje.esperaPorModificadores)
  }

  /// Si la sigue sosteniendo, a los dos segundos se rinde sin mandar nada.
  @Test func siNoSueltaNoManda() async {
    var publicados = 0
    let mandado = await EnvioDelMensaje.apretarIntro(
      por: .alSistema,
      apretadas: { AtajoSimulado.TeclasApretadas(modificadores: [55]) },
      crear: { _ in CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true) },
      publicar: { _ in publicados += 1 },
      dormir: { _ in }
    )
    #expect(!mandado)
    #expect(publicados == 0)
  }
}
