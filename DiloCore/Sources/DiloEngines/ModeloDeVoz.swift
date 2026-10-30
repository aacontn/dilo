import DiloText
import FluidAudio
import Foundation
import os

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
  private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "engines")

  private let carpeta: URL
  private let elegida: @Sendable () -> VarianteDeParakeet?
  /// Tus palabras para la segunda pasada, o nil con la función apagada. Se
  /// lee al cargar, como la variante.
  private let tusPalabras: @Sendable () -> [String]?

  public init(
    carpeta: URL = ParakeetModelStore.carpeta,
    elegida: @escaping @Sendable () -> VarianteDeParakeet? = { nil },
    tusPalabras: @escaping @Sendable () -> [String]? = { nil }
  ) {
    self.carpeta = carpeta
    self.elegida = elegida
    self.tusPalabras = tusPalabras
  }

  /// Los términos que reforzaría la segunda pasada, o vacío si no corre:
  /// apagada, sin el CTC en disco o sin palabras que sirvan.
  private var terminosDelRefuerzo: [String] {
    guard let palabras = tusPalabras(), ModeloDeTusPalabras.estaDescargado else { return [] }
    return RefuerzoDeTusPalabras.terminos(de: palabras)
  }

  /// La variante que dictaría ahora, o nil si no hay ninguna en disco.
  public var varianteEnUso: VarianteDeParakeet? {
    ResolucionDeParakeet.enUso(enDisco: ParakeetModelStore.enDisco(en: carpeta), elegida: elegida())
  }

  public var disponible: Bool { varianteEnUso != nil }

  /// La variante y, si la segunda pasada corre, la firma de Tus palabras:
  /// prenderla, apagarla o cambiar el diccionario recarga el modelo en el
  /// próximo dictado, nunca a media frase.
  public var firma: String {
    let terminos = terminosDelRefuerzo
    let variante = varianteEnUso?.rawValue ?? ""
    return terminos.isEmpty ? variante : variante + "+" + RefuerzoDeTusPalabras.firma(de: terminos)
  }

  public func cargar() async throws -> any ModeloDeVoz {
    guard let variante = varianteEnUso else { throw EngineError.modeloNoDescargado }
    let terminos = terminosDelRefuerzo
    // El CTC carga en paralelo al modelo principal: los dos van mientras la
    // persona habla, y ninguno espera al otro.
    async let refuerzo = Self.cargarRefuerzo(terminos)
    let modelos = try await ParakeetModelStore(variante: variante, carpeta: carpeta).cargar()
    let manager = AsrManager(config: .default)
    try await manager.loadModels(modelos)
    let listo = await refuerzo
    // La firma es la de lo pedido, haya cargado el refuerzo o no: un CTC que
    // falla no tiene que recargar el modelo en cada dictado.
    let firma = terminos.isEmpty ? variante.rawValue : variante.rawValue + "+" + RefuerzoDeTusPalabras.firma(de: terminos)
    return ModeloDeParakeet(manager: manager, variante: variante, refuerzo: listo, firma: firma)
  }

  /// Un refuerzo que no carga no deja a nadie sin dictar: se dicta sin él.
  private static func cargarRefuerzo(_ terminos: [String]) async -> RefuerzoDeTusPalabras? {
    guard !terminos.isEmpty else { return nil }
    do {
      return try await RefuerzoDeTusPalabras.cargar(terminos: terminos)
    } catch {
      logger.error("Tus palabras en Parakeet no cargó: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }
}

/// Parakeet cargado: el `AsrManager` y el estado del decoder que los parciales
/// arrastran de un trozo al siguiente.
actor ModeloDeParakeet: ModeloDeVoz {
  /// Sin `private`: la pasada final de una reunión transcribe un archivo
  /// entero con este mismo manager (`ParakeetEngine+Reuniones.swift`).
  let manager: AsrManager
  private var estadoParcial: TdtDecoderState?
  nonisolated let variante: VarianteDeParakeet
  private let refuerzo: RefuerzoDeTusPalabras?
  nonisolated let firma: String
  /// Si hay un parcial corriendo, y quién espera a que termine. El CTC de Tus
  /// palabras no corre encima de un parcial en el Neural Engine: es lo que
  /// le daba caídas intermitentes a FluidVoice.
  private var parcialEnVuelo = false
  private var esperandoAlParcial: [CheckedContinuation<Void, Never>] = []

  init(
    manager: AsrManager,
    variante: VarianteDeParakeet,
    refuerzo: RefuerzoDeTusPalabras? = nil,
    firma: String? = nil
  ) {
    self.manager = manager
    self.variante = variante
    self.refuerzo = refuerzo
    self.firma = firma ?? variante.rawValue
  }

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
    let cosido = CosturaDeTrozos.texto(
      de: tiempos.map {
        TokenDeVoz(texto: $0.token, inicio: $0.startTime, fin: $0.endTime)
      }
    )
    guard let refuerzo else { return cosido }
    await esperarAlParcial()
    return await refuerzo.aplicar(a: cosido, tiempos: tiempos, audio: muestras)
  }

  func transcribirParcial(_ trozo: [Float]) async throws -> String {
    parcialEnVuelo = true
    defer {
      parcialEnVuelo = false
      for quien in esperandoAlParcial { quien.resume() }
      esperandoAlParcial = []
    }
    let capas = await manager.decoderLayerCount
    var estado = estadoParcial ?? TdtDecoderState.make(decoderLayers: capas)
    let resultado = try await manager.transcribe(
      trozo, decoderState: &estado, language: .spanish
    )
    estadoParcial = estado
    return resultado.text
  }

  private func esperarAlParcial() async {
    guard parcialEnVuelo else { return }
    await withCheckedContinuation { esperandoAlParcial.append($0) }
  }

  func reiniciarParciales() {
    estadoParcial = nil
  }

  func liberar() async {
    await manager.cleanup()
  }
}
