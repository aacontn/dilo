import Foundation

/// Lee cuánto va de los límites de Codex, de sus propias sesiones en disco.
///
/// Codex anota en cada sesión (`~/.codex/sessions/AAAA/MM/DD/rollout-*.jsonl`)
/// un evento `token_count` que trae `rate_limits`: el porcentaje usado de la
/// ventana de cinco horas (`primary`) y de la semanal (`secondary`), y cuándo
/// se reinicia cada una. Es el mismo número que Codex muestra, así que no hay
/// nada que estimar: basta con la **última** línea que lo trae.
///
/// Sin red, sin credenciales y sin tocar nada de Codex: sólo lee.
public struct LectorDeCodex: Sendable {
  public let sesiones: URL
  /// Cuántos días hacia atrás buscar una sesión con límites. Una ventana
  /// semanal vieja de más de eso ya se reinició de todos modos.
  public var diasHaciaAtras = 8

  public init(sesiones: URL) {
    self.sesiones = sesiones
  }

  public func leer(ahora: Date = Date()) -> ConsumoDeIA? {
    for archivo in archivosRecientes(ahora: ahora) {
      if let consumo = Self.ultimoConsumo(en: archivo) {
        return ConsumoDeIA(
          ventanaCorta: consumo.ventanaCorta.vigente(en: ahora),
          ventanaSemanal: consumo.ventanaSemanal?.vigente(en: ahora),
          plan: consumo.plan
        )
      }
    }
    return nil
  }

  /// Las sesiones de los últimos días, la más recién escrita primero. Se
  /// recorren sólo las carpetas de esos días: el archivo de Codex crece con
  /// los meses y listarlo entero cada minuto no vale lo que cuesta.
  func archivosRecientes(ahora: Date) -> [URL] {
    let calendario = Calendar(identifier: .gregorian)
    let fm = FileManager.default
    var encontrados: [(URL, Date)] = []
    for dias in 0...diasHaciaAtras {
      guard let dia = calendario.date(byAdding: .day, value: -dias, to: ahora) else { continue }
      let c = calendario.dateComponents([.year, .month, .day], from: dia)
      let carpeta = sesiones
        .appending(path: String(format: "%04d", c.year ?? 0))
        .appending(path: String(format: "%02d", c.month ?? 0))
        .appending(path: String(format: "%02d", c.day ?? 0))
      let archivos = (try? fm.contentsOfDirectory(
        at: carpeta,
        includingPropertiesForKeys: [.contentModificationDateKey]
      )) ?? []
      for archivo in archivos where archivo.pathExtension == "jsonl" {
        let fecha = (try? archivo.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? .distantPast
        encontrados.append((archivo, fecha))
      }
    }
    return encontrados.sorted { $0.1 > $1.1 }.map(\.0)
  }

  /// La última línea con límites de un archivo. Se lee sólo la cola: una
  /// sesión larga pesa decenas de megas y la línea que importa está al final.
  static func ultimoConsumo(en archivo: URL, cola: Int = 512 * 1024) -> ConsumoDeIA? {
    guard let texto = LecturaDeCola.leer(archivo, bytes: cola) else { return nil }
    for linea in texto.split(separator: "\n").reversed() where linea.contains("\"rate_limits\"") {
      if let consumo = decodificar(linea) { return consumo }
    }
    return nil
  }

  static func decodificar(_ linea: Substring) -> ConsumoDeIA? {
    guard
      let evento = try? JSONDecoder().decode(Evento.self, from: Data(linea.utf8)),
      let limites = evento.payload?.rate_limits,
      let corta = limites.primary
    else { return nil }
    return ConsumoDeIA(
      ventanaCorta: corta.ventana,
      ventanaSemanal: limites.secondary?.ventana,
      plan: limites.plan_type
    )
  }

  // Sólo lo que se lee; el resto del evento se ignora a propósito para que un
  // campo nuevo de Codex no rompa la lectura.
  private struct Evento: Decodable {
    let payload: Carga?
  }

  private struct Carga: Decodable {
    let rate_limits: Limites?
  }

  private struct Limites: Decodable {
    let primary: Limite?
    let secondary: Limite?
    let plan_type: String?
  }

  private struct Limite: Decodable {
    let used_percent: Double
    let window_minutes: Double?
    let resets_at: Double?

    var ventana: VentanaDeUso {
      VentanaDeUso(
        porcentaje: used_percent,
        seReiniciaEn: resets_at.map { Date(timeIntervalSince1970: $0) },
        duracion: (window_minutes ?? 300) * 60
      )
    }
  }
}

/// Lee los últimos bytes de un archivo, empezando en una línea entera.
enum LecturaDeCola {
  static func leer(_ archivo: URL, bytes: Int) -> String? {
    guard let manija = try? FileHandle(forReadingFrom: archivo) else { return nil }
    defer { try? manija.close() }
    guard let fin = try? manija.seekToEnd() else { return nil }
    let desde = fin > UInt64(bytes) ? fin - UInt64(bytes) : 0
    try? manija.seek(toOffset: desde)
    guard let datos = try? manija.readToEnd() else { return nil }
    var texto = String(decoding: datos, as: UTF8.self)
    // Cortando a mitad de archivo la primera línea sale partida: se descarta.
    if desde > 0, let salto = texto.firstIndex(of: "\n") {
      texto = String(texto[texto.index(after: salto)...])
    }
    return texto
  }
}
