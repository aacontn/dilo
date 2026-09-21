import Foundation

/// Un parcial del dictado: lo que el motor ya dio por firme y lo que todavía
/// puede cambiar mientras la persona sigue hablando.
///
/// Los dos van separados porque el HUD los dibuja distinto: lo firme queda
/// quieto y lo volátil parpadea. Juntarlos en un solo `String` obligaría a
/// cada superficie a adivinar dónde termina uno y empieza el otro.
public struct EngineUpdate: Sendable, Equatable {
  public let finalizado: String
  public let volatil: String

  public init(finalizado: String, volatil: String) {
    self.finalizado = finalizado
    self.volatil = volatil
  }

  public var texto: String { finalizado + volatil }
}

/// Lo que el motor le cuenta a la sesión mientras corre: el flujo de
/// parciales, una falla que termina la sesión, y el nivel del micrófono para
/// el visual del HUD.
///
/// Es una estructura de closures y no tres parámetros sueltos porque los tres
/// viajan siempre juntos y ninguno tiene sentido sin los otros.
public struct EngineHandlers: Sendable {
  public let parcial: @Sendable (EngineUpdate) -> Void
  public let falla: @Sendable (String) -> Void
  public let nivel: @Sendable (Float) -> Void

  public init(
    parcial: @escaping @Sendable (EngineUpdate) -> Void,
    falla: @escaping @Sendable (String) -> Void = { _ in },
    nivel: @escaping @Sendable (Float) -> Void = { _ in }
  ) {
    self.parcial = parcial
    self.falla = falla
    self.nivel = nivel
  }
}

/// El contrato del **Motor de voz** (CONTEXT.md): apretar, hablar, soltar.
/// Nada del resto de la app sabe cuál corre.
///
/// Es un `Actor` y no una clase porque los dos motores reales guardan estado
/// de sesión que el micrófono toca desde otro hilo; el aislamiento lo da el
/// contrato y no la disciplina de quien lo implemente.
public protocol SpeechEngine: Actor {
  /// Deja el motor listo para este idioma sin arrancar una sesión. Es
  /// idempotente y puede tardar: es acá donde se descarga o se carga un
  /// modelo, nunca en `start`.
  func prewarm(locale: Locale) async throws

  /// Arranca la sesión. Vuelve cuando el motor ya está escuchando.
  func start(locale: Locale, handlers: EngineHandlers) async throws

  /// Cierra la sesión y entrega el texto completo. Es el momento que el spec
  /// mide: soltar → texto en menos de 300 ms.
  func finish() async throws -> String

  /// Abandona la sesión sin texto. Nunca lanza: cancelar es lo que se hace
  /// cuando algo ya salió mal.
  func cancel() async
}

extension SpeechEngine {
  /// Un motor que no tiene nada que precargar no tiene que decirlo.
  public func prewarm(locale: Locale) async throws {}
}

public enum EngineError: LocalizedError, Sendable {
  case sesionActiva
  case sinSesion
  case modeloNoDescargado
  case modeloNoCargado
  case sinMicrofono

  public var errorDescription: String? {
    switch self {
    case .sesionActiva:
      "Ya hay un dictado andando."
    case .sinSesion:
      "No hay ningún dictado andando."
    case .modeloNoDescargado:
      "El motor Parakeet todavía no está descargado."
    case .modeloNoCargado:
      "El motor Parakeet no alcanzó a cargar."
    case .sinMicrofono:
      "No hay micrófono disponible."
    }
  }
}
