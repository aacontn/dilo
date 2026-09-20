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
