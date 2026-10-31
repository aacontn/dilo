import Foundation

/// Qué parte de una **Pista** transcribir, y cuándo, mientras la reunión graba.
///
/// El guion en vivo es para leer lo que se acaba de decir, no el registro: eso
/// lo deja la pasada final. Un detector de voz liviano mira cada trozo; lo que
/// tiene voz abre un tramo, que se transcribe entero cada `entreParciales` para
/// que el texto avance mientras alguien habla y se cierra con un silencio. Un
/// monólogo se corta en `largoMaximo`, en la pausa más honda de lo último, para
/// que volver a transcribir un tramo abierto siempre cueste poco.
///
/// Trabaja con índices de muestra absolutos a 16 kHz y no sabe qué detector hay
/// atrás: recibe una probabilidad por trozo. Puro: los tests le pasan
/// probabilidades inventadas.
public struct TramosDeVoz: Sendable, Equatable {
  public struct Ajustes: Sendable, Equatable {
    public var tasa: Double = 16_000
    /// 4.096 muestras, los 256 ms de Silero.
    public var muestrasPorTrozo = 4_096
    /// Desde aquí un trozo tiene voz. 0,5 es el corte de Silero.
    public var umbralDeVoz: Float = 0.5
    /// Silencio que cierra un tramo. Corto: es lo que la línea tarda en
    /// quedar firme.
    public var silencioParaCerrar: Double = 0.7
    /// Audio de antes del trozo que dio la voz: el detector llega tarde a la
    /// primera sílaba.
    public var antesDeLaVoz: Double = 0.35
    /// Audio tras la última voz, para no comerse la última sílaba.
    public var despuesDeLaVoz: Double = 0.2
    /// Menos voz que esto en un tramo es un golpe en la mesa: no se transcribe.
    public var vozMinima: Double = 0.25
    /// Cada cuánto audio nuevo se vuelve a transcribir el tramo abierto. Con
    /// el segundo que tarda en llegar del disco, el vivo va a unos 3 s de lo
    /// dicho (spec: ≤ 4 s).
    public var entreParciales: Double = 1.5
    /// Lo más largo de un tramo. Transcribirlo entero cada `entreParciales`
    /// tiene que seguir siendo barato con las dos pistas hablando.
    public var largoMaximo: Double = 18
    /// Dónde se busca la pausa para cortar un monólogo.
    public var buscarCorteEn: Double = 3

    public init() {}

    func muestras(_ segundos: Double) -> Int { Int((segundos * tasa).rounded()) }
  }

  public enum Accion: Equatable, Sendable {
    /// Transcribir lo que va del tramo abierto.
    case parcial(Range<Int>)
    /// El tramo terminó: transcribirlo y dejar la línea firme.
    case cerrar(Range<Int>)
    /// El tramo era ruido: si se mostró algo, se quita.
    case descartar
  }

  private struct Tramo: Sendable, Equatable {
    var inicio: Int
    var ultimaVoz: Int
    var voz: Int
    var pedidoHasta: Int
  }

  private struct Muestreo: Sendable, Equatable {
    var fin: Int
    var probabilidad: Float
  }

  public let ajustes: Ajustes
  private var abierto: Tramo?
  private var recientes: [Muestreo] = []

  public init(ajustes: Ajustes = Ajustes()) {
    self.ajustes = ajustes
  }

  public var hayTramoAbierto: Bool { abierto != nil }

  /// Desde qué muestra hay que seguir guardando audio: lo que un tramo que se
  /// abra en el próximo trozo va a pedir hacia atrás.
  public func retenerDesde(fin: Int) -> Int {
    let antes = fin - ajustes.muestrasPorTrozo - ajustes.muestras(ajustes.antesDeLaVoz)
    return min(abierto?.inicio ?? antes, antes)
  }

  /// Un trozo más: `fin` es la muestra donde termina.
  public mutating func trozo(fin: Int, probabilidad: Float) -> [Accion] {
    let hayVoz = probabilidad >= ajustes.umbralDeVoz
    recientes.append(Muestreo(fin: fin, probabilidad: probabilidad))
    recientes.removeAll { $0.fin < fin - ajustes.muestras(ajustes.buscarCorteEn) }
    guard var tramo = abierto else {
      guard hayVoz else { return [] }
      let inicio = max(0, fin - ajustes.muestrasPorTrozo - ajustes.muestras(ajustes.antesDeLaVoz))
      abierto = Tramo(inicio: inicio, ultimaVoz: fin, voz: ajustes.muestrasPorTrozo, pedidoHasta: inicio)
      return []
    }
    if hayVoz {
      tramo.ultimaVoz = fin
      tramo.voz += ajustes.muestrasPorTrozo
    }
    if fin - tramo.ultimaVoz >= ajustes.muestras(ajustes.silencioParaCerrar) {
      abierto = nil
      guard tramo.voz >= ajustes.muestras(ajustes.vozMinima) else { return [.descartar] }
      return [.cerrar(tramo.inicio ..< min(fin, tramo.ultimaVoz + ajustes.muestras(ajustes.despuesDeLaVoz)))]
    }
    if fin - tramo.inicio >= ajustes.muestras(ajustes.largoMaximo) {
      let corte = pausa(despuesDe: tramo.inicio) ?? fin
      let cerrado = tramo.inicio ..< corte
      tramo.inicio = corte
      tramo.pedidoHasta = corte
      tramo.voz = 0
      abierto = tramo
      return [.cerrar(cerrado)]
    }
    if fin - tramo.pedidoHasta >= ajustes.muestras(ajustes.entreParciales) {
      tramo.pedidoHasta = fin
      abierto = tramo
      return [.parcial(tramo.inicio ..< fin)]
    }
    abierto = tramo
    return []
  }

  /// Cierra lo que esté abierto ya: empezó un dictado y lo que sigue en `yo`
  /// no es la reunión.
  public mutating func cerrarAhora(fin: Int) -> Accion? {
    guard let tramo = abierto else { return nil }
    abierto = nil
    return tramo.voz >= ajustes.muestras(ajustes.vozMinima) ? .cerrar(tramo.inicio ..< fin) : .descartar
  }

  /// El trozo con menos voz de lo último, para cortar entre dos palabras.
  private func pausa(despuesDe inicio: Int) -> Int? {
    recientes.filter { $0.fin > inicio }.min { $0.probabilidad < $1.probabilidad }?.fin
  }

  /// Sin detector de voz (el modelo no se pudo bajar), el nivel: basta para
  /// que el vivo siga, aunque un ruido fuerte también abra un tramo.
  public static func probabilidadPorNivel(_ muestras: [Float]) -> Float {
    guard !muestras.isEmpty else { return 0 }
    let suma = muestras.reduce(Float(0)) { $0 + $1 * $1 }
    let rms = (suma / Float(muestras.count)).squareRoot()
    return 20 * log10(max(rms, .leastNormalMagnitude)) > -42 ? 1 : 0
  }
}
