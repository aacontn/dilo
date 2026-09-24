import AppKit
import DiloModes
import Foundation
import Testing

@testable import Dilo

/// El panel del hover con secciones (2026-09-24): recientes —dictados y lo
/// copiado—, la próxima reunión y los modos.
@MainActor
@Suite("El panel del hover")
struct PanelDelHoverTests {
  private let pantalla = HUDScreenSnapshot(
    id: 3,
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    safeAreaTop: 0,
    auxiliaryTopLeftArea: nil,
    auxiliaryTopRightArea: nil,
    menuBarHeight: 24
  )

  // MARK: Recientes

  @Test func losRecientesVanArribaYNoSeRepiten() {
    let content = DictationHUDContent()
    content.agregarReciente("quedamos el martes", origen: .dictado)
    content.agregarReciente("https://dilo.app", origen: .copiado)
    // Dilo pega sus dictados pasando por el portapapeles: el mismo texto no
    // vuelve a entrar como copiado.
    content.agregarReciente("quedamos el martes", origen: .copiado)
    content.agregarReciente("   ", origen: .copiado)
    #expect(content.recientes.map(\.texto) == ["https://dilo.app", "quedamos el martes"])
    #expect(content.recientes.last?.origen == .dictado)
  }

  @Test func losRecientesTienenTecho() {
    let content = DictationHUDContent()
    for i in 0..<40 { content.agregarReciente("texto \(i)", origen: .copiado) }
    #expect(content.recientes.count == DictationHUDContent.recientesGuardados)
    #expect(content.recientes.first?.texto == "texto 39")
    #expect(content.seccionesDelPanel(conDatos: false).recientes == HUDNotchGeometry.recientesEnElPanel)
  }

  @Test func unRecienteSeVeEnUnaLinea() {
    let elemento = ElementoReciente(texto: "hola\nmundo\n\n  chao", origen: .copiado, cuando: Date())
    #expect(elemento.vistazo == "hola mundo   chao")
  }

  /// Tocar una fila copia su texto y la fila lo dice.
  @Test func tocarUnRecienteLoCopia() {
    let stage = HUDStage(settings: AppSettings.previewStore(), reloj: DrivenClock().deadlineClock)
    var copiado: String?
    stage.copiarAlPortapapeles = { copiado = $0 }
    stage.dictationContent.agregarReciente("mándale el informe a Carla", origen: .dictado)
    let elemento = stage.dictationContent.recientes[0]
    stage.dictationContent.alCopiarReciente?(elemento)
    #expect(copiado == "mándale el informe a Carla")
    #expect(stage.dictationContent.recienteCopiadoID == elemento.id)
  }

  // MARK: El portapapeles

  @Test func loSecretoDelPortapapelesNoEntra() {
    let portapapeles = NSPasteboard(name: NSPasteboard.Name("dilo-prueba-\(UUID())"))
    defer { portapapeles.releaseGlobally() }
    portapapeles.clearContents()
    portapapeles.setString("hola", forType: .string)
    #expect(VigiaDelPortapapeles.textoLegible(de: portapapeles) == "hola")

    portapapeles.clearContents()
    portapapeles.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
    portapapeles.setString("contraseña-secreta", forType: .string)
    #expect(VigiaDelPortapapeles.textoLegible(de: portapapeles) == nil)
  }

  @Test func elVigiaAvisaSoloCuandoCambia() {
    let portapapeles = NSPasteboard(name: NSPasteboard.Name("dilo-prueba-\(UUID())"))
    defer { portapapeles.releaseGlobally() }
    let vigia = VigiaDelPortapapeles(portapapeles: portapapeles)
    var avisos: [String] = []
    vigia.alCopiar = { avisos.append($0) }
    vigia.revisar()
    #expect(avisos.isEmpty)
    portapapeles.clearContents()
    portapapeles.setString("algo nuevo", forType: .string)
    vigia.revisar()
    vigia.revisar()
    #expect(avisos == ["algo nuevo"])
  }

  // MARK: La reunión

  private func evento(
    _ titulo: String, en minutos: Double, dura: Double = 30,
    todoElDia: Bool = false, textos: [String] = [], url: URL? = nil,
    ahora: Date
  ) -> LectorDelCalendario.Evento {
    let empieza = ahora.addingTimeInterval(minutos * 60)
    return LectorDelCalendario.Evento(
      titulo: titulo, empieza: empieza, termina: empieza.addingTimeInterval(dura * 60),
      todoElDia: todoElDia, cancelado: false, textos: textos, url: url
    )
  }

  @Test func laProximaEsLaQueNoTermino() throws {
    let ahora = Date()
    let reunion = try #require(LectorDelCalendario.proxima(de: [
      evento("Feriado", en: -60, dura: 24 * 60, todoElDia: true, ahora: ahora),
      evento("Ya pasó", en: -90, ahora: ahora),
      evento("Con Carla", en: 45, textos: ["https://us02web.zoom.us/j/123"], ahora: ahora),
      evento("Standup", en: 12, ahora: ahora),
    ], ahora: ahora))
    #expect(reunion.titulo == "Standup")
    #expect(reunion.enlace == nil)
  }

  @Test func reconoceElEnlaceDeLaVideollamada() {
    let enlace = LectorDelCalendario.enlaceDeVideollamada(
      url: URL(string: "https://example.com/agenda"),
      textos: ["Sala 3", "Unirse: https://meet.google.com/abc-defg-hij gracias"]
    )
    #expect(enlace?.host() == "meet.google.com")
    #expect(LectorDelCalendario.esVideollamada(URL(string: "https://acme.zoom.us/j/1")!))
    #expect(!LectorDelCalendario.esVideollamada(URL(string: "https://notzoom.us.evil.com")!))
  }

  @Test func elPanelDiceCuandoEmpieza() {
    let ahora = Date()
    func reunion(en minutos: Double) -> ProximaReunion {
      ProximaReunion(titulo: "x", empieza: ahora.addingTimeInterval(minutos * 60),
        termina: ahora.addingTimeInterval(minutos * 60 + 1800), enlace: nil)
    }
    #expect(HUDPanelDelHover.cuando(reunion(en: -2), ahora: ahora) == String(localized: "ahora"))
    #expect(HUDPanelDelHover.cuando(reunion(en: 12.5), ahora: ahora).contains("12"))
    #expect(HUDPanelDelHover.cuando(reunion(en: 200), ahora: ahora).contains(":"))
  }

  // MARK: El alto

  /// Cada sección suma su alto fijo, y sin secciones nuevas el panel mide lo
  /// de siempre: la línea de contexto.
  @Test func elAltoSumaLasSecciones() {
    let base = HUDNotchGeometry.altoDelPanelDeHover(for: pantalla)
    #expect(base == 24 + HUDNotchGeometry.altoDelContextoEnReposo)
    let conRecientes = HUDNotchGeometry.altoDelPanelDeHover(
      for: pantalla, secciones: SeccionesDelPanel(recientes: 2)
    )
    #expect(conRecientes == 24 + 2 * HUDNotchGeometry.altoDeUnReciente + HUDNotchGeometry.aireAlPieDelPanel)
    let todo = HUDNotchGeometry.altoDelPanelDeHover(for: pantalla, secciones: .todas)
    #expect(todo <= HUDNotchGeometry.altoMaximoDelHover)
    #expect(todo > conRecientes)
  }

  /// La ventana abierta crece por lo encendido, no por todo lo posible.
  @Test func laVentanaAbiertaCreceSoloPorLoEncendido() {
    var conReunion = pantalla
    conReunion.seccionesPosibles = SeccionesDelPanel(recientes: 3, reunion: true)
    let sin = HUDNotchGeometry.windowSize(for: pantalla).height
    let con = HUDNotchGeometry.windowSize(for: conReunion).height
    #expect(con > sin)
    var todo = pantalla
    todo.seccionesPosibles = .todas
    #expect(HUDNotchGeometry.windowSize(for: todo).height > con)
  }

  // MARK: Los modos

  @Test func elegirUnModoEnElPanelLoGuardaParaElAtajoGeneral() {
    let settings = AppSettings.previewStore()
    let stage = HUDStage(settings: settings, reloj: DrivenClock().deadlineClock)
    stage.colocar(en: pantalla)
    let id = settings.modos.first?.id
    stage.dictationContent.alElegirModo?(id)
    #expect(settings.hudModoDelAtajoGeneral == id)
    #expect(settings.sessionSettings.modoDelAtajoGeneralID == id)
    stage.dictationContent.alElegirModo?(nil)
    #expect(settings.hudModoDelAtajoGeneral == nil)
  }
}
