import Testing

@testable import DiloModes

/// El router de la Conversación: qué modelo contesta cada turno, con las
/// reglas decididas con Alfonso el 2026-10-29. Un test por regla.
struct RouterDeModelosTests {
  /// Decide una conversación entera y devuelve cada decisión.
  private func conversar(_ turnos: [String], eleccion: EleccionDeModelo = .automatico) -> [RouterDeModelos.Decision] {
    var router = RouterDeModelos()
    return turnos.map { router.decidir($0, eleccion: eleccion) }
  }

  // Regla 1: el primer turno va a Sonnet, sin inferir.

  @Test(arguments: [
    "Oye, ¿me ayudas a comparar dos ofertas de arriendo en Ñuñoa y analizar cuál me conviene más?",
    "Quiero que me expliques cómo funciona el código de un script en Python que lee un CSV",
    "¿Qué hora es en Santiago?",
  ])
  func elPrimerTurnoVaASonnetSinInferir(dicho: String) {
    #expect(conversar([dicho]) == [.init(.sonnet, .primerTurno)])
  }

  @Test func unPrimerTurnoLargoTampocoSube() {
    let largo = Array(repeating: "necesito ordenar las cuentas del departamento con mi socio y revisar cada gasto", count: 9)
      .joined(separator: " ")
    #expect(conversar([largo]).first?.nivel == .sonnet)
  }

  @Test(arguments: [
    ("Piénsalo bien: ¿me conviene dejar la pega para emprender?", NivelDeModelo.opus),
    ("Analiza a fondo este plan de negocios", .opus),
    ("Usa Opus para esto, porfa", .opus),
    ("Rápido, ¿cuánto es veinte por ciento de cuarenta lucas?", .haiku),
    ("¿Cuál es la capital de Perú? En corto.", .haiku),
    ("Usa Haiku: ¿cómo se dice gracias en japonés?", .haiku),
  ])
  func unaFraseExplicitaCambiaElModeloDesdeElPrimerTurno(dicho: String, nivel: NivelDeModelo) {
    #expect(conversar([dicho]) == [.init(nivel, .pedidoDeViva)])
  }

  @Test func unaFraseExplicitaCambiaEnCualquierTurno() {
    let decisiones = conversar([
      "¿Qué tal el día?",
      "Cuéntame algo de la historia de Valparaíso",
      "Ya, ahora piénsalo bien: ¿por qué se vino abajo el puerto después del canal de Panamá?",
      "Y ahora rápido, ¿en qué año abrió el canal?",
    ])
    #expect(decisiones.map(\.nivel) == [.sonnet, .sonnet, .opus, .haiku])
    #expect(decisiones[2].motivo == .pedidoDeViva)
    #expect(decisiones[3].motivo == .pedidoDeViva)
  }

  /// «rápido» suelto dentro de la frase no es un pedido.
  @Test func rapidoDentroDeLaFraseNoEsUnPedido() {
    let senales = SenalesDelTurno("¿Cuál es el auto más rápido que se vende en Chile hoy?")
    #expect(!senales.pideRapidez)
    #expect(!SenalesDelTurno("me corté el pelo corto").pideRapidez)
    #expect(SenalesDelTurno("rápido").pideRapidez)
  }

  // Regla 2: Haiku sólo para lo claramente trivial, desde cualquier turno.

  @Test(arguments: [
    "Hola", "Sí", "No", "Ya.", "Gracias", "Muchas gracias, Dilo", "Ok", "Dale", "Bacán",
    "Repite", "¿Qué dijiste?", "Sí, gracias", "Ya po, perfecto", "Buenos días", "Chao",
    "Sí, confirmo", "¿Qué?", "Oye", "Eso es",
  ])
  func loTrivialBajaAHaiku(dicho: String) {
    let decisiones = conversar(["¿Cómo funciona el Metro de Santiago de noche?", dicho])
    #expect(decisiones[1] == .init(.haiku, .trivial))
  }

  @Test func unSaludoDeEntradaTambienBaja() {
    #expect(conversar(["Hola, Dilo"]) == [.init(.haiku, .trivial)])
  }

  @Test(arguments: [
    "¿Qué es eso?",
    "No, pero explícame por qué",
    "Sí, y además quiero saber cuánto cuesta",
    "Gracias, ¿y cómo llego a Providencia desde acá?",
  ])
  func loQueParecePeroNoEsTrivialNoBaja(dicho: String) {
    let decisiones = conversar(["¿Qué micro me sirve para ir al centro?", dicho])
    #expect(decisiones[1].nivel == .sonnet)
  }

  // Regla 3: subir a Opus sólo con evidencia acumulada, nunca en el primero.

  @Test func dosTurnosComplejosDelMismoTemaSuben() {
    let decisiones = conversar([
      "Quiero comparar dos planes de isapre para mi familia",
      "Ya, y analiza también cuánto pagaría con cada uno si me operan",
    ])
    #expect(decisiones == [.init(.sonnet, .primerTurno), .init(.opus, .evidencia)])
  }

  @Test func unSoloTurnoComplejoNoSube() {
    let decisiones = conversar([
      "¿Qué tal estuvo el partido de anoche?",
      "Compárame a Colo-Colo con la U este año",
      "¿Y quién va primero?",
    ])
    #expect(decisiones.map(\.nivel) == [.sonnet, .sonnet, .sonnet])
  }

  @Test func unTurnoLargoYDensoDespuesDelPrimeroSube() {
    let largo = """
      Mira, te cuento el problema completo: tenemos una pyme de muebles en Maipú con doce \
      trabajadores, vendemos por Instagram y Mercado Libre, el inventario lo llevamos en una \
      planilla que nadie actualiza, las boletas se emiten a mano en el SII, los despachos los \
      coordina mi hermana por WhatsApp, y cada fin de mes descubrimos que faltan tableros, \
      sobran bisagras, y no sabemos qué productos dejan margen real después de pagar fletes, \
      comisiones del marketplace, arriendo del galpón y sueldos. Quiero ordenar todo esto este \
      trimestre sin gastar una fortuna en sistemas.
      """
    let decisiones = conversar(["Hola, tengo una consulta de mi negocio", largo])
    #expect(decisiones[1] == .init(.opus, .turnoLargo))
  }

  @Test func unTurnoLargoDeRellenoNoSube() {
    let relleno = Array(repeating: "eh o sea como que ya po y entonces eso igual", count: 12).joined(separator: " ")
    let decisiones = conversar(["¿Cómo estuvo tu semana?", relleno])
    #expect(decisiones[1].nivel == .sonnet)
  }

  // Regla 4: histéresis.

  @Test func arribaSeQuedaAlMenosTresTurnosDelTema() {
    let decisiones = conversar([
      "Necesito planificar la mudanza de la oficina",
      "Arma un cronograma por semanas con los pasos",
      "¿Y quién se encarga de los computadores?",
      "¿Cuánto nos demoramos en total?",
      "¿Y si lo hacemos un fin de semana?",
    ])
    #expect(decisiones.map(\.nivel) == [.sonnet, .opus, .opus, .opus, .sonnet])
    #expect(decisiones[2].motivo == .temaArriba)
    #expect(decisiones[4].motivo == .vuelveALaBase)
  }

  @Test func conMasEvidenciaSigueArribaDespuesDeLosTres() {
    let decisiones = conversar([
      "Quiero diseñar la arquitectura de una app de reservas",
      "Compara una base de datos SQL con una documental para esto",
      "¿Y el login?",
      "¿Cuánto cuesta el hosting?",
      "Ahora escríbeme el código del modelo de datos",
    ])
    #expect(decisiones.map(\.nivel) == [.sonnet, .opus, .opus, .opus, .opus])
  }

  @Test func losTrivialesDeEnMedioVanAHaikuSinBajarElTema() {
    var router = RouterDeModelos()
    _ = router.decidir("Necesito analizar los gastos del mes")
    #expect(router.decidir("Y compara con el mes pasado") == .init(.opus, .evidencia))
    #expect(router.decidir("Ya") == .init(.haiku, .trivial))
    #expect(router.decidir("Gracias") == .init(.haiku, .trivial))
    #expect(router.nivelDelTema == .opus)
    #expect(router.decidir("¿En qué gasté más?") == .init(.opus, .temaArriba))
  }

  @Test func cambiarDeTemaBajaAunqueNoHayanPasadoLosTres() {
    let decisiones = conversar([
      "Ayúdame a planificar un viaje al sur",
      "Compara ir en auto con ir en avión a Puerto Montt",
      "Cambiando de tema, ¿cómo se hace el pebre?",
    ])
    #expect(decisiones.map(\.nivel) == [.sonnet, .opus, .sonnet])
  }

  @Test func unModeloNombradoDuraLoQueElTema() {
    let decisiones = conversar([
      "¿Qué es un fondo mutuo?",
      "Usa Sonnet para esto: explícame la diferencia con un depósito a plazo",
      "Y analiza cuál me conviene, compara las comisiones",
      "Otra cosa, ¿qué hora es en Madrid?",
    ])
    #expect(decisiones.map(\.nivel) == [.sonnet, .sonnet, .sonnet, .sonnet])
    #expect(decisiones[2].motivo == .pedidoDeViva)
    #expect(decisiones[3].motivo == .base)
  }

  // Ajustes: un modelo fijo le gana al router, no a la voz.

  @Test func unModeloFijadoEnAjustesManda() {
    let decisiones = conversar(["Hola", "Analiza este contrato y compáralo con el anterior"], eleccion: .haiku)
    #expect(decisiones == [.init(.haiku, .fijado), .init(.haiku, .fijado)])
  }

  @Test func laVozLeGanaAAjustes() {
    let decisiones = conversar(["Piénsalo bien: ¿vendo el auto o lo arriendo?"], eleccion: .haiku)
    #expect(decisiones == [.init(.opus, .pedidoDeViva)])
  }

  @Test func elEsfuerzoVaAcordeAlModelo() {
    #expect(NivelDeModelo.haiku.esfuerzo == "low")
    #expect(NivelDeModelo.sonnet.esfuerzo == "medium")
    #expect(NivelDeModelo.opus.esfuerzo == "high")
    #expect(NivelDeModelo.allCases.map(\.modelo.id) == ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"])
  }

  @Test func laEleccionGuardadaNoSeRenombra() {
    #expect(EleccionDeModelo.allCases.map(\.rawValue) == ["automatico", "haiku", "sonnet", "opus"])
  }
}
