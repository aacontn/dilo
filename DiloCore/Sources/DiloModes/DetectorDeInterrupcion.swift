import Foundation

/// Cuándo la persona le habla encima al agente: interrumpir con la voz.
///
/// El micrófono sigue abierto mientras el agente habla, y por los parlantes
/// también entra su propia voz. Dilo sabe qué tan fuerte está sonando
/// (`salida`), así que aprende cuánto de eso vuelve por el micrófono. Con
/// audífonos no vuelve casi nada, y lo que pasa por encima es la persona. **Con
/// parlantes no se interrumpe con la voz, sólo con el gatillo**: una voz por
/// parlantes no se separa de la persona con niveles. En la llamada del
/// 2026-10-30 Kami se cortó sola dos veces, y lo que oyó de sí misma le llegó
/// como un turno; que se calle sola es mucho peor que tener que apretar una
/// tecla. Tampoco sirve comparar el texto: medio segundo de audio da palabras
/// inventadas (medido, 54 % de aciertos con 0,8 s).
///
/// Separarla de verdad con parlantes pide el procesamiento de voz de Apple, que
/// obliga a un solo motor de audio para voz y micrófono y baja lo demás que
/// suena. Los niveles van en la escala de la muesca (0 a 1 sobre 50 dB). Sin
/// nada sonando, el umbral es el de siempre (`FinDelTurno.nivelDeVoz`).
public struct DetectorDeInterrupcion: Sendable {
  /// Cuánto por encima del eco tiene que estar la voz: 0,18 son 9 dB.
  public static let margen: Float = 0.18
  /// Cuánta voz seguida interrumpe: una tos o un golpe no.
  public static let vozParaInterrumpir: Duration = .milliseconds(400)
  /// Con este eco o más, son parlantes: −0,45 son 22 dB bajo lo que suena, y
  /// unos audífonos con el micrófono aparte quedan muy por debajo.
  public static let ecoDeParlantes: Float = -0.45
  /// La salida más fuerte de este rato es contra la que se compara: el eco
  /// llega atrasado y la voz sube y baja entre sílabas.
  static let memoriaDeLaSalida: Duration = .milliseconds(500)
  /// Lo primero que suena en la llamada sólo sirve para medir el eco.
  static let calibracion: Duration = .milliseconds(400)
  /// Bajo esto la salida no está sonando.
  static let salidaAudible: Float = 0.2
  /// Qué tan rápido se ajusta el eco: sube rápido y baja lento, porque lo que
  /// engaña son sus picos y no su promedio. Con un promedio, los huecos entre
  /// sílabas lo bajaban y la propia voz terminaba pasando por encima.
  static let subidaDelEco: Float = 0.3
  static let bajadaDelEco: Float = 0.03
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

  /// Si lo que suena vuelve por el micrófono: ahí sólo interrumpe el gatillo.
  public var hayParlantes: Bool { (eco ?? -1) >= Self.ecoDeParlantes }

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
      guard !hayParlantes else {
        aprender(microfono - referencia, sobre: eco)
        ultimaVoz = nil
        voz = .zero
        primeraMuestra = nil
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
    if let referencia, let eco { aprender(microfono - referencia, sobre: eco) }
    if let ultimaVoz, instante - ultimaVoz > Self.huecoEntreSilabas {
      self.ultimaVoz = nil
      voz = .zero
      primeraMuestra = nil
    }
  }

  private mutating func aprender(_ medido: Float, sobre eco: Float) {
    let paso = medido > eco ? Self.subidaDelEco : Self.bajadaDelEco
    self.eco = eco + (medido - eco) * paso
  }
}
