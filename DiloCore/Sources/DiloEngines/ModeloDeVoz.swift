import FluidAudio
import Foundation

/// Un modelo de voz ya cargado en la RAM, visto desde el motor.
///
/// Existe para que `ParakeetEngine` no hable con FluidAudio directo. Las
/// reglas que importan —cuándo se carga, qué pasa si sueltas antes de que
/// esté, cuándo se suelta de la memoria— se prueban con `swift test`, y un
/// `AsrManager` de verdad pide 469 MB en disco y medio minuto de Core ML.
public protocol ModeloDeVoz: Sendable {
  /// La pasada final sobre el buffer entero, con estado propio: es la que
  /// manda y no arrastra nada de los parciales.
  func transcribir(_ muestras: [Float]) async throws -> String

  /// Un trozo nuevo arrastrando el estado del decoder, que cuesta lineal en
  /// vez de cuadrático.
  func transcribirParcial(_ trozo: [Float]) async throws -> String

  /// Olvida el estado de parciales: lo que viene es otra sesión.
  func reiniciarParciales() async

  /// Suelta lo que ocupa en RAM.
  func liberar() async
}

/// De dónde sale un modelo cargado, y si hay algo que cargar.
public protocol CargadorDeModelo: Sendable {
  /// Si el modelo está en disco **ahora**. Se pregunta cada vez y no se
  /// cachea: la descarga termina con la app abierta.
  var disponible: Bool { get }

  /// Lee el modelo del disco y lo deja listo para transcribir. Tarda: en un
  /// M1 ocioso son unos veinte segundos la primera vez.
  func cargar() async throws -> any ModeloDeVoz
}

/// El cargador de verdad: lee lo que ya está descargado y arma el
/// `AsrManager` de FluidAudio.
public struct CargadorDeParakeet: CargadorDeModelo {
  private let almacen: ParakeetModelStore

  public init(almacen: ParakeetModelStore = ParakeetModelStore()) {
    self.almacen = almacen
  }

  public var disponible: Bool { ParakeetModelStore.estaDescargado }

  public func cargar() async throws -> any ModeloDeVoz {
    let modelos = try await almacen.cargar()
    let manager = AsrManager(config: .default)
    try await manager.loadModels(modelos)
    return ModeloDeParakeet(manager: manager)
  }
}

/// Parakeet cargado: el `AsrManager` y el estado del decoder que los parciales
/// arrastran de un trozo al siguiente.
actor ModeloDeParakeet: ModeloDeVoz {
  private let manager: AsrManager
  private var estadoParcial: TdtDecoderState?

  init(manager: AsrManager) {
    self.manager = manager
  }

  func transcribir(_ muestras: [Float]) async throws -> String {
    var estado = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
    let resultado = try await manager.transcribe(
      muestras, decoderState: &estado, language: .spanish
    )
    return resultado.text
  }

  func transcribirParcial(_ trozo: [Float]) async throws -> String {
    let capas = await manager.decoderLayerCount
    var estado = estadoParcial ?? TdtDecoderState.make(decoderLayers: capas)
    let resultado = try await manager.transcribe(
      trozo, decoderState: &estado, language: .spanish
    )
    estadoParcial = estado
    return resultado.text
  }

  func reiniciarParciales() {
    estadoParcial = nil
  }

  func liberar() async {
    await manager.cleanup()
  }
}
