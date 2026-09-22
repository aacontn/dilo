import Foundation
import Testing

@testable import Dilo

/// Lo que la muesca abierta trajo de vuelta del overlay de Dilo-Tauri.
///
/// Sale del veredicto del 2026-09-21: «no se ve bien; revisa la animación que
/// teníamos antes; quizás va como la fusión de ambas ideas». El reposo se
/// queda como está —la muesca chica, sus curvas, su punto mango— y lo que se
/// abre adentro vuelve a ser lo del overlay: su onda de brasas, su cursiva con
/// cursor y sus curvas de entrada y salida.
///
/// Se afirma con funciones puras a propósito. Lo que hay que cuidar son los
/// **números** —los que están escritos en `RecordingOverlay.css` del repo
/// congelado—, y rasterizar nueve barras para medirlas dejaría el test
/// dependiendo del antialias.
struct FusionDelOverlayTests {
  // MARK: La onda de brasas

  /// La fórmula de altura del overlay, tal cual: `max(7, min(16, 6 + v^0.7 *
  /// 11))`. La raíz de 0,7 es lo que hace que una voz normal use casi toda la
  /// banda; con una recta, hablar normal dejaba la onda a media asta.
  @MainActor
  @Test func laAlturaDeCadaBarraEsLaDelOverlay() {
    let content = DictationHUDContent()
    content.levelHistory = [Float](repeating: 0, count: HUDWaveformView.barCount)
    let onda = HUDOndaDeBrasas(content: content)

    // En silencio, el piso: una fila de barras vivas, no una línea apagada.
    #expect(onda.alto(0) == 7)

    content.levelHistory = [Float](repeating: 1, count: HUDWaveformView.barCount)
    #expect(HUDOndaDeBrasas(content: content).alto(0) == 16, "a todo volumen, el techo")

    content.levelHistory = [Float](repeating: 0.25, count: HUDWaveformView.barCount)
    let media = HUDOndaDeBrasas(content: content).alto(0)
    #expect(media > 7 && media < 16)
    #expect(abs(media - (6 + pow(0.25, 0.7) * 11)) < 0.001)
  }

  /// Nueve barras. Con menos la ola no viaja; con más se adelgazan hasta
  /// volver a ser el ecualizador que la onda de Dilo nunca fue.
  @Test func sonNueveBarras() {
    #expect(HUDOndaDeBrasas.barras == 9)
    // Y caben en la banda de la forma abierta con aire: 16 de alto máximo por
    // barra, 20 de banda propia, 24 de la franja de la muesca.
    #expect(HUDOndaDeBrasas.altoDeLaBanda <= HUDMetrics.standard.waveBandHeight)
  }

  /// El vaivén de `@keyframes wsway`: entre 0,55 y 1,7, y desfasado por barra
  /// para que la ola viaje en vez de latir.
  @MainActor
  @Test func elVaivenRespiraEntreLosDosExtremosYNoAlUnisono() {
    let content = DictationHUDContent()
    let onda = HUDOndaDeBrasas(content: content)
    var minimo = CGFloat.infinity
    var maximo = -CGFloat.infinity
    for paso in 0..<400 {
      let v = onda.vaiven(0, en: Double(paso) * 0.01)
      minimo = min(minimo, v)
      maximo = max(maximo, v)
    }
    #expect(abs(minimo - 0.55) < 0.01)
    #expect(abs(maximo - 1.7) < 0.01)

    // Dos barras cualesquiera no pueden ir juntas: con los nueve períodos
    // iguales las barras suben y bajan a la vez y se lee como un latido.
    let instante = 0.37
    let valores = (0..<HUDOndaDeBrasas.barras).map { onda.vaiven($0, en: instante) }
    #expect(Set(valores.map { Int($0 * 1000) }).count == valores.count)
  }

  /// Un micrófono muerto no respira. Es la regla de CONTEXT.md —tiene que
  /// verse distinto del silencio— y una onda que sigue moviéndose sola dice
  /// exactamente lo contrario.
  @MainActor
  @Test func conElMicrofonoMuertoLaOndaSeQuedaQuieta() {
    let content = DictationHUDContent()
    content.isAudioAlive = false
    let onda = HUDOndaDeBrasas(content: content)
    #expect(onda.vaiven(0, en: 0.1) == 1)
    #expect(onda.vaiven(3, en: 2.7) == 1)
  }

  // MARK: El cursor

  /// `scaret-blink 1.05s steps(1)`: mitad encendido, mitad apagado, sin medias
  /// tintas.
  @Test func elCursorParpadeaMitadYMitad() {
    let cero = Date(timeIntervalSinceReferenceDate: 0)
    #expect(HUDCursorDeDictado.encendido(en: cero))
    #expect(HUDCursorDeDictado.encendido(en: cero.addingTimeInterval(0.5)))
    #expect(!HUDCursorDeDictado.encendido(en: cero.addingTimeInterval(0.6)))
    #expect(!HUDCursorDeDictado.encendido(en: cero.addingTimeInterval(1.04)))
    #expect(HUDCursorDeDictado.encendido(en: cero.addingTimeInterval(1.06)))
    #expect(HUDCursorDeDictado.periodo == 1.05)
  }

  // MARK: Las curvas

  /// La curva de Tauri, en sus dos puntas y en su carácter: `cubic-bezier(0.22,
  /// 1, 0.36, 1)` arranca disparada y frena al final. Es lo que hace que la
  /// muesca se sienta «líquida» en vez de mecánica, y es la razón por la que
  /// los cuatro fotogramas de `apertura-*.png` se reparten por avance y no por
  /// tiempo: a un tercio del tiempo la forma ya está casi abierta.
  @Test func laCurvaDeTauriArrancaDisparadaYFrena() {
    #expect(HUDRevealStyle.progresoDeTauri(0) == 0)
    #expect(HUDRevealStyle.progresoDeTauri(1) == 1)
    let aUnCuarto = HUDRevealStyle.progresoDeTauri(0.25)
    #expect(aUnCuarto > 0.75, "a un cuarto del tiempo ya pasó tres cuartos: \(aUnCuarto)")
    #expect(HUDRevealStyle.progresoDeTauri(0.75) > 0.98)
    // Monótona, o los fotogramas intermedios no querrían decir nada.
    var anterior = 0.0
    for paso in 1...100 {
      let ahora = HUDRevealStyle.progresoDeTauri(Double(paso) / 100)
      #expect(ahora >= anterior)
      anterior = ahora
    }
  }

  /// Una `cubic-bezier` lineal es la identidad: el despeje por bisección tiene
  /// que dar eso y no algo parecido.
  @Test func elDespejeDeLaCurvaEsExacto() {
    for paso in 0...10 {
      let t = Double(paso) / 10
      let y = HUDRevealStyle.bezier(t, x1: 1.0 / 3, y1: 1.0 / 3, x2: 2.0 / 3, y2: 2.0 / 3)
      #expect(abs(y - t) < 0.001, "en \(t) dio \(y)")
    }
  }

  /// Cada estilo de revelación vuelve a abrir distinto. Un único resorte para
  /// los cuatro era el ajuste que no hacía nada.
  @Test func cadaEstiloAbreConSuPropiaCurva() {
    let aperturas = HUDRevealStyle.allCases.map(\.apertura)
    #expect(Set(aperturas.map { String(describing: $0) }).count == HUDRevealStyle.allCases.count)
    // Y ninguno cierra rebotando: la forma vuelve a ser la muesca, y una
    // muesca que rebota al cerrarse se lee como un error. Todos los cierres
    // son curvas y ninguno es un resorte.
    for estilo in HUDRevealStyle.allCases {
      #expect(!String(describing: estilo.cierre).contains("Spring"), "\(estilo) rebota al cerrar")
    }
  }

  // MARK: El modo

  /// «Sin modo» fuera. Que sin modo no haya chip ya lo cuida
  /// `NotchEscenarioTests`; lo que faltaba es la otra mitad: el nombre del modo
  /// sobrevive a la sesión para que la muesca en reposo pueda decirlo, así que
  /// soltarlo con las flechas tiene que borrarlo también de ahí. Guardando sólo
  /// los nombres, el reposo seguía anunciando el modo recién soltado.
  @MainActor
  @Test func soltarElModoLoBorraDelReposo() {
    let stage = HUDStage(settings: AppSettings.previewStore(), reloj: DrivenClock().deadlineClock)
    let hud = DictationHUDController(stage: stage, settings: AppSettings.previewStore())

    hud.showShapingChoice("Correo")
    #expect(stage.dictationContent.modoActivo == "Correo")
    hud.showShapingChoice(nil)
    #expect(stage.dictationContent.modoActivo == nil)
  }
}
