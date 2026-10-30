import Testing

@testable import DiloText

/// El dictado se adapta a lo que hay antes del cursor.
struct AjusteAlCursorTests {
  /// Un corrector de mentira: conoce las palabras comunes del ejemplo y no
  /// los nombres.
  private func comun(_ palabra: String) -> Bool {
    ["quedó", "viene", "hola", "listo", "y"].contains(palabra)
  }

  private func ajustar(_ texto: String, _ previo: String?, tusPalabras: Set<String> = []) -> String {
    AjusteAlCursor.ajustar(texto, antesDelCursor: previo, tusPalabras: tusPalabras, esPalabraComun: comun)
  }

  @Test func aMitadDeFraseEntraConMinusculaYEspacio() {
    #expect(ajustar("Quedó listo", "el deploy") == " quedó listo")
  }

  @Test func trasUnPuntoEntraConMayuscula() {
    #expect(ajustar("quedó listo", "Listo. ") == "Quedó listo")
  }

  @Test func alComienzoDelCampoConMayuscula() {
    #expect(ajustar("hola", "") == "Hola")
  }

  @Test func lasSiglasYLasMarcasSeRespetan() {
    #expect(ajustar("API nueva", "la") == " API nueva")
    #expect(ajustar("iPhone nuevo", "mi") == " iPhone nuevo")
  }

  @Test func sinLecturaNoToca() {
    #expect(ajustar("Quedó listo", nil) == "Quedó listo")
  }

  @Test func trasUnaAperturaMinusculaYSinEspacio() {
    #expect(ajustar("Viene mañana", "¿") == "viene mañana")
    #expect(ajustar("Viene mañana", "(") == "viene mañana")
  }

  /// «Martina» no es palabra común: se queda con mayúscula.
  @Test func losNombresSeQuedan() {
    #expect(ajustar("Martina viene", "le dije a ") == "Martina viene")
  }

  @Test func tusPalabrasSeRespetanAunqueSeanComunes() {
    #expect(ajustar("Listo viene", "el proyecto", tusPalabras: ["Listo"]) == " Listo viene")
  }

  @Test func antesDeUnaComaNoVaEspacio() {
    #expect(ajustar(", y tú", "hola") == ", y tú")
  }

  @Test func trasUnSaltoDeLineaMayusculaSinEspacio() {
    #expect(ajustar("hola", "fin\n") == "Hola")
  }

  @Test func conEspacioAntesNoAgregaOtro() {
    #expect(ajustar(" Quedó", "el deploy  ") == "quedó")
  }

  @Test func siNadaEsComunNuncaBajaNada() {
    let texto = AjusteAlCursor.ajustar("Quedó listo", antesDelCursor: "el deploy", esPalabraComun: { _ in false })
    #expect(texto == " Quedó listo")
  }
}
