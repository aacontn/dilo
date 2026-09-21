import AppKit
import CoreGraphics
import Testing

@testable import Dilo

/// El notch como escenario permanente: dónde descansa la forma, de qué tamaño
/// crece, qué franja de la ventana toma el mouse y qué dice el chip de modo.
///
/// Sale de lo que Alfonso vio el 2026-09-21 en un Mac mini con dos 1080p sin
/// notch: «no se ve como un notch», «está como una ventana que se abrió»,
/// «cuando se deja de dictar, desaparece».
@Suite("Notch como escenario")
struct NotchEscenarioTests {
  private let conNotch = HUDScreenSnapshot(
    id: 1,
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    safeAreaTop: 32,
    auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
    auxiliaryTopRightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
    menuBarHeight: 32
  )
  /// Uno de los dos 1080p del Mac mini, con lo que trae de fábrica.
  private let simulado = HUDScreenSnapshot(
    id: 2,
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    safeAreaTop: 0,
    auxiliaryTopLeftArea: nil,
    auxiliaryTopRightArea: nil,
    menuBarHeight: 24
  )
  private var pildora: HUDScreenSnapshot {
    var copia = simulado
    copia.estiloSinNotch = .pildora
    return copia
  }

  // MARK: El default

  /// Lo que pidió Alfonso: una pantalla sin notch recién sacada de la caja
  /// dibuja el notch simulado, no la píldora.
  @MainActor
  @Test func deFabricaUnaPantallaSinNotchDibujaElNotchSimulado() {
    #expect(AppSettings.previewStore().hudEstiloSinNotch == .notchSimulado)
    #expect(simulado.estiloSinNotch == .notchSimulado)
    #expect(HUDNotchGeometry.simulatesNotch(for: simulado))
    #expect(!HUDNotchGeometry.dibujaPildora(for: simulado))
  }

  /// Quien no eligió nada pasa al notch simulado; quien eligió la píldora a
  /// mano la conserva. Una migración que le borra la elección a alguien es
  /// una preferencia perdida en silencio.
  @MainActor
  @Test func quienNoEligioPasaAlNotchSimuladoYQuienEligioConserva() {
    let suite = "cl.espaciodigital.dilo.tests.notch-escenario"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(AppSettings(defaults: defaults).hudEstiloSinNotch == .notchSimulado)

    let ajustes = AppSettings(defaults: defaults)
    ajustes.hudEstiloSinNotch = .pildora
    #expect(AppSettings(defaults: defaults).hudEstiloSinNotch == .pildora)
  }

  // MARK: Reposo

  /// En reposo la silueta mide lo que mide un notch de verdad: es lo que la
  /// hace leerse como notch y no como una ventana que se abrió.
  @Test func enReposoLaSiluetaMideLoQueUnNotch() {
    #expect(HUDNotchGeometry.reposoSize(for: simulado) == CGSize(width: 185, height: 32))
    #expect(HUDNotchGeometry.reposoSize(for: conNotch) == CGSize(width: 185, height: 32))
    // La píldora descansa más chica: cuelga sobre el escritorio, no sobre una
    // franja que el sistema ya tenía reservada.
    #expect(HUDNotchGeometry.reposoSize(for: pildora) == HUDNotchGeometry.reposoDeLaPildora)
    #expect(HUDNotchGeometry.reposoDeLaPildora.height < 32)
  }

  /// La forma abierta crece **desde** donde descansaba: su cabecera es la
  /// silueta de reposo. Es lo que reemplaza a la corona mango, que iba encima
  /// y se leía como un segundo objeto pegado arriba.
  @Test func laFormaCreceDesdeLaSiluetaEnReposo() {
    for pantalla in [simulado, pildora, conNotch] {
      #expect(
        HUDNotchGeometry.alturaDeCabecera(for: pantalla)
          == HUDNotchGeometry.reposoSize(for: pantalla).height
      )
      let abierto = HUDNotchGeometry.contentSize(
        for: pantalla,
        metrics: .standard,
        visualBandHeight: HUDMetrics.standard.waveBandHeight,
        includesTextBand: true,
        shapingBandHeight: HUDMetrics.standard.shapingBandHeight
      )
      #expect(abierto.height > HUDNotchGeometry.reposoSize(for: pantalla).height)
      #expect(abierto.width <= HUDNotchGeometry.windowSize(for: pantalla).width)
      #expect(
        abierto.height
          <= HUDNotchGeometry.windowSize(for: pantalla).height - HUDNotchGeometry.shadowPadding
      )
    }
  }

  /// El notch simulado nace del borde de arriba y va centrado; la píldora
  /// sigue colgando debajo de la barra, con su aire.
  @Test func cadaFormaSigueDondeLeToca() {
    #expect(HUDNotchGeometry.windowFrame(for: simulado).maxY == simulado.frame.maxY)
    #expect(HUDNotchGeometry.windowFrame(for: simulado).midX == simulado.frame.midX)
    #expect(
      HUDNotchGeometry.windowFrame(for: pildora).maxY
        == pildora.frame.maxY - pildora.menuBarHeight - HUDNotchGeometry.pillDetachment
    )
  }

  // MARK: Sólo la franja central

  /// La ventana anfitriona es mucho más ancha que la forma. Desde que el
  /// escenario vive siempre en pantalla, sólo la silueta puede tomar el
  /// mouse: lo demás son clics de la barra de menús y de la app de al lado.
  @Test func soloLaSiluetaTomaElMouse() {
    let reposo = HUDNotchGeometry.reposoSize(for: simulado)
    let zona = HUDNotchGeometry.zonaInteractiva(for: simulado, tamaño: reposo)
    let ventana = HUDNotchGeometry.windowSize(for: simulado)

    #expect(zona.width == reposo.width)
    #expect(zona.height == reposo.height)
    #expect(zona.maxY == ventana.height, "la silueta cuelga del tope de la ventana")
    #expect(zona.midX == ventana.width / 2)
    #expect(zona.width < ventana.width)
  }

  /// Y esa franja cae en el centro de la barra de menús, que macOS deja
  /// vacío: ni los menús de la app de la izquierda ni los status items de la
  /// derecha quedan debajo (issue #83).
  @Test func laFranjaEnReposoNoLlegaALosStatusItems() {
    let ventana = HUDNotchGeometry.windowFrame(for: simulado)
    let zona = HUDNotchGeometry.zonaInteractiva(
      for: simulado,
      tamaño: HUDNotchGeometry.reposoSize(for: simulado)
    )
    let enPantalla = CGRect(
      x: ventana.minX + zona.minX,
      y: ventana.minY + zona.minY,
      width: zona.width,
      height: zona.height
    )
    // 185 puntos centrados en una pantalla de 1920: quedan más de 800 puntos
    // libres de cada lado.
    #expect(enPantalla.minX - simulado.frame.minX > 800)
    #expect(simulado.frame.maxX - enPantalla.maxX > 800)
    #expect(enPantalla.maxY == simulado.frame.maxY)
  }

  /// Lo que hace que el reposo cueste lo que cuesta una ventana quieta: en
  /// reposo **no hay ninguna vista con `TimelineView` montada**, elija la
  /// persona el visual que elija. El spec §3 pide ~0 % de CPU ahí, y esto es
  /// lo que se puede afirmar sin un medidor (CI re-mide los números).
  @Test(arguments: HUDVoiceVisualStyle.allCases)
  func enReposoNoSeMontaNingunVisualAnimado(visual: HUDVoiceVisualStyle) {
    for reduceMotion in [false, true] {
      #expect(
        !DictationHUDShellView.montaVisualesDeVoz(
          estado: .reposo, visual: visual, reduceMotion: reduceMotion
        )
      )
      #expect(
        !DictationHUDShellView.montaVisualesDeVoz(
          estado: .resultado(.listo), visual: visual, reduceMotion: reduceMotion
        )
      )
      // Y preparando tampoco: nada de onda ficticia mientras falta algo.
      #expect(
        !DictationHUDShellView.montaVisualesDeVoz(
          estado: .preparando(.cargandoModelo), visual: visual, reduceMotion: reduceMotion
        )
      )
    }
    // Dictando sí, salvo con Reducir movimiento, donde manda el medidor
    // quieto.
    #expect(
      DictationHUDShellView.montaVisualesDeVoz(
        estado: .dictando, visual: visual, reduceMotion: false
      )
    )
    #expect(
      !DictationHUDShellView.montaVisualesDeVoz(
        estado: .dictando, visual: visual, reduceMotion: true
      )
    )
  }

  // MARK: El chip de modo

  /// El chip dice el nombre del modo y nada más. «Transformar: Correo» en
  /// gris nombraba el mecanismo, no la sesión.
  @Test func elChipUsaElNombreDelModo() {
    let dictando = DictationHUDShellView.chipDeModo(estado: .dictando, modo: "Correo")
    #expect(dictando?.nombre == "Correo")
    #expect(dictando?.trabajando == false)

    let procesando = DictationHUDShellView.chipDeModo(estado: .procesando, modo: "Correo")
    #expect(procesando?.nombre == "Correo")
    #expect(procesando?.trabajando == true)
  }

  /// Sin modo no hay chip, y en reposo tampoco: no hay sesión que nombrar.
  @Test func sinModoNoHayChip() {
    #expect(DictationHUDShellView.chipDeModo(estado: .dictando, modo: nil) == nil)
    #expect(DictationHUDShellView.chipDeModo(estado: .dictando, modo: "") == nil)
    #expect(DictationHUDShellView.chipDeModo(estado: .reposo, modo: "Correo") == nil)
    #expect(DictationHUDShellView.chipDeModo(estado: .resultado(.listo), modo: "Correo") == nil)
  }

  // MARK: El escenario

  /// Arranca en reposo, con la forma puesta y sin nadie ocupándola.
  @MainActor
  @Test func elEscenarioArrancaEnReposo() {
    let stage = HUDStage(settings: AppSettings.previewStore())
    #expect(stage.estado == .reposo)
    #expect(stage.occupant == .none)
    #expect(!stage.estado.captura)
    #expect(!stage.estado.anima)
  }

  /// Dictar abre la forma; soltar la deja otra vez en reposo **sin sacarla de
  /// la pantalla**. Que la forma desaparezca al terminar es exactamente lo
  /// que la volvía un aviso en vez de un lugar.
  @MainActor
  @Test func alSoltarVuelveAReposoYNoDesaparece() async throws {
    let stage = HUDStage(settings: AppSettings.previewStore())
    stage.claim(.dictation, on: simulado)
    stage.recibir(.escuchar)
    #expect(stage.estado == .dictando)

    stage.retract()
    try await Task.sleep(for: HUDStage.dismissDuration + .milliseconds(200))
    #expect(stage.estado == .reposo)
    #expect(stage.occupant == .none)
  }

  /// El hover revela contexto y **nunca** arranca una captura.
  @MainActor
  @Test func elHoverNoCaptura() async throws {
    let stage = HUDStage(settings: AppSettings.previewStore())
    stage.dictationContent.contexto = "Correo"
    stage.dictationContent.alEntrarElPuntero?(true)
    try await Task.sleep(for: HUDStage.toleranciaDelHover + .milliseconds(200))

    #expect(stage.dictationContent.punteroEncima)
    #expect(stage.dictationContent.contextoVisible == "Correo")
    #expect(stage.estado == .reposo)
    #expect(!stage.estado.captura, "un hover jamás abre el micrófono")
  }

  /// Y un clic en reposo pide el menú de acciones, no una sesión.
  @MainActor
  @Test func elClicEnReposoPideElMenuDeAcciones() {
    let stage = HUDStage(settings: AppSettings.previewStore())
    var pedidos = 0
    stage.alPedirAcciones = { pedidos += 1 }
    stage.dictationContent.alHacerClic?()
    #expect(pedidos == 1)
    #expect(stage.estado == .reposo)
  }
}
