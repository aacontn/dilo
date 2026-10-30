import Foundation
import Testing

@testable import DiloModes

/// El cliente en streaming de la Conversación, sin abrir un socket: las
/// líneas SSE se escriben a mano, como las manda Anthropic.
struct ConversacionConClaudeTests {
  private let historial = [MensajeDeLaConversacion(.persona, "Hola, ¿cómo estái?")]

  private func cuerpo(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
  }

  /// Un transporte que contesta estas líneas con este código.
  private func responde(_ lineas: [String], codigo: Int = 200) -> ClienteDeConversacion.Transporte {
    { peticion in
      let stream = AsyncThrowingStream<String, any Error> { continuacion in
        for linea in lineas { continuacion.yield(linea) }
        continuacion.finish()
      }
      return (stream, HTTPURLResponse(url: peticion.url!, statusCode: codigo, httpVersion: nil, headerFields: nil)!)
    }
  }

  private static let respuestaDeEjemplo = [
    "event: message_start",
    #"data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":120,"cache_read_input_tokens":0,"output_tokens":1}}}"#,
    "",
    #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
    #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"no se dice"}}"#,
    #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
    #"data: {"type":"ping"}"#,
    #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Bien, "}}"#,
    #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"¿y tú?"}}"#,
    #"data: {"type":"content_block_stop","index":1}"#,
    #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}"#,
    #"data: {"type":"message_stop"}"#,
  ]

  private func recorrer(_ cliente: ClienteDeConversacion) async throws -> [EventoDeLaRespuesta] {
    var eventos: [EventoDeLaRespuesta] = []
    for try await evento in cliente.responder(PedidoDeConversacion(nivel: .haiku, historial: historial)) {
      eventos.append(evento)
    }
    return eventos
  }

  @Test(arguments: NivelDeModelo.allCases)
  func elRequestEsStreamingYNoLlevaNadaQueDevuelva400(nivel: NivelDeModelo) throws {
    let request = try ClienteDeConversacion(clave: "secreta").armar(
      PedidoDeConversacion(nivel: nivel, historial: historial)
    )
    #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "secreta")
    #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

    let enviado = cuerpo(request)
    #expect(enviado["model"] as? String == nivel.modelo.id)
    #expect(enviado["stream"] as? Bool == true)
    #expect(enviado["max_tokens"] as? Int == nivel.maximoDeTokens)
    #expect((enviado["output_config"] as? [String: Any])?["effort"] as? String == nivel.esfuerzo)
    #expect((enviado["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    #expect(enviado["system"] as? String == PromptDeLaConversacion.instrucciones)
    for prohibido in ["temperature", "top_p", "top_k", "thinking"] {
      #expect(enviado[prohibido] == nil, "\(prohibido) es un 400 en los modelos 5.5")
    }
    let mensajes = enviado["messages"] as? [[String: String]]
    #expect(mensajes == [["role": "user", "content": "Hola, ¿cómo estái?"]])
  }

  @Test func sinClaveNoSeArmaNada() {
    #expect(throws: FallaDeClaude.faltaLaClave) {
      try ClienteDeConversacion(clave: "  ").armar(PedidoDeConversacion(nivel: .haiku, historial: historial))
    }
  }

  @Test func nuncaTerminaEnAssistant() {
    let conPrefill = historial + [MensajeDeLaConversacion(.dilo, "Bien")]
    #expect(throws: FallaDeClaude.self) {
      try ClienteDeConversacion(clave: "x").armar(PedidoDeConversacion(nivel: .haiku, historial: conPrefill))
    }
  }

  @Test func soloElTextoSeDiceYElUsoSaleConElFin() async throws {
    let eventos = try await recorrer(ClienteDeConversacion(clave: "x", transporte: responde(Self.respuestaDeEjemplo)))
    #expect(eventos == [
      .texto("Bien, "),
      .texto("¿y tú?"),
      .fin(UsoDeTokens(entrada: 120, salida: 42), cortada: false),
    ])
  }

  @Test func unRefusalEsFalla() async {
    let lineas = [
      #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Mira"}}"#,
      #"data: {"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":3}}"#,
      #"data: {"type":"message_stop"}"#,
    ]
    await #expect(throws: FallaDeClaude.seNego) {
      _ = try await recorrer(ClienteDeConversacion(clave: "x", transporte: responde(lineas)))
    }
  }

  @Test func maxTokensTerminaCortadaPeroTermina() async throws {
    let lineas = [
      #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Primero"}}"#,
      #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":2000}}"#,
      #"data: {"type":"message_stop"}"#,
    ]
    let eventos = try await recorrer(ClienteDeConversacion(clave: "x", transporte: responde(lineas)))
    #expect(eventos.last == .fin(UsoDeTokens(salida: 2000), cortada: true))
  }

  @Test func unErrorAMitadDelStreamTieneSuNombre() async {
    let lineas = [
      "event: error",
      #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
    ]
    await #expect(throws: FallaDeClaude.anthropicNoResponde(codigo: 529)) {
      _ = try await recorrer(ClienteDeConversacion(clave: "x", transporte: responde(lineas)))
    }
  }

  @Test(arguments: [(401, FallaDeClaude.claveRechazada), (429, .demasiadosPedidos), (529, .anthropicNoResponde(codigo: 529))])
  func unCodigoHTTPEsSuFalla(codigo: Int, falla: FallaDeClaude) async {
    await #expect(throws: falla) {
      _ = try await recorrer(ClienteDeConversacion(clave: "x", transporte: responde([], codigo: codigo)))
    }
  }

  @Test func unStreamQueSeCortaSinMessageStopNoEsUnaRespuesta() async {
    let lineas = [#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hola"}}"#]
    await #expect(throws: FallaDeClaude.sinConexion) {
      _ = try await recorrer(ClienteDeConversacion(clave: "x", transporte: responde(lineas)))
    }
  }

  @Test func elCostoCuentaLaCache() {
    let uso = UsoDeTokens(entrada: 1_000, salida: 500, escritosEnCache: 2_000, leidosDeCache: 10_000)
    // Sonnet: 1.000 × 2 + 2.000 × 2,5 + 10.000 × 0,2 + 500 × 10, por millón.
    let costo = CostosDeClaude.costo(de: uso, modelo: ModelosDeAnthropic.sonnet.id) ?? -1
    #expect(abs(costo - 0.014) < 1e-9)
    #expect(CostosDeClaude.costo(de: uso, modelo: "otro") == nil)
  }
}

/// Las oraciones que la voz dice a medida que llega el texto.
struct TrozosParaDecirTests {
  @Test func laPrimeraOracionSaleApenasTermina() {
    var trozos = TrozosParaDecir()
    #expect(trozos.agregar("Hola, ") == [])
    #expect(trozos.agregar("Alfonso. Mañana") == ["Hola, Alfonso."])
    #expect(trozos.agregar(" llueve en Santiago") == [])
    #expect(trozos.terminar() == "Mañana llueve en Santiago")
    #expect(trozos.terminar() == nil)
  }

  @Test func noCortaDecimalesNiAbreviaturas() {
    var trozos = TrozosParaDecir()
    #expect(trozos.agregar("Cuesta 3.5 lucas, aprox. lo mismo que en EE. UU. y el Sr. Pérez lo sabe. ") == [
      "Cuesta 3.5 lucas, aprox. lo mismo que en EE. UU. y el Sr. Pérez lo sabe.",
    ])
  }

  @Test func preguntasYExclamacionesTambienCortan() {
    var trozos = TrozosParaDecir()
    #expect(trozos.agregar("¿Te sirve? ¡Bacán! Seguimos") == ["¿Te sirve?", "¡Bacán!"])
  }

  @Test func elMarkdownNoSeDice() {
    var trozos = TrozosParaDecir()
    let dicho = trozos.agregar("## Pasos\n- **Primero** abre la app.\n* Después `guarda`.\n")
    #expect(dicho == ["Pasos", "Primero abre la app.", "Después guarda."])
  }
}

/// Lo gastado en el mes y el tope.
struct TopeDeGastoTests {
  private let calendario: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Santiago")!
    return c
  }()

  private func fecha(_ año: Int, _ mes: Int, _ dia: Int) -> Date {
    calendario.date(from: DateComponents(year: año, month: mes, day: dia, hour: 12))!
  }

  @Test func seGuardaYSeLeeSinNadaDeLoConversado() {
    let gasto = GastoDelMes(mes: "2026-10", dolares: 0.4213)
    #expect(gasto.guardado == "2026-10|0.4213")
    #expect(GastoDelMes(guardado: gasto.guardado) == gasto)
    #expect(GastoDelMes(guardado: "basura") == nil)
  }

  @Test func elMesNuevoEmpiezaEnCero() {
    let octubre = GastoDelMes(mes: "2026-10", dolares: 4.9)
    let noviembre = TopeDeGasto.vigente(octubre, ahora: fecha(2026, 11, 1), calendario: calendario)
    #expect(noviembre == GastoDelMes(mes: "2026-11", dolares: 0))
    #expect(TopeDeGasto.sumar(0.1, a: octubre, ahora: fecha(2026, 10, 29), calendario: calendario).dolares == 5.0)
  }

  @Test func alLlegarAlTopeNoSeLlama() {
    let ahora = fecha(2026, 10, 29)
    #expect(TopeDeGasto.puedeLlamar(GastoDelMes(mes: "2026-10", dolares: 4.99), tope: 5, ahora: ahora, calendario: calendario))
    #expect(!TopeDeGasto.puedeLlamar(GastoDelMes(mes: "2026-10", dolares: 5), tope: 5, ahora: ahora, calendario: calendario))
    #expect(TopeDeGasto.puedeLlamar(GastoDelMes(mes: "2026-09", dolares: 50), tope: 5, ahora: ahora, calendario: calendario))
  }
}

/// Los turnos en half duplex y el fin del turno por silencio.
struct MaquinaDeLaConversacionTests {
  @Test func unTurnoEntero() {
    var maquina = MaquinaDeLaConversacion()
    #expect(maquina.recibir(.llamar) == [.abrirMicrofono])
    #expect(maquina.microfonoAbierto)
    #expect(maquina.recibir(.terminoTuTurno) == [.cerrarMicrofono(entregar: true)])
    #expect(maquina.estado == .pensando)
    #expect(maquina.recibir(.transcrito(vacio: false)) == [.consultar])
    #expect(maquina.recibir(.empezoAHablar) == [])
    #expect(maquina.estado == .hablando)
    #expect(maquina.recibir(.terminoDeHablar) == [.abrirMicrofono])
    #expect(maquina.estado == .escuchando)
  }

  /// La regla del half duplex: mientras Dilo piensa o habla, el micrófono no
  /// va al motor.
  @Test func mientrasDiloHablaNoSeEscucha() {
    var maquina = MaquinaDeLaConversacion()
    _ = maquina.recibir(.llamar)
    _ = maquina.recibir(.terminoTuTurno)
    #expect(!maquina.microfonoAbierto)
    _ = maquina.recibir(.transcrito(vacio: false))
    _ = maquina.recibir(.empezoAHablar)
    #expect(!maquina.microfonoAbierto)
  }

  @Test func interrumpirTeDaElTurno() {
    var maquina = MaquinaDeLaConversacion()
    _ = maquina.recibir(.llamar)
    _ = maquina.recibir(.terminoTuTurno)
    _ = maquina.recibir(.transcrito(vacio: false))
    _ = maquina.recibir(.empezoAHablar)
    #expect(maquina.recibir(.interrumpir) == [.cancelarConsulta, .callarLaVoz, .abrirMicrofono])
    #expect(maquina.microfonoAbierto)
    // Escuchando, interrumpir no hace nada.
    #expect(maquina.recibir(.interrumpir) == [])
  }

  @Test func sinNadaDichoVuelveATuTurno() {
    var maquina = MaquinaDeLaConversacion()
    _ = maquina.recibir(.llamar)
    _ = maquina.recibir(.terminoTuTurno)
    #expect(maquina.recibir(.transcrito(vacio: true)) == [.abrirMicrofono])
    #expect(maquina.estado == .escuchando)
  }

  @Test func silenciarCierraYDescartaYAlVolverAbre() {
    var maquina = MaquinaDeLaConversacion()
    _ = maquina.recibir(.llamar)
    #expect(maquina.recibir(.silenciar(true)) == [.cerrarMicrofono(entregar: false)])
    #expect(!maquina.microfonoAbierto)
    #expect(maquina.recibir(.terminoTuTurno) == [])
    #expect(maquina.recibir(.silenciar(false)) == [.abrirMicrofono])
  }

  @Test func silenciadaDiloTerminaDeHablarPeroNoSeAbreElMicrofono() {
    var maquina = MaquinaDeLaConversacion()
    _ = maquina.recibir(.llamar)
    _ = maquina.recibir(.terminoTuTurno)
    _ = maquina.recibir(.transcrito(vacio: false))
    _ = maquina.recibir(.silenciar(true))
    #expect(maquina.recibir(.terminoDeHablar) == [])
    #expect(maquina.estado == .escuchando)
    #expect(!maquina.microfonoAbierto)
  }

  @Test func colgarSueltaTodo() {
    var maquina = MaquinaDeLaConversacion()
    _ = maquina.recibir(.llamar)
    #expect(maquina.recibir(.colgar) == [.cerrarMicrofono(entregar: false)])
    _ = maquina.recibir(.llamar)
    _ = maquina.recibir(.terminoTuTurno)
    _ = maquina.recibir(.transcrito(vacio: false))
    #expect(maquina.recibir(.colgar) == [.cancelarConsulta, .callarLaVoz])
    #expect(maquina.estado == .colgada)
    #expect(maquina.recibir(.terminoDeHablar) == [])
  }

  @Test func elSilencioTerminaElTurnoSoloDespuesDeHablar() {
    let t0 = ContinuousClock.now
    var fin = FinDelTurno(inicio: t0)
    func en(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }
    // Pieza callada: nunca termina.
    for ms in stride(from: 0, through: 3_000, by: 100) { fin.muestra(nivel: 0.1, en: en(ms)) }
    #expect(!fin.termino(en: en(3_000)))
    // Medio segundo de voz y después silencio.
    for ms in stride(from: 3_100, through: 3_600, by: 100) { fin.muestra(nivel: 0.6, en: en(ms)) }
    #expect(fin.huboVoz)
    for ms in stride(from: 3_700, through: 4_600, by: 100) { fin.muestra(nivel: 0.1, en: en(ms)) }
    #expect(!fin.termino(en: en(4_600)))
    #expect(fin.termino(en: en(3_600 + 1_100)))
  }

  @Test func unGolpeNoEsUnTurno() {
    let t0 = ContinuousClock.now
    var fin = FinDelTurno(inicio: t0)
    fin.muestra(nivel: 0.9, en: t0 + .milliseconds(100))
    fin.muestra(nivel: 0.1, en: t0 + .milliseconds(200))
    #expect(!fin.huboVoz)
    #expect(!fin.termino(en: t0 + .seconds(5)))
  }

  @Test func sinVozMuchoRatoCuelga() {
    let t0 = ContinuousClock.now
    let fin = FinDelTurno(inicio: t0)
    #expect(!fin.nadieHabla(en: t0 + .seconds(60)))
    #expect(fin.nadieHabla(en: t0 + FinDelTurno.sinVozParaColgar))
  }
}
