import Foundation

/// Lee cuánto va de la ventana de cinco horas de Claude Code, de sus propias
/// sesiones en disco.
///
/// A diferencia de Codex, Claude Code **no anota el porcentaje del plan**:
/// ese número lo pregunta a su servidor con la credencial de la cuenta, y leer
/// esa credencial desde Dilo sería pedirle a alguien su llave para mostrar un
/// porcentaje. Lo que sí queda en `~/.claude/projects/**/*.jsonl` es cada
/// respuesta con su uso, y con eso se arma la ventana del mismo modo que lo
/// hace `ccusage`: bloques de cinco horas que empiezan en la hora redonda del
/// primer mensaje, y uno nuevo cuando pasan cinco horas desde ese inicio o
/// cinco horas sin actividad.
///
/// **Qué cuenta como token.** Entrada, salida y escritura de caché; no la
/// lectura de caché. Una sesión larga relee cientos de miles de tokens de
/// caché en cada vuelta, que cuestan una fracción y dejarían el número de la
/// muesca en decenas de millones sin decir nada de cuánto se gastó.
///
/// Es un actor porque guarda hasta dónde leyó cada archivo: una sesión activa
/// pesa decenas de megas, y volver a leerla entera cada minuto sería lo más
/// caro que hiciera Dilo en reposo.
public actor LectorDeClaude {
  public let proyectos: URL
  static let duracionDelBloque: TimeInterval = 5 * 3600

  private var leidos: [URL: Leido] = [:]

  private struct Leido {
    var hasta: UInt64
    var mensajes: [String: Mensaje]
  }

  struct Mensaje: Equatable {
    let fecha: Date
    let tokens: Int
  }

  public init(proyectos: URL) {
    self.proyectos = proyectos
  }

  public func leer(ahora: Date = Date()) -> ConsumoDeIA? {
    let desde = ahora.addingTimeInterval(-24 * 3600)
    let archivos = archivosModificados(desde: desde)
    guard !archivos.isEmpty || !leidos.isEmpty else { return nil }
    for archivo in archivos { ponerAlDia(archivo) }
    // Lo que dejó de tocarse hace más de un día ya no puede estar en la
    // ventana: se suelta para que la memoria no crezca con los meses.
    let vigentes = Set(archivos)
    leidos = leidos.filter { vigentes.contains($0.key) }

    var unicos: [String: Mensaje] = [:]
    for leido in leidos.values {
      unicos.merge(leido.mensajes) { primero, _ in primero }
    }
    let mensajes = unicos.values.filter { $0.fecha >= desde && $0.fecha <= ahora }
    return ConsumoDeIA(ventanaCorta: Self.ventanaActual(de: Array(mensajes), ahora: ahora))
  }

  /// El bloque de cinco horas en curso, al modo de `ccusage`.
  static func ventanaActual(de mensajes: [Mensaje], ahora: Date) -> VentanaDeUso {
    let ordenados = mensajes.sorted { $0.fecha < $1.fecha }
    var inicio: Date?
    var ultimo: Date?
    var tokens = 0
    for mensaje in ordenados {
      if let comienzo = inicio, let previo = ultimo,
        mensaje.fecha < comienzo.addingTimeInterval(duracionDelBloque),
        mensaje.fecha.timeIntervalSince(previo) < duracionDelBloque {
        tokens += mensaje.tokens
      } else {
        inicio = horaRedonda(mensaje.fecha)
        tokens = mensaje.tokens
      }
      ultimo = mensaje.fecha
    }
    guard let inicio else {
      return VentanaDeUso(tokens: 0, seReiniciaEn: nil, duracion: duracionDelBloque)
    }
    let fin = inicio.addingTimeInterval(duracionDelBloque)
    return VentanaDeUso(tokens: tokens, seReiniciaEn: fin, duracion: duracionDelBloque)
      .vigente(en: ahora)
  }

  static func horaRedonda(_ fecha: Date) -> Date {
    Date(timeIntervalSince1970: (fecha.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
  }

  private func archivosModificados(desde: Date) -> [URL] {
    guard let recorrido = FileManager.default.enumerator(
      at: proyectos,
      includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else { return [] }
    var archivos: [URL] = []
    for case let archivo as URL in recorrido where archivo.pathExtension == "jsonl" {
      let valores = try? archivo.resourceValues(forKeys: [.contentModificationDateKey])
      if let fecha = valores?.contentModificationDate, fecha >= desde { archivos.append(archivo) }
    }
    return archivos
  }

  /// Lee sólo lo que el archivo creció desde la última vez.
  private func ponerAlDia(_ archivo: URL) {
    guard let manija = try? FileHandle(forReadingFrom: archivo) else { return }
    defer { try? manija.close() }
    guard let fin = try? manija.seekToEnd() else { return }
    var leido = leidos[archivo] ?? Leido(hasta: 0, mensajes: [:])
    // Un archivo que se achicó se reescribió: se lee de nuevo desde el
    // principio.
    if fin < leido.hasta { leido = Leido(hasta: 0, mensajes: [:]) }
    guard fin > leido.hasta else { return }
    try? manija.seek(toOffset: leido.hasta)
    guard let datos = try? manija.readToEnd() else { return }
    // Sólo hasta el último salto de línea: una línea a medio escribir se lee
    // la próxima vez, entera.
    guard let ultimoSalto = datos.lastIndex(of: UInt8(ascii: "\n")) else { return }
    let completas = datos[datos.startIndex...ultimoSalto]
    for linea in completas.split(separator: UInt8(ascii: "\n")) {
      if let (clave, mensaje) = Self.decodificar(Data(linea)) {
        leido.mensajes[clave] = mensaje
      }
    }
    leido.hasta += UInt64(completas.count)
    leidos[archivo] = leido
  }

  /// Una respuesta con su uso, y la clave con que se deduplica: Claude Code
  /// escribe una línea por bloque de contenido y repite el mismo uso en cada
  /// una, así que contar líneas contaría el mismo mensaje varias veces.
  static func decodificar(_ linea: Data) -> (String, Mensaje)? {
    // Filtro barato antes de decodificar: la inmensa mayoría de las líneas no
    // trae uso.
    guard linea.range(of: Data("\"usage\"".utf8)) != nil else { return nil }
    guard
      let entrada = try? JSONDecoder().decode(Entrada.self, from: linea),
      entrada.type == "assistant",
      let usado = entrada.message?.usage,
      let fecha = entrada.timestamp.flatMap(Self.fecha)
    else { return nil }
    let clave = [entrada.message?.id, entrada.requestId].compactMap { $0 }.joined(separator: ":")
    guard !clave.isEmpty else { return nil }
    let tokens = (usado.input_tokens ?? 0) + (usado.output_tokens ?? 0)
      + (usado.cache_creation_input_tokens ?? 0)
    return (clave, Mensaje(fecha: fecha, tokens: tokens))
  }

  static func fecha(_ texto: String) -> Date? {
    let conFraccion = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    return (try? conFraccion.parse(texto)) ?? (try? Date.ISO8601FormatStyle().parse(texto))
  }

  private struct Entrada: Decodable {
    let type: String?
    let timestamp: String?
    let requestId: String?
    let message: Contenido?
  }

  private struct Contenido: Decodable {
    let id: String?
    let usage: Uso?
  }

  private struct Uso: Decodable {
    let input_tokens: Int?
    let output_tokens: Int?
    let cache_creation_input_tokens: Int?
  }
}
