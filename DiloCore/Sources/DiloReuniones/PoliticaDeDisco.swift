import CryptoKit
import Foundation

/// Dónde se graba y cuándo no se empieza (spec, «Espacio» y «Si el SSD 1 no
/// está montado»). Grabar nunca depende del disco: sin el SSD, la reunión va
/// al respaldo interno y se junta cuando vuelve.
public enum PoliticaDeDisco {
  /// Con menos que esto libre en el destino no se empieza: una hora son
  /// ~230 MB las dos pistas, y quedarse sin disco a media reunión es perderla.
  public static let minimoParaEmpezar: Int64 = 1_000_000_000
  /// Grabando, bajo esto se avisa.
  public static let avisoBajo: Int64 = 500_000_000

  public enum Lugar: String, Sendable, Equatable {
    case raiz
    case respaldo
  }

  public enum Destino: Sendable, Equatable {
    case en(Lugar)
    /// No hay espacio donde tocaba grabar. Lleva cuánto había, para decirlo.
    case sinEspacio(Lugar, libre: Int64)
  }

  /// - Parameters:
  ///   - raizDisponible: el volumen de la raíz está montado y se puede
  ///     escribir. Una raíz fuera de `/Volumes` siempre lo está.
  ///   - libreEnRaiz, libreEnRespaldo: bytes libres, o nil si no se pudo
  ///     leer (entonces no se bloquea: mejor intentar que no grabar).
  public static func destino(raizDisponible: Bool, libreEnRaiz: Int64?, libreEnRespaldo: Int64?) -> Destino {
    let lugar: Lugar = raizDisponible ? .raiz : .respaldo
    let libre = raizDisponible ? libreEnRaiz : libreEnRespaldo
    if let libre, libre < minimoParaEmpezar { return .sinEspacio(lugar, libre: libre) }
    return .en(lugar)
  }

  public static func hayQueAvisar(libre: Int64?) -> Bool {
    guard let libre else { return false }
    return libre < avisoBajo
  }
}

/// Copia las reuniones del respaldo interno al SSD cuando vuelve, y sólo
/// borra la copia interna cuando la del SSD está comprobada: mismo tamaño y
/// misma suma de cada archivo (spec, «Si el SSD 1 no está montado»). Nada se
/// pierde y nada se queda a vivir en el interno.
public enum MudanzaDeReuniones {
  public struct Resultado: Sendable, Equatable {
    public var id: String
    public var destino: URL
    /// Si se borró la copia interna. Falso si algo no coincidió: se reintenta
    /// la próxima vez que se monte el disco.
    public var verificada: Bool
  }

  /// Muda todo lo que haya en `respaldo` a `raiz`, salvo las reuniones de
  /// `noTocar` (la que se está grabando ahora mismo).
  public static func mudar(desde respaldo: URL, a raiz: URL, noTocar: Set<String> = []) -> [Resultado] {
    let fm = FileManager.default
    let lector = LectorDeReuniones(raiz: respaldo)
    guard let pendientes = try? lector.todas() else { return [] }
    var resultados: [Resultado] = []
    for pendiente in pendientes where !noTocar.contains(pendiente.id) {
      let año = pendiente.carpeta.deletingLastPathComponent().lastPathComponent
      let destino = CarpetaDeReunion.url(raiz: raiz, año: año, nombre: pendiente.carpeta.lastPathComponent)
      let verificada = (try? copiar(pendiente.carpeta, a: destino)) ?? false
      if verificada {
        try? fm.removeItem(at: pendiente.carpeta)
        let carpetaDelAño = pendiente.carpeta.deletingLastPathComponent()
        if (try? fm.contentsOfDirectory(atPath: carpetaDelAño.path(percentEncoded: false)))?.isEmpty == true {
          try? fm.removeItem(at: carpetaDelAño)
        }
      }
      resultados.append(Resultado(id: pendiente.id, destino: destino, verificada: verificada))
    }
    return resultados
  }

  /// Copia cada archivo de la carpeta y comprueba la copia. Lo del respaldo
  /// manda: es lo más nuevo. Si el disco se desmontó a media reunión, en el
  /// SSD quedó `yo.wav` y un `reunion.json` viejo, y en el interno `yo-2.wav`
  /// con el `reunion.json` que nombra a los dos.
  static func copiar(_ origen: URL, a destino: URL) throws -> Bool {
    let fm = FileManager.default
    try fm.createDirectory(at: destino, withIntermediateDirectories: true)
    let archivos = try fm.contentsOfDirectory(at: origen, includingPropertiesForKeys: [.isRegularFileKey])
      .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    for archivo in archivos {
      let copia = destino.appending(path: archivo.lastPathComponent)
      if fm.fileExists(atPath: copia.path(percentEncoded: false)) {
        if try mismoContenido(archivo, copia) { continue }
        try fm.removeItem(at: copia)
      }
      try fm.copyItem(at: archivo, to: copia)
    }
    return try archivos.allSatisfy { try mismoContenido($0, destino.appending(path: $0.lastPathComponent)) }
  }

  static func mismoContenido(_ a: URL, _ b: URL) throws -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: b.path(percentEncoded: false)) else { return false }
    let tamañoA = try fm.attributesOfItem(atPath: a.path(percentEncoded: false))[.size] as? Int64
    let tamañoB = try fm.attributesOfItem(atPath: b.path(percentEncoded: false))[.size] as? Int64
    guard tamañoA == tamañoB else { return false }
    return try suma(a) == suma(b)
  }

  /// SHA-256 leyendo de a 1 MB: un WAV de una hora son 115 MB y no tiene por
  /// qué entrar entero a la RAM.
  public static func suma(_ url: URL) throws -> String {
    let archivo = try FileHandle(forReadingFrom: url)
    defer { try? archivo.close() }
    var hash = SHA256()
    while let trozo = try archivo.read(upToCount: 1 << 20), !trozo.isEmpty {
      hash.update(data: trozo)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
