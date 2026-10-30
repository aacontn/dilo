import Foundation

/// Cuándo la persona le habla encima al agente: interrumpir con la voz.
///
/// El micrófono sigue abierto mientras el agente habla, y por los parlantes
/// también entra su propia voz. Dilo sabe qué tan fuerte está sonando
/// (`salida`), así que aprende cuánto de eso vuelve por el micrófono y sólo
/// cuenta lo que pasa bastante por encima: con audífonos el eco es casi nada y
/// basta hablar; con parlantes fuertes hay que hablar más fuerte que el eco.
/// Sin nada sonando, el umbral es el de siempre (`FinDelTurno.nivelDeVoz`).
///
/// No se usa el procesamiento de voz de Apple: obliga a que voz y micrófono
/// vayan por un mismo motor de audio y baja el volumen de lo demás que suena.
/// Los niveles van en la escala de la muesca (0 a 1 sobre 50 dB). Los umbrales
/// son de partida, sin medir con Alfonso: son constantes con nombre y se
/// calibran acá.
public struct DetectorDeInterrupcion: Sendable {
  /// Cuánto por encima del eco tiene que estar la voz: 0,18 son 9 dB.
  public static let margen: Float = 0.18
  /// Cuánta voz seguida interrumpe: una tos o un golpe no.
  public static let vozParaInterrumpir: Duration = .milliseconds(300)
  /// La salida más fuerte de este rato es contra la que se compara: el eco
  /// llega atrasado y la voz sube y baja entre sílabas.
  static let memoriaDeLaSalida: Duration = .milliseconds(500)
  /// Lo primero que suena en la llamada sólo sirve para medir el eco.
  static let calibracion: Duration = .milliseconds(400)
  /// Bajo esto la salida no está sonando.
  static let salidaAudible: Float = 0.2
  /// Qué tan rápido se ajusta el eco mientras nadie interrumpe.
  static let suavidadDelEco: Float = 0.1
  /// Un hueco de este largo entre sílabas no corta la voz que se venía contando.
  static let huecoEntreSilabas: Duration = .milliseconds(250)

  private var eco: Float?
  private var mayorEco: Float?
  private var sonandoDesde: ContinuousClock.Instant?
  private var salidas: [(instante: ContinuousClock.Instant, nivel: Float)] = []
  private var ultimaVoz: ContinuousClock.Instant?
  private var voz: Duration = .zero
  private var primeraMuestra: Int?

  public init() {}

  /// Cuánto eco se aprendió, en la escala de la muesca, para el log.
  public var ecoAprendido: Float? { eco }

  /// Dónde empezó la voz que interrumpe, en muestras del micrófono; nil si
  /// todavía nadie interrumpe.
  public var inicioDeLaVoz: Int? {
    voz >= Self.vozParaInterrumpir ? primeraMuestra : nil
  }

  /// Cuánta voz se contó: el turno que sigue parte con ella.
  public var vozContada: Duration { voz }

  /// Empieza otro turno del agente. Lo aprendido del eco se queda: los
  /// parlantes son los mismos en toda la llamada.
  public mutating func reiniciar() {
    salidas.removeAll()
    sonandoDesde = nil
    ultimaVoz = nil
    voz = .zero
    primeraMuestra = nil
  }

  /// - Parameters:
  ///   - microfono: el nivel de lo que oyó el micrófono.
  ///   - salida: el nivel de lo que está sonando por la salida.
  ///   - indice: dónde empieza esta muestra en lo oído en la llamada.
  public mutating func muestra(
    microfono: Float,
    salida: Float,
    indice: Int,
    en instante: ContinuousClock.Instant
  ) {
    salidas.removeAll { instante - $0.instante > Self.memoriaDeLaSalida }
    if salida >= Self.salidaAudible { salidas.append((instante, salida)) }
    let referencia = salidas.map(\.nivel).max()

    var umbral = FinDelTurno.nivelDeVoz
    if let referencia {
      let desde = sonandoDesde ?? instante
      sonandoDesde = desde
      guard let eco else {
        // Midiendo: acá todavía no se puede distinguir a la persona del eco.
        mayorEco = max(mayorEco ?? -1, microfono - referencia)
        if instante - desde >= Self.calibracion { eco = mayorEco }
        return
      }
      umbral = max(umbral, referencia + eco + Self.margen)
    }

    if microfono >= umbral {
      if let ultimaVoz {
        let paso = instante - ultimaVoz
        if paso <= FinDelTurno.huecoMaximo { voz += paso }
      }
      ultimaVoz = instante
      if primeraMuestra == nil { primeraMuestra = indice }
      return
    }
    if let referencia, let eco {
      self.eco = eco + (microfono - referencia - eco) * Self.suavidadDelEco
    }
    if let ultimaVoz, instante - ultimaVoz > Self.huecoEntreSilabas {
      self.ultimaVoz = nil
      voz = .zero
      primeraMuestra = nil
    }
  }
}
