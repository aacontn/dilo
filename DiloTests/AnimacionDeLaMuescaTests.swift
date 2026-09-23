import AppKit
import SwiftUI
import Testing

@testable import Dilo

/// Cómo se mueve la muesca: que crezca desde sí misma y que el hover no se
/// recoja solo.
///
/// Sale del reporte del 2026-09-23: «al agrandar se ve trancado, y en el hover
/// tampoco». Al abrir, el alto de la forma lo imponía el contenido nuevo —que
/// entra a su alto final en el acto— y el negro saltaba a 160×88 antes de
/// ensancharse. Y el hover se cerraba a los cuatro segundos con el puntero
/// todavía encima.
///
/// Nada de esto abre una ventana: el layout se mide en una vista suelta y el
/// puntero se inyecta.
@MainActor
@Suite("La animación de la muesca")
struct AnimacionDeLaMuescaTests {
  /// Lo que mide la forma con un contenido de 88 de alto adentro.
  private func medir(ancho: CGFloat, alto: CGFloat, apertura: CGFloat, contenido: CGFloat = 88) -> CGSize {
    let vista = NSHostingView(
      rootView: MarcoDeLaForma(ancho: ancho, alto: alto, apertura: apertura) {
        Color.clear.frame(height: contenido)
      }
    )
    return vista.fittingSize
  }

  /// La fase que se veía trabada: el contenido abierto ya está montado y la
  /// revelación todavía no arrancó. La forma sigue siendo la muesca.
  @Test func recogidaMideLaMuescaAunqueElContenidoPidaMas() {
    #expect(medir(ancho: 160, alto: 24, apertura: 0) == CGSize(width: 160, height: 24))
  }

  @Test func abiertaMideLoQuePideElContenido() {
    #expect(medir(ancho: 400, alto: 88, apertura: 1) == CGSize(width: 400, height: 88))
    // Contra una carcasa real la banda de texto crece sobre lo declarado
    // (`HUDLongDraftStyle.growDown`), y la forma abierta la sigue.
    #expect(medir(ancho: 400, alto: 88, apertura: 1, contenido: 120).height == 120)
  }

  /// A mitad de camino el alto está entre los dos, y no pegado a ninguno.
  @Test func aMitadDeCaminoCreceEnAltoYEnAncho() {
    let mitad = medir(ancho: 280, alto: 56, apertura: 0.5)
    #expect(mitad.width == 280)
    #expect(mitad.height > 24 && mitad.height < 88)
  }

  // MARK: Los costados

  /// Con datos a los costados la muesca se alarga lo mismo a los dos lados y
  /// no crece de alto; la ventana en reposo la sigue, y la silueta sigue
  /// centrada.
  @Test func losCostadosAlarganLaMuescaSinMoverla() {
    var conDatos = simulado
    conDatos.anchoDeLosLados = HUDNotchGeometry.anchoDeUnLado
    let sin = HUDNotchGeometry.reposoSize(for: simulado)
    let con = HUDNotchGeometry.reposoSize(for: conDatos)
    #expect(con.width == sin.width + HUDNotchGeometry.anchoDeUnLado * 2)
    #expect(con.height == sin.height)
    #expect(
      HUDNotchGeometry.windowSize(for: conDatos, encuadre: .reposo).width
        == HUDNotchGeometry.windowSize(for: simulado, encuadre: .reposo).width
        + HUDNotchGeometry.anchoDeUnLado * 2
    )
    let silueta = HUDNotchGeometry.siluetaEnPantalla(for: conDatos, tamaño: con, encuadre: .reposo)
    #expect(silueta.midX == simulado.frame.midX)
  }

  // MARK: El hover

  private let simulado = HUDScreenSnapshot(
    id: 7,
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    safeAreaTop: 0,
    auxiliaryTopLeftArea: nil,
    auxiliaryTopRightArea: nil,
    menuBarHeight: 24
  )

  private var sobreLaMuesca: CGPoint {
    let silueta = HUDNotchGeometry.siluetaEnPantalla(
      for: simulado,
      tamaño: HUDNotchGeometry.reposoSize(for: simulado),
      encuadre: .reposo
    )
    return CGPoint(x: silueta.midX, y: silueta.midY)
  }

  /// Con el puntero todavía encima, vencer la red de seguridad no cierra el
  /// panel; cuando el puntero se fue sin que nadie avisara, sí.
  @Test func laRedDeSeguridadNoCierraConElPunteroEncima() async {
    let reloj = DrivenClock()
    let puntero = PunteroDePrueba()
    let stage = HUDStage(
      settings: AppSettings.previewStore(),
      reloj: reloj.deadlineClock,
      punteroEn: { puntero.punto }
    )
    stage.colocar(en: simulado)

    puntero.punto = sobreLaMuesca
    stage.punteroSeMovio(a: sobreLaMuesca)
    await reloj.waitForSleeper()
    while !stage.dictationContent.punteroEncima {
      reloj.advance(by: HUDStage.toleranciaDelHover)
      await Task.yield()
    }

    // Tres vencimientos seguidos con el mouse quieto encima: sigue abierto.
    for _ in 0..<3 {
      await reloj.waitForSleeper()
      reloj.advance(by: HUDStage.contextoMaximo)
      await Task.yield()
    }
    #expect(stage.dictationContent.punteroEncima)

    // El puntero se va y el área de seguimiento no dice nada.
    puntero.punto = PunteroDePrueba.lejos
    while stage.dictationContent.punteroEncima {
      await reloj.waitForSleeper()
      reloj.advance(by: HUDStage.contextoMaximo)
      await Task.yield()
    }
    #expect(stage.dictationContent.contextoVisible == nil)
    #expect(!stage.punteroSobreLaSilueta)
  }

  /// Mientras se dicta la forma no reclama nada, y la ventana entera deja
  /// pasar el mouse en vez de quedarse con los clics de su rectángulo.
  @Test func dictandoLaVentanaIgnoraElMouse() {
    let stage = HUDStage(
      settings: AppSettings.previewStore(),
      reloj: DrivenClock().deadlineClock,
      punteroEn: { CGPoint(x: -10_000, y: -10_000) }
    )
    stage.colocar(en: simulado)
    #expect(!stage.ventanaIgnoraElMouse, "en reposo la silueta recibe el hover")
    stage.claim(.dictation, on: simulado)
    stage.recibir(.escuchar)
    #expect(stage.ventanaIgnoraElMouse)
  }
}

/// Dónde está el puntero en un test: una caja, para poder moverlo después de
/// habérselo pasado al escenario.
@MainActor
private final class PunteroDePrueba {
  static let lejos = CGPoint(x: -10_000, y: -10_000)
  var punto = lejos
}
