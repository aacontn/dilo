import Testing

@testable import DiloCapabilities

/// Cuándo Dilo aprieta ↩ tras un dictado que terminó con «envía».
struct PoliticaDelEnvioTests {
  private func decidir(
    pidio: Bool = true,
    entrega: ResultadoDeEntrega = .pegado(.lectura),
    textoVacio: Bool = false,
    clase: ClaseDeDestino = .normal,
    campoSeguro: Bool = false,
    modoSinTerminar: Bool = false,
    admitePegadoDirecto: Bool = true
  ) -> PoliticaDelEnvio.Decision {
    PoliticaDelEnvio.decidir(
      pidio: pidio, entrega: entrega, textoVacio: textoVacio, clase: clase,
      campoSeguro: campoSeguro, modoSinTerminar: modoSinTerminar,
      admitePegadoDirecto: admitePegadoDirecto
    )
  }

  @Test func pegadoYConfirmadoManda() {
    #expect(decidir() == .enviar)
    #expect(decidir(entrega: .pegado(.campo)) == .enviar)
    #expect(decidir(entrega: .pegado(.tecleo)) == .enviar)
  }

  @Test func sinPedirloNuncaManda() {
    #expect(decidir(pidio: false) == .noSePidio)
    #expect(PoliticaDelEnvio.Decision.noSePidio.aviso == nil)
  }

  /// En una terminal ↩ ejecuta.
  @Test func nuncaEnUnaTerminal() {
    #expect(decidir(clase: .terminal) == .enUnaTerminal)
    #expect(decidir(clase: .terminal).aviso != nil)
  }

  @Test func nuncaEnUnCampoSeguro() {
    #expect(decidir(campoSeguro: true) == .campoSeguro)
  }

  /// Un ⌘V que nadie confirmó puede haber caído en otra parte.
  @Test func nuncaSinConfirmarQueEntro() {
    #expect(decidir(entrega: .pegadoSinConfirmar) == .sinConfirmar)
    #expect(decidir(entrega: .retenido(.focoCambio)) == .sinConfirmar)
    #expect(decidir(entrega: .copiado) == .soloCopiar)
  }

  @Test func nuncaSiElModoNoTermino() {
    #expect(decidir(modoSinTerminar: true) == .modoSinTerminar)
  }

  @Test func nuncaDondeNoSePuedePegarDirecto() {
    #expect(decidir(admitePegadoDirecto: false) == .sinPegadoDirecto)
  }

  /// «Envía.» sola manda lo que ya estaba escrito.
  @Test func soloEnviaMandaLoQueYaEstaba() {
    #expect(decidir(entrega: .nadaQueEntregar, textoVacio: true) == .enviar)
    #expect(decidir(entrega: .nadaQueEntregar, textoVacio: false) == .sinConfirmar)
  }
}
