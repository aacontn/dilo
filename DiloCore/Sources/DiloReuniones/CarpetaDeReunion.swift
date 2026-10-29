import Foundation

/// Dónde vive una **Reunión** en disco y cómo se llaman sus archivos.
///
/// ```
/// <raíz>/2026/2026-10-21-1530-reunion-con-camila/
///   reunion.json, yo.wav, ellos.wav, relojes.jsonl, guion.jsonl, guion.md
/// ```
///
/// Un año por carpeta para que Finder no liste mil. El nombre va en ASCII,
/// minúsculas y guiones (regla de la casa): el título con tildes vive en
/// `reunion.json`.
public enum CarpetaDeReunion {
  public static let reunion = "reunion.json"
  public static let guion = "guion.jsonl"
  public static let guionLegible = "guion.md"
  public static let relojes = "relojes.jsonl"

  /// La raíz de fábrica: junto al repo, dentro de la entidad Dilo, en el SSD
  /// que se respalda cada noche (spec, «Datos»).
  public static let raizDeFabrica = URL(filePath: "/Volumes/SSD 1/Dilo/reuniones", directoryHint: .isDirectory)

  /// El volumen del que depende la raíz de fábrica. Si no está montado se
  /// graba en el respaldo interno.
  public static func volumen(de raiz: URL) -> URL? {
    let componentes = raiz.standardizedFileURL.pathComponents
    guard componentes.count >= 3, componentes[1] == "Volumes" else { return nil }
    return URL(filePath: "/Volumes/\(componentes[2])", directoryHint: .isDirectory)
  }

  /// El respaldo interno, de paso: lo que se grabó con el SSD desmontado y
  /// espera a que vuelva.
  public static func respaldoInterno(applicationSupport: URL) -> URL {
    applicationSupport
      .appending(path: "Dilo", directoryHint: .isDirectory)
      .appending(path: "reuniones-pendientes", directoryHint: .isDirectory)
  }

  /// `2026-10-21T15:30:07`, en la hora del Mac. Es el id para agentes, el
  /// mismo formato que los dictados.
  public static func id(inicio: Date, zona: TimeZone = .current) -> String {
    let c = calendario(zona).dateComponents([.year, .month, .day, .hour, .minute, .second], from: inicio)
    return String(
      format: "%04d-%02d-%02dT%02d:%02d:%02d",
      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
    )
  }

  public static func año(inicio: Date, zona: TimeZone = .current) -> String {
    String(format: "%04d", calendario(zona).component(.year, from: inicio))
  }

  /// `2026-10-21-1530-reunion-con-camila`. Si ya existe una con ese nombre
  /// (dos reuniones en el mismo minuto con el mismo título) se le suma `-2`,
  /// `-3`…
  public static func nombre(
    inicio: Date, titulo: String, existentes: Set<String> = [], zona: TimeZone = .current
  ) -> String {
    let c = calendario(zona).dateComponents([.year, .month, .day, .hour, .minute], from: inicio)
    let fecha = String(
      format: "%04d-%02d-%02d-%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0
    )
    let base = "\(fecha)-\(enASCII(titulo))"
    guard existentes.contains(base) else { return base }
    var n = 2
    while existentes.contains("\(base)-\(n)") { n += 1 }
    return "\(base)-\(n)"
  }

  /// El título en ASCII, minúsculas y guiones, sin guiones dobles ni en los
  /// bordes, y corto: una ruta larga es la que se rompe en la línea de
  /// comandos. Si no queda nada (un título de puros emojis), «reunion».
  public static func enASCII(_ titulo: String, largoMaximo: Int = 48) -> String {
    let plegado = titulo
      .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "es"))
      .lowercased()
    var salida = ""
    var guionPendiente = false
    for escalar in plegado.unicodeScalars {
      let ascii = escalar.isASCII && (CharacterSet.alphanumerics.contains(escalar))
      if ascii {
        if guionPendiente, !salida.isEmpty { salida.append("-") }
        guionPendiente = false
        salida.unicodeScalars.append(escalar)
      } else {
        guionPendiente = true
      }
    }
    if salida.count > largoMaximo {
      salida = String(salida.prefix(largoMaximo))
      // No dejar media palabra colgando de un guion.
      while salida.hasSuffix("-") { salida.removeLast() }
    }
    return salida.isEmpty ? "reunion" : salida
  }

  /// La carpeta de una reunión bajo una raíz.
  public static func url(raiz: URL, año: String, nombre: String) -> URL {
    raiz.appending(path: año, directoryHint: .isDirectory).appending(path: nombre, directoryHint: .isDirectory)
  }

  private static func calendario(_ zona: TimeZone) -> Calendar {
    var calendario = Calendar(identifier: .gregorian)
    calendario.timeZone = zona
    return calendario
  }
}
