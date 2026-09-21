import Foundation

/// El **Motor de voz** de Apple (`SpeechTranscriber`), que es el que Talkify
/// ya tiene andando en `Talkify/Dictation/SpeechRecognitionService.swift`.
///
/// Acá no se reimplementa nada: el actor de Talkify sigue siendo el dueño de
/// SpeechAnalyzer, de las reservas de `AssetInventory` y de las sesiones
/// tibias por idioma. `AppleEngine` sólo le pone encima el contrato, con una
/// estructura de closures —el mismo patrón de
/// `DirectDictationController.Dependencies`— para que este paquete no tenga
/// que ver el árbol de la app y los tests puedan correr sin micrófono.
public actor AppleEngine: SpeechEngine {
  public struct Bridge: Sendable {
    public let prewarm: @Sendable (Locale) async throws -> Void
    public let start: @Sendable (Locale, EngineHandlers) async throws -> Void
    public let finish: @Sendable () async throws -> String
    public let cancel: @Sendable () async -> Void

    public init(
      prewarm: @escaping @Sendable (Locale) async throws -> Void,
      start: @escaping @Sendable (Locale, EngineHandlers) async throws -> Void,
      finish: @escaping @Sendable () async throws -> String,
      cancel: @escaping @Sendable () async -> Void
    ) {
      self.prewarm = prewarm
      self.start = start
      self.finish = finish
      self.cancel = cancel
    }
  }

  private let bridge: Bridge

  public init(bridge: Bridge) {
    self.bridge = bridge
  }

  public func prewarm(locale: Locale) async throws {
    try await bridge.prewarm(locale)
  }

  public func start(locale: Locale, handlers: EngineHandlers) async throws {
    try await bridge.start(locale, handlers)
  }

  public func finish() async throws -> String {
    try await bridge.finish()
  }

  public func cancel() async {
    await bridge.cancel()
  }
}
