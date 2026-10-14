import Foundation
import Synchronization
import os

/// Por qué un dictado terminó sin texto que pegar. Es un error y no un texto
/// vacío porque cada caso se dice con palabras en la muesca: perder un
/// dictado en silencio está prohibido (AGENTS.md), y un «listo» sobre nada es
/// la forma más callada de perderlo.
public enum TomaSinTexto: LocalizedError, Sendable, Equatable {
  /// La toma no tenía voz: un apretón sin querer, o el micrófono lejos.
  case nadieHablo
  /// Hubo voz y no salió texto: la toma quedó en RAM para reintentar.
  case guardada
  /// El reintento tampoco sacó texto: la toma sigue guardada.
  case tampocoSalio
  /// No hay toma que reintentar, o venció.
  case sinToma

  public var errorDescription: String? {
    switch self {
    case .nadieHablo:
      "No te escuché."
    case .guardada:
      "No salió el texto. Guardé lo que dijiste: reinténtalo desde el menú de Dilo."
    case .tampocoSalio:
      "Tampoco salió. La grabación sigue guardada."
    case .sinToma:
      "Ya no hay ninguna grabación guardada."
    }
  }
}

/// El **Motor de voz** que guarda la toma y revisa lo que sale.
///
/// Envuelve al router sin cambiarle el contrato: el resto de la app sigue
/// hablando con un `SpeechEngine`. Lo que agrega es la red bajo el soltar. El
/// audio de la sesión vive en una `GrabadoraEnRAM` que llena el micrófono, y
/// lo que el motor devuelve pasa por `RevisionDeToma`: se le sacan los
/// tokens, las firmas de subtítulos, los fantasmas sobre silencio y los
/// bucles. Si no queda texto —o el motor se cayó— y hubo voz, se le pide al
/// otro motor que transcriba el mismo audio. Si tampoco sale, lo dicho no se
/// pierde: queda **una** toma en RAM, nunca en disco, para reintentarla sin
/// volver a hablar. Se va sola a los diez minutos (`PoliticaDeGrabacion`).
public actor MotorConRespaldo: SpeechEngine {
  /// Transcribe audio que ya está en RAM con el motor pedido. Lanza si ese
  /// motor no puede ahora (Parakeet sin descargar, Apple sin el idioma).
  public typealias TranscribirDesdeRAM =
    @Sendable (SpeechEngineKind, [Float], Locale) async throws -> String

  private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "engines")

  private let motores: SpeechEngineRouter
  private let grabadora: GrabadoraEnRAM
  private let transcribir: TranscribirDesdeRAM
  private let reloj: any RelojDeReposo

  /// El idioma de la sesión en curso, para que una toma guardada se
  /// reintente en el mismo.
  private var idioma: Locale?
  /// Qué motor escuchó la sesión en curso: la segunda opinión es la del otro.
  private var ultimoMotor: SpeechEngineKind?
  private var tomaFallida: TomaFallida?
  private var vencimiento: Task<Void, Never>?
  /// A quién avisarle que hay —o que ya no hay— una toma guardada, con su
  /// duración. Lo escucha el menú de la barra.
  private var avisar: (@Sendable (TimeInterval?) -> Void)?
  /// Lo que tardó la revisión del último soltar —la segunda opinión incluida,
  /// si hizo falta—, para la latencia por fase de la app. Nil hasta que un
  /// soltar llega a revisarse.
  private var ultimaRevision: Duration?

  public init(
    motores: SpeechEngineRouter,
    grabadora: GrabadoraEnRAM,
    reloj: any RelojDeReposo = RelojDelSistema(),
    transcribir: @escaping TranscribirDesdeRAM
  ) {
    self.motores = motores
    self.grabadora = grabadora
    self.reloj = reloj
    self.transcribir = transcribir
  }

  public func observarTomaFallida(_ handler: @escaping @Sendable (TimeInterval?) -> Void) {
    avisar = handler
    handler(tomaFallida?.audio.duracion)
  }

  /// La duración de la toma guardada, o nil si no hay ninguna.
  public func duracionDeLaTomaFallida() -> TimeInterval? {
    tomaFallida?.audio.duracion
  }

  /// Lo que tardó la revisión del último `finish`, o nil si no llegó a
  /// revisarse.
  public func duracionDeLaUltimaRevision() -> Duration? {
    ultimaRevision
  }

  public func prewarm(locale: Locale) async throws {
    try await motores.prewarm(locale: locale)
  }

  public func start(locale: Locale, handlers: EngineHandlers) async throws {
    // Lo que haya quedado de una sesión anterior —un búfer que llegó tarde
    // después de parar— no es de esta.
    grabadora.descartar()
    idioma = locale
    ultimoMotor = nil
    try await motores.start(locale: locale, handlers: handlers)
    ultimoMotor = await motores.motorDeLaUltimaSesion()
  }

  public func finish() async throws -> String {
    ultimaRevision = nil
    let resultado: Result<String, any Error>
    do {
      resultado = .success(try await motores.finish())
    } catch {
      resultado = .failure(error)
    }
    let antesDeRevisar = ContinuousClock.now
    defer { ultimaRevision = antesDeRevisar.duration(to: .now) }
    // Después del `finish` del motor y no antes: es el que para el micrófono,
    // y lo que se dijo justo al soltar también es parte de la toma.
    let toma = grabadora.tomar()
    let muestras = toma.comoFloat()
    // Unos milisegundos para un minuto de audio (`GrabacionEnRAMTests`): lo
    // único que el camino feliz le suma a soltar→texto.
    let medida = MedidaDeToma.medir(muestras)
    let otroMotor = segundaOpinion(muestras, medida: medida)

    let veredicto: RevisionDeToma.Veredicto
    switch resultado {
    case let .success(crudo):
      veredicto = await RevisionDeToma.revisar(crudo: crudo, medida: medida, otroMotor: otroMotor)
    case let .failure(error):
      // El motor se cayó, pero lo dicho está en RAM. Una toma sin voz no vale
      // un rescate: ahí se dice el error del motor, como siempre.
      guard idioma != nil, medida.huboVoz else { throw error }
      Self.logger.error("el motor falló al soltar: \(error.localizedDescription, privacy: .public)")
      veredicto = await RevisionDeToma.revisar(crudo: "", medida: medida, otroMotor: otroMotor)
    }

    switch veredicto {
    case let .texto(texto):
      return texto
    case .nadieHablo:
      // Sin audio medido —una toma que la grabadora no vio— no se puede
      // decir que nadie habló: sale vacío, como siempre salió.
      guard medida.hayAudio else { return "" }
      throw TomaSinTexto.nadieHablo
    case .fallida:
      guard let idioma else { return "" }
      Self.logger.notice("ningún motor sacó texto de una toma con voz; queda en RAM")
      guardar(TomaFallida(audio: toma, idioma: idioma))
      throw TomaSinTexto.guardada
    }
  }

  /// La segunda opinión sobre esta toma: el otro motor, con plazo. Nil si no
  /// se sabe quién escuchó o en qué idioma.
  private func segundaOpinion(_ muestras: [Float], medida: MedidaDeToma) -> (@Sendable () async -> String?)? {
    guard let idioma, let escucho = ultimoMotor else { return nil }
    let transcribir = self.transcribir
    let reloj = self.reloj
    let plazo = Self.plazoDeSegundaOpinion(para: medida.duracion)
    return {
      await Self.conPlazo(plazo, reloj: reloj) {
        try await transcribir(escucho.otro, muestras, idioma)
      }
    }
  }

  /// Cuánto se espera a la segunda opinión antes de rendirse y guardar la
  /// toma. Es un rescate, así que puede tardar más que un dictado; pero un
  /// motor colgado no puede dejar la muesca procesando para siempre.
  static func plazoDeSegundaOpinion(para duracion: TimeInterval) -> Duration {
    .seconds(5) + .milliseconds(Int(duracion * 500))
  }

  /// Corre `trabajo` y devuelve lo que dé, o nil si lanza o si pasa el plazo.
  /// El trabajo que se pasa del plazo se cancela y se deja de esperar.
  static func conPlazo(
    _ plazo: Duration,
    reloj: any RelojDeReposo,
    _ trabajo: @escaping @Sendable () async throws -> String
  ) async -> String? {
    let respuesta = UnaSolaRespuesta()
    return await withCheckedContinuation { continuacion in
      respuesta.esperar(continuacion)
      let tarea = Task {
        let texto = try? await trabajo()
        respuesta.dar(texto)
      }
      let vencimiento = Task {
        do { try await reloj.dormir(plazo) } catch { return }
        tarea.cancel()
        respuesta.dar(nil)
      }
      respuesta.alTerminar { vencimiento.cancel() }
    }
  }

  public func cancel() async {
    // Un dictado cancelado no deja audio en RAM. La toma fallida no es de
    // esta sesión y se queda.
    grabadora.descartar()
    await motores.cancel()
  }

  /// Pasa la toma guardada otra vez: primero por el motor elegido ahora y,
  /// si no saca nada, por el otro. Devuelve el texto o lanza `TomaSinTexto`;
  /// si no sale, la toma se queda —con el reloj de vida desde cero— para
  /// otro intento.
  public func reintentar() async throws -> String {
    guard let toma = tomaFallida, !toma.vencida() else {
      olvidarLaToma()
      throw TomaSinTexto.sinToma
    }
    let muestras = toma.audio.comoFloat()
    let medida = MedidaDeToma.medir(muestras)
    let preferido = await motores.seleccion().efectivo
    for motor in [preferido, preferido.otro] {
      do {
        // Lo que salga pasa por la misma revisión que un dictado: un reintento
        // no es excusa para pegar un «[BLANK_AUDIO]».
        let texto = RevisionDeToma.depurar(
          try await transcribir(motor, muestras, toma.idioma), medida
        ).texto
        if !texto.isEmpty {
          olvidarLaToma()
          return texto
        }
      } catch {
        Self.logger.notice("reintento con \(motor.title, privacy: .public) falló: \(error.localizedDescription, privacy: .public)")
      }
    }
    guardar(TomaFallida(audio: toma.audio, idioma: toma.idioma))
    throw TomaSinTexto.tampocoSalio
  }

  /// La persona dijo que no la quiere. Se va de la RAM al tiro.
  public func descartarTomaFallida() {
    olvidarLaToma()
  }

  /// Guarda una toma —reemplazando la anterior, si había— y arma su
  /// vencimiento.
  private func guardar(_ toma: TomaFallida) {
    tomaFallida = toma
    vencimiento?.cancel()
    let reloj = self.reloj
    vencimiento = Task { [weak self] in
      do { try await reloj.dormir(PoliticaDeGrabacion.vidaDeLaTomaFallida) } catch { return }
      guard !Task.isCancelled else { return }
      await self?.vencer(toma.cuando)
    }
    avisar?(toma.audio.duracion)
  }

  /// Vence la toma, si sigue siendo la misma que armó este reloj.
  private func vencer(_ cuando: ContinuousClock.Instant) {
    guard tomaFallida?.cuando == cuando else { return }
    olvidarLaToma()
  }

  private func olvidarLaToma() {
    vencimiento?.cancel()
    vencimiento = nil
    guard tomaFallida != nil else { return }
    tomaFallida = nil
    avisar?(nil)
  }
}

/// Una continuación que se reanuda una sola vez, gane quien gane la carrera
/// entre el trabajo y el plazo.
private final class UnaSolaRespuesta: Sendable {
  private struct Estado {
    var continuacion: CheckedContinuation<String?, Never>?
    var alTerminar: (@Sendable () -> Void)?
    var terminada = false
  }

  private let estado = Mutex(Estado())

  func esperar(_ continuacion: CheckedContinuation<String?, Never>) {
    estado.withLock { $0.continuacion = continuacion }
  }

  func alTerminar(_ accion: @escaping @Sendable () -> Void) {
    let yaTermino = estado.withLock { estado -> Bool in
      guard !estado.terminada else { return true }
      estado.alTerminar = accion
      return false
    }
    if yaTermino { accion() }
  }

  func dar(_ texto: String?) {
    let (continuacion, accion) = estado.withLock { estado -> (CheckedContinuation<String?, Never>?, (@Sendable () -> Void)?) in
      guard !estado.terminada else { return (nil, nil) }
      estado.terminada = true
      defer {
        estado.continuacion = nil
        estado.alTerminar = nil
      }
      return (estado.continuacion, estado.alTerminar)
    }
    continuacion?.resume(returning: texto)
    accion?()
  }
}
