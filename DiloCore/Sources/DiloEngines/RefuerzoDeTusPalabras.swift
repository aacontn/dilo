import DiloText
import FluidAudio
import Foundation
import os

// Usa la API pública de FluidAudio 0.18.0 (Apache 2.0): `VocabularyBoostingSession`
// y `CtcModels`. La idea de correrlo sólo en la pasada final y de no dejar
// nunca a nadie sin texto viene de FluidVoice (GPL-3): técnica, sin código.

/// **Tus palabras** dentro de Parakeet: un CTC chico (parakeet-ctc-110m) busca
/// tus términos en el audio y reescribe las palabras del texto donde la
/// evidencia acústica alcanza. No toca el decodificador: es una segunda
/// mirada sobre la pasada final, y si falla, el texto queda como venía.
///
/// **Apagado de fábrica** (`diloTusPalabrasEnParakeet`) y sin poder
/// encenderse hasta que el CTC esté en disco: el modelo se baja a pedido en
/// Motor de voz, nunca solo en el primer dictado.
public struct RefuerzoDeTusPalabras: Sendable {
  private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "engines")

  /// Más términos que esto y el CTC tarda más de lo que aporta: FluidVoice
  /// corta en 256, y el rescore de FluidAudio ajusta sus umbrales por tamaño.
  public static let maximoDeTerminos = 200

  private let sesion: VocabularyBoostingSession

  /// Tus palabras como términos del CTC: sin repetidas, de tres letras o más
  /// (lo más corto el CTC lo encuentra en cualquier parte), las primeras 200.
  /// La normalización es la misma que recibe Apple.
  public static func terminos(de palabras: [String]) -> [String] {
    Array(
      DiccionarioPersonal.terminosParaElMotor(palabras)
        .filter { $0.filter(\.isLetter).count >= 3 }
        .prefix(maximoDeTerminos)
    )
  }

  /// Una firma corta de la lista, para saber si cambió desde que se cargó el
  /// modelo. FNV-1a: estable entre arranques, a diferencia de `hashValue`.
  public static func firma(de terminos: [String]) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in terminos.joined(separator: "\u{1F}").utf8 {
      hash ^= UInt64(byte)
      hash &*= 0x0000_0100_0000_01b3
    }
    return String(hash, radix: 16)
  }

  /// Carga el CTC y arma la sesión. Nil si no hay términos que reforzar o si
  /// el CTC no está en disco: el refuerzo nunca baja nada.
  static func cargar(terminos: [String]) async throws -> RefuerzoDeTusPalabras? {
    guard !terminos.isEmpty, ModeloDeTusPalabras.estaDescargado else { return nil }
    let ctc = try await CtcModels.load(
      from: ModeloDeTusPalabras.carpeta, variant: ModeloDeTusPalabras.variante
    )
    let sesion = try await VocabularyBoostingSession(
      vocabulary: CustomVocabularyContext(terms: terminos.map { CustomVocabularyTerm(text: $0) }),
      ctcModels: ctc
    )
    return RefuerzoDeTusPalabras(sesion: sesion)
  }

  /// El texto ya cosido (`CosturaDeTrozos`) con lo que el CTC encontró.
  ///
  /// `tiempos` y `audio` tienen que ser del mismo reloj: el audio que se le
  /// pasó al motor, desde su primera muestra.
  func aplicar(a cosido: String, tiempos: [TokenTiming], audio: [Float]) async -> String {
    guard let salida = await sesion.rescore(text: cosido, tokenTimings: tiempos, audioSamples: audio),
      salida.wasModified
    else { return cosido }
    let pares = salida.replacements.compactMap { r -> (original: String, nuevo: String)? in
      guard r.shouldReplace, let nuevo = r.replacementWord else { return nil }
      return (r.originalWord, nuevo)
    }
    // Al log va cuántos, nunca cuáles: son palabras dichas.
    Self.logger.info("Tus palabras en Parakeet reemplazó \(pares.count, privacy: .public)")
    return ReemplazosDeVocabulario.aplicar(pares, a: cosido)
  }
}

/// El CTC de Tus palabras en disco: si está, cómo se baja y cómo se va a la
/// Papelera.
///
/// **Vive en la carpeta de FluidAudio, no en la de Dilo**
/// (`…/Application Support/FluidAudio/Models/parakeet-ctc-110m-coreml`):
/// `VocabularyBoostingSession` lee el tokenizer de
/// `CtcModels.defaultCacheDirectory(for:)` y no deja elegir otra. Por eso
/// tiene su propio botón para mandarlo a la Papelera.
public actor ModeloDeTusPalabras {
  static let variante: CtcModelVariant = .ctc110m

  public static var carpeta: URL { CtcModels.defaultCacheDirectory(for: variante) }

  /// Lo que se baja, en megas, medido sobre la carpeta ya bajada.
  public static let megasDeDescarga = 99

  /// Los dos modelos, el vocabulario y el tokenizer: sin el tokenizer la
  /// sesión no arma los términos y el refuerzo no hace nada.
  public static var estaDescargado: Bool {
    CtcModels.modelsExist(at: carpeta)
      && FileManager.default.fileExists(atPath: carpeta.appendingPathComponent("tokenizer.json").path)
  }

  private var descarga: Task<Void, any Error>?

  public init() {}

  public func descargar() async throws {
    if Self.estaDescargado { return }
    if let descarga {
      try await descarga.value
      return
    }
    let tarea = Task { () throws -> Void in
      _ = try await CtcModels.download(variant: Self.variante)
    }
    descarga = tarea
    do {
      try await tarea.value
      descarga = nil
    } catch {
      descarga = nil
      if !Self.estaDescargado { try? FileManager.default.removeItem(at: Self.carpeta) }
      throw error
    }
  }

  public func cancelarDescarga() {
    descarga?.cancel()
    descarga = nil
  }

  /// A la Papelera, nunca un borrado definitivo, como los modelos de Parakeet.
  public func moverALaPapelera() throws {
    cancelarDescarga()
    guard FileManager.default.fileExists(atPath: Self.carpeta.path) else { return }
    try FileManager.default.trashItem(at: Self.carpeta, resultingItemURL: nil)
  }
}

/// Si la segunda pasada corre cuando el CTC está en disco. La clave es nueva y
/// vive acá para que el de fábrica se pruebe con `swift test`.
///
/// **Apagada de fábrica, por medición** (2026-10-29, M1, cinco dictados
/// sintéticos en español con `scripts/comparar-motores.sh --tus-palabras`):
/// suma **+225 ms** de mediana al soltar con Ultra (145 → 369 ms; con v3,
/// 225 → 566 ms) y se pasa de los 300 ms del spec §3; y el CTC, que es
/// inglés, reemplaza palabras comunes por términos del diccionario
/// («mañana» → «Martina», «de los» → «deploy»): el WER subió de 9,2 % a
/// 16,3 %. Acertó «de Camerón» → «Decameron». Queda para quien quiera
/// probarlo, y para medir con umbrales más altos o un CTC multilingüe.
public enum PreferenciaDeTusPalabrasEnParakeet {
  public static let clave = "diloTusPalabrasEnParakeet"
  public static let deFabrica = false

  public static func leer(_ defaults: UserDefaults) -> Bool {
    defaults.object(forKey: clave) as? Bool ?? deFabrica
  }

  /// Lo que el cargador recibe: Tus palabras si la función está encendida,
  /// nil si no. Se lee en cada carga del modelo.
  public static func palabras(en defaults: UserDefaults, clave claveDeLasPalabras: String) -> [String]? {
    guard leer(defaults) else { return nil }
    return defaults.stringArray(forKey: claveDeLasPalabras) ?? []
  }
}
