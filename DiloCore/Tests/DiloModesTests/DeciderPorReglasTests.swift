import Testing

@testable import DiloModes

/// La implementación 0 del `Decider`. Los dictados son del estilo del set con
/// que se midió el 2026-09-20: chilenos, cortos, con spanglish técnico.
struct DeciderPorReglasTests {
  private let decider = DeciderPorReglas(modos: Modo.deFabrica)
  private var pregunta: PreguntaTipada { .eleccion(Modo.deFabrica.map(\.id)) }

  @Test func laAppAlFrenteDecideYSeLaJuega() {
    let respuesta = decider.decidirAhora(
      "dale una revisada a esto",
      pregunta,
      en: ContextoDeDecision(appAlFrente: "Mail")
    )
    #expect(respuesta.valor == "correo")
    #expect(respuesta.probabilidad == 0.95)
  }

  @Test func laAppSeReconoceAunqueVengaConNombreLargo() {
    let respuesta = decider.decidirAhora(
      "arregla esto", pregunta, en: ContextoDeDecision(appAlFrente: "Visual Studio Code")
    )
    #expect(respuesta.valor == "codigo")
  }

  @Test func sinAppLasPalabrasClaveDesempatan() {
    let respuesta = decider.decidirAhora(
      "hay que hacer el deploy después del merge",
      pregunta,
      en: ContextoDeDecision()
    )
    #expect(respuesta.valor == "codigo")
    // Sin app, la señal es más débil y lo dice.
    #expect(respuesta.probabilidad < 0.95)
    #expect(respuesta.probabilidad > 0.5)
  }

  @Test func noAdivinaCuandoNoHayNingunaSenal() {
    let respuesta = decider.decidirAhora(
      "qué lindo día", pregunta, en: ContextoDeDecision(appAlFrente: "Finder")
    )
    // Contesta algo, pero con la probabilidad de haberlo sacado al azar: el
    // umbral de ResolucionDeModo lo descarta.
    #expect(respuesta.probabilidad < 0.5)
  }

  @Test func lasTildesNoCambianLaSenal() {
    let sinTilde = decider.decidirAhora(
      "oye, la cotizacion", pregunta, en: ContextoDeDecision()
    )
    let conTilde = decider.decidirAhora(
      "oye, la cotización", pregunta, en: ContextoDeDecision()
    )
    #expect(sinTilde.valor == conTilde.valor)
  }

  @Test func contestaSiONoCuandoSeLePregunta() {
    let reglas = DeciderPorReglas(reglas: [
      DeciderPorReglas.Regla(opcion: "sí", palabrasClave: ["cancela", "detente"]),
      DeciderPorReglas.Regla(opcion: "no"),
    ])
    let respuesta = reglas.decidirAhora("dilo, cancela eso", .siNo, en: ContextoDeDecision())
    #expect(respuesta.valor == "sí")
  }

  @Test func unPuntajeNoSaleDeReglasYLoDice() {
    let respuesta = decider.decidirAhora("lo que sea", .puntaje(1 ... 5), en: ContextoDeDecision())
    #expect(respuesta.probabilidad <= 0.2)
  }
}
