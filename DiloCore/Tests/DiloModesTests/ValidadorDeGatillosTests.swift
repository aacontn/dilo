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

  /// El reporte de Alfonso: teclado Apple extendido, F18 y F19 no se podían
  /// asignar. No escriben nada y no son del sistema, así que sirven solas.
  @Test func aceptaLaFilaExtendidaSola() {
    let extendidas: [Int64] = [
      Gatillo.Tecla.f13, Gatillo.Tecla.f14, Gatillo.Tecla.f15,
      Gatillo.Tecla.f16, Gatillo.Tecla.f17, Gatillo.Tecla.f18,
      Gatillo.Tecla.f19, Gatillo.Tecla.f20,
    ]
    for tecla in extendidas {
      let gatillo = Gatillo(keyCode: tecla, etiqueta: NombresDeTecla.nombre(tecla))
      #expect(ValidadorDeGatillos.revisar(gatillo).sirve, "\(gatillo.etiqueta)")
    }
  }

  /// F14 y F15 estaban marcadas como teclas del sistema porque los teclados
  /// Apple de 2007 les imprimían el brillo. Hoy el brillo no pasa por esos
  /// códigos y la lista sólo servía para dejar dos teclas libres sin usar.
  @Test func f14YF15YaNoCuentanComoTeclasDelSistema() {
    #expect(Gatillo.Tecla.sistema.contains(Gatillo.Tecla.f14) == false)
    #expect(Gatillo.Tecla.sistema.contains(Gatillo.Tecla.f15) == false)
  }

  /// F11 y F12: con los ajustes de fábrica el sistema las convierte en volumen
  /// antes de que el tap las vea, así que no llegan y no hay nada que
  /// rechazar; con "Usar F1, F2… como teclas de función" activado llegan como
  /// `keyDown` normales y son gatillos legítimos. El validador no opina.
  @Test func f11YF12SonGatillosValidosCuandoLleganComoTeclasDeFuncion() {
    for tecla: Int64 in [103, 111] {
      #expect(ValidadorDeGatillos.revisar(Gatillo(keyCode: tecla)).sirve)
    }
  }

  /// Las que no escriben, solas y sin modificadores: son justo las que un
  /// gatillo de mantener-para-hablar quiere.
  @Test func aceptaLasTeclasQueNoEscribenSolas() {
    let libres: [Int64] = [
      Gatillo.Tecla.fn, Gatillo.Tecla.escape,
      10,  // § de un teclado ISO
      71,  // Clear del teclado numérico
      76,  // Intro del teclado numérico
      114, 115, 116, 119, 121,  // ayuda, inicio, fin, páginas
      123, 124, 125, 126,  // flechas
    ]
    for tecla in libres {
      let gatillo = Gatillo(keyCode: tecla, etiqueta: NombresDeTecla.nombre(tecla))
      #expect(ValidadorDeGatillos.revisar(gatillo).sirve, "\(tecla)")
    }
  }

  /// Lo único que queda fuera: una tecla que escribe, pelada. Sostener la L
  /// para hablar llena el documento de eles.
  @Test func rechazaUnaTeclaQueEscribeSola() {
    for tecla: Int64 in [37, 18, 47, 82] {
      let gatillo = Gatillo(keyCode: tecla)
      #expect(ValidadorDeGatillos.revisar(gatillo).reparo == .teclaQueEscribeSola, "\(tecla)")
    }
  }

  /// Con un modificador encima deja de escribir y vuelve a servir. Es la
  /// salida que el mensaje de rechazo ofrece, así que tiene que existir.
  @Test func laMismaTeclaConUnModificadorSiSirve() {
    let controlL = Gatillo(keyCode: 37, modifierFlags: Gatillo.Modificador.control)
    #expect(ValidadorDeGatillos.revisar(controlL).sirve)
  }

  @Test func ningunModoDeFabricaTraeUnGatilloQueNoSirve() {
    for modo in Modo.deFabrica {
      guard let gatillo = modo.gatillo else { continue }
      #expect(ValidadorDeGatillos.revisar(gatillo).sirve, "\(modo.nombre)")
    }
  }
}
