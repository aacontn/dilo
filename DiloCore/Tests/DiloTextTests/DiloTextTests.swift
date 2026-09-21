import Testing

@testable import DiloText

struct DiloTextTests {
  @Test func colapsaLosEspaciosQueDejaLaDuda() {
    #expect(DiloText.limpiarEspacios("hola   mundo") == "hola mundo")
  }

  @Test func recortaLosBordes() {
    #expect(DiloText.limpiarEspacios("  hola mundo \n") == "hola mundo")
  }

  @Test func respetaLosSaltosDeLinea() {
    #expect(DiloText.limpiarEspacios("uno\n\ndos") == "uno\n\ndos")
  }
}

/// La costura entera: espacios, muletillas y tus palabras, en ese orden.
struct LimpiezaCompletaTests {
  @Test func unDictadoChilenoSaleListoParaPegar() {
    let dictado = "eh, o sea, mandé la cotización a espacio digital,  cachái, "
      + "y hay que deployar el build altiro"
    let preferencias = DiloText.Preferencias(palabrasPropias: ["Espacio Digital"])
    #expect(
      DiloText.limpiar(dictado, con: preferencias)
        == "mandé la cotización a Espacio Digital, y hay que deployar el build altiro"
    )
  }

  @Test func sinPreferenciasSigueSiendoLoQueDijiste() {
    let dictado = "¿tenís el commit listo?"
    #expect(DiloText.limpiar(dictado) == dictado)
  }
}
