import CoreGraphics
import Foundation
import Testing

@testable import Dilo

/// Que empezar y terminar un dictado **suenen**.
///
/// Sale del veredicto de Alfonso del 2026-09-21 sobre la build instalada:
/// «¿antes teníamos sonido cuando se activaba?». No sonaba. El Begin colgaba
/// de `showAudioLevel` —el primer búfer del micrófono, y sólo con el visual de
/// voz montado—, así que el escenario nuevo podía pasar de reposo a dictando
/// sin que nadie tocara `HUDSounds`. Ahora los dos sonidos son de la
/// transición del contrato, y esto es lo que lo sostiene.
///
/// Con un reproductor doble: la regla de este repo es que nada de la suite
/// toque el audio de este Mac.
@MainActor
struct SonidosDeLaSesionTests {
  /// Un `ReproductorDeSonidos` que no reproduce: anota.
  private final class Doble: ReproductorDeSonidos {
    enum Momento: Equatable { case begin, end, paste }

    private(set) var tocados: [Momento] = []
    private(set) var ajustes: [DictationSoundSettings] = []

    func playBegin(using settings: DictationSoundSettings) { anotar(.begin, settings) }
    func playEnd(using settings: DictationSoundSettings) { anotar(.end, settings) }
    func playPaste(using settings: DictationSoundSettings) { anotar(.paste, settings) }

    private func anotar(_ momento: Momento, _ settings: DictationSoundSettings) {
      tocados.append(momento)
      ajustes.append(settings)
    }
  }

  private func pantalla() -> HUDScreenSnapshot {
    HUDScreenSnapshot(
      id: 2,
      frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      safeAreaTop: 0,
      auxiliaryTopLeftArea: nil,
      auxiliaryTopRightArea: nil,
      menuBarHeight: 24,
      estiloSinNotch: .notchSimulado
    )
  }

  private func escenario(_ doble: Doble) -> HUDStage {
    let stage = HUDStage(
      settings: AppSettings.previewStore(),
      reloj: DrivenClock().deadlineClock,
      sonidos: doble
    )
    stage.claim(.dictation, on: pantalla())
    return stage
  }

  /// Lo que Alfonso pidió, afirmado de punta a punta: una sesión completa
  /// suena al empezar y suena al terminar.
  @Test func unaSesionSuenaAlEmpezarYAlTerminar() {
    let doble = Doble()
    let stage = escenario(doble)

    stage.recibir(.escuchar)
    #expect(doble.tocados == [.begin], "empezar a dictar no sonó")

    stage.recibir(.procesar)
    stage.recibir(.entregar(.listo))
    #expect(doble.tocados == [.begin, .end], "terminar no sonó, o sonó dos veces")
  }

  /// Nada que ver con que llegue audio: el sonido sale de la transición del
  /// contrato. Este es el caso exacto que se había roto —una sesión cuyo
  /// primer búfer no llega, o llega tarde— y que dejaba el arranque mudo.
  @Test func begunSuenaSinQueLlegueNingunNivelDeAudio() {
    let doble = Doble()
    let stage = escenario(doble)
    let hud = DictationHUDController(stage: stage, settings: AppSettings.previewStore())

    stage.recibir(.preparar(.cargandoModelo))
    #expect(doble.tocados.isEmpty, "preparando todavía no es dictar")

    stage.recibir(.escuchar)
    #expect(doble.tocados == [.begin])
    // Y el visual de voz no manda: ni montado ni no montado cambia el sonido.
    hud.showAudioLevel(0.4)
    #expect(doble.tocados == [.begin], "un nivel de audio no vuelve a sonar")
  }

  /// Una sola vez por sesión de cada lado. Procesar, entregar y volver a
  /// reposo son la misma salida, y el habla terminó una vez.
  @Test func elFinalSuenaUnaSolaVezAunqueLaSalidaTengaTresPasos() {
    let doble = Doble()
    let stage = escenario(doble)

    stage.recibir(.escuchar)
    stage.recibir(.procesar)
    stage.recibir(.entregar(.listo))
    stage.recibir(.cancelar)
    #expect(doble.tocados == [.begin, .end])
  }

  /// Esperar un modelo a mitad de dictado manda la forma a «preparando» y la
  /// trae de vuelta: eso no es empezar de nuevo, y sonaría dos veces.
  @Test func cargarUnModeloAMitadDeSesionNoVuelveASonar() {
    let doble = Doble()
    let stage = escenario(doble)

    stage.recibir(.escuchar)
    stage.recibir(.preparar(.aviso("Cargando el modelo… 40 %")))
    #expect(doble.tocados == [.begin], "irse a esperar un modelo no es terminar")
    stage.recibir(.escuchar)
    #expect(doble.tocados == [.begin], "volver de esperar un modelo no es empezar")

    stage.recibir(.entregar(.listo))
    #expect(doble.tocados == [.begin, .end])
  }

  /// Y dos sesiones seguidas suenan dos veces: las banderas se reinician al
  /// volver a reposo, no al arrancar la siguiente.
  @Test func dosSesionesSeguidasSuenanCadaUna() {
    let doble = Doble()
    let stage = escenario(doble)

    stage.recibir(.escuchar)
    stage.recibir(.entregar(.listo))
    stage.recibir(.cancelar)
    stage.claim(.dictation, on: pantalla())
    stage.recibir(.escuchar)
    stage.recibir(.entregar(.listo))
    #expect(doble.tocados == [.begin, .end, .begin, .end])
  }

  /// Cancelar mientras se dicta también cierra: la sesión terminó, aunque no
  /// haya entregado nada.
  @Test func cancelarMientrasSeDictaTambienSuena() {
    let doble = Doble()
    let stage = escenario(doble)

    stage.recibir(.escuchar)
    stage.recibir(.cancelar)
    #expect(doble.tocados == [.begin, .end])
  }

  /// Un aviso no es el final de un dictado. Un mensaje de estado entra por la
  /// misma forma y sale por el mismo resultado, y sonaría como si alguien
  /// hubiera terminado de hablar.
  @Test func unAvisoDesdeReposoNoSuena() {
    let doble = Doble()
    let stage = escenario(doble)

    stage.recibir(.entregar(.aviso("No se pudo pegar el texto")))
    #expect(doble.tocados.isEmpty)
  }

  /// Los sonidos que suenan son los **de la sesión**, congelados al empezar
  /// (ADR-0004), no los que estén en Ajustes cuando el dictado termine.
  @Test func sonidosDeLaSesionYNoLosDeAjustesAlTerminar() {
    let doble = Doble()
    let ajustes = AppSettings.previewStore()
    ajustes.soundSet = .marimba
    ajustes.dictationSoundVolume = 0.5
    let stage = HUDStage(
      settings: ajustes,
      reloj: DrivenClock().deadlineClock,
      sonidos: doble
    )
    stage.claim(.dictation, on: pantalla(), rendering: ajustes.sessionSettings)

    stage.recibir(.escuchar)
    ajustes.soundSet = .click
    stage.recibir(.entregar(.listo))

    #expect(doble.ajustes.count == 2)
    #expect(doble.ajustes.allSatisfy { $0.set == .marimba })
    #expect(doble.ajustes.allSatisfy { $0.volume == 0.5 })
  }

  /// Apagados no suena nada, y eso lo decide `HUDSounds` y no el escenario:
  /// el escenario siempre dice cuándo, el reproductor decide si.
  @Test func elInterruptorDeSonidosLoMiraElReproductor() {
    let apagados = DictationSoundSettings(set: .marimba, isEnabled: false, volume: 0.5)
    #expect(!apagados.isEnabled)
    #expect(DictationSoundSettings(set: .marimba, isEnabled: true, volume: 3).volume == 1)
  }
}
