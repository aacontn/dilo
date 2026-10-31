import Foundation

/// Una reunión leída del disco, con dónde está.
public struct ReunionEnDisco: Sendable, Equatable, Identifiable {
  public var reunion: Reunion
  public var carpeta: URL
  /// Si está en el respaldo interno, esperando que vuelva el SSD.
  public var enElRespaldo: Bool

  public init(reunion: Reunion, carpeta: URL, enElRespaldo: Bool) {
    self.reunion = reunion
    self.carpeta = carpeta
    self.enElRespaldo = enElRespaldo
  }

  public var id: String { reunion.id }

  public var estado: EstadoParaMostrar {
    EstadoParaMostrar.de(reunion.estado, enElRespaldo: enElRespaldo)
  }

  public func archivo(_ nombre: String) -> URL { carpeta.appending(path: nombre) }
}

/// Lee las reuniones de sus carpetas. Archivos legibles y sin base de datos,
/// como el historial: el CLI y el MCP los leen sin la app abierta (spec,
/// «Datos»).
public struct LectorDeReuniones: Sendable {
  public var raiz: URL
  public var respaldo: URL?

  public init(raiz: URL, respaldo: URL? = nil) {
    self.raiz = raiz
    self.respaldo = respaldo
  }

  /// Todas, de la más nueva a la más vieja. Una carpeta sin `reunion.json`
  /// legible no es una reunión y se salta: un archivo roto no esconde a las
  /// demás. Si la raíz no existe, no hay reuniones; si existe y no se deja
  /// listar, es un error que quien llama tiene que poder decir.
  public func todas() throws -> [ReunionEnDisco] {
    var salida = try leer(raiz, enElRespaldo: false)
    if let respaldo {
      let enElSSD = Set(salida.map(\.id))
      // Una reunión que ya se copió al SSD y todavía no se borró del interno
      // aparece una vez, la del SSD.
      salida += (try? leer(respaldo, enElRespaldo: true))?.filter { !enElSSD.contains($0.id) } ?? []
    }
    return salida.sorted { $0.reunion.inicio > $1.reunion.inicio }
  }

  public func reunion(id: String) throws -> ReunionEnDisco? {
    try todas().first { $0.id == id }
  }

  private func leer(_ raiz: URL, enElRespaldo: Bool) throws -> [ReunionEnDisco] {
    let fm = FileManager.default
    guard fm.fileExists(atPath: raiz.path(percentEncoded: false)) else { return [] }
    var salida: [ReunionEnDisco] = []
    for año in try fm.contentsOfDirectory(at: raiz, includingPropertiesForKeys: nil) {
      guard año.lastPathComponent.count == 4, Int(año.lastPathComponent) != nil else { continue }
      for carpeta in (try? fm.contentsOfDirectory(at: año, includingPropertiesForKeys: nil)) ?? [] {
        if let reunion = Self.reunion(en: carpeta) {
          salida.append(ReunionEnDisco(reunion: reunion, carpeta: carpeta, enElRespaldo: enElRespaldo))
        }
      }
    }
    return salida
  }

  public static func reunion(en carpeta: URL) -> Reunion? {
    guard let datos = try? Data(contentsOf: carpeta.appending(path: CarpetaDeReunion.reunion)) else { return nil }
    return try? Reunion.decodificador.decode(Reunion.self, from: datos)
  }

  public static func palabras(de reunion: ReunionEnDisco) -> [PalabraDelGuion] {
    guard let datos = try? Data(contentsOf: reunion.archivo(CarpetaDeReunion.guion)) else { return [] }
    return ArchivoDelGuion.leer(datos)
  }

  public static func lineas(de reunion: ReunionEnDisco) -> [LineaDelGuion] {
    LineasDelGuion.armar(palabras(de: reunion))
  }

  /// `guion.md` tal cual, o nil si todavía no hay guion.
  public static func guionLegible(de reunion: ReunionEnDisco) -> String? {
    try? String(contentsOf: reunion.archivo(CarpetaDeReunion.guionLegible), encoding: .utf8)
  }

  /// Las notas de la persona, en orden; ninguna si no escribió.
  public static func notas(de reunion: ReunionEnDisco) -> [NotaDeLaReunion] {
    notas(en: reunion.carpeta)
  }

  public static func notas(en carpeta: URL) -> [NotaDeLaReunion] {
    guard let datos = try? Data(contentsOf: carpeta.appending(path: CarpetaDeReunion.notas)) else { return [] }
    return ArchivoDeNotas.leer(datos)
  }

  public static func relojes(de reunion: ReunionEnDisco) -> [AnclaDeReloj] {
    guard let datos = try? Data(contentsOf: reunion.archivo(CarpetaDeReunion.relojes)) else { return [] }
    return AnclaDeReloj.leer(datos)
  }
}

/// Escribe lo de una reunión. Todo con escritura atómica: un corte de luz a
/// mitad de un `reunion.json` deja el anterior, no medio archivo.
public enum EscritorDeReunion {
  public static func guardar(_ reunion: Reunion, en carpeta: URL) throws {
    try FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
    let datos = try Reunion.codificador.encode(reunion)
    try datos.write(to: carpeta.appending(path: CarpetaDeReunion.reunion), options: .atomic)
  }

  /// `guion.jsonl` y su vista `guion.md`, siempre juntos: el `.md` es una
  /// vista del `.jsonl` y nunca puede quedar de otra versión.
  public static func guardarGuion(
    _ palabras: [PalabraDelGuion], reunion: Reunion, en carpeta: URL, zona: TimeZone = .current
  ) throws {
    try ArchivoDelGuion.codificar(palabras).write(to: carpeta.appending(path: CarpetaDeReunion.guion), options: .atomic)
    try regenerarLegible(palabras, reunion: reunion, en: carpeta, zona: zona)
  }

  /// `notas.jsonl`, entero: se llama una vez por nota, y si la reunión se mudó
  /// al respaldo la copia de allá tiene que tenerlas todas.
  public static func guardarNotas(_ notas: [NotaDeLaReunion], en carpeta: URL) throws {
    try FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
    try ArchivoDeNotas.codificar(notas).write(to: carpeta.appending(path: CarpetaDeReunion.notas), options: .atomic)
  }

  /// Vuelve a escribir `guion.md`: tras renombrar a un hablante, el guion es
  /// el mismo pero los nombres no. Las notas se leen de su archivo, para que
  /// ningún camino las pierda.
  public static func regenerarLegible(
    _ palabras: [PalabraDelGuion], reunion: Reunion, en carpeta: URL, zona: TimeZone = .current
  ) throws {
    let markdown = LineasDelGuion.markdown(
      reunion: reunion, lineas: LineasDelGuion.armar(palabras), notas: LectorDeReuniones.notas(en: carpeta), zona: zona
    )
    try Data(markdown.utf8).write(to: carpeta.appending(path: CarpetaDeReunion.guionLegible), options: .atomic)
  }

  /// Renombra a un hablante en todas sus líneas: cambia `reunion.json` y
  /// regenera `guion.md`; las palabras nombran al hablante por id y no se
  /// tocan.
  public static func renombrar(_ id: String, a nombre: String?, en reunion: ReunionEnDisco) throws -> Reunion {
    var nueva = reunion.reunion
    nueva.renombrar(id, a: nombre)
    try guardar(nueva, en: reunion.carpeta)
    try regenerarLegible(LectorDeReuniones.palabras(de: reunion), reunion: nueva, en: reunion.carpeta)
    return nueva
  }
}
