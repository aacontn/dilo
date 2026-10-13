import Foundation
import Testing
import os

@testable import DiloEngines

/// Un motor que escucha bien y se cae al soltar, como Core ML cuando falla.
actor MotorQueSeCae: SpeechEngine {
  struct Caida: LocalizedError {
    var errorDescription: String? { "Core ML se cayó" }
  }

  private var activa = false

  func start(locale: Locale, handlers: EngineHandlers) async throws { activa = true }

  func finish() async throws -> String {
    guard activa else { throw EngineError.sinSesion }
    activa = false
    throw Caida()
  }

  func cancel() async { activa = false }
}

/// Lo que cada motor contesta cuando se le pasa audio en RAM, y a quién se
/// le preguntó.
final class TranscriptorFalso: Sendable {
  private let respuestas: OSAllocatedUnfairLock<[SpeechEngineKind: Result<String, EngineError>]>
  private let preguntas = OSAllocatedUnfairLock<[SpeechEngineKind]>(initialState: [])

  init(_ respuestas: [SpeechEngineKind: Result<String, EngineError>] = [:]) {
    self.respuestas = OSAllocatedUnfairLock(initialState: respuestas)
  }

  var aQuienes: [SpeechEngineKind] { preguntas.withLock { $0 } }

  func contestar(_ motor: SpeechEngineKind, _ resultado: Result<String, EngineError>) {
    respuestas.withLock { $0[motor] = resultado }
  }

  var cierre: MotorConRespaldo.TranscribirDesdeRAM {
    { motor, _, _ in
      self.preguntas.withLock { $0.append(motor) }
      return try self.respuestas.withLock { $0[motor] ?? .failure(.modeloNoDescargado) }.get()
    }
  }
}

/// Los avisos al menú, en orden.
final class AvisosDeToma: Sendable {
  private let lista = OSAllocatedUnfairLock<[TimeInterval?]>(initialState: [])
  var todos: [TimeInterval?] { lista.withLock { $0 } }
  func agregar(_ aviso: TimeInterval?) { lista.withLock { $0.append(aviso) } }
}

struct MotorConRespaldoTests {
  private let locale = Locale(identifier: "es-CL")

  private func armar(
    parakeet: any SpeechEngine = MotorQueSeCae(),
    apple: any SpeechEngine = MotorFalso(texto: "de Apple"),
    transcriptor: TranscriptorFalso = TranscriptorFalso(),
    reloj: any RelojDeReposo = RelojFalso()
  ) -> (MotorConRespaldo, GrabadoraEnRAM) {
    let grabadora = GrabadoraEnRAM()
    let router = SpeechEngineRouter(
      apple: apple, parakeet: parakeet, elegido: .parakeet, parakeetDescargado: { true })
    let motor = MotorConRespaldo(
      motores: router, grabadora: grabadora, reloj: reloj, transcribir: transcriptor.cierre)
    return (motor, grabadora)
  }

  /// `segundos` de algo que suena a voz, con medio segundo de sala a cada
  /// lado: una toma de voz pareja de punta a punta no tiene piso del que
  /// distinguirse, y una persona siempre respira antes de hablar.
  private func hablar(_ grabadora: GrabadoraEnRAM, segundos: Double) {
    let toma = AudioDePrueba.ruido(segundos: 0.5, amplitud: 0.000_3)
      + AudioDePrueba.tono(segundos: segundos)
      + AudioDePrueba.ruido(segundos: 0.5, amplitud: 0.000_3, semilla: 5)
    toma.withUnsafeBufferPointer { _ = grabadora.agregar($0) }
  }

  @Test func unFinalNormalNoGuardaNada() async throws {
    let (motor, grabadora) = armar(parakeet: MotorFalso(texto: "hola"))
    try await motor.start(locale: locale, handlers: EngineHandlers { _ in })
    hablar(grabadora, segundos: 2)
    #expect(try await motor.finish() == "hola")
    #expect(await motor.duracionDeLaTomaFallida() == nil)
    // La RAM de la toma se fue con el final.
    #expect(grabadora.cuenta == 0)
  }

  /// El caso que este archivo existe para cubrir: el motor se cae al soltar
  /// y lo dicho queda en RAM, dicho con palabras.
  @Test func siElMotorSeCaeConVozLaTomaSeGuarda() async throws {
    let avisos = AvisosDeToma()
    let (motor, grabadora) = armar()
    await motor.observarTomaFallida { avisos.agregar($0) }
    try await motor.start(locale: locale, handlers: EngineHandlers { _ in })
    hablar(grabadora, segundos: 3)

    await #expect(throws: TomaSinTexto.guardada) { try await motor.finish() }
    #expect(await motor.duracionDeLaTomaFallida() == 4)
    #expect(avisos.todos == [nil, 4])
  }

  /// Sin voz no hay dictado que perder: el error del motor sale tal cual.
  @Test func siElMotorSeCaeSinVozNoSeGuardaNada() async throws {
    let (motor, grabadora) = armar()
    try await motor.start(locale: locale, handlers: EngineHandlers { _ in })
    AudioDePrueba.ruido(segundos: 2, amplitud: 0.000_3).withUnsafeBufferPointer { _ = grabadora.agregar($0) }

    await #expect(throws: MotorQueSeCae.Caida.self) { try await motor.finish() }
    #expect(await motor.duracionDeLaTomaFallida() == nil)
  }

  @Test func elReintentoPruebaElElegidoYDespuesElOtro() async throws {
    let transcriptor = TranscriptorFalso()
    let avisos = AvisosDeToma()
    let (motor, grabadora) = armar(transcriptor: transcriptor)
    await motor.observarTomaFallida { avisos.agregar($0) }
    try await motor.start(locale: locale, handlers: EngineHandlers { _ in })
    hablar(grabadora, segundos: 2)
    _ = try? await motor.finish()
    // Al soltar, Apple tampoco pudo (todavía no tenía el idioma, digamos).
    #expect(transcriptor.aQuienes == [.apple])

    transcriptor.contestar(.parakeet, .success("  "))
    transcriptor.contestar(.apple, .success("lo que dije"))
    #expect(try await motor.reintentar() == "lo que dije")
    #expect(transcriptor.aQuienes == [.apple, .parakeet, .apple])
    // Salió: la toma se va de la RAM y el menú se entera.
    #expect(await motor.duracionDeLaTomaFallida() == nil)
    #expect(avisos.todos.last == .some(nil))
  }

  @Test func unReintentoQueTampocoSaleDejaLaTomaGuardada() async throws {
    let (motor, grabadora) = armar()
    try await motor.start(locale: locale, handlers: EngineHandlers { _ in })
    hablar(grabadora, segundos: 2)
    _ = try? await motor.finish()

    await #expect(throws: TomaSinTexto.tampocoSalio) { try await motor.reintentar() }
    #expect(await motor.duracionDeLaTomaFallida() == 3)
  }

  @Test func sinTomaNoHayReintento() async throws {
    let (motor, _) = armar()
    await #expect(throws: TomaSinTexto.sinToma) { try await motor.reintentar() }
  }

  /// Esc bota el audio de la sesión, pero no la toma de un dictado anterior
  /// que alguien todavía puede querer reintentar.
  @Test func cancelarBotaLaSesionPeroNoLaTomaGuardada() async throws {
    let (motor, grabadora) = armar()
    try await motor.start(locale: locale, handlers: EngineHandlers { _ in })
    hablar(grabadora, segundos: 2)
    _ = try? await motor.finish()

    try await motor.start(locale: locale, handlers: EngineHandlers { _ in })
    hablar(grabadora, segundos: 1)
    await motor.cancel()
    #expect(grabadora.cuenta == 0)
    #expect(await motor.duracionDeLaTomaFallida() == 3)
  }

  @Test func laTomaSeVaSolaCuandoVence() async throws {
    let reloj = RelojFalso()
    let (motor, grabadora) = armar(reloj: reloj)
    try await motor.start(locale: locale, handlers: EngineHandlers { _ in })
    hablar(grabadora, segundos: 2)
    _ = try? await motor.finish()

    // El mismo reloj cuenta el plazo de la segunda opinión que se intentó al
    // soltar; lo que importa es que la vida de la toma esté corriendo.
    try await esperarA("que la toma arme su vencimiento") {
      await reloj.esperas.contains(PoliticaDeGrabacion.vidaDeLaTomaFallida)
    }
    await reloj.avanzar()
    try await esperarA("que la toma venza") { await motor.duracionDeLaTomaFallida() == nil }
  }

  @Test func descartarLaBotaAlTiro() async throws {
    let avisos = AvisosDeToma()
    let (motor, grabadora) = armar()
    await motor.observarTomaFallida { avisos.agregar($0) }
    try await motor.start(locale: locale, handlers: EngineHandlers { _ in })
    hablar(grabadora, segundos: 2)
    _ = try? await motor.finish()

    await motor.descartarTomaFallida()
    #expect(await motor.duracionDeLaTomaFallida() == nil)
    #expect(avisos.todos == [nil, 3, nil])
  }

  /// El motor escuchó voz y no sacó nada: el otro motor transcribe el mismo
  /// audio y el dictado sale igual, sin que nadie tenga que reintentar.
  @Test func elOtroMotorRescataUnaTomaVacia() async throws {
    let transcriptor = TranscriptorFalso([.apple: .success("Te mando el informe mañana.")])
    let (motor, grabadora) = armar(parakeet: MotorFalso(texto: ""), transcriptor: transcriptor)
    try await motor.start(locale: locale, handlers: EngineHandlers { _ in })
    hablar(grabadora, segundos: 3)

    #expect(try await motor.finish() == "Te mando el informe mañana.")
    #expect(transcriptor.aQuienes == [.apple])
    #expect(await motor.duracionDeLaTomaFallida() == nil)
  }

  @Test func siElMotorSeCaeElOtroRescata() async throws {
    let transcriptor = TranscriptorFalso([.apple: .success("Lo que dije.")])
    let (motor, grabadora) = armar(transcriptor: transcriptor)
    try await motor.start(locale: locale, handlers: EngineHandlers { _ in })
    hablar(grabadora, segundos: 2)

    #expect(try await motor.finish() == "Lo que dije.")
    #expect(await motor.duracionDeLaTomaFallida() == nil)
  }

  /// Un «gracias» sobre una sala callada lo inventó el motor: no se pega, y
  /// la muesca dice que no escuchó en vez de acusar un dictado que no hubo.
  @Test func unFantasmaSobreSilencioNoSePega() async throws {
    let (motor, grabadora) = armar(parakeet: MotorFalso(texto: "¡Gracias por ver!"))
    try await motor.start(locale: locale, handlers: EngineHandlers { _ in })
    AudioDePrueba.ruido(segundos: 3, amplitud: 0.000_3).withUnsafeBufferPointer { _ = grabadora.agregar($0) }

    await #expect(throws: TomaSinTexto.nadieHablo) { try await motor.finish() }
    #expect(await motor.duracionDeLaTomaFallida() == nil)
  }

  /// El mismo «gracias», dicho de verdad, se pega.
  @Test func unGraciasConVozSePega() async throws {
    let (motor, grabadora) = armar(parakeet: MotorFalso(texto: "Gracias."))
    try await motor.start(locale: locale, handlers: EngineHandlers { _ in })
    hablar(grabadora, segundos: 0.8)
    #expect(try await motor.finish() == "Gracias.")
  }

  /// Sin audio medido —la grabadora no vio la toma— nadie puede decir que
  /// nadie habló: sale vacío, como salía siempre.
  @Test func sinAudioMedidoSaleVacioComoSiempre() async throws {
    let (motor, _) = armar(parakeet: MotorFalso(texto: ""))
    try await motor.start(locale: locale, handlers: EngineHandlers { _ in })
    #expect(try await motor.finish() == "")
  }

  /// La firma de Amara pegada al final de un dictado real se va, y lo
  /// dictado queda.
  @Test func laFirmaDeAmaraSeVaDeUnDictadoReal() async throws {
    let (motor, grabadora) = armar(
      parakeet: MotorFalso(texto: "Nos vemos el lunes en la oficina. Subtítulos realizados por la comunidad de Amara.org"))
    try await motor.start(locale: locale, handlers: EngineHandlers { _ in })
    hablar(grabadora, segundos: 2)
    #expect(try await motor.finish() == "Nos vemos el lunes en la oficina.")
  }
}
