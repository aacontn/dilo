import Foundation
import os

/// Por qué un dictado terminó sin texto que pegar. Es un error y no un texto
/// vacío porque cada caso se dice con palabras en la muesca: perder un
/// dictado en silencio está prohibido (AGENTS.md), y un «listo» sobre nada es
/// la forma más callada de perderlo.
public enum TomaSinTexto: LocalizedError, Sendable, Equatable {
  /// Hubo voz y no salió texto: la toma quedó en RAM para reintentar.
  case guardada
  /// El reintento tampoco sacó texto: la toma sigue guardada.
  case tampocoSalio
  /// No hay toma que reintentar, o venció.
  case sinToma

  public var errorDescription: String? {
    switch self {
    case .guardada:
      "No salió el texto. Guardé lo que dijiste: reinténtalo desde el menú de Dilo."
    case .tampocoSalio:
      "Tampoco salió. La grabación sigue guardada."
    case .sinToma:
      "Ya no hay ninguna grabación guardada."
    }
  }
}

/// El **Motor de voz** que guarda la toma.
///
/// Envuelve al router sin cambiarle el contrato: el resto de la app sigue
/// hablando con un `SpeechEngine`. Lo que agrega es la red bajo el soltar. El
/// audio de la sesión vive en una `GrabadoraEnRAM` que llena el micrófono, y
/// si el motor se cae al soltar —Core ML que falla, un analizador que no
/// termina— lo dicho no se pierde: queda **una** toma en RAM, nunca en
/// disco, para reintentarla con el mismo motor o con el otro sin volver a
/// hablar. Se va sola a los diez minutos (`PoliticaDeGrabacion`).
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
  private var tomaFallida: TomaFallida?
  private var vencimiento: Task<Void, Never>?
  /// A quién avisarle que hay —o que ya no hay— una toma guardada, con su
  /// duración. Lo escucha el menú de la barra.
  private var avisar: (@Sendable (TimeInterval?) -> Void)?

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

  public func prewarm(locale: Locale) async throws {
    try await motores.prewarm(locale: locale)
  }

  public func start(locale: Locale, handlers: EngineHandlers) async throws {
    // Lo que haya quedado de una sesión anterior —un búfer que llegó tarde
    // después de parar— no es de esta.
    grabadora.descartar()
    idioma = locale
    try await motores.start(locale: locale, handlers: handlers)
  }

  public func finish() async throws -> String {
    let resultado: Result<String, any Error>
    do {
      resultado = .success(try await motores.finish())
    } catch {
      resultado = .failure(error)
    }
    // Después del `finish` del motor y no antes: es el que para el micrófono,
    // y lo que se dijo justo al soltar también es parte de la toma.
    let toma = grabadora.tomar()

    switch resultado {
    case let .success(texto):
      return texto
    case let .failure(error):
      // El motor se cayó, pero lo dicho está en RAM. Una toma sin voz no vale
      // un rescate: ahí se dice el error del motor, como siempre.
      guard let idioma, MedidaDeToma.medir(toma.comoFloat()).huboVoz else { throw error }
      Self.logger.error("el motor falló al soltar; la toma queda en RAM: \(error.localizedDescription, privacy: .public)")
      guardar(TomaFallida(audio: toma, idioma: idioma))
      throw TomaSinTexto.guardada
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
    let preferido = await motores.seleccion().efectivo
    for motor in [preferido, preferido.otro] {
      do {
        let texto = try await transcribir(motor, muestras, toma.idioma)
          .trimmingCharacters(in: .whitespacesAndNewlines)
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
