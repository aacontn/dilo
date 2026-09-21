import CoreGraphics
import Foundation
import Testing

@testable import Dilo

/// El notch simulado: la otra forma que puede tomar el HUD en una pantalla
/// sin carcasa (Ajustes → Apariencia, «En pantallas sin notch»).
///
/// Alfonso trabaja en un Mac mini con dos 1080p externos, que es el 80 % de
/// su uso, y ahí la píldora bajo la barra no se lee como notch. La imitación
/// se pega al borde de arriba y ocupa la franja del centro de la barra de
/// menús, que macOS deja vacía. Lo que esta suite cuida es que elegir una no
/// cambie nada de la otra, y que un MacBook no se entere de que el ajuste
/// existe.
@Suite("Notch simulado")
struct HUDNotchSimuladoTests {
  private let conNotch = HUDScreenSnapshot(
    id: 1,
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    safeAreaTop: 32,
    auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
    auxiliaryTopRightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
    menuBarHeight: 32
  )
  /// Uno de los dos 1080p del Mac mini, con el ajuste en cada valor.
  private let pildora = HUDScreenSnapshot(
    id: 2,
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    safeAreaTop: 0,
    auxiliaryTopLeftArea: nil,
    auxiliaryTopRightArea: nil,
    menuBarHeight: 24,
    estiloSinNotch: .pildora
  )
  private let simulado = HUDScreenSnapshot(
    id: 2,
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    safeAreaTop: 0,
    auxiliaryTopLeftArea: nil,
    auxiliaryTopRightArea: nil,
    menuBarHeight: 24,
    estiloSinNotch: .notchSimulado
  )

  /// Lo que pide el pedido: la forma cuelga del borde de arriba, centrada.
  @Test func elNotchSimuladoCuelgaDelBordeDeArribaYVaCentrado() {
    let ventana = HUDNotchGeometry.windowFrame(for: simulado)
    #expect(ventana.maxY == simulado.frame.maxY)
    #expect(ventana.midX == simulado.frame.midX)
  }

  /// Y la píldora sigue donde estaba: debajo de la barra, con su aire.
  @Test func laPildoraNoSeMueveDeDondeEstaba() {
    let ventana = HUDNotchGeometry.windowFrame(for: pildora)
    #expect(
      ventana.maxY
        == pildora.frame.maxY - pildora.menuBarHeight - HUDNotchGeometry.pillDetachment
    )
    #expect(ventana.midX == pildora.frame.midX)
  }

  /// La carcasa simulada mide lo que el notch de un MacBook, no lo que la
  /// ventana:
  /// la franja que se tapa de la barra de menús son 185 puntos en el centro.
  /// Lo demás de la ventana es holgura invisible para la sombra.
  @Test func enReposoMideLoMismoQueUnNotchDeVerdad() {
    let reposo = HUDNotchGeometry.closedSize(for: simulado)
    #expect(reposo == CGSize(width: 185, height: 32))
    #expect(reposo == HUDNotchGeometry.closedSize(for: pildora))
    #expect(reposo == HUDNotchGeometry.closedSize(for: conNotch))
    #expect(reposo.width >= 180 && reposo.width <= 200)
  }

  /// Abierto crece igual que la píldora: el ajuste mueve la forma, no la
  /// engorda. Si alguna vez se ensancha, tapa menús de verdad.
  @Test func abiertoNoEsMasAnchoQueLaPildora() {
    let metrics = HUDMetrics.standard
    let tamano = { (pantalla: HUDScreenSnapshot) in
      HUDNotchGeometry.contentSize(
        for: pantalla,
        metrics: metrics,
        visualBandHeight: metrics.waveBandHeight,
        includesTextBand: true,
        shapingBandHeight: metrics.shapingBandHeight
      )
    }
    #expect(tamano(simulado).width == tamano(pildora).width)
    #expect(tamano(simulado).width <= HUDNotchGeometry.windowSize(for: simulado).width)
  }

  /// Las esquinas: rectas arriba —nace del borde, como el notch real— y
  /// redondeadas abajo. La píldora se cierra por los cuatro lados.
  @Test func elNotchSimuladoNoSeCierraPorArriba() {
    #expect(!HUDNotchGeometry.closesAtTop(for: simulado))
    #expect(HUDNotchGeometry.topCornerRadius(for: simulado, metrics: .standard) == 0)
    #expect(HUDNotchGeometry.closesAtTop(for: pildora))
    #expect(
      HUDNotchGeometry.topCornerRadius(for: pildora, metrics: .standard)
        == HUDMetrics.standard.bottomCornerRadius
    )
    #expect(HUDMetrics.standard.bottomCornerRadius > 0)
  }

  /// Sin fillets nuevos: la curva que se abre hacia el bisel necesita un
  /// bisel de verdad, y una pantalla externa no lo tiene (ADR-0001).
  @Test func elNotchSimuladoNoInventaFillets() {
    #expect(HUDNotchGeometry.filletSize(for: simulado) == 0)
    #expect(HUDNotchGeometry.filletSize(for: pildora) == 0)
  }

  /// El contenido sigue siendo el de Dilo —onda, texto parcial y chip de
  /// modo—: lo que cambia es dónde cuelga la forma, no qué lleva adentro.
  @Test func adentroVaLoMismoQueEnLaPildora() {
    #expect(HUDNotchGeometry.drawsPill(for: simulado))
    #expect(HUDNotchGeometry.drawsPill(for: pildora))
  }

  /// Con carcasa real el ajuste no se mira: misma ventana, mismo reposo,
  /// mismos fillets y mismo piso de escala con cualquiera de los dos valores.
  @Test func conNotchRealNadaCambia() {
    var conAjusteSimulado = conNotch
    conAjusteSimulado.estiloSinNotch = .notchSimulado

    #expect(!HUDNotchGeometry.simulatesNotch(for: conAjusteSimulado))
    #expect(
      HUDNotchGeometry.windowFrame(for: conAjusteSimulado)
        == HUDNotchGeometry.windowFrame(for: conNotch)
    )
    #expect(HUDNotchGeometry.windowFrame(for: conNotch).maxY == conNotch.frame.maxY)
    #expect(
      HUDNotchGeometry.closedSize(for: conAjusteSimulado)
        == HUDNotchGeometry.closedSize(for: conNotch)
    )
    #expect(
      HUDNotchGeometry.filletSize(for: conAjusteSimulado)
        == HUDNotchGeometry.filletSize(for: conNotch)
    )
    #expect(
      HUDNotchGeometry.minimumScale(for: conAjusteSimulado)
        == HUDNotchGeometry.minimumScale(for: conNotch)
    )
    #expect(
      HUDNotchGeometry.topCornerRadius(for: conAjusteSimulado, metrics: .standard)
        == HUDNotchGeometry.topCornerRadius(for: conNotch, metrics: .standard)
    )
    #expect(!HUDNotchGeometry.drawsPill(for: conAjusteSimulado))
  }

  /// El ajuste se guarda y se vuelve a leer tal cual: el `rawValue` es la
  /// elección de la persona y renombrarlo se la borra en silencio.
  @MainActor
  @Test func elAjusteSeGuardaYSeRelee() {
    let suite = "cl.espaciodigital.dilo.tests.notch-simulado"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    let ajustes = AppSettings(defaults: defaults)
    #expect(ajustes.hudEstiloSinNotch == .notchSimulado)
    ajustes.hudEstiloSinNotch = .pildora

    #expect(AppSettings(defaults: defaults).hudEstiloSinNotch == .pildora)
  }

  /// Quien había **encendido** el interruptor viejo pedía que la forma
  /// despejara la barra de menús: esa elección vale como haber elegido la
  /// píldora y se respeta al actualizar. Apagado quería la forma donde iría
  /// el notch, que es el default de hoy.
  @MainActor
  @Test func elInterruptorViejoSeTraduceALaFormaQuePedia() {
    let suite = "cl.espaciodigital.dilo.tests.notch-simulado-migracion"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set(false, forKey: "hudClearsMenuBar")
    #expect(AppSettings(defaults: defaults).hudEstiloSinNotch == .notchSimulado)

    defaults.set(true, forKey: "hudClearsMenuBar")
    #expect(AppSettings(defaults: defaults).hudEstiloSinNotch == .pildora)
  }
}
