import CoreGraphics
import Foundation
import Testing

@testable import Dilo

/// El arnés de la muesca: pedir un estado por su nombre y verlo en la ventana
/// real sin dictar.
///
/// Lo que se afirma acá es lo que lo hace seguro de tener encendido en Debug:
/// que un pedido malo o viejo no hace nada, que una escena no suena ni deja
/// botones vivos, y que un dictado de verdad le gana a la muestra.
@Suite("Arnés de la muesca")
struct ArnesDeLaMuescaTests {
  private let ahora = Date(timeIntervalSinceReferenceDate: 800_000_000)

  private func leer(_ linea: String, haceSegundos: TimeInterval = 0) throws(PedidoDeMuestras.Rechazo)
    -> PedidoDeMuestras
  {
    try PedidoDeMuestras.leer(linea, emitido: ahora.addingTimeInterval(-haceSegundos), ahora: ahora)
  }

  @Test func unPedidoBienEscritoSeLee() throws {
    let pedido = try leer("mostrar dictando procesando --segundos 5 --texto hola que tal")
    #expect(pedido.orden == .mostrar([.dictando, .procesando], cada: .seconds(5), mantener: false, texto: "hola que tal"))
    #expect(try leer("mostrar todas").orden == .mostrar(
      EscenaDeMuestra.allCases, cada: .seconds(PedidoDeMuestras.segundosDeFabrica), mantener: false, texto: nil
    ))
    #expect(try leer("mostrar hover --mantener").orden == .mostrar([.hover], cada: .seconds(8), mantener: true, texto: nil))
    #expect(try leer("siguiente").orden == .siguiente)
    #expect(try leer("cerrar").orden == .cerrar)
  }

  /// Los seis rechazos: verbo desconocido, escena desconocida, segundos fuera
  /// de rango por los dos lados, texto de más y un pedido de hace once
  /// segundos.
  @Test func losPedidosMalosSeRechazan() {
    #expect(throws: PedidoDeMuestras.Rechazo.vacio) { try leer("") }
    #expect(throws: PedidoDeMuestras.Rechazo.vacio) { try leer("mostrar --segundos 3") }
    #expect(throws: PedidoDeMuestras.Rechazo.ordenDesconocida("bailar")) { try leer("bailar dictando") }
    #expect(throws: PedidoDeMuestras.Rechazo.escenaDesconocida("reunion")) { try leer("mostrar reunion") }
    #expect(throws: PedidoDeMuestras.Rechazo.segundosFueraDeRango) { try leer("mostrar dictando --segundos 0") }
    #expect(throws: PedidoDeMuestras.Rechazo.segundosFueraDeRango) { try leer("mostrar dictando --segundos 31") }
    #expect(throws: PedidoDeMuestras.Rechazo.segundosFueraDeRango) { try leer("mostrar dictando --segundos") }
    let largo = String(repeating: "a", count: PedidoDeMuestras.largoMaximoDelTexto + 1)
    #expect(throws: PedidoDeMuestras.Rechazo.textoMuyLargo) { try leer("mostrar dictando --texto \(largo)") }
    #expect(throws: PedidoDeMuestras.Rechazo.vencido) { try leer("mostrar dictando", haceSegundos: 11) }
  }

  @Test func elGuionAvanzaConSuTurnoYUnPlazoViejoNoLoMueve() {
    var guion = GuionDeMuestras()
    let efectos = guion.recibir(.mostrar([.reposo, .dictando, .acuse], cada: .seconds(4), mantener: false, texto: nil))
    #expect(efectos == [.dibujar(.reposo), .programarSiguiente(.seconds(4), turno: 1)])
    // `siguiente` adelanta: el plazo del turno 1 ya no vale.
    #expect(guion.recibir(.siguiente) == [.dibujar(.dictando), .programarSiguiente(.seconds(4), turno: 2)])
    #expect(guion.vencio(turno: 1).isEmpty)
    #expect(guion.vencio(turno: 2) == [.dibujar(.acuse), .programarSiguiente(.seconds(4), turno: 3)])
    // Se acabó la cola: vuelve al estado real.
    #expect(guion.vencio(turno: 3) == [.soltar])
    #expect(guion.actual == nil)
  }

  @Test func mantenerNoProgramaYCerrarSuelta() {
    var guion = GuionDeMuestras()
    #expect(guion.recibir(.mostrar([.hover, .reposo], cada: .seconds(8), mantener: true, texto: nil)) == [.dibujar(.hover)])
    #expect(guion.vencio(turno: guion.turno).isEmpty)
    #expect(guion.recibir(.cerrar) == [.soltar])
    // Cerrar sin nada en pantalla no suelta dos veces.
    #expect(guion.recibir(.cerrar).isEmpty)
  }

  @Test func elNombreDeLaNotificacionEsDeEstaCopia() {
    #expect(ReceptorDeMuestras.nombre(paraElBundle: "cl.espaciodigital.dilo.prueba").rawValue
      == "cl.espaciodigital.dilo.prueba.debug.muesca")
    #expect(ReceptorDeMuestras.nombre(paraElBundle: nil).rawValue == "cl.espaciodigital.dilo.debug.muesca")
  }

  // El escenario de verdad, sin GUI: una pantalla inyectada y un reloj dirigido.

  private final class Sonidos: ReproductorDeSonidos {
    private(set) var tocados = 0
    func playBegin(using settings: DictationSoundSettings) { tocados += 1 }
    func playEnd(using settings: DictationSoundSettings) { tocados += 1 }
    func playPaste(using settings: DictationSoundSettings) { tocados += 1 }
  }

  private let simulado = HUDScreenSnapshot(
    id: 2,
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    safeAreaTop: 0,
    auxiliaryTopLeftArea: nil,
    auxiliaryTopRightArea: nil,
    menuBarHeight: 24
  )

  @MainActor
  private func escenario(_ reloj: DrivenClock, sonidos: Sonidos = Sonidos()) -> HUDStage {
    let stage = HUDStage(
      settings: AppSettings.previewStore(),
      reloj: reloj.deadlineClock,
      sonidos: sonidos,
      punteroEn: { .zero }
    )
    stage.colocar(en: simulado)
    return stage
  }

  /// Cada nombre dibuja el estado que dice, y ninguno suena.
  @MainActor
  @Test(arguments: EscenaDeMuestra.allCases)
  func cadaEscenaPoneSuEstadoSinSonar(escena: EscenaDeMuestra) {
    let sonidos = Sonidos()
    let stage = escenario(DrivenClock(), sonidos: sonidos)
    stage.mostrarMuestra(escena, texto: nil)
    #expect(stage.estado == escena.estado)
    #expect(stage.enMuestra)
    #expect(sonidos.tocados == 0, "una escena no es una sesión")
    #expect(!stage.estado.captura || escena == .dictando || escena == .dictandoLargo)
  }

  @MainActor
  @Test func elHoverDelArnesAbreElPanelYElMouseNoLoCierra() {
    let stage = escenario(DrivenClock())
    stage.mostrarMuestra(.hoverCompleto, texto: nil)
    #expect(stage.dictationContent.contextoVisible != nil)
    #expect(stage.encuadre == .abierta)
    #expect(stage.dictationContent.proximaReunion != nil)
    // El mouse de verdad se fue: la escena se queda.
    stage.punteroSalio()
    #expect(stage.dictationContent.punteroEncima)
  }

  /// El acuse dura 700 ms en la app; en el arnés se queda lo que dura la
  /// escena, porque lo que se viene a mirar es el estado.
  @MainActor
  @Test func unResultadoNoVenceMientrasSeMuestra() async {
    let reloj = DrivenClock()
    let stage = escenario(reloj)
    stage.mostrarMuestra(.acuse, texto: nil)
    reloj.advance(by: .seconds(5))
    await Task.yield()
    #expect(stage.estado == .resultado(.listo))
  }

  /// Los botones quedan apagados mientras dura, y vuelven al soltar.
  @MainActor
  @Test func losBotonesSeApaganYVuelven() {
    let stage = escenario(DrivenClock())
    var notas = 0
    stage.dictationContent.alDictarNota = { notas += 1 }
    stage.dictationContent.recientes = []
    stage.mostrarMuestra(.hoverCompleto, texto: nil)
    stage.dictationContent.alDictarNota?()
    #expect(notas == 0)
    #expect(stage.dictationContent.alHacerClic == nil)
    stage.soltarMuestra()
    #expect(!stage.enMuestra)
    #expect(stage.estado == .reposo)
    #expect(stage.dictationContent.recientes.isEmpty, "lo prestado vuelve")
    #expect(stage.dictationContent.alHacerClic != nil)
    stage.dictationContent.alDictarNota?()
    #expect(notas == 1)
  }

  /// Un dictado de verdad le gana a la muestra: la escena se suelta en el
  /// mismo `claim`, el arnés se entera, y la sesión suena como siempre.
  @MainActor
  @Test func unDictadoDeVerdadLeGanaALaMuestra() {
    let sonidos = Sonidos()
    let stage = escenario(DrivenClock(), sonidos: sonidos)
    var interrumpida = false
    stage.alInterrumpirLaMuestra = { interrumpida = true }
    stage.mostrarMuestra(.retenido, texto: nil)
    #expect(stage.control.congelado)

    stage.claim(.dictation, on: simulado)
    stage.recibir(.escuchar)
    #expect(interrumpida)
    #expect(!stage.enMuestra)
    #expect(!stage.control.congelado)
    #expect(stage.estado == .dictando)
    #expect(sonidos.tocados == 1, "el Begin de la sesión real")
  }
}
