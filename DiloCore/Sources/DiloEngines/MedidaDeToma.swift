import Accelerate
import Foundation

// Técnica observada en Ocelli (Ghidra, FUN_100143694 / FUN_100143c6c: ventanas de
// 50 ms con salto de 25 ms, piso = percentil 10, umbral = máx(−50 dBFS, piso + 6 dB),
// voz contada en ventanas de 100 ms). Implementación propia.
/// Cuánto sonó una toma y cuánto de eso fue voz.
///
/// Una pasada sobre el audio que ya está en RAM, al soltar. Sirve a tres
/// decisiones: si una frase de agradecimiento es fantasma (la toma estaba
/// casi muda), si vale la pena pedirle una segunda opinión al otro motor, y
/// si una toma sin texto merece guardarse para reintentar. El umbral se
/// adapta a la sala —piso más 6 dB— para que un ventilador no cuente como
/// voz y un micrófono bajito no cuente como silencio.
public struct MedidaDeToma: Sendable, Equatable {
  public let rms: Float
  public let pico: Float
  public let piso: Float
  public let umbral: Float
  public let segundosConVoz: Double
  public let duracion: Double

  /// −50 dBFS: por debajo de esto nada cuenta como voz, aunque la sala sea
  /// un estudio. Ocelli.
  public static let umbralMinimo: Float = 0.003_162
  /// +6 dB sobre el piso de la sala. Ocelli.
  public static let margenSobreElPiso: Float = 1.995
  /// −48 dBFS de RMS en toda la toma: casi silencio digital. Es el único
  /// caso en que una frase fantasma de nivel 2 se borra. Ocelli.
  public static let dBDeTomaMuda: Float = -48
  /// Con menos voz que esto la toma también cuenta como muda: un «gracias»
  /// de 0,2 s sobre una sala con ruido no lo dijo nadie. Propio.
  public static let segundosDeVozDeTomaMuda: Double = 0.3
  /// Con al menos esto de voz, una toma sin texto se guarda para
  /// reintentar: alguien habló y el motor no lo entendió. Debajo, fue un
  /// apretón sin querer o una tos, y basta con decir que no se escuchó.
  public static let segundosDeVozParaGuardar: Double = 0.5

  public var rmsDB: Float { 20 * log10(max(rms, 1e-9)) }

  /// Si hay audio que medir. Sin audio —una toma que la grabadora no vio,
  /// como la del WAV de las métricas— nada de lo que sigue opina: no se
  /// puede llamar muda a una toma que nadie midió.
  public var hayAudio: Bool { duracion > 0 }

  /// La sala estaba casi en silencio digital: el único caso en que una
  /// frase fantasma de nivel 2 se borra (≈ regla de −48 dB de Ocelli).
  public var casiMuda: Bool {
    hayAudio && (rmsDB < Self.dBDeTomaMuda || segundosConVoz < Self.segundosDeVozDeTomaMuda)
  }

  /// Alguien habló lo suficiente como para que perder la toma sea perder un
  /// dictado.
  public var huboVoz: Bool { segundosConVoz >= Self.segundosDeVozParaGuardar }

  public static let vacia = MedidaDeToma(
    rms: 0, pico: 0, piso: 0, umbral: umbralMinimo, segundosConVoz: 0, duracion: 0)

  public static func medir(_ muestras: [Float], tasa: Double = PoliticaDeGrabacion.tasa) -> MedidaDeToma {
    guard !muestras.isEmpty else { return .vacia }
    let duracion = Double(muestras.count) / tasa
    return muestras.withUnsafeBufferPointer { todo in
      let rms = vDSP.rootMeanSquare(todo)
      let pico = vDSP.maximumMagnitude(todo)

      // El piso de la sala: el percentil 10 de la energía en ventanas de
      // 50 ms que se pisan cada 25 ms.
      let ancho = Int(tasa * 0.05)
      let salto = Int(tasa * 0.025)
      var energias: [Float] = []
      energias.reserveCapacity(todo.count / max(salto, 1) + 1)
      var inicio = 0
      while inicio + ancho <= todo.count {
        energias.append(vDSP.rootMeanSquare(UnsafeBufferPointer(rebasing: todo[inicio..<inicio + ancho])))
        inicio += salto
      }
      energias.sort()
      let piso = energias.isEmpty ? 0 : energias[energias.count / 10]
      let umbral = max(umbralMinimo, piso * margenSobreElPiso)

      // La voz se cuenta en ventanas de 100 ms sin pisarse.
      let ventana = Int(tasa * 0.1)
      var conVoz = 0
      inicio = 0
      while inicio + ventana <= todo.count {
        if vDSP.rootMeanSquare(UnsafeBufferPointer(rebasing: todo[inicio..<inicio + ventana])) > umbral {
          conVoz += 1
        }
        inicio += ventana
      }
      return MedidaDeToma(
        rms: rms, pico: pico, piso: piso, umbral: umbral,
        segundosConVoz: Double(conVoz) * 0.1, duracion: duracion)
    }
  }
}
