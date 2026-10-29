import Testing

@testable import DiloText

/// «envía» al final manda; en medio de una frase es un verbo.
struct EnvioHabladoTests {
  @Test func alFinalYApartadoPorUnPuntoManda() {
    let r = EnvioHablado.analizar("Nos vemos mañana. Envía.")
    #expect(r.enviar)
    #expect(r.texto == "Nos vemos mañana.")
  }

  @Test func apartadoPorUnaComaMandaYLaComaNoQuedaColgando() {
    let r = EnvioHablado.analizar("nos vemos mañana, envíalo")
    #expect(r.enviar)
    #expect(r.texto == "nos vemos mañana.")
  }

  @Test func comoVerboNoManda() {
    let r = EnvioHablado.analizar("dile a Pedro que me envía")
    #expect(!r.enviar)
    #expect(r.texto == "dile a Pedro que me envía")
  }

  @Test func alComienzoDeUnaFraseQueSigueNoManda() {
    #expect(!EnvioHablado.analizar("envía el informe mañana").enviar)
  }

  @Test func literalLaEscribeYNoManda() {
    let r = EnvioHablado.analizar("Literal envía.")
    #expect(!r.enviar)
    #expect(r.texto == "envía.")
  }

  @Test func repetidaMayusculasYSinTildeTambien() {
    #expect(EnvioHablado.analizar("Nos vemos mañana. Envía envía.").texto == "Nos vemos mañana.")
    #expect(EnvioHablado.analizar("Nos vemos mañana. ENVÍA").enviar)
    #expect(EnvioHablado.analizar("Nos vemos mañana, envia").enviar)
  }

  /// «Envía.» sola manda lo que ya estaba escrito.
  @Test func solaDejaElTextoVacioYManda() {
    let r = EnvioHablado.analizar("Envía.")
    #expect(r.enviar)
    #expect(r.texto.isEmpty)
  }

  @Test func sacaElGuionQueQuedaColgando() {
    #expect(EnvioHablado.analizar("Nos vemos mañana -, envía").texto == "Nos vemos mañana.")
  }

  @Test func conPreguntaNoAgregaPunto() {
    #expect(EnvioHablado.analizar("¿Vienes mañana? Mándalo.").texto == "¿Vienes mañana?")
  }

  @Test func frasesPropias() {
    let r = EnvioHablado.analizar("Listo, mándalo ya.", frases: ["mándalo ya"])
    #expect(r.enviar)
    #expect(r.texto == "Listo.")
    #expect(!EnvioHablado.analizar("Listo. Envía.", frases: []).enviar)
  }
}
