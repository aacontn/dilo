import AppKit
import CoreGraphics
import SwiftUI
import Testing

@testable import Dilo

/// La píldora sin notch: dónde va, qué tapa y qué no, y los tres estados que
/// la máquina del HUD prevé.
///
/// Las tres reglas de esta suite salen de la primera prueba de Talkify en
/// español (spec §8): la píldora no tapa la barra de menús, no se puede
/// confundir con el HUD del sistema, y sobrevive a una app en pantalla
/// completa.
@Suite("Píldora sin notch")
struct HUDPildoraTests {
  private let conNotch = HUDScreenSnapshot(
    id: 1,
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    safeAreaTop: 32,
    auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
    auxiliaryTopRightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
    menuBarHeight: 32
  )
  /// Uno de los dos 1080p de esta máquina: sin notch, con barra de menús
  /// propia. Es el caso normal, no el borde.
  private let sinNotch = HUDScreenSnapshot(
    id: 2,
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    safeAreaTop: 0,
    auxiliaryTopLeftArea: nil,
    auxiliaryTopRightArea: nil,
    menuBarHeight: 24
  )

  @Test func unaPantallaSinCarcasaDibujaLaPildora() {
    #expect(HUDNotchGeometry.drawsPill(for: sinNotch))
    #expect(!HUDNotchGeometry.drawsPill(for: conNotch))
  }

  /// Issue #83, y la lección 2 del spec: la píldora **nunca** entra en la
  /// franja de la barra de menús, que es donde viven los status items —
  /// incluido el de Dilo.
  @Test func laPildoraNuncaEntraEnLaFranjaDeLaBarraDeMenus() {
    let frame = HUDNotchGeometry.windowFrame(for: sinNotch, clearsMenuBar: true)
    #expect(frame.maxY <= sinNotch.frame.maxY - sinNotch.menuBarHeight)
  }

  /// Y tampoco queda pegada a ella: el aire es lo que la vuelve un objeto
  /// aparte en vez de la continuación de la franja donde macOS 27 pone su
  /// propio HUD de volumen.
  @Test func laPildoraSeSeparaDeLaBarraDeMenus() {
    let frame = HUDNotchGeometry.windowFrame(for: sinNotch, clearsMenuBar: true)
    let borde = sinNotch.frame.maxY - sinNotch.menuBarHeight
    #expect(borde - frame.maxY == HUDNotchGeometry.pillDetachment)
    #expect(HUDNotchGeometry.pillDetachment > 0)
  }

  /// Dentro de un espacio en pantalla completa la barra se autooculta y el
  /// sistema reporta cero: sin piso, la píldora saltaría al borde superior al
  /// cambiar de espacio a media sesión y volvería a bajar al salir.
  @Test func laPildoraNoSaltaCuandoLaBarraSeAutooculta() {
    let enPantallaCompleta = HUDScreenSnapshot(
      id: 3,
      frame: sinNotch.frame,
      safeAreaTop: 0,
      auxiliaryTopLeftArea: nil,
      auxiliaryTopRightArea: nil,
      menuBarHeight: 0
    )
    let inset = HUDNotchGeometry.topInset(for: enPantallaCompleta, clearsMenuBar: true)
    #expect(inset == HUDNotchGeometry.menuBarClearanceFloor + HUDNotchGeometry.pillDetachment)
    #expect(inset > 0)
  }

  /// Una pantalla con carcasa no se toca: ahí la forma nace del recorte y
  /// hugs el borde real, con la preferencia encendida o apagada.
  @Test func conNotchNadaDeEstoAplica() {
    #expect(HUDNotchGeometry.topInset(for: conNotch, clearsMenuBar: true) == 0)
    #expect(
      HUDNotchGeometry.windowFrame(for: conNotch, clearsMenuBar: true).maxY
        == conNotch.frame.maxY
    )
  }

  /// La píldora flota separada, así que se cierra por los cuatro lados. Con
  /// carcasa las esquinas de arriba son rectas: comparten el borde del
  /// recorte.
  @Test func laPildoraSeCierraPorArriba() {
    let radio = HUDNotchGeometry.topCornerRadius(for: sinNotch, metrics: .standard)
    #expect(radio == HUDMetrics.standard.bottomCornerRadius)
    #expect(HUDNotchGeometry.topCornerRadius(for: conNotch, metrics: .standard) == 0)
  }

  /// La preferencia existe, pero viene encendida: es la regla de `AGENTS.md`,
  /// no una opción con dos lados buenos. Si alguien le cambia el default, esto
  /// se cae.
  @MainActor
  @Test func despejarLaBarraDeMenusVieneEncendidoDeFabrica() {
    #expect(AppSettings.previewStore().hudClearsMenuBar)
  }

  /// La corona mango reemplaza los 32 puntos de carcasa simulada, que sin
  /// cámara que esquivar quedaban negros y vacíos — igualitos al HUD del
  /// sistema.
  @Test func laCoronaEsMasBajaQueLaCarcasaSimulada() {
    #expect(HUDMetrics.standard.pillCrownHeight < HUDNotchGeometry.closedSize(for: sinNotch).height)
    #expect(HUDMetrics.standard.pillCrownHeight > 0)
  }

  /// La píldora entera —corona, onda y texto parcial, más la etiqueta de
  /// transformación— tiene que caber en la ventana fija, que nunca se
  /// redimensiona (ADR-0001).
  @Test func laPildoraCompletaCabeEnLaVentanaFija() {
    let metrics = HUDMetrics.standard
    let alto = HUDNotchGeometry.contentSize(
      for: sinNotch,
      metrics: metrics,
      visualBandHeight: metrics.waveBandHeight,
      includesTextBand: true,
      shapingBandHeight: metrics.shapingBandHeight,
      housingBandHeight: metrics.pillCrownHeight
    ).height
    let ventana = HUDNotchGeometry.windowFrame(for: sinNotch, clearsMenuBar: true)
    #expect(alto <= ventana.height - HUDNotchGeometry.shadowPadding)
  }

  /// El alto de banda explícito sólo lo usa la píldora: sin él manda la
  /// carcasa, que es hardware.
  @Test func sinAltoExplicitoMandaLaCarcasa() {
    let conDefault = HUDNotchGeometry.contentSize(
      for: conNotch,
      metrics: .standard,
      visualBandHeight: 0,
      includesTextBand: false,
      shapingBandHeight: 0
    )
    #expect(conDefault.height == HUDNotchGeometry.closedSize(for: conNotch).height)
  }

  /// Spec §5: la máquina prevé tres estados y v1 dibuja uno.
  @Test func laMaquinaPreveTresEstadosYDibujaUno() {
    #expect(HUDSessionKind.allCases.count == 3)
    #expect(HUDSessionKind.dictando.surface == .dictado)
    #expect(HUDSessionKind.reunion.surface == .ninguna)
    #expect(HUDSessionKind.conversando.surface == .ninguna)
    #expect(HUDSessionKind.allCases.filter(\.isDrawn) == [.dictando])
  }

  /// Un estado sin superficie no abre el escenario: una forma negra vacía se
  /// lee como un cuelgue, no como "esto viene en camino".
  @MainActor
  @Test(arguments: [HUDSessionKind.reunion, .conversando])
  func unEstadoSinSuperficieNoAbreElEscenario(kind: HUDSessionKind) {
    let stage = HUDStage(settings: AppSettings.previewStore())
    stage.claim(.dictation, on: sinNotch, kind: kind)
    #expect(stage.occupant == .none)
  }

  @MainActor
  @Test func dictarSiAbreElEscenario() {
    let stage = HUDStage(settings: AppSettings.previewStore())
    stage.claim(.dictation, on: sinNotch)
    #expect(stage.occupant == .dictation)
    #expect(stage.sessionKind == .dictando)
  }

  /// Issue #84: el nivel y el comportamiento que hacen que la forma sobreviva
  /// a una app en pantalla completa nativa. Se comprueban como constantes
  /// porque el caso real necesita una app en pantalla completa y un humano.
  @Test func elPanelViveSobreLasAppsEnPantallaCompleta() {
    #expect(HUDPanel.overlayLevel.rawValue > NSWindow.Level.mainMenu.rawValue)
    #expect(HUDPanel.overlayLevel.rawValue < NSWindow.Level.screenSaver.rawValue)
    #expect(HUDPanel.overlayCollectionBehavior.contains(.canJoinAllSpaces))
    #expect(HUDPanel.overlayCollectionBehavior.contains(.fullScreenAuxiliary))
    #expect(HUDPanel.overlayCollectionBehavior.contains(.stationary))
  }

  /// Dibuja la píldora a PNG para poder mirarla en vez de deducirla del
  /// diff, como hace `HUDRenderTests` con las superficies del notch. Escribe
  /// sólo cuando `TALKIFY_RENDER_DIR` está puesto; si no, se conforma con
  /// comprobar que rinde.
  @MainActor
  @Test func laPildoraSeDibuja() throws {
    let content = DictationHUDContent()
    content.text = "Esto es la píldora de Dilo, "
    content.volatileText = "con el texto parcial mientras hablas"
    content.languageTag = "ES"
    content.isRevealed = true
    content.showsVoiceVisual = true
    content.audioLevel = 0.7
    content.levelHistory = (0..<HUDWaveformView.barCount).map {
      Float(0.25 + 0.6 * abs(sin(Double($0) / 3.1)))
    }

    // El estilo por defecto (Chart Line) llena su buffer desde un `onChange`
    // que en un render de una sola pasada nunca corre; los estilos de barras
    // dibujan directo del historial, que es lo que hay que poder mirar acá.
    for estilo in [HUDWaveformStyle.article, .silver, .siriWave] {
      let store = AppSettings.previewStore()
      store.waveformStyle = estilo
      let vista = DictationHUDShellView(
        screen: sinNotch,
        settings: store.sessionSettings,
        content: content
      )
        .frame(width: 640, height: 200, alignment: .top)

      let renderer = ImageRenderer(content: vista)
      renderer.scale = 2
      let imagen = try #require(renderer.cgImage)
      #expect(imagen.width == 1280)

      if let dir = ProcessInfo.processInfo.environment["TALKIFY_RENDER_DIR"] {
        let carpeta = URL(filePath: dir)
        try? FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
        let bitmap = NSBitmapImageRep(cgImage: imagen)
        if let data = bitmap.representation(using: .png, properties: [:]) {
          try data.write(to: carpeta.appending(path: "pildora-sin-notch-\(estilo.rawValue).png"))
        }
      }
    }
  }

  /// `isFloatingPanel` le pone `.floating` (3) a la ventana de paso: si se
  /// asigna después del nivel, el HUD termina debajo de la barra de menús.
  @MainActor
  @Test func elPanelConservaSuNivelDespuesDeConstruirse() {
    let panel = HUDPanel(contentRect: .zero, contentView: NSView())
    #expect(panel.level == HUDPanel.overlayLevel)
    panel.level = .floating
    panel.assertOverlayOrder()
    #expect(panel.level == HUDPanel.overlayLevel)
  }
}
