import DiloEngines
import Foundation

/// El **Motor de voz** del dictado, prestado a la **Conversación** por su
/// contrato (`SpeechEngine`): empezar a escuchar, terminar y entregar el
/// texto, o cancelar. La conversación no sabe si escucha Parakeet o Apple,
/// igual que el dictado.
///
/// Lo arma `DirectDictationController.Dependencies.live` con el mismo router
/// de motores, para que haya **un** modelo de Parakeet en la RAM y no dos.
/// Como el router atiende una sesión a la vez, la conversación y el dictado
/// no escuchan juntos: mientras hay conversación, el gatillo del dictado le
/// da el turno a la persona (`DirectDictationController.hayConversacion`).
struct MotorParaConversar: Sendable {
  var empezar: @Sendable (Locale, EleccionDeMicrofono, EngineHandlers) async throws -> Void
  var terminar: @Sendable () async throws -> String
  var cancelar: @Sendable () async -> Void
  /// El idioma del dictado resuelto a lo que el motor sabe escuchar.
  var locale: @Sendable (String) async throws -> Locale
}
