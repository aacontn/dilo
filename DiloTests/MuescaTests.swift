import CoreGraphics
import Foundation
import Testing

@testable import Dilo

/// La muesca: la silueta que Dilo dibuja en una pantalla sin carcasa.
///
/// Sale del veredicto de Alfonso sobre el notch simulado del 2026-09-21, en su
/// Mac mini con dos 1080p: «deja tu cuadrado terrible feo; la idea es que sea
/// una pequeña muesca, algo chiquitito». El rectángulo de 185×32 con fillets
/// en cero era un bloque apoyado encima de la barra. Lo que esta suite cuida
/// es lo que lo convierte en un recorte del borde: el alto sale de la barra de
/// menús de esa pantalla, el ancho es de muesca y las dos esquinas de arriba
/// son cóncavas.
@Suite("La muesca")
struct MuescaTests {
  private func pantalla(barra: CGFloat, ancho: CGFloat = 1920) -> HUDScreenSnapshot {
    HUDScreenSnapshot(
      id: 2,
      frame: CGRect(x: 0, y: 0, width: ancho, height: 1080),
      safeAreaTop: 0,
      auxiliaryTopLeftArea: nil,
      auxiliaryTopRightArea: nil,
      menuBarHeight: barra,
      estiloSinNotch: .notchSimulado
    )
  }

  private let conNotch = HUDScreenSnapshot(
    id: 1,
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    safeAreaTop: 32,
    auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
    auxiliaryTopRightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
    menuBarHeight: 32
  )

  /// El alto es el de la barra de menús de **esa** pantalla, medida, no una
  /// constante: la misma app en un 1080p y en un Retina escalado se encuentra
  /// barras distintas, y una muesca más alta que la barra sobresale al
  /// escritorio.
  @Test(arguments: [24.0, 25.0, 37.0])
  func elAltoEsElDeLaBarraDeMenus(barra: Double) {
    let pantalla = pantalla(barra: barra)
    #expect(HUDNotchGeometry.reposoSize(for: pantalla).height == barra)
    #expect(HUDNotchGeometry.alturaDeCabecera(for: pantalla) == barra)
  }

  /// Dentro de un espacio en pantalla completa la barra se autooculta y el
  /// sistema reporta cero. Sin piso la muesca desaparecería al cambiar de
  /// espacio y volvería a salir al salir: se queda donde está.
  @Test func conLaBarraAutoocultaLaMuescaNoSeColapsa() {
    let altura = HUDNotchGeometry.reposoSize(for: pantalla(barra: 0)).height
    #expect(altura == HUDNotchGeometry.menuBarClearanceFloor)
    #expect(altura > 0)
  }

  /// El ancho de una muesca, no el de una carcasa prestada. El rango es el de
  /// las referencias que Alfonso pasó —Boring Notch, Sapphire—: por debajo se
  /// lee como una pestaña y por encima vuelve a ser el bloque.
  @Test func elAnchoEnReposoEsDeMuesca() {
    let ancho = HUDNotchGeometry.reposoSize(for: pantalla(barra: 24)).width
    #expect(ancho >= 150 && ancho <= 170)
    #expect(ancho < HUDNotchGeometry.fallbackClosedSize.width)
  }

  /// Las dos curvas cóncavas de arriba son lo que funde la silueta con el
  /// borde. Enmienda ADR-0001, que las reservaba para una carcasa física.
  @Test func laMuescaLlevaCurvasComoCasas() {
    let simulada = pantalla(barra: 24)
    let fillet = HUDNotchGeometry.filletSize(for: simulada)
    #expect(fillet > 0)
    #expect(fillet >= 8 && fillet <= 10)
    // Algo menores que contra hardware: el bisel que imitan es dibujado.
    #expect(fillet < HUDNotchGeometry.filletSize(for: conNotch))
    // Y las de abajo siguen siendo convexas, con un radio que se nota sobre
    // una silueta del alto de la barra.
    #expect(HUDNotchGeometry.radioEnReposo(for: simulada) >= 10)
    #expect(HUDNotchGeometry.radioEnReposo(for: simulada) <= 12)
  }

  /// La píldora no las lleva: flota separada de la barra y no toca ningún
  /// borde en el que fundirse.
  @Test func laPildoraSigueSinCurvas() {
    var pildora = pantalla(barra: 24)
    pildora.estiloSinNotch = .pildora
    #expect(HUDNotchGeometry.filletSize(for: pildora) == 0)
    #expect(HUDNotchGeometry.reposoSize(for: pildora) == HUDNotchGeometry.reposoDeLaPildora)
  }

  /// Crecer no despega la forma del borde ni la descentra: la muesca abierta
  /// es la misma muesca más grande, anclada arriba y al medio.
  @Test func alExpandirseSigueAncladaArribaYAlCentro() {
    let simulada = pantalla(barra: 24)
    let ventana = HUDNotchGeometry.windowFrame(for: simulada)
    #expect(ventana.maxY == simulada.frame.maxY, "la ventana nace del borde de arriba")
    #expect(ventana.midX == simulada.frame.midX)

    let reposo = HUDNotchGeometry.reposoSize(for: simulada)
    let abierta = HUDNotchGeometry.contentSize(
      for: simulada,
      metrics: .standard,
      visualBandHeight: HUDMetrics.standard.waveBandHeight,
      includesTextBand: true,
      shapingBandHeight: HUDMetrics.standard.shapingBandHeight
    )
    #expect(abierta.width > reposo.width)
    #expect(abierta.height > reposo.height)

    for tamaño in [reposo, abierta] {
      let zona = HUDNotchGeometry.zonaInteractiva(for: simulada, tamaño: tamaño)
      #expect(zona.maxY == HUDNotchGeometry.windowSize(for: simulada).height)
      #expect(zona.midX == HUDNotchGeometry.windowSize(for: simulada).width / 2)
      #expect(ventana.minY + zona.maxY == simulada.frame.maxY)
    }
  }

  /// Y la cabecera de la forma abierta sigue siendo la silueta en reposo: la
  /// muesca crece desde donde descansaba, no aparece encima de ella.
  @Test func laFormaAbiertaCreceDesdeLaMuesca() {
    let simulada = pantalla(barra: 24)
    #expect(
      HUDNotchGeometry.alturaDeCabecera(for: simulada)
        == HUDNotchGeometry.reposoSize(for: simulada).height
    )
  }


  /// Cerrada, la muesca es la barra negra que ya estaba ahí. En una app en
  /// pantalla completa esa barra no está, así que el **reposo** se esconde:
  /// una muesca flotando sobre el borde de un Keynote es justo lo contrario.
  @Test func enPantallaCompletaElReposoSeEsconde() {
    #expect(HUDNotchGeometry.reposoSeEsconde(for: pantalla(barra: 0)))
    #expect(!HUDNotchGeometry.reposoSeEsconde(for: pantalla(barra: 24)))
    // Con carcasa el recorte físico sigue ahí pase lo que pase.
    let conNotchSinBarra = HUDScreenSnapshot(
      id: conNotch.id,
      frame: conNotch.frame,
      safeAreaTop: conNotch.safeAreaTop,
      auxiliaryTopLeftArea: conNotch.auxiliaryTopLeftArea,
      auxiliaryTopRightArea: conNotch.auxiliaryTopRightArea,
      menuBarHeight: 0
    )
    #expect(!HUDNotchGeometry.reposoSeEsconde(for: conNotchSinBarra))
  }

  /// Y los estados activos sí aparecen: dictando, procesando y el resultado
  /// dicen algo que no puede esperar a que alguien salga del espacio.
  @MainActor
  @Test func enPantallaCompletaLosEstadosActivosSiAparecen() {
    let reloj = DrivenClock()
    let stage = HUDStage(settings: AppSettings.previewStore(), reloj: reloj.deadlineClock)
    stage.claim(.dictation, on: pantalla(barra: 0))
    #expect(stage.escondido, "el reposo se esconde")
    stage.recibir(.escuchar)
    #expect(!stage.escondido)
    stage.recibir(.procesar)
    #expect(!stage.escondido)
    stage.recibir(.entregar(.listo))
    #expect(!stage.escondido)
    stage.recibir(.cancelar)
    #expect(stage.escondido)
  }


  /// El retardo del hover es un ajuste, no una constante: dónde está la línea
  /// entre «me acerqué a mirar» y «pasé camino al menú» depende de cómo mueve
  /// el mouse cada persona. De fábrica, medio segundo.
  @MainActor
  @Test func elRetardoDelHoverLoMandaElAjuste() async {
    #expect(AppSettings.previewStore().hudRetardoDeHover == HUDStage.retardoDeHoverDeFabrica)

    let ajustes = AppSettings.previewStore()
    ajustes.hudRetardoDeHover = 1.2
    let reloj = DrivenClock()
    let stage = HUDStage(settings: ajustes, reloj: reloj.deadlineClock)
    stage.dictationContent.contexto = "Correo"
    stage.dictationContent.alEntrarElPuntero?(true)

    await reloj.waitForSleeper()
    reloj.advance(by: .milliseconds(500))
    await Task.yield()
    #expect(!stage.dictationContent.punteroEncima, "medio segundo no alcanza con 1,2 s")

    reloj.advance(by: .milliseconds(700))
    while !stage.dictationContent.punteroEncima {
      await Task.yield()
    }
    #expect(stage.dictationContent.contextoVisible == "Correo")
    #expect(!stage.estado.captura, "un hover jamás abre el micrófono")
  }


  /// Elegir una pantalla manda sobre el cursor y sobre el destino con foco:
  /// quien la eligió quiere la muesca ahí.
  @Test func laPantallaElegidaMandaSobreElCursor() {
    let principal = pantalla(barra: 24)
    let segunda = HUDScreenSnapshot(
      id: 3,
      frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
      safeAreaTop: 0,
      auxiliaryTopLeftArea: nil,
      auxiliaryTopRightArea: nil,
      menuBarHeight: 24,
      estiloSinNotch: .notchSimulado,
      nombre: "La de al lado"
    )
    let pantallas = [principal, segunda]

    #expect(
      HUDPlacement.selectDisplay(
        from: pantallas,
        targetDisplayID: principal.id,
        pointerLocation: CGPoint(x: 10, y: 10),
        pantallaElegida: "La de al lado"
      )?.id == segunda.id
    )
    // Y si esa pantalla se desconectó, se cae al orden automático en vez de
    // dejar a Dilo sin escenario.
    #expect(
      HUDPlacement.selectDisplay(
        from: [principal],
        targetDisplayID: nil,
        pointerLocation: CGPoint(x: 10, y: 10),
        pantallaElegida: "La de al lado"
      )?.id == principal.id
    )
    // Sin elección, lo de siempre.
    #expect(
      HUDPlacement.selectDisplay(
        from: pantallas,
        targetDisplayID: segunda.id,
        pointerLocation: CGPoint(x: 10, y: 10)
      )?.id == segunda.id
    )
  }

  /// El picker conserva la elección aunque su pantalla no esté conectada: un
  /// picker que no contiene su selección la pisa, y desenchufar un monitor
  /// borraría la preferencia en silencio.
  @Test func elPickerDePantallaConservaLaEleccionDesconectada() {
    let opciones = AppearanceSettingsView.pantallas(
      conectadas: ["Built-in Retina Display"],
      elegida: "La de al lado"
    )
    #expect(opciones.first == "", "la automática va primero y se guarda vacía")
    #expect(opciones.contains("La de al lado"))
    #expect(opciones.contains("Built-in Retina Display"))
  }


  /// De fábrica no dice nada: la muesca cerrada es la barra negra que ya
  /// estaba ahí. Quien quiera el modo activo lo enciende.
  @MainActor
  @Test func deFabricaLaMuescaNoDiceElModo() {
    #expect(!AppSettings.previewStore().hudModoEnReposo)
    #expect(!AppSettings.previewStore().sessionSettings.muestraElModoEnReposo)
  }

  /// El retardo se lee en palabras cuando es cero: «al instante» no es medio
  /// segundo redondeado.
  @Test func elRetardoCeroSeDiceConPalabras() {
    #expect(AppearanceSettingsView.etiquetaDelRetardo(0) == String(localized: "Al instante"))
    #expect(AppearanceSettingsView.etiquetaDelRetardo(0.5).hasSuffix(" s"))
  }

  /// Con carcasa real nada de esto se mira: ahí manda el recorte físico.
  @Test func conNotchRealNadaCambia() {
    var conAjuste = conNotch
    conAjuste.estiloSinNotch = .notchSimulado
    #expect(HUDNotchGeometry.reposoSize(for: conAjuste) == CGSize(width: 185, height: 32))
    #expect(HUDNotchGeometry.filletSize(for: conAjuste) == 11)
    #expect(HUDNotchGeometry.radioEnReposo(for: conAjuste) == 11)
  }
}
