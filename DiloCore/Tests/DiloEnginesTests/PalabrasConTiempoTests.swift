import Foundation
import Testing

@testable import DiloEngines

/// Los tokens de Parakeet en palabras con su tiempo: lo que la pasada final de
/// una reunión le pega a cada hablante.
struct PalabrasConTiempoTests {
  @Test func losTokensSeJuntanPorSuEspacio() {
    let tokens = [
      TokenDeVoz(texto: " Cerr", inicio: 0.0, fin: 0.2),
      TokenDeVoz(texto: "amos", inicio: 0.2, fin: 0.4),
      TokenDeVoz(texto: " el", inicio: 0.5, fin: 0.6),
      TokenDeVoz(texto: "▁precio", inicio: 0.6, fin: 1.0),
      TokenDeVoz(texto: ",", inicio: 1.0, fin: 1.05),
      TokenDeVoz(texto: "<blank>", inicio: 1.1, fin: 1.2),
    ]
    let palabras = PalabraConTiempo.palabras(de: tokens)
    #expect(palabras.map(\.texto) == ["Cerramos", "el", "precio,"])
    #expect(palabras.first == PalabraConTiempo(texto: "Cerramos", inicio: 0, fin: 0.4))
    #expect(palabras.last?.fin == 1.05)
  }

  @Test func elPrimerTokenAbrePalabraAunqueNoTraigaEspacio() {
    let palabras = PalabraConTiempo.palabras(de: [TokenDeVoz(texto: "Hola", inicio: 0, fin: 0.3)])
    #expect(palabras.map(\.texto) == ["Hola"])
    #expect(PalabraConTiempo.palabras(de: []).isEmpty)
  }
}
