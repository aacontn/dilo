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

  /// El gatillo de Alfonso es F19, y toda tecla de función —como las
  /// flechas— lleva el bit de fn, que el estado del HID deja marcado tras
  /// soltarla. fn no cambia lo que hace ⌘V: con el bit encendido se pega al
  /// tiro. Antes esperaba dos segundos y terminaba en la tarjeta
  /// (`retenido(teclasSostenidas)`, 14-oct 18:24).
  @Test func elBitDeFnNoEstorbaAlPegar() async {
    let reloj = RelojQueAvanza()
    let deUnaTeclaDeFuncion = CGEventFlags(rawValue: 0x2080_0000)
    for vistas in [CGEventFlags.maskSecondaryFn, deUnaTeclaDeFuncion] {
      let espera = await teclado(modificadores: { _ in vistas }, reloj: reloj)
        .esperarTeclado(ahora: { reloj.ahora }, dormir: { reloj.dormir($0) })
      #expect(espera.motivo == nil)
    }
    #expect(reloj.ahora == .zero)
  }

  /// Para teclear sí importa fn, pero la tecla y no el bit: un bit que quedó
  /// de F19 no impide el reintento; fn apretada de verdad, sí (🌐A es el Dock).
  @Test func paraTeclearFnSeMiraPorSuTecla() {
    let bitColgado = LecturasDelTeclado(
      entradaSegura: { false }, modificadores: { .maskSecondaryFn }, fnAbajo: { false })
    #expect(bitColgado.sePuedeTeclear)
    let fnApretada = LecturasDelTeclado(
      entradaSegura: { false }, modificadores: { .maskSecondaryFn }, fnAbajo: { true })
    #expect(!fnApretada.sePuedeTeclear)
  }

  /// Una tarea cancelada no puede dormir. Antes devolvía «teclas sostenidas»
  /// al instante sin volver a mirar; ahora mira una vez más y lo dice.
  @Test func cancelarLaEsperaMiraUnaVezMasYLoDice() async {
    struct Cancelado: Error {}
    let lecturas = OSAllocatedUnfairLock(initialState: 0)
    let soltaron = LecturasDelTeclado(
      entradaSegura: { false },
      modificadores: { lecturas.withLock { $0 += 1; return $0 == 1 ? .maskShift : [] } }
    )
    let libre = await soltaron.esperarTeclado(ahora: { .zero }, dormir: { _ in throw Cancelado() })
    #expect(libre.motivo == nil)
    #expect(libre.interrumpida)

    let sostenida = LecturasDelTeclado(entradaSegura: { false }, modificadores: { .maskShift })
    let espera = await sostenida.esperarTeclado(ahora: { .zero }, dormir: { _ in throw Cancelado() })
    #expect(espera.motivo == .teclasSostenidas)
    #expect(espera.interrumpida)
    #expect(espera.lineaDelLog.contains("se canceló"))
  }

  /// Rendirse deja dicho qué teclas vio: un «teclas sostenidas» sin nombres
  /// no se puede arreglar.
  @Test func alRendirseDiceQueTeclasVio() async {
    let reloj = RelojQueAvanza()
    let espera = await teclado(modificadores: { _ in [.maskAlternate, .maskSecondaryFn] }, reloj: reloj)
      .esperarTeclado(ahora: { reloj.ahora }, dormir: { reloj.dormir($0) })
    #expect(espera.motivo == .teclasSostenidas)
    #expect(!espera.interrumpida)
    #expect(espera.vistas == [.maskAlternate, .maskSecondaryFn])
    #expect(espera.lineaDelLog.contains("⌥ fn (0x880000)"))
    #expect(espera.lineaDelLog.contains("tras 2000 ms"))
    #expect(EsperaDelTeclado.describir([]) == "ninguna (0x0)")
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
