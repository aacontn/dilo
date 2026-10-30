import Testing

@testable import DiloModes

/// La escucha de nombres, lo puro: si lo oído es un llamado, qué tramo se
/// transcribe y cuándo, el búfer que se pisa solo y las pausas.
struct NombreQueDespiertaTests {
  let dilo = Agente.deFabrica[0]
  let regla = NombreQueDespierta(agentes: Agente.deFabrica)

  @Test(arguments: [
    ("Dilo, ¿qué tengo hoy?", "¿Qué tengo hoy?"),
    ("Dilo, abre mis notas.", "Abre mis notas."),
    ("dilo. resume la reunión", "Resume la reunión"),
    ("Oye Dilo, ¿me escuchas?", "¿Me escuchas?"),
    ("DÍLO ¿qué hay de nuevo?", "¿Qué hay de nuevo?"),
    // Lo que Parakeet escribe en vez de «Dilo», medido en la espiga.
    ("Digo, ¿qué hora es?", "¿Qué hora es?"),
    ("Di lo, para.", "Para."),
    ("Lilo, gracias.", "Gracias."),
  ])
  func elNombreApartadoAlPrincipioEsUnLlamado(dicho: String, turno: String) {
    #expect(regla.oir(dicho) == .init(agente: dilo, primerTurno: turno))
  }

  @Test(arguments: [
    ("Cami, ¿qué tengo hoy?", "¿Qué tengo hoy?"),
    ("Kami, ¿qué tengo hoy?", "¿Qué tengo hoy?"),
    ("Oye Camí, abre mis notas.", "Abre mis notas."),
    ("Kammy, para.", "Para."),
  ])
  func unNombrePropioSeReconocePorComoSuena(dicho: String, turno: String) {
    let kami = Agente(id: "dilo", nombre: "Kami", tipo: .dilo, seLlamaPorNombre: true)
    let regla = NombreQueDespierta(agentes: [kami])
    #expect(regla.oir(dicho) == .init(agente: kami, primerTurno: turno))
    // Y el nombre viejo ya no despierta.
    #expect(regla.oir("Dilo, ¿qué tengo hoy?") == nil)
  }

  @Test(arguments: ["Dilo.", "Dilo", "  dilo  ", "Oye, Dilo.", "Digo."])
  func soloElNombreEsUnLlamadoSinTurno(dicho: String) {
    #expect(regla.oir(dicho) == .init(agente: dilo, primerTurno: nil))
  }

  @Test(arguments: [
    // El verbo: sin signo que lo aparte, «dilo» es parte de la frase.
    "Dilo otra vez.",
    "Dilo como quieras.",
    "Digo que no hay problema.",
    "Di lo que piensas.",
    // Palabras parecidas que el motor escribe como son.
    "Dile a Marta que llego tarde.",
    "Dijo que venía mañana.",
    "Milo, ven acá.",
    "Tilo es mi perro.",
    // El nombre que no va al principio.
    "La aplicación se llama Dilo y funciona bien.",
    "Ayer le pregunté a Dilo por el calendario.",
    "Hola que tal Dilo, ¿cómo estás?",
    "",
    "…",
  ])
  func loDemasNoDespierta(dicho: String) {
    #expect(regla.oir(dicho) == nil)
  }

  @Test func conElNombreYaOidoNoHaceFaltaElSigno() {
    // La búsqueda oyó «Dilo, ¿qué…»; el tramo entero salió pegado.
    #expect(regla.oir("Di lo que hay de nuevo.") == nil)
    #expect(regla.oir("Di lo que hay de nuevo.", exigirApartado: false) == .init(agente: dilo, primerTurno: "Que hay de nuevo."))
    #expect(regla.oir("Que hay de nuevo.", exigirApartado: false) == nil)
  }

  @Test func soloEscuchaALosQueSeLlamanPorNombre() {
    #expect(regla.oir("Switchboard, ¿qué tengo hoy?") == nil)
    var agentes = Agente.deFabrica
    agentes[2].seLlamaPorNombre = true
    let conSwitchboard = NombreQueDespierta(agentes: agentes)
    #expect(conSwitchboard.oir("Switchboard, ¿qué tengo hoy?")?.agente.id == "switchboard")
    #expect(conSwitchboard.oir("Switch board, ¿qué tengo hoy?")?.primerTurno == "¿Qué tengo hoy?")
  }

  @Test func ganaElNombreMasLargo() {
    let claude = Agente(id: "claude", nombre: "Claude", tipo: .dilo, seLlamaPorNombre: true)
    let code = Agente(id: "code", nombre: "Claude Code", tipo: .claudeCode, seLlamaPorNombre: true)
    let regla = NombreQueDespierta(agentes: [claude, code])
    #expect(regla.oir("Claude Code, revisa los tests.") == .init(agente: code, primerTurno: "Revisa los tests."))
    #expect(regla.oir("Claude, ¿qué hora es?")?.agente == claude)
  }

  @Test func lasVariantesSePuedenPasar() {
    var agentes = Agente.deFabrica
    agentes[1].seLlamaPorNombre = true
    let regla = NombreQueDespierta(agentes: agentes) { agente in
      agente.id == "claude-code" ? ["claude code", "cloud code"] : [agente.nombre]
    }
    #expect(regla.oir("Cloud Code, corre los tests.")?.agente.id == "claude-code")
  }

  @Test func sinNombresNoHayNadaQueEscuchar() {
    let nadie = Agente.deFabrica.map { agente -> Agente in
      var a = agente
      a.seLlamaPorNombre = false
      return a
    }
    #expect(NombreQueDespierta(agentes: nadie).hayNombres == false)
    #expect(regla.hayNombres)
  }
}

struct VentanaDeEscuchaTests {
  /// Trozos de 256 ms, como los da Silero: 4.096 muestras a 16 kHz.
  static let paso = 4_096

  /// Pasa una secuencia de voz (true) y silencio (false), un trozo por
  /// elemento, y junta lo que pide la ventana.
  func pasar(_ voz: [Bool], ventana: inout VentanaDeEscucha, desde: Int = 0) -> [(Int, VentanaDeEscucha.Accion)] {
    var acciones: [(Int, VentanaDeEscucha.Accion)] = []
    for (i, hay) in voz.enumerated() {
      let inicio = (desde + i) * Self.paso
      let accion = ventana.trozo(probabilidad: hay ? 0.9 : 0.1, inicio: inicio, fin: inicio + Self.paso)
      if accion != .nada { acciones.append((desde + i, accion)) }
    }
    return acciones
  }

  @Test func elSilencioNoPideNada() {
    var ventana = VentanaDeEscucha()
    #expect(pasar(Array(repeating: false, count: 100), ventana: &ventana).isEmpty)
    #expect(!ventana.ocupada)
  }

  @Test func unTramoLargoPideSoloElPrincipio() throws {
    var ventana = VentanaDeEscucha()
    let acciones = pasar(Array(repeating: true, count: 40), ventana: &ventana)
    // Una sola búsqueda, de ~1,5 s y con lo de antes de la voz.
    #expect(acciones.count == 1)
    guard case let .buscarNombre(rango) = try #require(acciones.first?.1) else {
      Issue.record("no pidió buscar")
      return
    }
    #expect(rango.lowerBound == 0)
    #expect(rango.count >= 24_000 && rango.count < 24_000 + Self.paso)
  }

  @Test func sinNombreElRestoDelTramoSeIgnora() {
    var ventana = VentanaDeEscucha()
    _ = pasar(Array(repeating: true, count: 7), ventana: &ventana)
    let respuesta = ventana.resolver(hayNombre: false)
    #expect(respuesta == .nada)
    // Sigue hablando: no se vuelve a transcribir nada de este tramo.
    #expect(pasar(Array(repeating: true, count: 30), ventana: &ventana, desde: 7).isEmpty)
    // Se calla y vuelve a hablar: tramo nuevo, búsqueda nueva.
    let acciones = pasar(Array(repeating: false, count: 3) + Array(repeating: true, count: 7), ventana: &ventana, desde: 37)
    #expect(acciones.count == 1)
  }

  @Test func conNombreEsperaQueTermineYPideElTramoEntero() throws {
    var ventana = VentanaDeEscucha()
    _ = pasar(Array(repeating: true, count: 7), ventana: &ventana)
    let respuesta = ventana.resolver(hayNombre: true)
    #expect(respuesta == .nada)
    // Sigue: «…¿qué tengo hoy en el calendario?», y se calla.
    let acciones = pasar(Array(repeating: true, count: 8) + Array(repeating: false, count: 6), ventana: &ventana, desde: 7)
    #expect(acciones.count == 1)
    guard case let .transcribirLlamado(rango) = try #require(acciones.first?.1) else {
      Issue.record("no pidió el llamado")
      return
    }
    #expect(rango.lowerBound == 0)
    // Hasta la última voz (trozo 14) más un poco, no hasta el final del silencio.
    #expect(rango.upperBound >= 15 * Self.paso && rango.upperBound < 16 * Self.paso)
    // El silencio tras el nombre es el de `FinDelTurno`.
    let callado = acciones[0].0 - 14
    #expect(Double(callado * Self.paso) / 16_000 >= 1.1)
    #expect(!ventana.ocupada)
  }

  @Test func unTramoCortoSeBuscaEnteroYNoSeTranscribeDosVeces() throws {
    var ventana = VentanaDeEscucha()
    // «Dilo.» y silencio: el tramo termina antes de la ventana.
    let acciones = pasar([true, true] + Array(repeating: false, count: 4), ventana: &ventana)
    #expect(acciones.count == 1)
    guard case .buscarNombre = try #require(acciones.first?.1) else {
      Issue.record("no pidió buscar")
      return
    }
    let respuesta = ventana.resolver(hayNombre: true)
    #expect(respuesta == .llamarConLoBuscado)
    #expect(!ventana.ocupada)
  }

  @Test func elLlamadoTieneTope() {
    var ventana = VentanaDeEscucha()
    _ = pasar(Array(repeating: true, count: 7), ventana: &ventana)
    _ = ventana.resolver(hayNombre: true)
    let acciones = pasar(Array(repeating: true, count: 60), ventana: &ventana, desde: 7)
    #expect(acciones.count == 1)
    if case let .transcribirLlamado(rango) = acciones.first?.1 {
      #expect(Double(rango.count) / 16_000 <= ventana.ajustes.maximoDelLlamado + 0.3)
    } else {
      Issue.record("no cortó el llamado")
    }
    // Lo que sigue hablando es la misma persona: no se busca otro nombre.
    #expect(ventana.ocupada)
  }

  @Test func loQueSePideCabeEnElBufer() {
    let ajustes = VentanaDeEscucha.Ajustes()
    let bufer = BuferDeEscucha()
    let maximo = ajustes.maximoDelLlamado + ajustes.antesDeLaVoz + 0.3
    #expect(Double(bufer.capacidad) / ajustes.tasa >= maximo)
  }

  @Test func unaRespuestaQueNadieEsperaNoHaceNada() {
    var ventana = VentanaDeEscucha()
    let respuesta = ventana.resolver(hayNombre: true)
    #expect(respuesta == .nada)
    _ = pasar([true, true, true], ventana: &ventana)
    ventana.olvidar()
    #expect(!ventana.ocupada)
  }
}

struct BuferDeEscuchaTests {
  @Test func guardaLoUltimoYPisaLoViejo() {
    var bufer = BuferDeEscucha(segundos: 1, tasa: 10)
    bufer.agregar((0..<25).map(Float.init))
    #expect(bufer.escritas == 25)
    #expect(bufer.desde == 15)
    #expect(bufer.tramo(15..<25) == (15..<25).map(Float.init))
    // Lo pisado ya no está: se entrega sólo lo que queda.
    #expect(bufer.tramo(0..<18) == [15, 16, 17])
    #expect(bufer.tramo(0..<10).isEmpty)
    #expect(bufer.tramo(20..<40) == (20..<25).map(Float.init))
  }

  @Test func unTrozoMasGrandeQueElBuferDejaLoUltimo() {
    var bufer = BuferDeEscucha(segundos: 1, tasa: 4)
    bufer.agregar([1, 2, 3, 4, 5, 6, 7])
    #expect(bufer.escritas == 7)
    #expect(bufer.tramo(0..<7) == [4, 5, 6, 7])
  }

  @Test func vaciarBorraTodo() {
    var bufer = BuferDeEscucha(segundos: 1, tasa: 8)
    bufer.agregar([1, 2, 3, 4, 5])
    bufer.vaciar()
    #expect(bufer.escritas == 0)
    #expect(bufer.tramo(0..<8).isEmpty)
    bufer.agregar([9])
    #expect(bufer.tramo(0..<8) == [9])
  }

  @Test func sonPocosSegundos() {
    // El diseño: «un búfer de RAM de pocos segundos que se pisa solo».
    #expect(BuferDeEscucha().capacidad == 12 * 16_000)
  }
}

struct PausasDeLaEscuchaTests {
  @Test func apagadaDeFabrica() {
    let pausas = PausasDeLaEscucha()
    #expect(pausas.estado == .apagada)
    #expect(!pausas.abreElMicrofono)
  }

  @Test func prendidaEscuchaSiNadaLaPausa() {
    let pausas = PausasDeLaEscucha(prendida: true)
    #expect(pausas.estado == .escuchando)
    #expect(pausas.abreElMicrofono)
  }

  @Test func cadaMotivoPausaYSoloSinNingunoVuelve() {
    var pausas = PausasDeLaEscucha(prendida: true)
    let cierra = pausas.marcar(.dictado, true)
    let otra = pausas.marcar(.pantallaBloqueada, true)
    #expect(cierra && !otra)
    #expect(pausas.estado == .pausada([.dictado, .pantallaBloqueada]))
    let sinDictado = pausas.marcar(.dictado, false)
    #expect(!sinDictado && !pausas.abreElMicrofono)
    let abre = pausas.marcar(.pantallaBloqueada, false)
    #expect(abre && pausas.abreElMicrofono)
  }

  @Test func apagadaNoAbreAunqueNoHayaMotivos() {
    var pausas = PausasDeLaEscucha(prendida: true)
    pausas.marcar(.reunion, true)
    pausas.prendida = false
    pausas.marcar(.reunion, false)
    #expect(pausas.estado == .apagada)
  }

  @Test func elMotivoQueSeDiceEsElQueSeArreglaPrimero() {
    var pausas = PausasDeLaEscucha(prendida: true)
    pausas.marcar(.pantallaBloqueada, true)
    pausas.marcar(.conversacion, true)
    #expect(pausas.motivoPrincipal == .conversacion)
    pausas.marcar(.sinMotor, true)
    #expect(pausas.motivoPrincipal == .sinMotor)
    #expect(PausasDeLaEscucha(prendida: true).motivoPrincipal == nil)
  }
}
