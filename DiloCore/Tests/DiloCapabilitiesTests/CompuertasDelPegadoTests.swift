import CoreGraphics
import Foundation
import os
import Testing

@testable import DiloCapabilities

/// Un reloj que avanza sólo cuando alguien duerme: un plazo de dos segundos
/// se cumple sin esperar dos segundos.
final class RelojQueAvanza: Sendable {
  private let tiempo = OSAllocatedUnfairLock(initialState: Duration.zero)

  var ahora: Duration { tiempo.withLock { $0 } }

  func dormir(_ duracion: Duration) {
    tiempo.withLock { $0 += duracion }
  }
}

struct CompuertasDelPegadoTests {
  private func teclado(
    segura: Bool = false,
    modificadores: @escaping @Sendable (Duration) -> CGEventFlags,
    reloj: RelojQueAvanza
  ) -> LecturasDelTeclado {
    LecturasDelTeclado(
      entradaSegura: { segura },
      modificadores: { modificadores(reloj.ahora) }
    )
  }

  @Test func conElTecladoLibrePegaAlTiro() async {
    let reloj = RelojQueAvanza()
    let motivo = await teclado(modificadores: { _ in [] }, reloj: reloj)
      .esperarTecladoLibre(ahora: { reloj.ahora }, dormir: { reloj.dormir($0) })
    #expect(motivo == nil)
    #expect(reloj.ahora == .zero)
  }

  /// Casi siempre es la mano soltando el gatillo: ⇧ que se suelta a los
  /// 300 ms no es motivo para no pegar.
  @Test func unaMayusculaQueSeSueltaALos300msPega() async {
    let reloj = RelojQueAvanza()
    let motivo = await teclado(
      modificadores: { ahora in ahora < .milliseconds(300) ? .maskShift : [] },
      reloj: reloj
    ).esperarTecladoLibre(ahora: { reloj.ahora }, dormir: { reloj.dormir($0) })
    #expect(motivo == nil)
    #expect(reloj.ahora >= .milliseconds(300))
    #expect(reloj.ahora < .seconds(2))
  }

  @Test func unaTeclaSostenidaMasDeDosSegundosNoPega() async {
    let reloj = RelojQueAvanza()
    let motivo = await teclado(modificadores: { _ in .maskAlternate }, reloj: reloj)
      .esperarTecladoLibre(ahora: { reloj.ahora }, dormir: { reloj.dormir($0) })
    #expect(motivo == .teclasSostenidas)
    #expect(reloj.ahora >= .seconds(2))
  }

  /// ⌘ sostenida no estorba: `AtajoSimulado` pega con ella abajo sin
  /// soltarla. Bloq Mayús tampoco: es un estado.
  @Test func comandoYBloqMayusNoEstorbanAlPegar() async {
    let reloj = RelojQueAvanza()
    let motivo = await teclado(
      modificadores: { _ in [.maskCommand, .maskAlphaShift] },
      reloj: reloj
    ).esperarTecladoLibre(ahora: { reloj.ahora }, dormir: { reloj.dormir($0) })
    #expect(motivo == nil)
  }

  @Test func conEntradaSeguraNoPegaNiEspera() async {
    let reloj = RelojQueAvanza()
    let motivo = await teclado(segura: true, modificadores: { _ in [] }, reloj: reloj)
      .esperarTecladoLibre(ahora: { reloj.ahora }, dormir: { reloj.dormir($0) })
    #expect(motivo == .entradaSegura)
    #expect(reloj.ahora == .zero)
  }

  /// Teclear con ⌘ abajo es mandar atajos: «hola» sería ⌘H.
  @Test func paraTeclearTambienEstorbaComando() {
    let conComando = LecturasDelTeclado(entradaSegura: { false }, modificadores: { .maskCommand })
    #expect(!conComando.sePuedeTeclear)
    #expect(LecturasDelTeclado.libre.sePuedeTeclear)
    let segura = LecturasDelTeclado(entradaSegura: { true }, modificadores: { [] })
    #expect(!segura.sePuedeTeclear)
  }
}

struct PoliticaDeEntregaTests {
  @Test func cadaAppCaeEnSuClase() {
    #expect(ClaseDeDestino.de(bundleID: nil) == .normal)
    #expect(ClaseDeDestino.de(bundleID: "com.apple.Notes") == .normal)
    #expect(ClaseDeDestino.de(bundleID: "com.apple.Terminal") == .terminal)
    #expect(ClaseDeDestino.de(bundleID: "com.googlecode.iterm2") == .terminal)
    #expect(ClaseDeDestino.de(bundleID: "com.mitchellh.ghostty") == .terminal)
    #expect(ClaseDeDestino.de(bundleID: "com.apple.ScreenSharing") == .escritorioRemoto)
    #expect(ClaseDeDestino.de(bundleID: "com.microsoft.rdc.macos") == .escritorioRemoto)
    #expect(ClaseDeDestino.de(bundleID: "com.p5sys.jump.mac.viewer") == .escritorioRemoto)
  }

  /// En una shell un salto de línea tecleado ejecuta, y el valor del campo es
  /// todo el historial: ni se teclea ni se verifica por el campo.
  @Test func enUnaTerminalNiSeTecleaNiSeVerifica() {
    let politica = PoliticaDeEntrega.para(.terminal)
    #expect(!politica.reintentarTecleando)
    #expect(!politica.verificarElCampo)
    #expect(politica.alProceso)
  }

  /// Los remotos leen el teclado a bajo nivel: el ⌘V va al HID, como hasta
  /// ahora, aunque el anfitrión sepa mandarlo al proceso.
  @Test func losRemotosRecibenElAtajoPorElHID() {
    let politica = PoliticaDeEntrega.para(.escritorioRemoto, alProcesoSePuede: true)
    #expect(!politica.alProceso)
    #expect(politica.tiempos == .remoto)
  }

  @Test func sinElAnfitrionNingunAtajoVaAlProceso() {
    #expect(!PoliticaDeEntrega.para(.normal, alProcesoSePuede: false).alProceso)
    #expect(!PoliticaDeEntrega.para(.terminal, alProcesoSePuede: false).alProceso)
  }

  /// La última lectura del campo es la única que puede concluir «no cambió»,
  /// así que tiene que caer dentro de la ventana.
  @Test func laUltimaLecturaDelCampoCabeEnLaVentana() {
    for tiempos in [TiemposDePegado.deFabrica, .remoto] {
      #expect(tiempos.lecturasDelCampo.last! < tiempos.ventana)
      #expect(tiempos.lecturasDelCampo == tiempos.lecturasDelCampo.sorted())
    }
  }
}
