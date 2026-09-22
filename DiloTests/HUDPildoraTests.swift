import AppKit
import CoreGraphics
import SwiftUI
import Testing

@testable import Dilo

/// La píldora sin notch: dónde va, qué tapa y qué no, y los tres estados que
/// la máquina del HUD prevé.
///
/// Las tres reglas de esta suite salen de la primera prueba de la app heredada en
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
  /// Uno de los dos 1080p de esta máquina, con la píldora elegida a mano.
  ///
  /// El ajuste va explícito desde que el default es el notch simulado
  /// (2026-09-21): esta suite cuida la forma que cuelga debajo de la barra, y
  /// heredar el default la dejaría probando la otra.
  private let sinNotch = HUDScreenSnapshot(
    id: 2,
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    safeAreaTop: 0,
    auxiliaryTopLeftArea: nil,
    auxiliaryTopRightArea: nil,
    menuBarHeight: 24,
    estiloSinNotch: .pildora
  )

  @Test func unaPantallaSinCarcasaDibujaLaPildora() {
    #expect(HUDNotchGeometry.drawsPill(for: sinNotch))
    #expect(!HUDNotchGeometry.drawsPill(for: conNotch))
  }

  /// Issue #83, y la lección 2 del spec: la píldora **nunca** entra en la
  /// franja de la barra de menús, que es donde viven los status items —
  /// incluido el de Dilo.
  @Test func laPildoraNuncaEntraEnLaFranjaDeLaBarraDeMenus() {
    let frame = HUDNotchGeometry.windowFrame(for: sinNotch)
    #expect(frame.maxY <= sinNotch.frame.maxY - sinNotch.menuBarHeight)
  }

  /// Y tampoco queda pegada a ella: el aire es lo que la vuelve un objeto
  /// aparte en vez de la continuación de la franja donde macOS 27 pone su
  /// propio HUD de volumen.
  @Test func laPildoraSeSeparaDeLaBarraDeMenus() {
    let frame = HUDNotchGeometry.windowFrame(for: sinNotch)
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
      menuBarHeight: 0,
      estiloSinNotch: .pildora
    )
    let inset = HUDNotchGeometry.topInset(for: enPantallaCompleta)
    #expect(inset == HUDNotchGeometry.menuBarClearanceFloor + HUDNotchGeometry.pillDetachment)
    #expect(inset > 0)
  }

  /// Una pantalla con carcasa no se toca: ahí la forma nace del recorte y
  /// hugs el borde real, con la preferencia encendida o apagada.
  @Test func conNotchNadaDeEstoAplica() {
    #expect(HUDNotchGeometry.topInset(for: conNotch) == 0)
    #expect(
      HUDNotchGeometry.windowFrame(for: conNotch).maxY
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

  /// **El default cambió el 2026-09-21:** sin carcasa se dibuja el notch
  /// simulado. La píldora se queda como elección a mano, no como lo que trae
  /// la app. Si alguien vuelve a invertirlo, esto se cae.
  @MainActor
  @Test func laPildoraYaNoEsElDefaultDeFabrica() {
    #expect(AppSettings.previewStore().hudEstiloSinNotch == .notchSimulado)
    #expect(HUDEstiloSinNotch.allCases.contains(.pildora))
  }

  /// Elegida a mano, la píldora sigue siendo la píldora: no simula un notch.
  @Test func elegidaAManoLaPantallaDibujaLaPildora() {
    #expect(sinNotch.estiloSinNotch == .pildora)
    #expect(!HUDNotchGeometry.simulatesNotch(for: sinNotch))
    #expect(HUDNotchGeometry.dibujaPildora(for: sinNotch))
  }

  /// La píldora entera —cabecera, onda y texto parcial, más el chip de
  /// modo— tiene que caber en la ventana fija, que nunca se redimensiona
  /// (ADR-0001).
  @Test func laPildoraCompletaCabeEnLaVentanaFija() {
    let metrics = HUDMetrics.standard
    let alto = HUDNotchGeometry.contentSize(
      for: sinNotch,
      metrics: metrics,
      visualBandHeight: metrics.waveBandHeight,
      includesTextBand: true,
      shapingBandHeight: metrics.shapingBandHeight
    ).height
    let ventana = HUDNotchGeometry.windowFrame(for: sinNotch)
    #expect(alto <= ventana.height - HUDNotchGeometry.shadowPadding)
  }

  /// Con carcasa real la cabecera es la carcasa, que es hardware.
  @Test func conCarcasaLaCabeceraEsLaCarcasa() {
    #expect(
      HUDNotchGeometry.alturaDeCabecera(for: conNotch)
        == HUDNotchGeometry.closedSize(for: conNotch).height
    )
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
  /// sólo cuando `DILO_RENDER_DIR` está puesto; si no, se conforma con
  /// comprobar que rinde.
  @MainActor
  @Test func laPildoraSeDibuja() throws {
    let content = DictationHUDContent()
    content.estado = .dictando
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
    for estilo in [HUDWaveformStyle.article, .silver, .siriWave, .brasas] {
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

      if let dir = ProcessInfo.processInfo.environment["DILO_RENDER_DIR"] {
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
