import Testing

@testable import DiloText

struct FiltroDeArtefactosTests {
  @Test(arguments: [
    ("[BLANK_AUDIO]", ""),
    ("[ Silence ]", ""),
    ("<|endoftext|>", ""),
    ("(Música) hola <unk> mundo .", "hola mundo."),
    (">> [música de fondo] Te mando el informe.", "Te mando el informe."),
    ("Listo [risas] , nos vemos", "Listo, nos vemos"),
  ])
  func sacaTokensYAnotaciones(_ entrada: String, _ salida: String) {
    #expect(FiltroDeArtefactos.aplicar(entrada) == salida)
  }

  /// Con texto limpio no toca nada, ni el espaciado raro que la persona
  /// dictó a propósito.
  @Test(arguments: [
    "Pon música de fondo, por favor.",
    "Me dio risa , la verdad",
    "Línea uno\nLínea dos",
    "",
  ])
  func elTextoLimpioQuedaIgual(_ texto: String) {
    #expect(FiltroDeArtefactos.aplicar(texto) == texto)
  }
}

struct FrasesFantasmaTests {
  @Test(arguments: [
    ("Listo. Subtítulos realizados por la comunidad de Amara.org", "Listo."),
    ("Subtítulos por la comunidad de Amara.org", ""),
    ("Te llamo mañana. Subtítulos realizados por Juan Pérez.", "Te llamo mañana."),
    ("Nos vemos el lunes amara.org", "Nos vemos el lunes"),
  ])
  func elNivelUnoSeVaSiempre(_ entrada: String, _ salida: String) {
    #expect(FrasesFantasma.quitarSiempre(entrada) == salida)
  }

  @Test(arguments: [
    "Activa los subtítulos por favor.",
    "El video está subtitulado por Marta.",
    "Gracias por todo.",
  ])
  func elNivelUnoNoSeComeUnDictado(_ texto: String) {
    #expect(FrasesFantasma.quitarSiempre(texto) == texto)
  }

  @Test(arguments: ["¡Gracias por ver!", "Suscríbete.", "Chao", "Thank you.", "Muchas gracias.", "Música"])
  func unFantasmaDeNivelDosSeBorraSoloConLaTomaMuda(_ frase: String) {
    #expect(FrasesFantasma.esFantasma(frase, tomaCasiMuda: true))
    #expect(!FrasesFantasma.esFantasma(frase, tomaCasiMuda: false))
  }

  @Test func unGraciasDentroDeUnaFraseNoEsFantasma() {
    #expect(!FrasesFantasma.esFantasma("Gracias por el informe de ayer", tomaCasiMuda: true))
    #expect(!FrasesFantasma.esFantasma("", tomaCasiMuda: true))
  }
}

struct DetectorDeBuclesTests {
  @Test func puntuacionSinPalabras() {
    #expect(DetectorDeBucles.motivo("............!!!") == .puntuacion)
    #expect(DetectorDeBucles.motivo("¿?¿?¿?¿?¿?¿?¿?") == .puntuacion)
  }

  @Test func unaLetraMilVeces() {
    #expect(DetectorDeBucles.motivo("aaaaaaaaaaaaaaaa") == .repeticionDeCaracteres)
    #expect(DetectorDeBucles.motivo("ja ja ja ja ja ja") == .repeticionDeCaracteres)
  }

  @Test func unaFraseQueDaVueltas() {
    let bucle = Array(repeating: "te lo mando", count: 6).joined(separator: " ")
    #expect(DetectorDeBucles.motivo(bucle) == .repeticionDePalabras)
    #expect(DetectorDeBucles.colapsar(bucle + " mañana").0 == "te lo mando mañana")
  }

  @Test func elHablaNormalNoEsBucle() {
    #expect(DetectorDeBucles.motivo("Mañana te mando el informe, sin falta.") == nil)
    #expect(DetectorDeBucles.motivo("Sí.") == nil)
    // Tres vueltas son habla; la palabra repetida la ve Muletillas.
    #expect(DetectorDeBucles.colapsar("no no no hola").1 == 0)
    // Una repetición dentro de una frase larga no la vuelve un bucle.
    #expect(
      DetectorDeBucles.motivo("Dale dale dale dale, después te cuento cómo nos fue con el cliente y la propuesta")
        == nil)
  }

  /// Compara sin mayúsculas ni puntuación y deja la primera vuelta como vino.
  @Test func colapsarConservaLaPrimeraVuelta() {
    let (texto, quitadas) = DetectorDeBucles.colapsar("Te lo mando, te lo mando, te lo mando, te lo mando.")
    #expect(texto == "Te lo mando,")
    #expect(quitadas == 9)
  }

  @Test func colapsarSinBucleDevuelveElTextoTalCual() {
    let texto = "Línea uno\nlínea dos  con espacios"
    #expect(DetectorDeBucles.colapsar(texto).0 == texto)
  }
}
