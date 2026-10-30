import Foundation

/// Lo que un diarizador dice de una pista: por cada cuadro de tiempo, cuánta
/// actividad tiene cada hablante (0…1).
///
/// Es la forma común a todos los de FluidAudio —Nemotron 3 da cuadros de
/// 10 ms × 8, Sortformer de 80 ms × 4, LS-EEND de 100 ms × 10— y la que se
/// puede armar desde los segmentos de VBx. Así la regla de palabra → hablante
/// vive una sola vez y no sabe qué modelo corrió.
public struct ActividadDeHablantes: Sendable, Equatable {
  public let segundosPorCuadro: Double
  public let hablantes: Int
  /// Fila por cuadro: `[c0h0, c0h1, …, c1h0, …]`.
  public var probabilidades: [Float]

  public init(segundosPorCuadro: Double, hablantes: Int, probabilidades: [Float]) {
    precondition(hablantes > 0 && segundosPorCuadro > 0)
    self.segundosPorCuadro = segundosPorCuadro
    self.hablantes = hablantes
    self.probabilidades = probabilidades
  }

  public var cuadros: Int { probabilidades.count / hablantes }
  public var duracion: Double { Double(cuadros) * segundosPorCuadro }

  public func probabilidad(cuadro: Int, hablante: Int) -> Float {
    guard cuadro >= 0, cuadro < cuadros, hablante >= 0, hablante < hablantes else { return 0 }
    return probabilidades[cuadro * hablantes + hablante]
  }

  /// Un segmento de hablante, como lo da un diarizador que no entrega
  /// cuadros (VBx) o como se etiqueta a mano.
  public struct Segmento: Sendable, Equatable {
    public var hablante: Int
    public var desde: Double
    public var hasta: Double

    public init(hablante: Int, desde: Double, hasta: Double) {
      self.hablante = hablante
      self.desde = desde
      self.hasta = hasta
    }
  }

  /// Cuadros de 10 ms con 1 donde el segmento dice que habla y 0 donde no.
  public static func desde(
    segmentos: [Segmento], hablantes: Int, segundosPorCuadro: Double = 0.01, duracion: Double? = nil
  ) -> ActividadDeHablantes {
    let fin = duracion ?? segmentos.map(\.hasta).max() ?? 0
    let cuadros = max(0, Int((fin / segundosPorCuadro).rounded(.up)))
    var probabilidades = [Float](repeating: 0, count: cuadros * max(hablantes, 1))
    for segmento in segmentos where segmento.hablante >= 0 && segmento.hablante < hablantes {
      let a = max(0, Int((segmento.desde / segundosPorCuadro).rounded(.down)))
      let b = min(cuadros, Int((segmento.hasta / segundosPorCuadro).rounded(.up)))
      guard a < b else { continue }
      for cuadro in a..<b { probabilidades[cuadro * hablantes + segmento.hablante] = 1 }
    }
    return ActividadDeHablantes(
      segundosPorCuadro: segundosPorCuadro, hablantes: max(hablantes, 1), probabilidades: probabilidades
    )
  }

  /// Los segmentos donde un hablante supera el umbral, con un mínimo de
  /// duración: lo que se escribe en un RTTM o se compara con etiquetas.
  public func segmentos(umbral: Float = AtribucionDeHablantes.umbral, minimo: Double = 0.2) -> [Segmento] {
    var salida: [Segmento] = []
    for hablante in 0..<hablantes {
      var inicio: Int?
      for cuadro in 0...cuadros {
        let activo = cuadro < cuadros && probabilidad(cuadro: cuadro, hablante: hablante) > umbral
        if activo, inicio == nil {
          inicio = cuadro
        } else if !activo, let a = inicio {
          let desde = Double(a) * segundosPorCuadro
          let hasta = Double(cuadro) * segundosPorCuadro
          if hasta - desde >= minimo { salida.append(Segmento(hablante: hablante, desde: desde, hasta: hasta)) }
          inicio = nil
        }
      }
    }
    return salida.sorted { $0.desde < $1.desde }
  }
}

/// Palabra → hablante: el hablante con más actividad en el tramo de la
/// palabra; si dos superan el umbral, solape (spec, «Quién habló»). Es la
/// receta de la propia documentación de Nemotron 3 en FluidAudio.
public enum AtribucionDeHablantes {
  /// Sobre esto un hablante «está hablando» en el tramo. Es el umbral de los
  /// segmentos de FluidAudio (`Nemotron3Diarizer.segments`): mismo número,
  /// para que el guion y un RTTM digan lo mismo.
  public static let umbral: Float = 0.5
  /// Bajo el umbral pero sobre esto, el que más tiene igual se queda con la
  /// palabra: una palabra corta en el borde de un turno rara vez llega a 0,5
  /// de media.
  public static let umbralDebil: Float = 0.15
  /// Hasta dónde se busca a alguien hablando cuando el tramo de la palabra
  /// quedó vacío: el diarizador y Parakeet no cortan en el mismo cuadro.
  public static let margen: Double = 0.5

  public struct Resultado: Sendable, Equatable {
    /// El índice del hablante en la actividad, o nil si nadie.
    public var hablante: Int?
    public var solape: Bool

    public init(hablante: Int?, solape: Bool = false) {
      self.hablante = hablante
      self.solape = solape
    }
  }

  public static func hablante(desde: Double, hasta: Double, en actividad: ActividadDeHablantes) -> Resultado {
    let medias = mediaPorHablante(desde: desde, hasta: hasta, en: actividad)
    let sobreUmbral = medias.indices.filter { medias[$0] >= umbral }
    let mayor = medias.indices.max { medias[$0] < medias[$1] }
    if sobreUmbral.count >= 2, let mayor { return Resultado(hablante: mayor, solape: true) }
    if let uno = sobreUmbral.first { return Resultado(hablante: uno) }
    if let mayor, medias[mayor] >= umbralDebil { return Resultado(hablante: mayor) }
    return Resultado(hablante: masCercano(a: (desde + hasta) / 2, en: actividad))
  }

  /// La actividad media de cada hablante en el tramo. Una palabra más corta
  /// que un cuadro mira el cuadro que la contiene.
  static func mediaPorHablante(desde: Double, hasta: Double, en actividad: ActividadDeHablantes) -> [Float] {
    let spf = actividad.segundosPorCuadro
    var a = Int((max(0, desde) / spf).rounded(.down))
    var b = Int((max(0, hasta) / spf).rounded(.up))
    if b <= a { b = a + 1 }
    a = min(a, actividad.cuadros)
    b = min(b, actividad.cuadros)
    guard a < b else { return [Float](repeating: 0, count: actividad.hablantes) }
    var sumas = [Float](repeating: 0, count: actividad.hablantes)
    for cuadro in a..<b {
      for hablante in 0..<actividad.hablantes {
        sumas[hablante] += actividad.probabilidad(cuadro: cuadro, hablante: hablante)
      }
    }
    let n = Float(b - a)
    return sumas.map { $0 / n }
  }

  /// Quién habla en el cuadro más cercano al instante, dentro del margen.
  static func masCercano(a instante: Double, en actividad: ActividadDeHablantes) -> Int? {
    let spf = actividad.segundosPorCuadro
    let centro = Int((instante / spf).rounded(.down))
    let alcance = Int((margen / spf).rounded(.up))
    for distancia in 0...alcance {
      for cuadro in Set([centro - distancia, centro + distancia]).sorted() {
        guard cuadro >= 0, cuadro < actividad.cuadros else { continue }
        let mejor = (0..<actividad.hablantes).max {
          actividad.probabilidad(cuadro: cuadro, hablante: $0) < actividad.probabilidad(cuadro: cuadro, hablante: $1)
        }
        if let mejor, actividad.probabilidad(cuadro: cuadro, hablante: mejor) >= umbral { return mejor }
      }
    }
    return nil
  }
}
