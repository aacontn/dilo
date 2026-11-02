import Foundation
import Testing

@testable import DiloReuniones

/// Parakeet pegado escribe la misma sílaba decenas de veces; el guion se
/// queda con la primera vuelta.
struct BuclesDeLaPistaTests {
  private func pista(_ texto: String) -> [PalabraDeLaPista] {
    texto.split(separator: " ").enumerated().map { i, palabra in
      PalabraDeLaPista(texto: String(palabra), desde: Double(i), hasta: Double(i) + 0.5)
    }
  }

  private func texto(_ palabras: [PalabraDeLaPista]) -> String {
    palabras.map(\.texto).joined(separator: " ")
  }

  /// Lo de la reunión del 2026-11-02: «pa» 21 veces.
  @Test func unaSilabaPegadaQuedaEnUna() {
    let pegada = "y entonces " + Array(repeating: "pa", count: 21).joined(separator: " ") + " ya"
    #expect(texto(BuclesDeLaPista.colapsar(pista(pegada))) == "y entonces pa ya")
  }

  @Test func unaFraseQueDaVueltasQuedaEnUna() {
    let pegada = "te lo mando, te lo mando te lo mando te lo mando listo"
    #expect(texto(BuclesDeLaPista.colapsar(pista(pegada))) == "te lo mando, listo")
  }

  /// Tres vueltas son habla.
  @Test func tresVueltasSeQuedan() {
    let habla = "no no no así no"
    #expect(texto(BuclesDeLaPista.colapsar(pista(habla))) == habla)
  }

  @Test func losTiemposDeLoQueQuedaNoCambian() {
    let palabras = pista("a pa pa pa pa b")
    let colapsadas = BuclesDeLaPista.colapsar(palabras)
    #expect(colapsadas.map(\.desde) == [0, 1, 5])
  }

  @Test func mayusculasYTildesSonLaMismaVuelta() {
    #expect(texto(BuclesDeLaPista.colapsar(pista("Sí sí, si SÍ fin"))) == "Sí fin")
  }
}
