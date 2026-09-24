import CoreGraphics
import DiloConsumo
import Foundation
import Testing
@testable import Dilo

/// La sección «Datos en la muesca» y el detalle que abre el hover: lo que se
/// guarda, lo que se dice y cuánto crece el panel.
@MainActor
struct DatosDeLaMuescaSettingsTests {
  private let simulada = HUDScreenSnapshot(
    id: 2,
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    safeAreaTop: 0,
    auxiliaryTopLeftArea: nil,
    auxiliaryTopRightArea: nil,
    menuBarHeight: 24,
    estiloSinNotch: .notchSimulado
  )

  private func defaultsDePrueba() -> UserDefaults {
    let suite = "cl.espaciodigital.dilo.tests.muesca-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  // MARK: Lo que se guarda

  @Test func deFabricaNoHayNingunDato() {
    let settings = AppSettings(defaults: defaultsDePrueba())
    #expect(settings.hudDisposicion == DisposicionDeLaMuesca())
    #expect(!settings.hudPorcentajeDeClaude)
  }

  /// Quien eligió datos con los dos pickers de Apariencia los conserva.
  @Test func laEleccionDeAparienciaSeMigra() {
    let defaults = defaultsDePrueba()
    defaults.set("codex", forKey: "hudDatoIzquierdo")
    defaults.set("ram", forKey: "hudDatoDerecho")
    let settings = AppSettings(defaults: defaults)
    #expect(settings.hudDisposicion.dato(en: .izquierdo) == .codex)
    #expect(settings.hudDisposicion.dato(en: .derecho) == .ram)
  }

  @Test func laDisposicionSeGuardaYSeReleeIgual() {
    let defaults = defaultsDePrueba()
    let settings = AppSettings(defaults: defaults)
    settings.hudDisposicion.encender(.claude, en: .derecho)
    settings.hudDisposicion.encender(.cpu, en: .izquierdo)
    let otra = AppSettings(defaults: defaults)
    #expect(otra.hudDisposicion == settings.hudDisposicion)
  }

  // MARK: El hover

  /// Con datos, el panel del hover crece lo que pide el detalle y sigue bajo
  /// su techo, con carcasa real o sin ella.
  @Test func elPanelDelHoverCreceConLosDatosSinPasarSuTecho() {
    var conDatos = simulada
    conDatos.anchoDeLosLados = HUDNotchGeometry.anchoDeUnLado
    let sin = HUDNotchGeometry.altoDelPanelDeHover(for: simulada)
    let con = HUDNotchGeometry.altoDelPanelDeHover(for: conDatos)
    #expect(con == sin + HUDNotchGeometry.altoDelDetalleDeDatos)
    #expect(con <= HUDNotchGeometry.altoMaximoDelHover)

    var notch = HUDPreviewScreen.notched
    notch.anchoDeLosLados = HUDNotchGeometry.anchoDeUnLado
    #expect(
      HUDNotchGeometry.reposoSize(for: notch).height
        + HUDNotchGeometry.altoDelContextoEnReposo
        + HUDNotchGeometry.altoDelDetalleDeDatos
        <= HUDNotchGeometry.altoMaximoDelHover
    )
    // La ventana abierta alcanza para el panel más alto.
    #expect(HUDNotchGeometry.windowSize(for: conDatos).height >= con)
  }

  @Test func elDetalleNombraCadaFila() {
    #expect(HUDDetalleDeLosDatos.nombre(.semana) == String(localized: "Semana"))
    #expect(HUDDetalleDeLosDatos.nombre(.tokensDelBloque) == String(localized: "Tokens, 5 h"))
    #expect(HUDDetalleDeLosDatos.seReinicia(en: "2 h 14 min")
      == String(localized: "Se reinicia en \("2 h 14 min")"))
  }

  // MARK: Lo que dice la sección

  /// Lo que no cabe se dice, y el consejo cambia si el otro costado está
  /// libre o no.
  @Test func loQueNoCabeDiceQuienYQueHacer() {
    let libre = DatosDeLaMuescaCopy.noCabe(en: .izquierdo, ocupa: .codex, elOtroLleno: false)
    #expect(libre == String(localized: "No cabe: a la izquierda ya va \("Codex"). Elige la derecha o apaga \("Codex")."))
    let lleno = DatosDeLaMuescaCopy.noCabe(en: .derecho, ocupa: .cpu, elOtroLleno: true)
    #expect(lleno.contains("CPU"))
    #expect(lleno != DatosDeLaMuescaCopy.noCabe(en: .derecho, ocupa: .cpu, elOtroLleno: false))
  }

  /// «Probar ahora» dice la falla en palabras; la sesión vencida manda a
  /// Claude Code, que es quien la renueva.
  @Test func probarAhoraDiceLaFallaEnPalabras() {
    let ahora = Date(timeIntervalSince1970: 1_790_180_000)
    let vencida = DatosDeLaMuescaCopy.Prueba(falla: .sesionVencida, ahora: ahora)
    #expect(!vencida.salioBien)
    #expect(vencida.texto == String(localized: "Tu sesión de Claude Code venció. Abre Claude Code para que renueve su sesión."))
    let sinRed = DatosDeLaMuescaCopy.Prueba(falla: .sinRed, ahora: ahora)
    #expect(sinRed.texto != vencida.texto)

    let consumo = ConsumoDeIA(ventanaCorta: VentanaDeUso(
      porcentaje: 42, seReiniciaEn: ahora.addingTimeInterval(3 * 3600 + 60), duracion: 18_000))
    let bien = DatosDeLaMuescaCopy.Prueba(consumo: consumo, ahora: ahora)
    #expect(bien.salioBien)
    #expect(bien.texto.contains("42%"))
    #expect(bien.texto.contains("3 h 1 min"))
  }

  @Test func laSeccionVaEnAjustesJuntoAApariencia() {
    #expect(SettingsSection.datosDeLaMuesca.group == .settings)
    let orden = SettingsSectionGroup.settings.sections
    let apariencia = orden.firstIndex(of: .appearance)
    #expect(orden.firstIndex(of: .datosDeLaMuesca) == apariencia.map { $0 + 1 })
    #expect(!SettingsSection.datosDeLaMuesca.icon.isEmpty)
  }
}
