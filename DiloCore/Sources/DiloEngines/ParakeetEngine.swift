import FluidAudio
import Foundation
import os

/// El **Motor de voz** Parakeet TDT v3 (int8) corriendo en Core ML, por
/// FluidAudio (Apache 2.0).
///
/// Acumula el audio mientras la persona habla y transcribe el buffer completo
/// al soltar: el modelo es batch, no streaming, así que esa pasada final es la
/// que manda. Los parciales de en medio son una cortesía para que el HUD no
/// esté mudo, y se calculan sobre los trozos nuevos arrastrando el estado del
/// decoder, que cuesta lineal en vez de cuadrático.
///
/// **Medido en este M1** (16 GB, macOS 27) con un dictado de 8,9 s hecho con
/// `say -v Mónica`, 5 repeticiones tras una pasada de calentamiento
/// (`MedicionDeMotoresTests`):
///
/// | | soltar → texto |
/// | --- | --- |
/// | Parakeet v3 int8, buffer de 8,9 s | **198 ms** (min 198, max 206) |
/// | Apple `SpeechTranscriber`, mismo audio en vivo | **35 ms** (min 32, max 76) |
///
/// Los dos pasan los 300 ms del spec §3. Apple llega antes porque transcribe
/// mientras hablas y al soltar sólo le queda cerrar; Parakeet transcribe todo
/// de una y a cambio pone las comas donde van —en esta misma frase Apple se
/// comió tres— y dicta igual en cualquier Mac.
///
/// El modelo pesa **469 MB** en disco (23 archivos, int8) y se baja en ~60 s
/// con fibra. La primera compilación del encoder a Core ML cuesta **28 s** y
/// pasa una sola vez, dentro de la descarga: por eso la barra termina en
/// "Preparando el modelo…" y no en 100 %.
public actor ParakeetEngine: SpeechEngine {
  private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "engines")

  /// Parakeet trabaja a 16 kHz mono. No es configurable: es el modelo.
  public static let sampleRate: Double = 16_000

  /// Cada cuánto se intenta un parcial. Dos segundos es el trozo más corto
  /// que le da al TDT contexto suficiente para no cortar palabras a la mitad.
  private static let segundosPorParcial: Double = 2

  /// **Los parciales están encendidos porque salen baratos en este M1.**
  /// Un trozo de 2 s se transcribe en **124 ms** arrastrando el estado del
  /// decoder: 6 % de ocupación mientras la persona habla, y nunca dos a la
  /// vez. Si en una máquina más lenta esto empezara a morder, se apaga acá y
  /// el HUD queda mostrando sólo la forma de onda hasta que sueltas.
  private static let parcialesEncendidos = true

  private let captura: any AudioCapture
  private let almacen: ParakeetModelStore
  private var manager: AsrManager?
  /// La carga del modelo en vuelo. Existe para que apretar el gatillo justo
  /// después de descargar el modelo no espere dos segundos antes de empezar a
  /// grabar: la captura arranca al tiro y el modelo termina de cargar
  /// mientras la persona habla, que es cuando no cuesta nada.
  private var carga: Task<AsrManager, any Error>?

  private var handlers: EngineHandlers?
  private var activa = false
  private var muestras: [Float] = []
  /// Hasta dónde ya se leyó para parciales.
  private var leidoHastaParcial = 0
  private var textoParcial = ""
  private var estadoParcial: TdtDecoderState?
  /// Un parcial a la vez: si el anterior no ha terminado, este trozo espera
  /// al siguiente turno en vez de apilar trabajo sobre el Neural Engine.
  private var parcialEnVuelo = false

  public init(captura: any AudioCapture, almacen: ParakeetModelStore = ParakeetModelStore()) {
    self.captura = captura
    self.almacen = almacen
  }

  public var estaListo: Bool { manager != nil }

  public func prewarm(locale: Locale) async throws {
    _ = try await cargarModelo()
  }

  /// Carga el modelo una sola vez, aunque se lo pidan tres veces seguidas.
  private func cargarModelo() async throws -> AsrManager {
    if let manager { return manager }
    if let carga { return try await carga.value }

    let almacen = self.almacen
    let tarea = Task { () throws -> AsrManager in
      let modelos = try await almacen.cargar()
      let nuevo = AsrManager(config: .default)
      try await nuevo.loadModels(modelos)
      return nuevo
    }
    carga = tarea

    do {
      let listo = try await tarea.value
      manager = listo
      carga = nil
      Self.logger.info("Parakeet cargado y listo")
      return listo
    } catch {
      carga = nil
      throw error
    }
  }

  /// Suelta el modelo de la RAM. La sesión siguiente lo vuelve a cargar.
  public func descargarDeMemoria() async {
    guard let manager else { return }
    await manager.cleanup()
    self.manager = nil
  }

  public func start(locale: Locale, handlers: EngineHandlers) async throws {
    guard !activa else { throw EngineError.sesionActiva }
    guard ParakeetModelStore.estaDescargado else { throw EngineError.modeloNoDescargado }

    // El modelo se carga en paralelo a la grabación: recién se necesita al
    // soltar. Grabar desde el primer milisegundo importa más que tenerlo todo
    // listo antes de escuchar.
    if manager == nil, carga == nil {
      Task { _ = try? await self.cargarModelo() }
    }

    muestras.removeAll(keepingCapacity: true)
    leidoHastaParcial = 0
    textoParcial = ""
    estadoParcial = nil
    parcialEnVuelo = false
    self.handlers = handlers
    activa = true

    do {
      try captura.iniciar(
        sampleRate: Self.sampleRate,
        muestras: { [weak self] trozo in
          Task { await self?.recibir(trozo) }
        },
        nivel: handlers.nivel,
        falla: handlers.falla
      )
    } catch {
      activa = false
      self.handlers = nil
      throw error
    }
  }

  public func finish() async throws -> String {
    guard activa else { throw EngineError.sinSesion }
    activa = false
    captura.detener()
    handlers = nil

    let audio = muestras
    muestras.removeAll(keepingCapacity: false)
    // Un apretón sin voz no vale una pasada por el modelo.
    guard audio.count > Int(Self.sampleRate * 0.2) else { return "" }

    let manager = try await cargarModelo()
    var estado = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
    let resultado = try await manager.transcribe(audio, decoderState: &estado, language: .spanish)
    return resultado.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func cancel() async {
    guard activa else { return }
    activa = false
    captura.detener()
    handlers = nil
    muestras.removeAll(keepingCapacity: false)
    textoParcial = ""
    estadoParcial = nil
  }

  private func recibir(_ trozo: [Float]) {
    guard activa else { return }
    muestras.append(contentsOf: trozo)
    guard Self.parcialesEncendidos, !parcialEnVuelo else { return }

    let pendientes = muestras.count - leidoHastaParcial
    guard pendientes >= Int(Self.sampleRate * Self.segundosPorParcial) else { return }

    let corte = muestras.count
    let nuevo = Array(muestras[leidoHastaParcial..<corte])
    leidoHastaParcial = corte
    parcialEnVuelo = true
    Task { await self.transcribirParcial(nuevo) }
  }

  private func transcribirParcial(_ trozo: [Float]) async {
    defer { parcialEnVuelo = false }
    // Mientras el modelo no haya terminado de cargar no hay parcial que dar;
    // el trozo se pierde y el texto de verdad igual sale de la pasada final.
    guard activa, let manager else { return }
    if estadoParcial == nil {
      estadoParcial = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
    }
    guard activa, var estado = estadoParcial else { return }

    do {
      let resultado = try await manager.transcribe(
        trozo, decoderState: &estado, language: .spanish
      )
      estadoParcial = estado
      guard activa else { return }
      textoParcial += resultado.text
      // Todo lo que Parakeet entrega ya viene firme: el modelo no revisa lo
      // que dijo. Por eso no hay nada volátil que mostrar.
      handlers?.parcial(EngineUpdate(finalizado: textoParcial, volatil: ""))
    } catch {
      // Un parcial que falla no rompe la sesión: el texto de verdad sale de
      // la pasada final sobre el buffer entero.
      Self.logger.debug("parcial de Parakeet falló: \(error.localizedDescription, privacy: .public)")
    }
  }
}
