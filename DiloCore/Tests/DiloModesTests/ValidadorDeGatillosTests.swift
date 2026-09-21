import Testing

@testable import DiloModes

/// Los casos vienen de los diez minutos que Alfonso dictó el 2026-09-20 en un
/// teclado ISO latinoamericano. El primero es el bug literal.
struct ValidadorDeGatillosTests {
  @Test func rechazaOpcionDerechaSola() {
    let altGr = Gatillo(
      keyCode: Gatillo.Tecla.opcionDerecha, esModificador: true, etiqueta: "⌥ derecha"
    )
    #expect(ValidadorDeGatillos.revisar(altGr).reparo == .opcionSola)
  }

  @Test func rechazaTambienLaOpcionIzquierda() {
    let opcion = Gatillo(
      keyCode: Gatillo.Tecla.opcionIzquierda, esModificador: true, etiqueta: "⌥"
    )
    #expect(ValidadorDeGatillos.revisar(opcion).reparo == .opcionSola)
  }

  @Test func rechazaLasTeclasDeVolumen() {
    for tecla in [72, 73, 74] {
      let gatillo = Gatillo(keyCode: Int64(tecla), etiqueta: "volumen")
      #expect(ValidadorDeGatillos.revisar(gatillo).reparo == .teclaDelSistema)
    }
  }

  @Test func rechazaOpcionMasLetraPorqueEscribeUnSimbolo() {
    let opcionD = Gatillo(
      keyCode: 2, modifierFlags: Gatillo.Modificador.opcion, etiqueta: "⌥ D"
    )
    #expect(
      ValidadorDeGatillos.revisar(opcionD).reparo == .opcionMasTeclaQueEscribe
    )
  }

  @Test func aceptaOpcionCuandoLaTeclaNoEscribeNada() {
    let opcionEscape = Gatillo(
      keyCode: Gatillo.Tecla.escape,
      modifierFlags: Gatillo.Modificador.opcion,
      etiqueta: "⌥ ⎋"
    )
    #expect(ValidadorDeGatillos.revisar(opcionEscape).sirve)
  }

  @Test func aceptaFnYLaAlternativaDelSpec() {
    #expect(ValidadorDeGatillos.revisar(.fn).sirve)
    #expect(ValidadorDeGatillos.revisar(.controlOpcionEspacio).sirve)
  }

  @Test func rechazaUnGatilloSinTecla() {
    #expect(ValidadorDeGatillos.revisar(Gatillo()).reparo == .vacio)
  }

  @Test func ningunDefaultEscribeSimbolosEnTecladoLatino() {
    for gatillo in ValidadorDeGatillos.porDefecto {
      #expect(ValidadorDeGatillos.revisar(gatillo).sirve, "\(gatillo.etiqueta)")
    }
  }

  @Test func ningunModoDeFabricaTraeUnGatilloQueNoSirve() {
    for modo in Modo.deFabrica {
      guard let gatillo = modo.gatillo else { continue }
      #expect(ValidadorDeGatillos.revisar(gatillo).sirve, "\(modo.nombre)")
    }
  }
}
