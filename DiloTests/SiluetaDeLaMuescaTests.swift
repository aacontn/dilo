import CoreGraphics
import SwiftUI
import Testing

@testable import Dilo

/// La silueta en una sola pieza mide lo mismo que medían las tres: el cuerpo
/// en su marco y las alas colgando fuera, a los costados.
@Suite("Silueta de la muesca")
struct SiluetaDeLaMuescaTests {
  private let marco = CGRect(x: 0, y: 0, width: 160, height: 24)

  @Test func laMuescaLlevaSusAlasFueraDelMarco() {
    let silueta = SiluetaDeLaMuesca(estilo: .muesca, radioDeHombro: 9, radioInferior: 11)
    let caja = silueta.path(in: marco).boundingRect
    // Con tolerancia: la resta del disco del ala deja el borde en 1e-13.
    #expect(abs(caja.minX - -9) < 0.001)
    #expect(abs(caja.width - (160 + 2 * 9)) < 0.001)
    #expect(abs(caja.minY) < 0.001)
    #expect(abs(caja.height - 24) < 0.001, "las alas no bajan más que el cuerpo")
  }

  /// La píldora se cierra por los cuatro lados y no lleva alas, aunque se le
  /// pida un hombro.
  @Test func laIslaNoLlevaAlas() {
    let silueta = SiluetaDeLaMuesca(estilo: .isla, radioDeHombro: 9, radioInferior: 8)
    #expect(silueta.path(in: marco).boundingRect == marco)
    // Y redondea arriba: la esquina de arriba a la izquierda queda fuera.
    #expect(!silueta.path(in: marco).contains(CGPoint(x: 0.5, y: 0.5)))
  }

  /// La muesca comparte el borde de arriba: el tope es recto, y justo al
  /// lado del cuerpo el ala ya es negro.
  @Test func elTopeEsRectoYElAlaFundeConElBorde() {
    let camino = SiluetaDeLaMuesca(estilo: .muesca, radioDeHombro: 9, radioInferior: 11).path(in: marco)
    #expect(camino.contains(CGPoint(x: 0.5, y: 0.5)))
    #expect(camino.contains(CGPoint(x: -0.5, y: 0.5)), "el ala arranca pegada al borde")
    #expect(!camino.contains(CGPoint(x: -8.5, y: 8.5)), "y se curva hacia afuera, cóncava")
    // Las esquinas de abajo sí se redondean.
    #expect(!camino.contains(CGPoint(x: 0.5, y: 23.5)))
  }

  /// Un ala más alta que el cuerpo se asomaría por debajo: se acota al alto,
  /// y si con la esquina de abajo no caben, los dos radios se achican juntos
  /// (como `DroppyNotchShellShape`): 6 de hombro y 3 abajo en 6 de alto son
  /// 4 y 2.
  @Test func unHombroMasAltoQueElCuerpoSeAcota() {
    let bajo = CGRect(x: 0, y: 0, width: 100, height: 6)
    let caja = SiluetaDeLaMuesca(estilo: .muesca, radioDeHombro: 11, radioInferior: 3).path(in: bajo).boundingRect
    #expect(abs(caja.height - 6) < 0.001)
    #expect(abs(caja.minX - -4) < 0.001)
  }

  /// Los radios de la forma abierta caben uno sobre el otro y no se tocan:
  /// el hombro de 19 y el borde redondo de 19 del aviso, en 38 de alto.
  @Test func losRadiosQueCabenNoSeAchican() {
    let aviso = CGRect(x: 0, y: 0, width: 304, height: 38)
    let caja = SiluetaDeLaMuesca(estilo: .muesca, radioDeHombro: 19, radioInferior: 19).path(in: aviso).boundingRect
    #expect(abs(caja.minX - -19) < 0.001)
    // El cuerpo sin alas tiene las mismas esquinas que con alas.
    let cuerpo = SiluetaDeLaMuesca(estilo: .muesca, radioDeHombro: 30, radioInferior: 19).sinHombros
    #expect(cuerpo.path(in: aviso).boundingRect == aviso)
    #expect(!cuerpo.path(in: aviso).contains(CGPoint(x: 2, y: 36)), "la esquina de abajo es redonda")
  }

  @Test func sinHombrosEsElCuerpoSolo() {
    let silueta = SiluetaDeLaMuesca(estilo: .muesca, radioDeHombro: 9, radioInferior: 11)
    #expect(silueta.sinHombros.path(in: marco).boundingRect == marco)
  }

  /// La que cada pantalla dibuja: alas de 11 contra la carcasa, de 9 en el
  /// notch simulado, ninguna en la píldora bajo la barra.
  @Test func cadaPantallaDibujaLaSuya() {
    let simulado = HUDScreenSnapshot(
      id: 2, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeAreaTop: 0,
      auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil, menuBarHeight: 24
    )
    var pildora = simulado
    pildora.estiloSinNotch = .pildora
    #expect(SiluetaDeLaMuesca.para(simulado, radioInferior: 11).estilo == .muesca)
    #expect(SiluetaDeLaMuesca.para(simulado, radioInferior: 11).radioDeHombro == 9)
    #expect(SiluetaDeLaMuesca.para(pildora, radioInferior: 8).estilo == .isla)
    #expect(SiluetaDeLaMuesca.para(HUDPreviewScreen.notched, radioInferior: 11).radioDeHombro == 11)
  }
}
