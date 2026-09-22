import Foundation

/// Leer el historial, no sólo escribirlo: buscar, copiar y borrar una entrada
/// sin salir de Dilo.
///
/// Los archivos diarios siguen siendo texto plano en una carpeta que la
/// persona ve en el Finder — esa decisión no cambia, y es lo que permite que
/// alguien los lea, los busque y los borre con sus propias herramientas si
/// prefiere. Esto es la misma operación desde adentro.
extension DictationHistoryStore {
  /// Un dictado guardado. `dia` y `hora` se guardan como el archivo los
  /// escribió, no como `Date`: reparsear una fecha que ya está escrita es
  /// una forma barata de perderla.
  struct Entrada: Sendable, Equatable, Identifiable {
    let dia: String
    let hora: String
    let fuente: String?
    /// El modo con que se dictó, si hubo uno.
    let modo: String?
    /// Qué motor transcribió, si la entrada lo dice.
    ///
    /// Opcional **y por defecto nil**: todo lo escrito antes del 2026-09-22
    /// no lo lleva, y un historial que dejara de leerse por eso sería peor
    /// que no saber el motor. Una entrada vieja se sigue mostrando entera,
    /// sin motor.
    var motor: String? = nil
    let texto: String

    var id: String { "\(dia) \(hora) \(texto.prefix(24))" }

    /// Lo que se muestra bajo el texto: dónde iba, con qué modo salió y qué
    /// motor lo transcribió.
    var procedencia: String {
      [fuente, modo, motor].compactMap { $0 }.joined(separator: " · ")
    }
  }

  /// Todas las entradas, de la más nueva a la más vieja.
  func entradas(in folder: URL) throws -> [Entrada] {
    let archivos = (try? FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: nil
    )) ?? []
    let dias = archivos
      .filter { Self.isHistoryFileName($0.lastPathComponent) }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }

    return dias.flatMap { archivo -> [Entrada] in
      let dia = String(archivo.lastPathComponent.dropLast(4))
      let contenido = (try? String(contentsOf: archivo, encoding: .utf8)) ?? ""
      return Self.parsear(contenido, dia: dia).reversed()
    }
  }

  /// Las entradas que contienen lo buscado, en el texto, la app o el modo.
  /// Sin tildes y sin mayúsculas: se busca como se recuerda, no como se
  /// escribió.
  func buscar(_ consulta: String, in folder: URL) throws -> [Entrada] {
    let todas = try entradas(in: folder)
    let limpia = Self.plegar(consulta)
    guard !limpia.isEmpty else { return todas }
    return todas.filter { entrada in
      Self.plegar(entrada.texto).contains(limpia)
        || Self.plegar(entrada.procedencia).contains(limpia)
    }
  }

  /// Borra una entrada y deja el resto del día intacto. Si el día queda sin
  /// entradas, el archivo se va con ella: un archivo vacío es basura que la
  /// persona ve en su carpeta.
  func borrar(_ entrada: Entrada, in folder: URL) throws {
    let archivo = folder.appending(path: "\(entrada.dia).txt")
    guard let contenido = try? String(contentsOf: archivo, encoding: .utf8) else { return }
    let quedan = Self.parsear(contenido, dia: entrada.dia).filter { $0 != entrada }

    guard !quedan.isEmpty else {
      try FileManager.default.removeItem(at: archivo)
      return
    }
    let texto = quedan.map { entrada in
      "\(Self.encabezado(de: entrada))\n\(entrada.texto)\n\n"
    }.joined()
    try Data(texto.utf8).write(to: archivo, options: .atomic)
  }

  static func encabezado(de entrada: Entrada) -> String {
    var partes = [entrada.hora]
    if let fuente = entrada.fuente { partes.append(fuente) }
    if let modo = entrada.modo { partes.append("\(separadorDeModo)\(modo)") }
    if let motor = entrada.motor { partes.append("\(separadorDeMotor)\(motor)") }
    return partes.joined(separator: " ")
  }

  /// Un archivo diario son bloques de "encabezado, texto, línea en blanco".
  /// Una línea que empieza con `[hh:mm:ss]` abre una entrada; todo lo demás
  /// es cuerpo, incluidas las dos líneas que deja una traducción.
  static func parsear(_ contenido: String, dia: String) -> [Entrada] {
    var entradas: [Entrada] = []
    var hora: String?
    var fuente: String?
    var modo: String?
    var motor: String?
    var cuerpo: [String] = []

    func cerrar() {
      guard let horaAbierta = hora else { return }
      let texto = cuerpo.joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !texto.isEmpty {
        entradas.append(
          Entrada(
            dia: dia, hora: horaAbierta, fuente: fuente,
            modo: modo, motor: motor, texto: texto
          )
        )
      }
      hora = nil
      fuente = nil
      modo = nil
      motor = nil
      cuerpo = []
    }

    for linea in contenido.components(separatedBy: "\n") {
      guard let partes = encabezadoPartido(linea) else {
        if hora != nil { cuerpo.append(linea) }
        continue
      }
      cerrar()
      hora = partes.hora
      fuente = partes.fuente
      modo = partes.modo
      motor = partes.motor
    }
    cerrar()
    return entradas
  }

  static func encabezadoPartido(
    _ linea: String
  ) -> (hora: String, fuente: String?, modo: String?, motor: String?)? {
    guard linea.hasPrefix("["), let cierre = linea.firstIndex(of: "]") else { return nil }
    let hora = String(linea[linea.startIndex ... cierre])
    guard hora.count == 10 else { return nil }

    var resto = String(linea[linea.index(after: cierre)...])
      .trimmingCharacters(in: .whitespaces)
    // El motor primero: va al final de la línea, así que sacarlo antes deja
    // el modo donde siempre estuvo y una entrada vieja —que no lo lleva— se
    // parte exactamente igual que antes.
    var motor: String?
    if let marca = resto.range(of: separadorDeMotor) {
      motor = String(resto[marca.upperBound...]).trimmingCharacters(in: .whitespaces)
      resto = String(resto[..<marca.lowerBound]).trimmingCharacters(in: .whitespaces)
    }
    var modo: String?
    if let marca = resto.range(of: separadorDeModo) {
      modo = String(resto[marca.upperBound...]).trimmingCharacters(in: .whitespaces)
      resto = String(resto[..<marca.lowerBound]).trimmingCharacters(in: .whitespaces)
    }
    return (
      hora,
      resto.isEmpty ? nil : resto,
      modo?.isEmpty == true ? nil : modo,
      motor?.isEmpty == true ? nil : motor
    )
  }

  static func plegar(_ texto: String) -> String {
    texto.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
  }
}
