import Foundation

@testable import DiloEngines

/// Un **Motor de voz** que no oye nada y contesta lo que uno le diga. Sirve
/// para probar el contrato —quién arranca, quién termina, qué pasa si se
/// llama dos veces— sin micrófono, sin modelo y sin red.
actor MotorFalso: SpeechEngine {
  private let texto: String
  private(set) var arranques = 0
  private(set) var cierres = 0
  private(set) var cancelaciones = 0
  private(set) var precalentamientos = 0
  private(set) var ultimoLocale: Locale?
  private var handlers: EngineHandlers?
  private var activa = false

  init(texto: String = "hola") {
    self.texto = texto
  }

  func prewarm(locale: Locale) async throws {
    precalentamientos += 1
  }

  func start(locale: Locale, handlers: EngineHandlers) async throws {
    guard !activa else { throw EngineError.sesionActiva }
    activa = true
    arranques += 1
    ultimoLocale = locale
    self.handlers = handlers
  }

  /// Simula que el motor entregó un parcial mientras la persona habla.
  func emitir(_ parcial: EngineUpdate) {
    handlers?.parcial(parcial)
  }

  func finish() async throws -> String {
    guard activa else { throw EngineError.sinSesion }
    activa = false
    cierres += 1
    handlers = nil
    return texto
  }

  func cancel() async {
    guard activa else { return }
    activa = false
    cancelaciones += 1
    handlers = nil
  }
}
