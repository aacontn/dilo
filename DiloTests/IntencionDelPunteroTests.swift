import CoreGraphics
import Foundation
import Testing

@testable import Dilo

/// Cuándo abre y cuándo cierra el panel del hover: frenarse encima abre
/// antes del retardo, pasar rápido hacia la barra no abre, y al salir hay una
/// gracia corta. Todo con instantes inventados: nada duerme.
@Suite("Intención del puntero")
struct IntencionDelPunteroTests {
  private func ms(_ n: Int) -> Duration { .milliseconds(n) }
  /// Un punto sobre la muesca; la y crece hacia arriba, como en pantalla.
  private let encima = CGPoint(x: 960, y: 1068)

  @Test func quietoEncimaAbreAntesDelRetardo() {
    var i = IntencionDelPuntero()
    #expect(i.muestra(encima, dentro: true, t: ms(0)) == .revisarEn(ms(160)))
    #expect(i.revisar(t: ms(160)) == .abrir)
    #expect(i.abierto)
  }

  @Test func moviendoseEncimaEsperaElRetardo() {
    var i = IntencionDelPuntero()
    _ = i.muestra(encima, dentro: true, t: ms(0))
    // Barre la muesca a 1000 pt/s, una muestra cada 10 ms.
    var t = 10
    while t < 500 {
      let punto = CGPoint(x: encima.x + CGFloat(t), y: encima.y)
      #expect(i.muestra(punto, dentro: true, t: ms(t)) != .abrir)
      t += 10
    }
    #expect(i.muestra(CGPoint(x: encima.x + 500, y: encima.y), dentro: true, t: ms(500)) == .abrir)
  }

  /// Lento sobre la muesca, sin llegar a pararse, también es mirar.
  @Test func lentoEncimaAbreAlSostenerse() {
    var i = IntencionDelPuntero()
    _ = i.muestra(encima, dentro: true, t: ms(0))
    var decision = IntencionDelPuntero.Decision.nada
    var t = 10
    while decision != .abrir, t <= 400 {
      // 50 pt/s: medio punto cada diez milisegundos.
      decision = i.muestra(CGPoint(x: encima.x + CGFloat(t) / 20, y: encima.y), dentro: true, t: ms(t))
      t += 10
    }
    #expect(decision == .abrir)
    #expect(t - 10 < 500, "antes del retardo")
  }

  /// Subiendo rápido hacia la barra, quedarse contra el borde no cuenta como
  /// frenarse: abre recién con el retardo entero.
  @Test func deCaminoALaBarraNoAbreAntes() {
    var i = IntencionDelPuntero()
    _ = i.muestra(CGPoint(x: encima.x, y: encima.y - 30), dentro: false, t: ms(0))
    // 30 puntos hacia arriba en 10 ms: 3000 pt/s.
    _ = i.muestra(encima, dentro: true, t: ms(10))
    #expect(i.revisar(t: ms(200)) != .abrir)
    #expect(i.revisar(t: ms(510)) == .abrir)
  }

  /// El retardo de Ajustes manda también sobre el frenado: subirlo alarga la
  /// permanencia en proporción, y bajarlo nunca la deja más larga que él.
  @Test func laPermanenciaSigueAlRetardo() {
    var ajustes = IntencionDelPuntero.Ajustes()
    #expect(ajustes.permanenciaEfectiva == ms(160))
    ajustes.retardo = ms(1_200)
    #expect(ajustes.permanenciaEfectiva == ms(384))
    ajustes.retardo = ms(100)
    #expect(ajustes.permanenciaEfectiva == ms(100))
  }

  @Test func conRetardoCeroAbreAlInstante() {
    var i = IntencionDelPuntero()
    i.ajustes.retardo = .zero
    #expect(i.muestra(encima, dentro: true, t: ms(0)) == .abrir)
  }

  /// Al salir hay una gracia: volver antes no cierra, irse de verdad sí.
  @Test func alSalirEsperaLaGracia() {
    var i = IntencionDelPuntero()
    _ = i.muestra(encima, dentro: true, t: ms(0))
    #expect(i.revisar(t: ms(160)) == .abrir)

    let afuera = CGPoint(x: 400, y: 1068)
    #expect(i.muestra(afuera, dentro: false, t: ms(1000)) == .revisarEn(ms(250)))
    // Vuelve a los 100 ms: nada se cierra.
    #expect(i.muestra(encima, dentro: true, t: ms(1100)) == .nada)
    #expect(i.revisar(t: ms(1250)) == .nada)
    #expect(i.abierto)

    // Se va de verdad.
    #expect(i.muestra(afuera, dentro: false, t: ms(2000)) == .revisarEn(ms(250)))
    #expect(i.revisar(t: ms(2100)) == .revisarEn(ms(150)))
    #expect(i.revisar(t: ms(2250)) == .cerrar)
    #expect(!i.abierto)
  }

  /// Entrar y salir antes de decidir no deja nada pendiente.
  @Test func pasarDeLargoNoDejaNada() {
    var i = IntencionDelPuntero()
    _ = i.muestra(encima, dentro: true, t: ms(0))
    #expect(i.muestra(CGPoint(x: 400, y: 1068), dentro: false, t: ms(50)) == .nada)
    #expect(i.revisar(t: ms(160)) == .nada)
    #expect(i.revisar(t: ms(600)) == .nada)
  }

  @Test func reiniciarOlvidaTodoMenosLosAjustes() {
    var i = IntencionDelPuntero()
    i.ajustes.retardo = ms(300)
    _ = i.muestra(encima, dentro: true, t: ms(0))
    _ = i.revisar(t: ms(160))
    i.reiniciar()
    #expect(!i.abierto)
    #expect(i.ajustes.retardo == ms(300))
    #expect(i.revisar(t: ms(1000)) == .nada)
  }

  // En el escenario, con el reloj dirigido.

  private let simulado = HUDScreenSnapshot(
    id: 2,
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    safeAreaTop: 0,
    auxiliaryTopLeftArea: nil,
    auxiliaryTopRightArea: nil,
    menuBarHeight: 24
  )

  /// Posarse quieto sobre la muesca abre el panel a los 160 ms, antes del
  /// medio segundo de fábrica; irse lo cierra tras la gracia.
  @MainActor
  @Test func enElEscenarioQuietoAbreAntesYAlIrseCierraTrasLaGracia() async {
    let reloj = DrivenClock()
    let stage = HUDStage(settings: AppSettings.previewStore(), reloj: reloj.deadlineClock, punteroEn: { .zero })
    stage.colocar(en: simulado)
    let silueta = HUDNotchGeometry.siluetaEnPantalla(
      for: simulado, tamaño: HUDNotchGeometry.reposoSize(for: simulado), encuadre: .reposo
    )
    stage.punteroSeMovio(a: CGPoint(x: silueta.midX, y: silueta.midY))
    #expect(!stage.dictationContent.punteroEncima)
    // En pasos de 10 ms: cada plazo se arma en su propia tarea, y un salto
    // grande podría caer antes de que la siguiente empiece a esperar.
    while !stage.dictationContent.punteroEncima {
      reloj.advance(by: .milliseconds(10))
      await Task.yield()
    }
    #expect(reloj.deadlineClock.now() < HUDStage.toleranciaDelHover, "abrió antes del retardo")

    let salida = reloj.deadlineClock.now()
    stage.punteroSeMovio(a: CGPoint(x: 300, y: simulado.frame.maxY - 8))
    #expect(stage.dictationContent.punteroEncima, "la gracia manda")
    while stage.dictationContent.punteroEncima {
      reloj.advance(by: .milliseconds(10))
      await Task.yield()
    }
    #expect(reloj.deadlineClock.now() - salida < HUDStage.toleranciaDelHover, "cerró con la gracia, no con el retardo")
    #expect(!stage.estado.captura)
  }
}
