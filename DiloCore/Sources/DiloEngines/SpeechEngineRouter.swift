import Foundation

/// El que decide cuál **Motor de voz** corre y se lo esconde al resto de la
/// app. Es un `SpeechEngine` más: la sesión de dictado habla con esto y nunca
/// pregunta qué hay detrás.
///
/// `finish()` y `cancel()` van siempre al motor que arrancó la sesión, aunque
/// la persona cambie de motor en Ajustes a media frase: la foto de los
/// ajustes se congela al apretar el gatillo (CONTEXT.md) y el texto tiene que
/// salir de quien escuchó.
public actor SpeechEngineRouter: SpeechEngine {
  private let apple: any SpeechEngine
  private let parakeet: any SpeechEngine
  /// Si el modelo de Parakeet está en disco **ahora**. Se pregunta cada vez y
  /// no se cachea: la descarga termina mientras la app está abierta.
  private let parakeetDescargado: @Sendable () -> Bool
  /// Se llama cuando lo elegido no es lo que va a correr. Una caída callada
  /// es peor que la caída.
  private let avisar: @Sendable (EngineSelection) -> Void

  private var elegido: SpeechEngineKind
  private var enCurso: (any SpeechEngine)?
  private var ultimoAviso: String?

  public init(
    apple: any SpeechEngine,
    parakeet: any SpeechEngine,
    elegido: SpeechEngineKind = .porDefecto,
    parakeetDescargado: @escaping @Sendable () -> Bool,
    avisar: @escaping @Sendable (EngineSelection) -> Void = { _ in }
  ) {
    self.apple = apple
    self.parakeet = parakeet
    self.elegido = elegido
    self.parakeetDescargado = parakeetDescargado
    self.avisar = avisar
  }

  /// La elección de Ajustes. Aplica al próximo dictado, como todo lo demás.
  public func elegir(_ motor: SpeechEngineKind) {
    elegido = motor
  }

  public func seleccion() -> EngineSelection {
    EngineResolver.resolver(elegido: elegido, parakeetDescargado: parakeetDescargado())
  }

  /// Por qué el último dictado no corrió con el motor elegido, o nil si sí.
  public func avisoVigente() -> String? { ultimoAviso }

  public func prewarm(locale: Locale) async throws {
    try await motor(for: seleccion().efectivo).prewarm(locale: locale)
  }

  public func start(locale: Locale, handlers: EngineHandlers) async throws {
    guard enCurso == nil else { throw EngineError.sesionActiva }

    let eleccion = seleccion()
    ultimoAviso = eleccion.aviso
    if eleccion.cayoAApple { avisar(eleccion) }

    let elegidoAhora = motor(for: eleccion.efectivo)
    try await elegidoAhora.start(locale: locale, handlers: handlers)
    enCurso = elegidoAhora
  }

  public func finish() async throws -> String {
    guard let enCurso else { throw EngineError.sinSesion }
    self.enCurso = nil
    return try await enCurso.finish()
  }

  public func cancel() async {
    guard let enCurso else { return }
    self.enCurso = nil
    await enCurso.cancel()
  }

  private func motor(for kind: SpeechEngineKind) -> any SpeechEngine {
    switch kind {
    case .apple: apple
    case .parakeet: parakeet
    }
  }
}
