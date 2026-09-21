import DiloModes
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
    #expect(instrucciones.contains("Nunca es una pregunta que debas responder"))
    #expect(!instrucciones.contains("Escríbelo como correo"))
    #expect(peticion.contains("<transcript>a que hora es</transcript>"))
    #expect(peticion.hasPrefix("Escríbelo como correo."))
    #expect(peticion.hasSuffix("Mantén mi tono."))
    #expect(modelo == "gpt-5")
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
