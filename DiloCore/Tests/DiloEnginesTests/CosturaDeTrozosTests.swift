import DiloText
import Foundation
import Testing

@testable import DiloEngines

/// La costura de las ventanas de Parakeet, con tokens como los que entrega el
/// modelo: el texto lleva un espacio adelante cuando abre palabra, y ninguno
/// cuando continúa la anterior.
struct CosturaDeTrozosTests {
  /// Arma una fila de tokens a partir de pedazos `(texto, inicio)`, cada uno
  /// durando 80 ms como una ventana del encoder.
  private func tokens(_ pedazos: [(String, TimeInterval)]) -> [TokenDeVoz] {
    pedazos.map { TokenDeVoz(texto: $0.0, inicio: $0.1, fin: $0.1 + 0.08) }
  }

  @Test func lasVentanasPegadasSeSeparan() {
    // "rápido" cierra una ventana; "Ahora" abre la siguiente sin la marca de
    // palabra nueva y medio segundo después.
    let fila = tokens([
      (" es", 1.0), (" rápi", 1.2), ("do", 1.4), ("Ahora", 2.0), (" habría", 2.3),
    ])
    #expect(fila.map(\.texto).joined().trimmingCharacters(in: .whitespaces) == "es rápidoAhora habría")
    #expect(CosturaDeTrozos.texto(de: fila) == "es rápido Ahora habría")
  }

  @Test func unaPalabraConMayusculaAdentroSeQuedaEntera() {
    // "iPhone" sale en dos tokens pegados en el tiempo: no es una costura.
    let fila = tokens([(" el", 1.0), (" i", 1.2), ("Phone", 1.28), (" nuevo", 1.4)])
    #expect(CosturaDeTrozos.texto(de: fila) == "el iPhone nuevo")
  }

  @Test func unaPalabraPartidaEnSilabasSeQuedaEntera() {
    let fila = tokens([(" con", 1.0), ("fi", 1.08), ("gu", 1.16), ("ración", 1.24)])
    #expect(CosturaDeTrozos.texto(de: fila) == "configuración")
  }

  @Test func laMinusculaDespuesDelSilencioNoParteNada() {
    // Sin mayúscula no hay evidencia de costura: el modelo puede haber
    // dudado a mitad de palabra y partirla sería inventar.
    let fila = tokens([(" rápi", 1.0), ("do", 1.6)])
    #expect(CosturaDeTrozos.texto(de: fila) == "rápido")
  }

  @Test func laPuntuacionDeLaVentanaAnteriorNoSeSepara() {
    let fila = tokens([(" tan", 1.0), (".", 1.08), ("Qué", 1.6), (" tan", 1.9)])
    #expect(CosturaDeTrozos.texto(de: fila) == "tan. Qué tan")
  }

  @Test func sinTokensNoHayTexto() {
    #expect(CosturaDeTrozos.texto(de: []) == "")
  }

  @Test func elParrafoDeAlfonso() {
    let fila = tokens([
      (" Igual", 0.0), (" se", 0.2), (" ve", 0.4), (" que", 0.6), (" es", 0.8),
      (" rápido", 1.0), ("Ahora", 1.8), (" habría", 2.1), (" que", 2.3),
      (" ver", 2.5), (" qué", 2.7), (" tan", 2.9), (".", 3.0),
    ])
    #expect(
      CosturaDeTrozos.texto(de: fila)
        == "Igual se ve que es rápido Ahora habría que ver qué tan."
    )
  }
}
