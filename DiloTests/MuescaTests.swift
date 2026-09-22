import AppKit
import CoreGraphics
import Foundation
import SwiftUI
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
  private func pantalla(
    barra: CGFloat,
    ancho: CGFloat = 1920,
    nombre: String = ""
  ) -> HUDScreenSnapshot {
    HUDScreenSnapshot(
      id: 2,
      frame: CGRect(x: 0, y: 0, width: ancho, height: 1080),
      safeAreaTop: 0,
      auxiliaryTopLeftArea: nil,
      auxiliaryTopRightArea: nil,
      menuBarHeight: barra,
      estiloSinNotch: .notchSimulado,
      nombre: nombre
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
  ///
  /// Los argumentos son `CGFloat` y no `Double` a propósito. Dentro de
  /// `#expect`, la conversión implícita entre los dos se resuelve mal y el
  /// macro da falso comparando dos valores idénticos: el rojo decía
  /// «Expectation failed: (… → 25.0) == (barra → 25.0)». La misma
  /// comparación, fuera del macro, da verdadero.
  @Test(arguments: [24.0, 25.0, 37.0] as [CGFloat])
  func elAltoEsElDeLaBarraDeMenus(barra: CGFloat) {
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
    let abierta = HUDNotchGeometry.tamañoDictando(for: simulada)
    #expect(abierta.width > reposo.width)
    #expect(abierta.height > reposo.height)

    for tamaño in [reposo, abierta] {
      let zona = HUDNotchGeometry.zonaInteractiva(for: simulada, tamaño: tamaño)
      #expect(zona.maxY == HUDNotchGeometry.windowSize(for: simulada).height)
      #expect(zona.midX == HUDNotchGeometry.windowSize(for: simulada).width / 2)
      #expect(ventana.minY + zona.maxY == simulada.frame.maxY)
    }
  }

  /// Y dictando **apenas** crece.
  ///
  /// 540×146 fue un panel de media barra de menús; 400×88 seguía siéndolo en
  /// chico. El veredicto del 2026-09-22: «crece mucho cuando le estoy
  /// dictando; podría crecer por un 10 % del notch real y avanzar en el texto
  /// como lo está haciendo actualmente, que sería lo ideal». Los rangos que
  /// pidió, escritos: el alto de la barra más un décimo, y entre un 10 y un
  /// 25 % más de ancho que el reposo.
  @Test(arguments: [24.0, 25.0, 37.0] as [CGFloat])
  func dictandoLaMuescaApenasCrece(barra: CGFloat) {
    let simulada = pantalla(barra: barra)
    let reposo = HUDNotchGeometry.reposoSize(for: simulada)
    let dictando = HUDNotchGeometry.tamañoDictando(for: simulada)

    #expect(dictando.height > reposo.height, "crece, pero se nota apenas")
    #expect(dictando.height <= reposo.height * 1.15)
    #expect(dictando.width >= reposo.width * 1.10)
    #expect(dictando.width <= reposo.width * 1.25)
  }

  /// Los números de la pantalla del reclamo, enteros: 184×26 donde la barra
  /// mide 24, contra los 400×88 que Alfonso rechazó.
  @Test func laMuescaDictandoMide184Por26() {
    let dictando = HUDNotchGeometry.tamañoDictando(for: pantalla(barra: 24))
    #expect(dictando == CGSize(width: 184, height: 26))
    #expect(dictando.height >= 26 && dictando.height <= 28)
    #expect(dictando.width >= 180 && dictando.width <= 200)
  }

  /// Contra una carcasa real no aplica: ahí los primeros puntos del borde son
  /// el recorte físico, y una línea de texto adentro es una línea que nadie
  /// puede leer. Esa pantalla sigue colgando sus bandas por debajo.
  @Test func conCarcasaRealLaFormaAbiertaSigueColgandoBandas() {
    let abierta = HUDNotchGeometry.contentSize(
      for: conNotch,
      metrics: .standard,
      visualBandHeight: HUDMetrics.standard.waveBandHeight,
      includesTextBand: true,
      shapingBandHeight: HUDMetrics.standard.shapingBandHeight
    )
    #expect(abierta.width == 400)
    #expect(abierta.height > HUDNotchGeometry.reposoSize(for: conNotch).height * 2)
  }

  /// El panel del hover **sí** puede ser más grande que la muesca dictando, y
  /// tiene techo.
  ///
  /// Ahí el mouse está encima a propósito —nadie abre el hover de paso— y es
  /// donde van a vivir las acciones que no son el dictado: reuniones, el
  /// último dictado, modos, ajustes. Dictando es al revés: la forma aparece
  /// sola encima de la barra de menús mientras alguien escribe en otra app.
  @Test func elPanelDelHoverPuedeSerMasGrandeQueLaMuescaDictando() {
    let simulada = pantalla(barra: 24)
    let reposo = HUDNotchGeometry.reposoSize(for: simulada)
    let alto = HUDNotchGeometry.altoDelPanelDeHover(for: simulada)
    #expect(alto > reposo.height)
    #expect(alto > HUDNotchGeometry.tamañoDictando(for: simulada).height)
    #expect(alto <= HUDNotchGeometry.altoMaximoDelHover)
    #expect(HUDNotchGeometry.altoMaximoDelHover <= 110)
    // El ancho es el del contenido elegido en Ajustes, no uno medido del
    // texto ni el de la muesca dictando.
    #expect(HUDMetrics.standard.contentWidth == 400)
    #expect(HUDMetrics.standard.contentWidth > HUDNotchGeometry.tamañoDictando(for: simulada).width)
  }

  /// Y la ventana abierta se dimensiona por el más alto de los dos, que es el
  /// panel del hover: 90 puntos de alto donde antes eran 190.
  @Test func laVentanaAbiertaLaManejaElPanelDelHover() {
    let simulada = pantalla(barra: 24)
    #expect(
      HUDNotchGeometry.altoDeLaFormaMasAlta(for: simulada)
        == HUDNotchGeometry.altoDelPanelDeHover(for: simulada)
    )
    #expect(HUDNotchGeometry.windowSize(for: simulada) == CGSize(width: 488, height: 90))
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
    let simulada = pantalla(barra: 24)
    // El puntero entra por el área de seguimiento de `HUDHostingView`, que es
    // la única fuente de «está encima»: la ventana ya no ignora el mouse.
    let stage = HUDStage(settings: ajustes, reloj: reloj.deadlineClock)
    stage.colocar(en: simulada)
    stage.dictationContent.contexto = "Correo"
    let silueta = HUDNotchGeometry.siluetaEnPantalla(
      for: simulada,
      tamaño: HUDNotchGeometry.reposoSize(for: simulada),
      encuadre: .reposo
    )
    stage.punteroSeMovio(a: CGPoint(x: silueta.midX, y: silueta.midY))

    await reloj.waitForSleeper()
    reloj.advance(by: .milliseconds(500))
    await Task.yield()
    #expect(!stage.dictationContent.punteroEncima, "medio segundo no alcanza con 1,2 s")

    while !stage.dictationContent.punteroEncima {
      reloj.advance(by: .milliseconds(700))
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

  /// La forma dentro de la ventana, estado por estado.
  ///
  /// La geometría pura ya estaba probada y estaba **bien**: lo que se rompió
  /// fue el paso de la geometría a la vista. Un hijo que pedía
  /// `maxHeight: .infinity` se quedaba con el alto entero de la ventana
  /// anfitriona —dimensionada para el estado más alto— y el fondo negro se
  /// estiraba detrás: la muesca de 160×24 se veía en un 1080p externo como un
  /// bloque de 160×196 colgando de la barra, con el punto mango abajo del
  /// todo. Ningún test de geometría podía verlo, porque la geometría decía
  /// 24.
  ///
  /// Por eso esto no le pregunta a `HUDNotchGeometry`: rasteriza la vista de
  /// verdad dentro de un lienzo del tamaño de la ventana y mira dónde quedó el
  /// negro. Fuera de pantalla, sin montar ninguna ventana y sin tocar la GUI.
  @MainActor
  private func formaDibujada(
    en pantalla: HUDScreenSnapshot,
    content: DictationHUDContent,
    settings: DictationSessionSettings
  ) throws -> FormaMedida {
    let ventana = HUDNotchGeometry.windowSize(for: pantalla)
    let renderer = ImageRenderer(
      content: DictationHUDShellView(screen: pantalla, settings: settings, content: content)
        .frame(width: ventana.width, height: ventana.height, alignment: .top)
    )
    renderer.scale = 1
    let mapa = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))

    // Las alas cóncavas se van afinando hacia afuera hasta desaparecer, así
    // que sus últimas columnas son antialias y no cuentan como negro opaco:
    // un ancho medido incluyéndolas depende del rasterizador. El cuerpo se
    // mide por debajo de ellas, donde la forma tiene su ancho entero.
    let ala = Int(HUDNotchGeometry.filletSize(for: pantalla).rounded(.up))
    var marco = Extremos()
    var cuerpo = Extremos()
    for y in 0..<mapa.pixelsHigh {
      for x in 0..<mapa.pixelsWide {
        guard let color = mapa.colorAt(x: x, y: y), esNegroOpaco(color) else { continue }
        marco.sumar(x: x, y: y)
        if y >= ala { cuerpo.sumar(x: x, y: y) }
      }
    }
    return FormaMedida(
      marco: try #require(marco.rect, "la forma no dibujó nada negro"),
      cuerpo: try #require(cuerpo.rect, "la forma no tiene cuerpo bajo las alas")
    )
  }

  /// Lo que se mide de un PNG de la forma: todo el negro, y el negro por
  /// debajo de las alas, que es el cuerpo a su ancho entero.
  private struct FormaMedida {
    let marco: CGRect
    let cuerpo: CGRect
  }

  private struct Extremos {
    var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min

    mutating func sumar(x: Int, y: Int) {
      minX = min(minX, x)
      maxX = max(maxX, x)
      minY = min(minY, y)
      maxY = max(maxY, y)
    }

    var rect: CGRect? {
      guard minX <= maxX else { return nil }
      return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
  }

  /// La forma es negro opaco y la sombra que la rodea es negro al 35 %, así
  /// que lo que las separa es la opacidad, no el color.
  private func esNegroOpaco(_ color: NSColor) -> Bool {
    guard let rgb = color.usingColorSpace(.sRGB) else { return false }
    return rgb.alphaComponent > 0.9
      && rgb.redComponent < 0.1
      && rgb.greenComponent < 0.1
      && rgb.blueComponent < 0.1
  }

  /// Lo que se le pide a cada estado: su tamaño, pegado arriba y centrado, y
  /// nunca el alto de la ventana.
  @MainActor
  private func afirmar(
    _ forma: FormaMedida,
    mide esperado: CGSize,
    en pantalla: HUDScreenSnapshot,
    _ estado: String
  ) {
    let ala = HUDNotchGeometry.filletSize(for: pantalla)
    let ventana = HUDNotchGeometry.windowSize(for: pantalla)
    #expect(abs(forma.cuerpo.width - esperado.width) <= 1, "\(estado): ancho \(forma.cuerpo.width)")
    #expect(abs(forma.marco.height - esperado.height) <= 1, "\(estado): alto \(forma.marco.height)")
    #expect(forma.marco.minY == 0, "\(estado): nace del borde de arriba")
    #expect(abs(forma.cuerpo.midX - ventana.width / 2) <= 1, "\(estado): centrada en la ventana")
    // Las alas cuelgan a los lados y no ensanchan el cuerpo ni un punto más
    // que su propio radio.
    #expect(forma.marco.width <= esperado.width + ala * 2, "\(estado): las alas no se pasan")
    // El síntoma exacto del bug, afirmado aparte: la forma no se come la
    // ventana entera.
    #expect(
      forma.marco.height <= ventana.height - HUDNotchGeometry.holguraDeSombra(),
      "\(estado): la forma no es la ventana"
    )
  }

  /// En reposo la muesca mide 160×24 dentro de una ventana de 488×90, y el
  /// resto de la ventana queda transparente.
  @MainActor
  @Test func enReposoLaFormaMideLaMuescaYNoLaVentana() throws {
    let simulada = pantalla(barra: 24)
    let content = DictationHUDContent()
    let forma = try formaDibujada(
      en: simulada,
      content: content,
      settings: AppSettings.previewStore().sessionSettings
    )
    afirmar(forma, mide: CGSize(width: 160, height: 24), en: simulada, "reposo")
  }

  /// El hover abre la silueta hasta el ancho de la forma abierta y unos pocos
  /// puntos más de alto, con techo. Sigue siendo la silueta creciendo, no una
  /// ventana que se abrió.
  @MainActor
  @Test func elHoverDibujaElPanelDeContextoYNadaMas() throws {
    let simulada = pantalla(barra: 24)
    let content = DictationHUDContent()
    content.contexto = "Correo"
    content.punteroEncima = true
    let forma = try formaDibujada(
      en: simulada,
      content: content,
      settings: AppSettings.previewStore().sessionSettings
    )
    afirmar(forma, mide: CGSize(width: 400, height: 46), en: simulada, "hover")
    #expect(forma.marco.height <= HUDNotchGeometry.altoMaximoDelHover)
  }

  /// Dictando: 184×26 en una sola línea —la onda compacta y el parcial—, que
  /// es lo que Alfonso pidió el 2026-09-22.
  @MainActor
  @Test func dictandoLaFormaMideLoQueDeclaraLaGeometria() throws {
    let simulada = pantalla(barra: 24)
    let content = DictationHUDContent()
    content.estado = .dictando
    content.isRevealed = true
    content.showsVoiceVisual = true
    content.shapingChoiceLabel = "Correo"
    let forma = try formaDibujada(
      en: simulada,
      content: content,
      settings: AppSettings.previewStore().sessionSettings
    )
    afirmar(forma, mide: CGSize(width: 184, height: 26), en: simulada, "dictando")
  }

  /// El final no crece: el acuse es la misma muesca de 184×26 con un check
  /// donde estaba la onda.
  ///
  /// Eran 400×50 con «Listo» y «Copiar» al lado. Veredicto del 2026-09-22:
  /// «al finalizar de dictar me sale Listo y Copiar al lado, porque también
  /// es innecesario; podría reemplazarse la onda por un check o algo así como
  /// lo hacíamos en el Tauri».
  @MainActor
  @Test func elAcuseMideLoMismoQueDictando() throws {
    let simulada = pantalla(barra: 24)
    let content = DictationHUDContent()
    content.estado = .resultado(.listo)
    content.isRevealed = true
    // Las palabras dictadas siguen puestas: el acuse no las dibuja igual.
    content.text = "quedamos el martes a las diez en la oficina"
    let forma = try formaDibujada(
      en: simulada,
      content: content,
      settings: AppSettings.previewStore().sessionSettings
    )
    afirmar(forma, mide: HUDNotchGeometry.tamañoDictando(for: simulada), en: simulada, "acuse")
  }

  /// Y un error tampoco: la misma muesca, con la línea que dice qué pasó.
  @MainActor
  @Test func elErrorMideLoMismoYSiDicePalabras() throws {
    let simulada = pantalla(barra: 24)
    let content = DictationHUDContent()
    content.estado = .resultado(.aviso("No se pudo pegar el texto"))
    content.isRevealed = true
    content.text = "No se pudo pegar el texto"
    let forma = try formaDibujada(
      en: simulada,
      content: content,
      settings: AppSettings.previewStore().sessionSettings
    )
    afirmar(forma, mide: HUDNotchGeometry.tamañoDictando(for: simulada), en: simulada, "error")
  }

  /// La línea que deja el escenario en el log del sistema, para diagnosticar
  /// esto sin mirar la pantalla de nadie:
  ///
  ///     log show --predicate 'subsystem == "cl.espaciodigital.dilo"' --last 5m
  @Test func laLineaDelLogLlevaLosDosTamanos() {
    let simulada = pantalla(barra: 24, nombre: "DELL U2412M")
    #expect(
      RegistroDeLaMuesca.linea(
        estado: .reposo,
        ventana: HUDNotchGeometry.windowSize(for: simulada),
        forma: HUDNotchGeometry.reposoSize(for: simulada),
        pantalla: simulada.nombre,
        notchReal: HUDNotchGeometry.hasMeasuredNotch(for: simulada)
      ) == "estado=reposo ventana=488x90 forma=160x24 pantalla=DELL U2412M notchReal=false"
    )
    // Sin nombre no se escribe un hueco: una línea con `pantalla=` vacío se
    // lee como que la pantalla no tiene nombre, no como que el campo faltó.
    #expect(
      RegistroDeLaMuesca.linea(
        estado: .dictando,
        ventana: CGSize(width: 488, height: 90),
        forma: CGSize(width: 184, height: 26),
        pantalla: "",
        notchReal: true
      ) == "estado=dictando ventana=488x90 forma=184x26 pantalla=? notchReal=true"
    )
  }
}
