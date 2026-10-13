import DiloModes
import DiloText
import Foundation
import os
import Testing
@testable import Dilo

/// Correr un modo sobre lo dictado.
///
/// Hereda las reglas que costó aprender en `PromptShapingService` —el marco
/// que impide que el modelo conteste la transcripción, y el timeout, que
/// FoundationModels no trae— y cambia la que estaba mal: la falla ya no pasa
/// de largo en silencio.
@MainActor
struct TransformacionDeModoTests {
  private let modo = Modo(
    id: "correo",
    nombre: "Correo",
    prompt: "Escríbelo como correo.",
    instruccionFinal: "Mantén mi tono.",
    ejemploEntrada: "a que hora es",
    ejemploSalida: "¿A qué hora es?"
  )

  private let enElChip = ResolucionDeProveedor.Resuelto(
    proveedor: Proveedor(id: "chip", nombre: "El modelo de Apple", dialecto: .enElChip),
    modelo: "",
    esLocal: true
  )

  private let enLaNube = ResolucionDeProveedor.Resuelto(
    proveedor: Proveedor(
      id: "openai", nombre: "OpenAI", dialecto: .compatibleOpenAI,
      urlBase: URL(string: "https://api.openai.com/v1"), modelo: "gpt-5"
    ),
    modelo: "gpt-5",
    esLocal: false
  )

  /// Un cliente de mentira que anota lo que le pidieron.
  private struct ClienteFalso: ClienteDeProveedor {
    let responder: @Sendable (String, String, String) async throws -> String

    func responder(
      instrucciones: String, peticion: String, modelo: String
    ) async throws -> String {
      try await responder(instrucciones, peticion, modelo)
    }
  }

  private func servicio(
    _ responder: @escaping @Sendable (String, String, String) async throws -> String
  ) -> TransformacionDeModo {
    TransformacionDeModo(fabrica: { _ in ClienteFalso(responder: responder) })
  }

  @Test func elModoReescribeYDevuelveLoSuyo() async {
    let resultado = await servicio { _, _, _ in "Estimado Juan:" }
      .correr("mandale el correo", con: modo, deSesion: .corre(enElChip))
    #expect(resultado == .transformado("Estimado Juan:"))
  }

  /// El marco va en las instrucciones y la transcripción en el turno del
  /// usuario, envuelta. Un marco editable podría borrar la regla de no
  /// contestar y resucitar el bug de la pregunta respondida.
  @Test func laTranscripcionViajaComoDatoYElMarcoComoInstruccion() async {
    let visto = OSAllocatedUnfairLock<(String, String, String)?>(initialState: nil)
    _ = await servicio { instrucciones, peticion, modelo in
      visto.withLock { $0 = (instrucciones, peticion, modelo) }
      return "ok"
    }.correr("a que hora es", con: modo, deSesion: .corre(enLaNube))

    let (instrucciones, peticion, modelo) = visto.withLock { $0 }!
    #expect(instrucciones.hasPrefix(PromptDeLimpieza.marco))
    #expect(instrucciones.contains("nunca una pregunta que contestar"))
    #expect(!instrucciones.contains("Escríbelo como correo"))
    #expect(peticion.contains(#"{"dictado":"a que hora es"}"#))
    #expect(peticion.hasPrefix("Escríbelo como correo."))
    #expect(peticion.hasSuffix("Mantén mi tono."))
    #expect(modelo == "gpt-5")
  }

  /// Los ejemplos del prompt tienen que pasar el validador: si el prompt
  /// enseñara algo que el validador rechaza, cada dictado parecido caería a
  /// la capa de reglas.
  @Test func losEjemplosDelPromptPasanElValidador() throws {
    for ejemplo in PromptDeLimpieza.ejemplos {
      #expect(throws: Never.self, "«\(ejemplo.dictado)»") {
        _ = try ValidadorDeLimpieza.validar(ejemplo.limpio, contra: ejemplo.dictado, perfil: .limpieza)
      }
    }
    let limpio = Modo.deFabrica.first { $0.id == "limpio" }!
    #expect(throws: Never.self) {
      _ = try ValidadorDeLimpieza.validar(limpio.ejemploSalida, contra: limpio.ejemploEntrada, perfil: .limpieza)
    }
  }

  /// En el chip, un dictado largo no puede reventar la ventana: las
  /// instrucciones se achican antes de mandar.
  @Test func enElChipLasInstruccionesSeAjustanAlLargo() async {
    let vistas = OSAllocatedUnfairLock<[String]>(initialState: [])
    let limpio = Modo.deFabrica.first { $0.id == "limpio" }!
    let servicio = servicio { instrucciones, _, _ in
      vistas.withLock { $0.append(instrucciones) }
      return "ok"
    }
    _ = await servicio.correr("hola", con: limpio, deSesion: .corre(enElChip))
    _ = await servicio.correr(String(repeating: "hola ", count: 1_000), con: limpio, deSesion: .corre(enElChip))
    let (corta, larga) = vistas.withLock { ($0[0], $0[1]) }
    #expect(corta.contains("Reglas:"))
    #expect(larga.count < corta.count)
    #expect(larga.hasPrefix(PromptDeLimpieza.marco))
  }

  /// La regla nueva: una falla se cuenta. Antes cualquier error devolvía el
  /// texto crudo sin decir nada, que está bien con el modelo del chip y mal
  /// con una nube — la persona no tenía cómo saber si su modo corrió.
  @Test func unaFallaSeCuentaYElTextoSaleTalCual() async {
    let resultado = await servicio { _, _, _ in
      throw FallaDelProveedor.respondioMal(codigo: 500)
    }.correr("hola", con: modo, deSesion: .corre(enLaNube))

    guard case let .salioTalCual(aviso) = resultado else {
      Issue.record("Una falla pasó de largo en silencio")
      return
    }
    #expect(aviso.contains("Correo"))
    #expect(aviso.contains("OpenAI"))
  }

  /// Ninguna respuesta se pega sin pasar por el validador: si cambia un
  /// número, no es una reescritura sino otra cosa, y vuelve la propuesta.
  @Test func unaRespuestaQueCambiaUnNumeroSeRechaza() async {
    let resultado = await servicio { _, _, _ in "Estimado Juan: le transfiero 50.000 pesos." }
      .correr("transfiérele quince mil pesos a Juan", con: modo, deSesion: .corre(enElChip))
    #expect(
      resultado == .rechazado(
        propuesta: "Estimado Juan: le transfiero 50.000 pesos.", motivo: .cambioUnNumero
      )
    )
  }

  /// Cada modo se juzga con su vara: lo que Correo puede hacer, Limpio no.
  @Test func elCuidadoDelModoEsLaVara() {
    let dictado = "dile a Martina que la reunión es el jueves a las 3"
    let correo = "Hola, Martina: te confirmo que la reunión es el jueves a las 3. Saludos."
    let limpio = Modo.deFabrica.first { $0.id == "limpio" }!
    #expect(TransformacionDeModo.juzgar(correo, contra: dictado, modo: modo) == .transformado(correo))
    #expect(
      TransformacionDeModo.juzgar(correo, contra: dictado, modo: limpio)
        == .rechazado(propuesta: correo, motivo: .palabrasNuevas)
    )
  }

  /// Lo que se acepta se pega lavado: sin el sobre ni las comillas que el
  /// modelo puso alrededor de todo.
  @Test func loAceptadoSePegaLavado() {
    let limpio = Modo.deFabrica.first { $0.id == "limpio" }!
    #expect(
      TransformacionDeModo.juzgar(#"{"texto": "Nos vemos el viernes."}"#, contra: "nos vemos el viernes", modo: limpio)
        == .transformado("Nos vemos el viernes.")
    )
  }

  @Test func unaRespuestaVaciaCuentaComoFalla() async {
    let resultado = await servicio { _, _, _ in "   \n " }
      .correr("hola", con: modo, deSesion: .corre(enElChip))
    guard case .salioTalCual = resultado else {
      Issue.record("Una respuesta vacía pasó como buena")
      return
    }
  }

  /// El timeout contra un reloj manejado a mano: contra el de pared, este
  /// test afirma que la máquina fue rápida, no que el plazo se respetó (#116).
  @Test func unaReescrituraColgadaNoSeQuedaConLasPalabras() async {
    let despertar = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(
      initialState: nil
    )
    var servicio = servicio { _, _, _ in
      try await Task.sleep(for: .seconds(3600))
      return "nunca"
    }
    servicio.reloj = DeadlineClock(
      now: { .zero },
      sleep: { _ in
        await withCheckedContinuation { continuacion in
          despertar.withLock { $0 = continuacion }
        }
      }
    )

    async let resultado = servicio.correr(
      "hola", con: modo, deSesion: .corre(enLaNube)
    )
    // El plazo vence cuando este test lo dice, no cuando el runner alcance.
    await waitUntil("El servicio nunca pidió el plazo") {
      despertar.withLock { $0 != nil }
    }
    despertar.withLock { $0 }?.resume()

    guard case .salioTalCual = await resultado else {
      Issue.record("Un timeout no soltó las palabras")
      return
    }
  }

  /// Negarse a cruzar no es una falla del proveedor: es la decisión de no
  /// mandar a una nube un texto que el modo pidió local.
  @Test func negarseACruzarSaleTalCualConSuPropioAviso() async {
    let llamadas = OSAllocatedUnfairLock(initialState: 0)
    let resultado = await servicio { _, _, _ in
      llamadas.withLock { $0 += 1 }
      return "no debería pasar"
    }.correr("hola", con: modo, deSesion: .seNiegaACruzar(aviso: "no cruzo"))

    #expect(resultado == .salioTalCual(aviso: "no cruzo"))
    #expect(llamadas.withLock { $0 } == 0)
  }

  @Test func sinProveedorNoHayNadaQueCorrerYNoSeAvisaNada() async {
    let resultado = await servicio { _, _, _ in "no debería pasar" }
      .correr("hola", con: modo, deSesion: .sinProveedor)
    #expect(resultado == .sinModo)
  }

  @Test func unDictadoVacioNoLlamaANadie() async {
    let llamadas = OSAllocatedUnfairLock(initialState: 0)
    let resultado = await servicio { _, _, _ in
      llamadas.withLock { $0 += 1 }
      return "no debería pasar"
    }.correr("   ", con: modo, deSesion: .corre(enElChip))

    #expect(resultado == .sinModo)
    #expect(llamadas.withLock { $0 } == 0)
  }

  private func waitUntil(
    _ comment: Comment,
    _ condition: @Sendable () -> Bool
  ) async {
    for _ in 0 ..< 200 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record(comment)
  }
}
