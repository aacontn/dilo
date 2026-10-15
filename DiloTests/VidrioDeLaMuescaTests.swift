import CoreGraphics
import Foundation
import Testing

@testable import Dilo

/// El panel del hover al estilo Dynamic Glass: negro opaco con el vidrio sólo
/// en la franja de abajo. El vidrio no sale en PNG, así que lo que se afirma
/// acá son los números y quién lo enciende: que la franja nunca sube al
/// texto, que el pie sigue oscuro, que está encendido de fábrica, que el
/// arnés lo enciende sólo en sus escenas y que soltar la muestra lo apaga.
@Suite("Vidrio de la muesca")
struct VidrioDeLaMuescaTests {
  /// Los 32 medidos en Droppy en un panel alto; en uno bajo, nunca más de lo
  /// que cuelga bajo la cabecera.
  @Test func elRadioEsElDeDroppySiCabe() {
    #expect(PanelDeVidrio.radio(para: CGSize(width: 400, height: 200), cabecera: 24) == 32)
    #expect(PanelDeVidrio.radio(para: CGSize(width: 400, height: 46), cabecera: 24) == 22)
    #expect(PanelDeVidrio.radio(para: CGSize(width: 120, height: 200), cabecera: 24) == 30)
  }

  /// El vidrio es sólo el último ~30 % del panel, con piso y techo, y nunca
  /// sube a la cabecera.
  @Test func laFranjaDeVidrioEsElPie() {
    #expect(PanelDeVidrio.franja(para: 142, cabecera: 24) > 40)
    #expect(PanelDeVidrio.franja(para: 142, cabecera: 24) < 44)
    #expect(PanelDeVidrio.franja(para: 82, cabecera: 24) == PanelDeVidrio.franjaMinima)
    #expect(PanelDeVidrio.franja(para: 248, cabecera: 24) == PanelDeVidrio.franjaMaxima)
    #expect(PanelDeVidrio.franja(para: 40, cabecera: 24) == 16)
    #expect(abs(PanelDeVidrio.inicioDeLaFranja(para: 200, cabecera: 24) - 0.7) < 0.0001)
  }

  /// El punto más claro del panel —el borde de abajo— sigue siendo vidrio
  /// oscuro: deja pasar a lo sumo un tercio del fondo, y el negro de encima
  /// nunca llega a cero. Con los números de la 0.4.5 (tinte 0,3 y nada de
  /// negro encima) pasaba el 70 %, y sobre una página blanca el panel era
  /// gris claro con letra blanca.
  @Test func elPieSigueOscuro() {
    #expect(PanelDeVidrio.negroAlPie > 0)
    #expect(PanelDeVidrio.transmisionAlPie > 0)
    #expect(PanelDeVidrio.transmisionAlPie <= 0.34)
  }

  /// Abrir rebota apenas (unos 2,5 %) y cerrar casi nada (0,15 %): la ventana
  /// anfitriona tiene que alojar ese sobrepaso.
  @Test func losResortesDeDroppy() {
    #expect(CurvaDeLaMuesca.apertura == CurvaDeLaMuesca(respuesta: 0.47, amortiguacion: 0.76))
    #expect(CurvaDeLaMuesca.cierre == CurvaDeLaMuesca(respuesta: 0.54, amortiguacion: 0.9))
    #expect(CurvaDeLaMuesca.apertura.sobrepaso > 0.02 && CurvaDeLaMuesca.apertura.sobrepaso < 0.03)
    #expect(CurvaDeLaMuesca.cierre.sobrepaso < 0.002)
    #expect(CurvaDeLaMuesca(respuesta: 0.5, amortiguacion: 1).sobrepaso == 0)
  }

  /// Encendido de fábrica desde el 2026-10-14, y apagable: lo que alguien
  /// eligió se respeta. El contenido arranca sin vidrio porque el escenario
  /// lo lee del ajuste recién al abrir el panel.
  @MainActor
  @Test func encendidoDeFabricaYApagable() {
    let nombre = "VidrioDeLaMuescaTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: nombre)!
    defer { defaults.removePersistentDomain(forName: nombre) }
    #expect(AppSettings(defaults: defaults).hudPanelDeVidrio)
    #expect(!DictationHUDContent().panelDeVidrio)
    AppSettings(defaults: defaults).hudPanelDeVidrio = false
    #expect(!AppSettings(defaults: defaults).hudPanelDeVidrio)
  }

  /// La forma abierta lleva los hombros de Droppy hasta donde la ventana
  /// abierta deja lugar para sus alas y su sombra; la píldora, ninguno.
  @Test func losHombrosDeLaFormaAbierta() {
    let simulada = HUDScreenSnapshot(
      id: 3, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeAreaTop: 0,
      auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil, menuBarHeight: 24
    )
    var pildora = simulada
    pildora.estiloSinNotch = .pildora
    let panel = CGSize(width: 400, height: 120)
    let hombro = FormaAbierta.hombro(para: panel, en: simulada)
    let ventana = HUDNotchGeometry.windowSize(for: simulada)
    #expect(hombro > HUDNotchGeometry.filletSize(for: simulada))
    #expect(hombro <= FormaAbierta.hombro)
    #expect(panel.width + 2 * (hombro + HUDNotchGeometry.holguraDeSombra()) <= ventana.width)
    let aviso = HUDNotchGeometry.tamañoDelAviso(for: simulada)
    // El aviso: borde de abajo redondo entero y el hombro hasta donde empieza.
    let radio = FormaAbierta.radioDelAviso(para: aviso)
    #expect(radio == aviso.height / 2)
    #expect(FormaAbierta.hombro(para: aviso, en: simulada, radioInferior: radio) == aviso.height - radio)
    #expect(FormaAbierta.hombro(para: panel, en: pildora) == 0)
  }

  @MainActor
  @Test func elArnesEnciendeElVidrioSoloEnSusEscenas() {
    let stage = HUDStage(settings: AppSettings.previewStore(), punteroEn: { .zero })
    stage.colocar(en: HUDScreenSnapshot(
      id: 3,
      frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      safeAreaTop: 0,
      auxiliaryTopLeftArea: nil,
      auxiliaryTopRightArea: nil,
      menuBarHeight: 24
    ))
    stage.mostrarMuestra(.hoverCompletoVidrio, texto: nil)
    #expect(stage.dictationContent.panelDeVidrio)
    #expect(stage.dictationContent.contextoVisible != nil)
    stage.mostrarMuestra(.hover, texto: nil)
    #expect(!stage.dictationContent.panelDeVidrio)
    stage.mostrarMuestra(.hoverVidrio, texto: nil)
    #expect(stage.dictationContent.panelDeVidrio)
    stage.soltarMuestra()
    #expect(!stage.dictationContent.panelDeVidrio)
  }
}
