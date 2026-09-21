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
  /// El motor está cargando su modelo en la RAM mientras la persona ya está
  /// hablando, y después que terminó. Es un aviso y no una falla: el dictado
  /// no se pierde, sólo espera. Un motor que no carga nada nunca lo llama.
  public let cargando: @Sendable (Bool) -> Void

  public init(
    parcial: @escaping @Sendable (EngineUpdate) -> Void,
    falla: @escaping @Sendable (String) -> Void = { _ in },
    nivel: @escaping @Sendable (Float) -> Void = { _ in },
    cargando: @escaping @Sendable (Bool) -> Void = { _ in }
  ) {
    self.parcial = parcial
    self.falla = falla
    self.nivel = nivel
    self.cargando = cargando
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
  /// idempotente y puede tardar: es acá donde un motor reserva lo que el
  /// sistema le presta —los analizadores de Apple, el idioma— antes de que
  /// alguien apriete el gatillo.
  ///
  /// **Lo que no va acá es un modelo propio en la RAM.** Precalentar corre al
  /// arrancar la app y cada vez que cambian los idiomas: cargar ahí los 469 MB
  /// de Parakeet subió el reposo de 18,8 MB a 46,4 MB para una app que quizá
  /// nadie use esa tarde (plan, Tarea 9). Ese modelo se carga al `start`, en
  /// paralelo a la grabación, y se suelta solo (`MotorConModeloEnMemoria`).
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

/// Un motor que carga un modelo propio en la RAM y lo puede soltar.
///
/// Está aparte de `SpeechEngine` porque es cierto de uno solo: el motor de
/// Apple usa los modelos del sistema y no tiene RAM que devolver. Quien arma
/// el motor doble pregunta por este protocolo y no por el tipo concreto, así
/// que los tests siguen pudiendo poner un motor falso donde va Parakeet.
public protocol MotorConModeloEnMemoria: SpeechEngine {
  /// Cada cuánto se suelta el modelo si nadie dicta. `nil` es "nunca".
  func configurarReposo(_ intervalo: Duration?) async

  /// Suelta el modelo ahora. El dictado siguiente lo vuelve a cargar.
  func descargarDeMemoria() async

  /// Si el modelo está cargado en este momento.
  func tieneModeloEnMemoria() async -> Bool
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
