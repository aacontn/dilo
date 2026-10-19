import Foundation
import Testing
@testable import Dilo

/// La promesa del rediseño de Ajustes (2026-10-19): nada de lo que la
/// ventana ofrecía se pierde, y lo que se movió se encuentra buscándolo.
/// Mismo espíritu que `PanelDeLaBarraTests.nadaDelMenuGrisSePierde`.
@MainActor
struct IndiceDeAjustesTests {
  /// Todo lo que la ventana de la 0.9.1 dejaba cambiar, por su nombre en el
  /// índice. Si alguien saca un caso de `AjusteID`, esto no compila; si lo
  /// deja huérfano de sección, falla abajo. Un ajuste nuevo se agrega a
  /// `AjusteID`, no hace falta tocar esta lista.
  static let deLaVentanaVieja: [AjusteID] = [
    // Dictado (y su desplegable «Idiomas y traducción»)
    .atajoDeDictar, .microfono, .microfonoListo, .entregarElTexto, .guardarElHistorial,
    .carpetaDelHistorial, .borrarElHistorial, .idiomaDeDictado, .segundoIdioma,
    .teclaDelSegundoIdioma, .traducirCon, .traducirA,
    // Modos
    .tusModos, .agregarModo, .restaurarModos, .queDiloElija, .contextoApp, .contextoTexto,
    .contextoSeleccion, .contextoSitio, .contextoEnLinea, .proveedorGeneral,
    .modeloDelProveedor, .urlBaseDelProveedor, .claveDelProveedor,
    // Tus palabras
    .tusPalabras, .ofrecerCorrecciones, .aprenderConClaude, .modeloParaRevisar,
    .modeloParaOrdenar, .ordenarAhora, .loQueOrdenoClaude, .cuandoDigo, .comandosAlDictar,
    .sacarMuletillas, .listaDeMuletillas,
    // Historial (y «Actividad de dictado»)
    .buscarEnElHistorial, .actividad, .latencias,
    // Transcripciones
    .guardarTranscripcionEn, .carpetaDeTranscripciones,
    // Motor de voz
    .motorDeVoz, .modeloDeParakeet, .soltarElModelo,
    // Atajos
    .teclas, .cuantoEsUnToque, .deshacerUnEsc,
    // Apariencia (y «Sonidos»)
    .color, .queSeVe, .estiloDeLaOnda, .paletaDelHalo, .centroDelHalo, .tamanoDelNotch,
    .pantallasSinNotch, .enQuePantalla, .esperaDelHover, .modoEnReposo, .panelConVidrio,
    .esconderAlCompartir, .comoAparece, .textoLargo, .sonarAlDictar, .juegoDeSonidos, .volumen,
    // Datos en la muesca
    .datoClaudeCode, .datoCodex, .datoCPU, .datoMemoria, .datoGPU, .datoRed, .datoDisco,
    .porcentajeDelPlan, .avisosDeLimite, .agentesEnLaMuesca, .recientesDelPortapapeles,
    .proximaReunion, .notaRapida, .traducirEnElPanel, .modosEnElPanel,
    // General (y «Leer en voz alta»)
    .abrirAlIniciarSesion, .vozQueLee, .traducirAntesDeLeer, .bajarVoces, .vozPersonal,
    // Novedades y Acerca de
    .novedades, .version, .buscarActualizaciones, .actualizacionesSolas, .licencias,
  ]

  @Test func nadaDeLaVentanaViejaSePierde() {
    let navegables = Set(SettingsSectionGroup.allCases.flatMap(\.sections))
    for ajuste in Self.deLaVentanaVieja where ajuste.estaDisponible {
      #expect(navegables.contains(ajuste.seccion), "\(ajuste) vive en una sección que no se navega")
      // Y buscarlo por su nombre lo encuentra.
      #expect(IndiceDeAjustes.buscar(ajuste.titulo).contains(ajuste), "buscar «\(ajuste.titulo)» no encuentra \(ajuste)")
    }
  }

  @Test func cadaAjusteTieneNombreYUnaSeccionQueSeNavega() {
    let navegables = Set(SettingsSectionGroup.allCases.flatMap(\.sections))
    for ajuste in AjusteID.allCases where ajuste.estaDisponible {
      #expect(!ajuste.titulo.isEmpty, "\(ajuste) sin título")
      #expect(navegables.contains(ajuste.seccion), "\(ajuste)")
      #expect(ajuste.ancla.seccion == ajuste.seccion, "\(ajuste) salta a otra sección")
    }
  }

  @Test func seEncuentraLoQueSeBuscaSinSaberElNombre() {
    #expect(IndiceDeAjustes.buscar("microfono").first == .microfono)
    #expect(IndiceDeAjustes.buscar("api key").contains(.claveDelProveedor))
    // Lo que se mudó a Claude se encuentra con su nombre de antes.
    #expect(IndiceDeAjustes.buscar("clave anthropic").first == .claveDeAnthropic)
    #expect(IndiceDeAjustes.buscar("traducir con").first == .traducirCon)
    #expect(IndiceDeAjustes.buscar("revisar cada correccion").first == .modeloParaRevisar)
    #expect(IndiceDeAjustes.buscar("muletillas").first == .sacarMuletillas)
    #expect(IndiceDeAjustes.buscar("glaciar").first == .color)
  }

  @Test func laSeccionAlAbrirRecuerdaDiezMinutos() {
    let cierre = Date(timeIntervalSince1970: 1_000_000)
    let ultima = SettingsSection.modos.rawValue
    #expect(SeccionAlAbrir.decidir(pedida: nil, ultima: ultima, cerradaEn: cierre, ahora: cierre + 60) == .modos)
    #expect(SeccionAlAbrir.decidir(pedida: nil, ultima: ultima, cerradaEn: cierre, ahora: cierre + 11 * 60) == .portada)
    #expect(SeccionAlAbrir.decidir(pedida: nil, ultima: ultima, cerradaEn: nil, ahora: cierre) == .portada)
    // Lo pedido de afuera gana siempre.
    #expect(SeccionAlAbrir.decidir(pedida: .novedades, ultima: ultima, cerradaEn: cierre, ahora: cierre + 1) == .novedades)
    // Una sección guardada que ya no se navega no se abre sola.
    #expect(SeccionAlAbrir.decidir(pedida: nil, ultima: SettingsSection.sounds.rawValue, cerradaEn: cierre, ahora: cierre + 1) == .portada)
    #expect(SeccionAlAbrir.decidir(pedida: nil, ultima: "transformar", cerradaEn: cierre, ahora: cierre + 1) == .portada)
  }
}
