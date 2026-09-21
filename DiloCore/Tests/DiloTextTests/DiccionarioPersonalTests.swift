import Testing

@testable import DiloText

/// Los casos del Tauri portados —son las mismas reglas— más los nombres con
/// que Alfonso trabaja, que es donde esto se gana o se pierde.
struct DiccionarioPersonalTests {
  private func aplicar(
    _ texto: String, _ palabras: [String], umbral: Double = 0.5
  ) -> String {
    DiccionarioPersonal.aplicar(texto, palabras: palabras, umbral: umbral)
  }

  @Test func sinPalabrasPropiasNoTocaNada() {
    #expect(aplicar("hay que deployar el build", []) == "hay que deployar el build")
  }

  @Test func corrigeLoQueSuenaParecido() {
    #expect(aplicar("helo wrold", ["hello", "world"]) == "hello world")
  }

  @Test func juntaLoQueElDictadoPartioEnDos() {
    let resultado = aplicar("el cobro lo hace Charge B, todos los meses", ["ChargeBee"])
    #expect(resultado.contains("ChargeBee,"))
    #expect(!resultado.contains("Charge B"))
  }

  @Test func juntaHastaTresPalabras() {
    #expect(aplicar("usa Chat G P T para esto", ["ChatGPT"]).contains("ChatGPT"))
  }

  @Test func prefiereElGrupoMasLargo() {
    #expect(aplicar("Open AI GPT model", ["OpenAI", "GPT"]) == "OpenAI GPT model")
  }

  @Test func conservaLasMayusculasDelDictado() {
    #expect(aplicar("CHARGE B es caro", ["ChargeBee"]).contains("CHARGEBEE"))
  }

  @Test func noDuplicaElNumeroDelFinal() {
    // "GPT4" no puede terminar en "GPT-44": la puntuación del borde se
    // conserva, no se cuenta dos veces.
    #expect(!aplicar("usa GPT4 para esto", ["GPT-4"]).contains("GPT-44"))
  }

  @Test func laYYElAmpersandLlevanAlMismoLado() {
    #expect(aplicar("mándaselo a R y D", ["R&D"], umbral: 0.18) == "mándaselo a R&D")
    #expect(aplicar("mándaselo a R and D", ["R&D"], umbral: 0.18) == "mándaselo a R&D")
    #expect(aplicar("mándaselo a R&D", ["R&D"], umbral: 0.18) == "mándaselo a R&D")
  }

  @Test func losNombresDeLaCasaSalenBien() {
    #expect(
      aplicar("mandé la cotización a espacio digital", ["Espacio Digital"])
        == "mandé la cotización a Espacio Digital"
    )
    #expect(
      aplicar("la landing de decamerón", ["Decameron"]) == "la landing de Decameron"
    )
    #expect(aplicar("el repo de blokit", ["Blokkit"]) == "el repo de Blokkit")
  }

  @Test func noSeMeteConElSpanglishQueNoEsSuyo() {
    let dictado = "hay que deployar el build después del commit"
    #expect(aplicar(dictado, ["Decameron", "Espacio Digital"]) == dictado)
  }

  @Test func laListaParaElMotorVaLimpia() {
    let terminos = DiccionarioPersonal.terminosParaElMotor(
      ["  Decameron ", "", "decameron", "Blokkit", "   "]
    )
    #expect(terminos == ["Decameron", "Blokkit"])
  }
}
