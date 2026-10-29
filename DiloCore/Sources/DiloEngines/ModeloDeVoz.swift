import DiloText
import FluidAudio
import Foundation

/// Un modelo de voz ya cargado en la RAM, visto desde el motor.
///
/// Existe para que `ParakeetEngine` no hable con FluidAudio directo. Las
/// reglas que importan —cuándo se carga, qué pasa si sueltas antes de que
/// esté, cuándo se suelta de la memoria— se prueban con `swift test`, y un
/// `AsrManager` de verdad pide cientos de megas en disco y medio minuto de Core ML.
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

  /// Qué modelo es, para saber si sigue siendo el que hay que usar: Ultra
  /// puede terminar de bajar con v3 en la RAM.
  var firma: String { get }
}

extension ModeloDeVoz {
  public var firma: String { "" }
}

/// De dónde sale un modelo cargado, y si hay algo que cargar.
public protocol CargadorDeModelo: Sendable {
  /// Si el modelo está en disco **ahora**. Se pregunta cada vez y no se
  /// cachea: la descarga termina con la app abierta.
  var disponible: Bool { get }

  /// Lee el modelo del disco y lo deja listo para transcribir. Tarda: en un
  /// M1 ocioso son unos veinte segundos la primera vez.
  func cargar() async throws -> any ModeloDeVoz

  /// La firma del modelo que `cargar()` traería **ahora**. Si no es la del
  /// que está en la RAM, el motor lo suelta antes del próximo dictado.
  var firma: String { get }
}

extension CargadorDeModelo {
  public var firma: String { "" }
}

/// El cargador de verdad: resuelve qué variante dicta, lee lo que ya está
/// descargado y arma el `AsrManager` de FluidAudio.
///
/// La variante se resuelve **cada vez** (`ResolucionDeParakeet`), no al armar
/// el cargador: la descarga de Ultra termina con la app abierta, y la
/// elección de Ajustes cambia sin reiniciar nada.
public struct CargadorDeParakeet: CargadorDeModelo {
  private let carpeta: URL
  private let elegida: @Sendable () -> VarianteDeParakeet?

  public init(
    carpeta: URL = ParakeetModelStore.carpeta,
    elegida: @escaping @Sendable () -> VarianteDeParakeet? = { nil }
  ) {
    self.carpeta = carpeta
    self.elegida = elegida
  }

  /// La variante que dictaría ahora, o nil si no hay ninguna en disco.
  public var varianteEnUso: VarianteDeParakeet? {
    ResolucionDeParakeet.enUso(enDisco: ParakeetModelStore.enDisco(en: carpeta), elegida: elegida())
  }

  public var disponible: Bool { varianteEnUso != nil }

  public var firma: String { varianteEnUso?.rawValue ?? "" }

  public func cargar() async throws -> any ModeloDeVoz {
    guard let variante = varianteEnUso else { throw EngineError.modeloNoDescargado }
    let modelos = try await ParakeetModelStore(variante: variante, carpeta: carpeta).cargar()
    let manager = AsrManager(config: .default)
    try await manager.loadModels(modelos)
    return ModeloDeParakeet(manager: manager, variante: variante)
  }
}

/// Parakeet cargado: el `AsrManager` y el estado del decoder que los parciales
/// arrastran de un trozo al siguiente.
actor ModeloDeParakeet: ModeloDeVoz {
  private let manager: AsrManager
  private var estadoParcial: TdtDecoderState?
  nonisolated let variante: VarianteDeParakeet

  init(manager: AsrManager, variante: VarianteDeParakeet) {
    self.manager = manager
    self.variante = variante
  }

  nonisolated var firma: String { variante.rawValue }

  func transcribir(_ muestras: [Float]) async throws -> String {
    var estado = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
    let resultado = try await manager.transcribe(
      muestras, decoderState: &estado, language: .spanish
    )
    // El texto ya armado viene con las costuras de las ventanas pegadas sin
    // espacio; los tiempos de cada token son los que dicen dónde estuvo la
    // costura (ver `CosturaDeTrozos`). Sin tiempos —nunca visto, pero el
    // tipo los da opcionales— se devuelve lo que vino.
    guard let tiempos = resultado.tokenTimings, !tiempos.isEmpty else {
      return resultado.text
    }
    return CosturaDeTrozos.texto(
      de: tiempos.map {
        TokenDeVoz(texto: $0.token, inicio: $0.startTime, fin: $0.endTime)
      }
    )
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
