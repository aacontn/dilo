import Foundation

/// Lo poco que la detección necesita saber del disco. Existe para que los
/// tests armen una carpeta de mentira en memoria y nunca miren el `~/.claude`
/// de quien los corre.
public protocol SistemaDeArchivos: Sendable {
  /// Lo que hay directamente dentro de una carpeta, o nil si no existe o no
  /// es una carpeta.
  func contenido(de carpeta: URL) -> [URL]?
}

/// El disco de verdad.
public struct SistemaDeArchivosReal: SistemaDeArchivos {
  public init() {}

  public func contenido(de carpeta: URL) -> [URL]? {
    try? FileManager.default.contentsOfDirectory(
      at: carpeta,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
  }
}

/// En qué quedó una fuente de datos en este Mac, para la tarjeta de Ajustes.
public enum EstadoDeLaFuente: Equatable, Sendable {
  /// Hay de dónde leer.
  case listo
  /// La herramienta no está, o nunca se usó: no hay registros que leer.
  case noEncontrado
  /// Esta versión de Dilo no puede leerla: el sandbox de App Store no deja
  /// entrar a las carpetas de otras apps.
  case noDisponibleEnEstaVersion
}

/// Si cada fuente de la muesca tiene de dónde leer, mirado en vivo.
///
/// Es lo que Ajustes muestra en cada tarjeta —*Listo*, *No encontrado*, *No
/// disponible en esta versión*— y vive acá, fuera de la vista, para poder
/// afirmarlo con un disco de mentira. Mira sólo si hay **una** sesión: corta
/// en el primer `.jsonl` que encuentra, así que cuesta lo mismo con diez
/// sesiones que con diez mil.
public struct DeteccionDeFuentes: Sendable {
  public let inicio: URL
  public let admiteArchivosDeOtrasApps: Bool
  let sistema: any SistemaDeArchivos

  /// Cuántas carpetas se miran como mucho por fuente antes de rendirse. Una
  /// instalación normal encuentra su primera sesión en la primera o la
  /// segunda; esto es para que una carpeta rara no deje a Ajustes pensando.
  static let carpetasComoMucho = 300

  public init(
    inicio: URL = URL(filePath: NSHomeDirectory()),
    admiteArchivosDeOtrasApps: Bool,
    sistema: any SistemaDeArchivos = SistemaDeArchivosReal()
  ) {
    self.inicio = inicio
    self.admiteArchivosDeOtrasApps = admiteArchivosDeOtrasApps
    self.sistema = sistema
  }

  /// Dónde deja cada herramienta sus registros, o nil si el dato no sale de
  /// archivos. Es el único lugar que lo dice: los lectores de la muesca
  /// arrancan de acá.
  public static func carpeta(de dato: DatoDeLaMuesca, en inicio: URL) -> URL? {
    switch dato {
    case .claude: inicio.appending(path: ".claude/projects")
    case .codex: inicio.appending(path: ".codex/sessions")
    case .ninguno, .cpu, .ram: nil
    }
  }

  /// Qué tan hondo están las sesiones bajo su carpeta: Claude Code guarda
  /// `projects/<proyecto>/<sesión>.jsonl`, Codex
  /// `sessions/AAAA/MM/DD/rollout-*.jsonl`.
  static func niveles(de dato: DatoDeLaMuesca) -> Int {
    switch dato {
    case .claude: 2
    case .codex: 4
    case .ninguno, .cpu, .ram: 0
    }
  }

  public func estado(de dato: DatoDeLaMuesca) -> EstadoDeLaFuente {
    guard dato.leeArchivosDeOtraApp else { return .listo }
    guard admiteArchivosDeOtrasApps else { return .noDisponibleEnEstaVersion }
    guard let carpeta = Self.carpeta(de: dato, en: inicio) else { return .listo }
    return haySesion(bajo: carpeta, niveles: Self.niveles(de: dato)) ? .listo : .noEncontrado
  }

  /// Si hay al menos un `.jsonl` hasta `niveles` carpetas más abajo.
  func haySesion(bajo raiz: URL, niveles: Int) -> Bool {
    var pendientes: [(URL, Int)] = [(raiz, 1)]
    var miradas = 0
    while let (carpeta, nivel) = pendientes.popLast(), miradas < Self.carpetasComoMucho {
      miradas += 1
      guard let entradas = sistema.contenido(de: carpeta) else { continue }
      if entradas.contains(where: { $0.pathExtension == "jsonl" }) { return true }
      guard nivel < niveles else { continue }
      // Lo más nuevo primero: en Codex las carpetas son fechas, y la del día
      // es la que tiene más chance de tener algo.
      let hijas = entradas.filter { $0.pathExtension.isEmpty }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
      pendientes.append(contentsOf: hijas.map { ($0, nivel + 1) })
    }
    return false
  }
}
