import Foundation

/// Un par (muestra, hora del Mac) de una pista: una línea de `relojes.jsonl`.
///
/// Dos dispositivos son dos relojes. Un 0,1 % de deriva son 3,6 s por hora,
/// lo bastante para que Yo conteste antes de la pregunta (spec,
/// «Alineación»). Cada pista anota uno cada 10 s y todo tiempo del guion se
/// traduce al reloj del Mac antes de intercalar.
public struct AnclaDeReloj: Codable, Sendable, Equatable {
  /// La pista, o nil para el ancla del inicio de la reunión: la hora del Mac
  /// en que se apretó «Grabar», que es el cero del guion.
  public var pista: Pista?
  /// La muestra de 16 kHz de la pista, contada desde la primera de su primera
  /// parte.
  public var muestra: Int64
  /// La hora del Mac en segundos (`mach_absolute_time` pasado a segundos).
  /// No avanza con el Mac dormido, igual que el audio.
  public var host: Double

  public init(pista: Pista?, muestra: Int64, host: Double) {
    self.pista = pista
    self.muestra = muestra
    self.host = host
  }

  public static func codificar(_ ancla: AnclaDeReloj) -> Data {
    let codificador = JSONEncoder()
    codificador.outputFormatting = [.sortedKeys]
    var datos = (try? codificador.encode(ancla)) ?? Data()
    datos.append(0x0A)
    return datos
  }

  public static func leer(_ datos: Data) -> [AnclaDeReloj] {
    let decodificador = JSONDecoder()
    return datos.split(separator: 0x0A).compactMap { try? decodificador.decode(AnclaDeReloj.self, from: Data($0)) }
  }
}

/// Traduce una muestra de una pista a segundos de la reunión, por sus anclas.
///
/// Entre dos anclas se interpola en línea recta; antes de la primera y
/// después de la última se sigue la pendiente del tramo más cercano, que es
/// la deriva medida. Sin anclas de una pista se asume que empezó con la
/// reunión y corre a 16 kHz exactos: es lo mejor que se puede decir, y un
/// archivo sin `relojes.jsonl` (uno reparado a medias) igual da un guion.
public struct AlineacionDeRelojes: Sendable {
  public static let tasa: Double = 16_000

  private let inicio: Double?
  private let porPista: [Pista: [AnclaDeReloj]]

  public init(_ anclas: [AnclaDeReloj]) {
    inicio = anclas.first { $0.pista == nil }?.host
    var porPista: [Pista: [AnclaDeReloj]] = [:]
    for pista in Pista.allCases {
      // Ordenadas por muestra y sin repetidas: dos anclas en la misma muestra
      // darían una pendiente infinita.
      var vistas = Set<Int64>()
      porPista[pista] = anclas
        .filter { $0.pista == pista }
        .sorted { $0.muestra < $1.muestra }
        .filter { vistas.insert($0.muestra).inserted }
    }
    self.porPista = porPista
  }

  /// La hora del Mac de una muestra, en segundos, o nil sin anclas.
  public func host(muestra: Double, pista: Pista) -> Double? {
    guard let anclas = porPista[pista], let primera = anclas.first else { return nil }
    guard anclas.count > 1 else {
      return primera.host + (muestra - Double(primera.muestra)) / Self.tasa
    }
    // El tramo que contiene la muestra, o el del borde más cercano.
    var i = 0
    while i < anclas.count - 2, Double(anclas[i + 1].muestra) <= muestra { i += 1 }
    let a = anclas[i]
    let b = anclas[i + 1]
    let pendiente = (b.host - a.host) / Double(b.muestra - a.muestra)
    return a.host + (muestra - Double(a.muestra)) * pendiente
  }

  /// Segundos de la reunión de un instante de la pista dado en segundos
  /// locales (muestra / 16 000), que es como los devuelve Parakeet.
  public func segundos(local: Double, pista: Pista) -> Double {
    let muestra = local * Self.tasa
    guard let inicio, let host = host(muestra: muestra, pista: pista) else { return local }
    return host - inicio
  }

  /// El instante local de la pista que corresponde a unos segundos de la
  /// reunión: el camino inverso, para buscar en el audio de `ellos` lo que
  /// coincide con una palabra de `yo`.
  public func local(segundos: Double, pista: Pista) -> Double {
    guard let inicio, let anclas = porPista[pista], let primera = anclas.first else { return segundos }
    let host = inicio + segundos
    guard anclas.count > 1 else { return Double(primera.muestra) / Self.tasa + (host - primera.host) }
    var i = 0
    while i < anclas.count - 2, anclas[i + 1].host <= host { i += 1 }
    let a = anclas[i]
    let b = anclas[i + 1]
    let pendiente = Double(b.muestra - a.muestra) / (b.host - a.host)
    return (Double(a.muestra) + (host - a.host) * pendiente) / Self.tasa
  }

  /// Cuánto se aparta el reloj de una pista del Mac, en partes por millón:
  /// lo que la Fase 0 quiere medir. Nil con menos de dos anclas.
  public func derivaPPM(pista: Pista) -> Double? {
    guard let anclas = porPista[pista], let a = anclas.first, let b = anclas.last, b.muestra > a.muestra else {
      return nil
    }
    let segundosDeAudio = Double(b.muestra - a.muestra) / Self.tasa
    let segundosDelMac = b.host - a.host
    guard segundosDelMac > 0 else { return nil }
    return (segundosDeAudio / segundosDelMac - 1) * 1_000_000
  }
}
