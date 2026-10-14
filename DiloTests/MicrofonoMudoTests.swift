import CoreGraphics
import DiloEngines
import Foundation
import Testing

@testable import Dilo

/// El silencio y un micrófono muerto tienen que verse distinto (CONTEXT.md).
/// El detector es puro y se prueba en `DiloCore`; acá, lo que la muesca y la
/// sesión hacen con lo que dice.
@MainActor
@Suite("Micrófono que entrega ceros")
struct MicrofonoMudoTests {
  private func escuchando() -> (DictationHUDController, HUDStage) {
    let store = AppSettings.previewStore()
    let stage = HUDStage(settings: store)
    let hud = DictationHUDController(stage: stage, settings: store)
    hud.showListening(on: CGDirectDisplayID?.none, isLatched: false, settings: store.sessionSettings)
    return (hud, stage)
  }

  @Test func aLosCincoSegundosLaMuescaLoDiceYAlVolverSeDespeja() {
    let (hud, stage) = escuchando()
    #expect(stage.estado == .dictando)

    hud.avisarDelMicrofono(.reabrir)
    #expect(stage.estado == .dictando, "reabrir es callado: no hay nada que decir todavía")
    #expect(hud.textForTesting.isEmpty)

    hud.avisarDelMicrofono(.avisar)
    #expect(stage.estado == .preparando(.aviso(AvisoDelMicrofono.sinSonido)))
    #expect(hud.textForTesting == AvisoDelMicrofono.sinSonido)

    hud.avisarDelMicrofono(.escalar)
    #expect(hud.textForTesting == AvisoDelMicrofono.sigueSinSonido)

    hud.avisarDelMicrofono(.revivio)
    #expect(stage.estado == .dictando)
    #expect(hud.textForTesting.isEmpty)
  }

  /// Un aviso que llega tarde —el salto al hilo principal— no puede reabrir
  /// una forma que ya terminó de escuchar.
  @Test func unAvisoTardioNoTocaLoQueYaTermino() {
    let (hud, stage) = escuchando()
    hud.showFinalizing()
    hud.avisarDelMicrofono(.avisar)
    #expect(stage.estado == .dictando)
    #expect(hud.textForTesting.isEmpty)
  }

  @Test func laSesionSabeSiElMicrofonoEstaMudoYEmpiezaSinAviso() {
    let microfono = MicrofonoDeLaSesion()
    #expect(!microfono.estaMudo)
    microfono.detectorVio(.reabrir)
    #expect(!microfono.estaMudo)
    microfono.detectorVio(.avisar)
    #expect(microfono.estaMudo)
    microfono.detectorVio(.revivio)
    #expect(!microfono.estaMudo)
    microfono.detectorVio(.escalar)
    #expect(microfono.estaMudo)
    microfono.empezarSesion()
    #expect(!microfono.estaMudo)
  }

  @Test func elAvisoLlegaAQuienLoPidio() {
    let microfono = MicrofonoDeLaSesion()
    let vistos = Vistos()
    microfono.alAvisar { vistos.agregar($0) }
    microfono.detectorVio(.avisar)
    microfono.detectorVio(.revivio)
    #expect(vistos.eventos == [.avisar, .revivio])
  }
}

private final class Vistos: @unchecked Sendable {
  private let candado = NSLock()
  private var guardados: [DetectorDeMicMuerto.Evento] = []
  func agregar(_ evento: DetectorDeMicMuerto.Evento) { candado.withLock { guardados.append(evento) } }
  var eventos: [DetectorDeMicMuerto.Evento] { candado.withLock { guardados } }
}
