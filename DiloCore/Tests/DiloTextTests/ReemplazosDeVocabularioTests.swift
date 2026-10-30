import Testing

@testable import DiloText

/// Lo que la segunda pasada de Tus palabras reemplaza, sobre el texto cosido.
struct ReemplazosDeVocabularioTests {
  @Test func reemplazaUnaFraseConBordes() {
    #expect(
      ReemplazosDeVocabulario.aplicar([("de camerún", "Decameron")], a: "Hablé con de camerún ayer")
        == "Hablé con Decameron ayer"
    )
  }

  /// «año» no calza dentro de «años».
  @Test func respetaLosBordesUnicode() {
    #expect(ReemplazosDeVocabulario.aplicar([("año", "AÑO")], a: "los años y el año") == "los años y el AÑO")
  }

  /// Dos reemplazos de la misma palabra van a dos lugares, en orden.
  @Test func cadaParVaMasAdelanteQueElAnterior() {
    let texto = "martina dijo que martina viene"
    let pares: [(original: String, nuevo: String)] = [("martina", "Martina"), ("martina", "Martina")]
    #expect(ReemplazosDeVocabulario.aplicar(pares, a: texto) == "Martina dijo que Martina viene")
  }

  @Test func loQueNoEstaNoTocaNada() {
    #expect(ReemplazosDeVocabulario.aplicar([("blokit", "Blokkit")], a: "nada que ver") == "nada que ver")
    #expect(ReemplazosDeVocabulario.aplicar([], a: "igual") == "igual")
  }

  /// La costura que `CosturaDeTrozos` arregló no vuelve: sólo cambia la
  /// palabra reemplazada.
  @Test func noTocaElRestoDelTexto() {
    let cosido = "Es rápido. Ahora le escribo a andes flags, ¿ya?"
    #expect(
      ReemplazosDeVocabulario.aplicar([("andes flags", "Andes Flags")], a: cosido)
        == "Es rápido. Ahora le escribo a Andes Flags, ¿ya?"
    )
  }
}
