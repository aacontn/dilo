import Accelerate
import Foundation
import Synchronization

// Origen: imnotpayingforwisprflow, Sources/DictationCore/RecordingPolicy.swift:3-16
// (MIT, © 2026 Yosef Shammout). Reescrito al estilo de Dilo; los números son los
// suyos.
/// Cuánto puede durar un **Dictado** y cuándo se avisa que se acaba.
///
/// El tope existe por la RAM, no por gusto: el audio de la toma vive en
/// memoria y en ninguna otra parte —la misma decisión de privacidad que
/// `UltimoDictado`—, así que tiene que tener techo.
public enum PoliticaDeGrabacion {
  public static let tasa: Double = 16_000
  public static let duracionMaxima: Duration = .seconds(300)
  public static let muestrasMaximas = 4_800_000
  /// Desde cuándo la muesca cuenta hacia atrás.
  public static let avisoAntesDelTope: Duration = .seconds(15)
  /// Cuánto vive una toma fallida que nadie reintentó. Pasado esto se bota:
  /// la RAM de reposo (< 60 MB, spec §3) no se negocia por un rescate
  /// olvidado.
  public static let vidaDeLaTomaFallida: Duration = .seconds(600)

  public enum Fase: Equatable, Sendable {
    case normal
    /// Quedan estos segundos, redondeados hacia arriba.
    case terminaEn(segundos: Int)
    case tope
  }

  public static func fase(transcurrido: Duration) -> Fase {
    let quedan = duracionMaxima - transcurrido
    if quedan <= .zero { return .tope }
    if quedan <= avisoAntesDelTope {
      return .terminaEn(segundos: Int(segundos(quedan).rounded(.up)))
    }
    return .normal
  }

  /// «4:59»: lo que dice el menú junto a una toma guardada.
  public static func reloj(_ duracion: TimeInterval) -> String {
    let total = max(0, Int(duracion.rounded(.down)))
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  static func segundos(_ duracion: Duration) -> Double {
    Double(duracion.components.seconds) + Double(duracion.components.attoseconds) / 1e18
  }
}

/// Una toma de audio en RAM, a 16 kHz mono.
///
/// Se guarda en `Int16` y no en `Float`: cinco minutos son 9,6 MB y no 19,2.
/// La pérdida (96 dB de rango) no la oye ningún **Motor de voz**.
public struct TomaDeAudio: Sendable, Equatable {
  public let muestras: [Int16]
  public let tasa: Double

  public init(muestras: [Int16], tasa: Double = PoliticaDeGrabacion.tasa) {
    self.muestras = muestras
    self.tasa = tasa
  }

  public var duracion: TimeInterval { Double(muestras.count) / tasa }

  /// Lo que piden los motores y la medida: `Float` en [-1, 1]. Con vDSP
  /// porque corre al soltar.
  public func comoFloat() -> [Float] {
    guard !muestras.isEmpty else { return [] }
    var salida = [Float](repeating: 0, count: muestras.count)
    vDSP.convertElements(of: muestras, to: &salida)
    vDSP.multiply(1 / Float(Int16.max), salida, result: &salida)
    return salida
  }
}

/// El audio de la sesión en curso, acumulado desde el hilo de audio.
///
/// Un solo dueño para los dos motores: Apple no guarda nada y Parakeet bota
/// su buffer al terminar, así que sin esto un dictado cuyo motor falla al
/// soltar se pierde entero. Perder un dictado en silencio está prohibido
/// (AGENTS.md); esto es lo que deja reintentarlo sin volver a hablar.
public final class GrabadoraEnRAM: Sendable {
  private struct Estado {
    var muestras: [Int16] = []
    var llena = false
  }

  private let estado = Mutex(Estado())
  private let tope: Int

  public init(tope: Int = PoliticaDeGrabacion.muestrasMaximas) {
    self.tope = tope
  }

  /// Agrega un trozo ya convertido a 16 kHz mono. Devuelve `false` cuando el
  /// tope se alcanzó: lo que venga después no se guarda.
  ///
  /// Barato a propósito: corre en el hilo de audio, con trozos de unos
  /// cientos de muestras.
  @discardableResult
  public func agregar(_ trozo: UnsafeBufferPointer<Float>) -> Bool {
    estado.withLock { estado in
      guard !estado.llena else { return false }
      // Treinta segundos de entrada: la mayoría de los dictados no pasan de
      // ahí, y crecer de a poco en el hilo de audio es copiar muchas veces.
      if estado.muestras.isEmpty {
        estado.muestras.reserveCapacity(Int(PoliticaDeGrabacion.tasa) * 30)
      }
      let caben = min(trozo.count, tope - estado.muestras.count)
      for muestra in trozo.prefix(caben) {
        let acotada = muestra.isFinite ? max(-1, min(1, muestra)) : 0
        estado.muestras.append(Int16(acotada * Float(Int16.max)))
      }
      if estado.muestras.count >= tope { estado.llena = true }
      return !estado.llena
    }
  }

  /// Entrega lo grabado y deja la grabadora vacía para la sesión siguiente:
  /// la RAM de la toma se va con quien la tomó, no se queda acá.
  public func tomar() -> TomaDeAudio {
    estado.withLock { estado in
      defer { estado = Estado() }
      return TomaDeAudio(muestras: estado.muestras)
    }
  }

  /// Bota lo grabado sin entregarlo: cancelar con Esc no deja nada en RAM.
  public func descartar() {
    estado.withLock { $0 = Estado() }
  }

  /// Cuántas muestras lleva la sesión. Para las pruebas.
  var cuenta: Int { estado.withLock { $0.muestras.count } }
}

/// Lo que queda de un dictado cuyo texto no salió, para reintentarlo sin
/// volver a hablar. **Una sola**, en RAM, nunca en disco: una nueva reemplaza
/// a la anterior.
public struct TomaFallida: Sendable {
  public let audio: TomaDeAudio
  /// El idioma de la sesión, para reintentar igual.
  public let idioma: Locale
  public let cuando: ContinuousClock.Instant

  public init(audio: TomaDeAudio, idioma: Locale, cuando: ContinuousClock.Instant = .now) {
    self.audio = audio
    self.idioma = idioma
    self.cuando = cuando
  }

  public func vencida(ahora: ContinuousClock.Instant = .now) -> Bool {
    cuando.duration(to: ahora) > PoliticaDeGrabacion.vidaDeLaTomaFallida
  }
}
