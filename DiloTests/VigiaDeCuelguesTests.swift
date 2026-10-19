import Testing
@testable import Dilo

/// La regla del vigilante de cuelgues de Ajustes (`UmbralDeCuelgue`).
struct VigiaDeCuelguesTests {
  @Test func unPingDeTreintaMilisegundosNoEsCuelgue() {
    let regla = UmbralDeCuelgue()
    #expect(!regla.esCuelgue(.milliseconds(30)))
    #expect(!regla.esCuelgue(.milliseconds(300)))
    #expect(regla.esCuelgue(.milliseconds(301)))
    #expect(regla.esCuelgue(.seconds(2)))
  }

  @Test func laCadenciaEsMasCortaQueElUmbral() {
    // Si el ping saliera más lento que el umbral, un cuelgue corto entre
    // dos pings no se vería nunca.
    let regla = UmbralDeCuelgue()
    #expect(regla.cadencia < regla.umbral)
  }

  @Test func losMilisegundosSeRedondeanHaciaAbajo() {
    #expect(UmbralDeCuelgue.milisegundos(.milliseconds(1_250)) == 1_250)
    #expect(UmbralDeCuelgue.milisegundos(.microseconds(300_900)) == 300)
    #expect(UmbralDeCuelgue.milisegundos(.seconds(2)) == 2_000)
  }
}
