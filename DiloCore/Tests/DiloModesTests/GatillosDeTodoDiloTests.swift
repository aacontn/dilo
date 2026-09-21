import Testing

@testable import DiloModes

/// El validador corriendo contra **todos** los atajos de Dilo, no sólo contra
/// los del panel que uno tiene abierto.
///
/// Antes cada pantalla revisaba lo suyo: Modos comparaba contra los otros
/// modos y Atajos contra sus cuatro roles. Así la tecla del dictado normal y
/// la de un modo podían quedar iguales, y el modo no disparaba nunca sin que
/// nada lo dijera.
struct GatillosDeTodoDiloTests {
  private let ocupados: [ValidadorDeGatillos.GatilloEnUso] = [
    .init(id: "dictado", nombre: "Dictado", gatillo: .fn),
    .init(id: "segundoIdioma", nombre: "Segundo idioma", gatillo: .controlOpcionEspacio),
    .init(id: "leerEnVozAlta", nombre: "Leer en voz alta", gatillo: Gatillo(
      keyCode: Gatillo.Tecla.escape,
      modifierFlags: Gatillo.Modificador.opcion,
      etiqueta: "⌥ ⎋"
    )),
    .init(id: "limpio", nombre: "Limpio", gatillo: .controlComandoL),
  ]

  @Test func unaTeclaLibreSirve() {
    let libre = Gatillo(
      keyCode: 2,
      modifierFlags: Gatillo.Modificador.control | Gatillo.Modificador.comando,
      etiqueta: "⌃ ⌘ D"
    )
    #expect(ValidadorDeGatillos.revisar(libre, entre: ocupados, salvo: "correo").sirve)
  }

  /// La colisión que faltaba: un modo pidiendo la tecla del dictado normal.
  @Test func unModoNoPuedeQuedarseConLaTeclaDelDictado() {
    let veredicto = ValidadorDeGatillos.revisar(.fn, entre: ocupados, salvo: "correo")
    #expect(veredicto.reparo == .yaLaUsa("Dictado"))
    #expect(veredicto.reparo?.explicacion.contains("Dictado") == true)
  }

  @Test func tampocoLaDelSegundoIdiomaNiLaDeLeerEnVozAlta() {
    #expect(
      ValidadorDeGatillos.revisar(.controlOpcionEspacio, entre: ocupados, salvo: "correo")
        .reparo == .yaLaUsa("Segundo idioma")
    )
    let leer = Gatillo(
      keyCode: Gatillo.Tecla.escape,
      modifierFlags: Gatillo.Modificador.opcion,
      // Otra etiqueta a propósito: lo que choca es la tecla, no el texto.
      etiqueta: "Opción Escape"
    )
    #expect(
      ValidadorDeGatillos.revisar(leer, entre: ocupados, salvo: "correo")
        .reparo == .yaLaUsa("Leer en voz alta")
    )
  }

  @Test func unModoChocaConOtroModo() {
    #expect(
      ValidadorDeGatillos.revisar(.controlComandoL, entre: ocupados, salvo: "correo")
        .reparo == .yaLaUsa("Limpio")
    )
  }

  /// Reasignarle a alguien la tecla que ya tenía no es una colisión.
  @Test func nadieChocaConsigoMismo() {
    #expect(
      ValidadorDeGatillos.revisar(.controlComandoL, entre: ocupados, salvo: "limpio").sirve
    )
  }

  /// La tecla que no sirve se rechaza por lo que es, antes de mirar si está
  /// ocupada: el reparo útil es el que explica por qué esa tecla no sirve.
  @Test func laTeclaQueNoSirveSeRechazaAunqueEsteLibre() {
    let opcionSola = Gatillo(
      keyCode: Gatillo.Tecla.opcionDerecha, esModificador: true, etiqueta: "⌥ derecha"
    )
    #expect(
      ValidadorDeGatillos.revisar(opcionSola, entre: ocupados, salvo: nil).reparo == .opcionSola
    )
  }

  @Test func sinNadieOcupandoNadaSoloManadanLasReglasDeLaTecla() {
    #expect(ValidadorDeGatillos.revisar(.fn, entre: [], salvo: nil).sirve)
  }
}
