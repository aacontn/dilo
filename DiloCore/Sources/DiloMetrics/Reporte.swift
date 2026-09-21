import Foundation

/// Cada uno de los cinco números del spec §3, con su umbral y su unidad.
///
/// El orden del `CaseIterable` es el orden de la tabla del reporte.
public enum Metrica: String, CaseIterable, Sendable, Codable {
  case ramEnReposo
  case cpuEnReposo
  case arranqueEnFrio
  case latenciaSoltarTexto
  case tamanoDelApp

  public var titulo: String {
    switch self {
    case .ramEnReposo: "RAM en reposo"
    case .cpuEnReposo: "CPU en reposo"
    case .arranqueEnFrio: "Arranque en frío"
    case .latenciaSoltarTexto: "Soltar → texto"
    case .tamanoDelApp: ".app sin modelos"
    }
  }

  /// Cómo se midió, en una línea. Va en el reporte porque un número sin su
  /// método es una opinión: `ps` y `footprint` no miden lo mismo.
  public var metodo: String {
    switch self {
    case .ramEnReposo: "footprint phys_footprint, 60 s tras arrancar, sin dictar"
    case .cpuEnReposo: "tiempo de CPU consumido / tiempo transcurrido, ventana de 60 s"
    case .arranqueEnFrio: "open -n -a → NSRunningApplication.isFinishedLaunching, mediana"
    case .latenciaSoltarTexto: "WAV de 5 s inyectado; de MicrophoneInput.stop() al portapapeles"
    case .tamanoDelApp: "bytes del bundle en disco"
    }
  }

  public var umbral: Double {
    switch self {
    case .ramEnReposo: Umbrales.ramEnReposoMB
    case .cpuEnReposo: Umbrales.cpuEnReposoPorcentaje
    case .arranqueEnFrio: Umbrales.arranqueEnFrioSegundos
    case .latenciaSoltarTexto: Umbrales.latenciaSoltarTextoSegundos
    case .tamanoDelApp: Umbrales.tamanoDelAppMB
    }
  }

  public var unidad: String {
    switch self {
    case .ramEnReposo, .tamanoDelApp: "MB"
    case .cpuEnReposo: "%"
    case .arranqueEnFrio, .latenciaSoltarTexto: "s"
    }
  }

  /// Todos los umbrales del spec son techos: "menor que" y nunca "igual a".
  public func cumple(_ valor: Double) -> Bool { valor < umbral }

  public func formatear(_ valor: Double) -> String {
    switch self {
    case .ramEnReposo, .tamanoDelApp: String(format: "%.1f MB", valor)
    case .cpuEnReposo: String(format: "%.2f %%", valor)
    case .arranqueEnFrio: String(format: "%.0f ms", valor * 1_000)
    case .latenciaSoltarTexto: String(format: "%.0f ms", valor * 1_000)
    }
  }

  public var umbralFormateado: String {
    switch self {
    case .ramEnReposo, .tamanoDelApp: String(format: "< %.0f MB", umbral)
    case .cpuEnReposo: String(format: "< %.0f %%", umbral)
    case .arranqueEnFrio, .latenciaSoltarTexto: String(format: "< %.0f ms", umbral * 1_000)
    }
  }
}

/// Lo que una corrida de `scripts/metrics.sh` deja escrito.
///
/// Se versiona en `docs/metricas/ultima-medicion.json` a propósito: el test de
/// umbrales lee ese archivo, así que un número que empeora rompe `swift test`
/// en la máquina de quien lo empeoró, no tres semanas después en CI.
public struct Reporte: Codable, Sendable, Equatable {
  public var generado: Date
  public var app: String
  public var maquina: String
  /// Nota libre: en qué condiciones se midió, qué quedó fuera.
  public var nota: String
  /// Una entrada por métrica medida. Una métrica ausente es una métrica que
  /// no se pudo medir, y eso también es un fallo (ver `problemas`).
  public var valores: [Metrica: Double]
  /// Lo que este entorno no puede medir, con la razón, métrica por métrica.
  ///
  /// Una métrica acá no cuenta como fallo: el runner de CI no tiene
  /// Accesibilidad ni a quién pedírsela, así que exigirle la latencia es
  /// pedirle que invente un número. Igual sale en la tabla, con el porqué.
  /// **Sólo la llena `dilo-metrics --ci`**: en un Mac de verdad lo que no se
  /// midió sigue siendo un fallo, que es todo el punto del archivo versionado.
  public var sinMedirEnEsteEntorno: [Metrica: String]

  public init(
    generado: Date = Date(),
    app: String,
    maquina: String,
    nota: String = "",
    valores: [Metrica: Double],
    sinMedirEnEsteEntorno: [Metrica: String] = [:]
  ) {
    self.generado = generado
    self.app = app
    self.maquina = maquina
    self.nota = nota
    self.valores = valores
    self.sinMedirEnEsteEntorno = sinMedirEnEsteEntorno
  }

  /// Decodifica a mano por un solo campo: `sinMedirEnEsteEntorno` no está en
  /// las mediciones ya versionadas y Swift no usa el valor por defecto cuando
  /// la clave falta. Sin esto, agregar el campo rompe cada reporte anterior.
  public init(from decoder: Decoder) throws {
    let contenedor = try decoder.container(keyedBy: CodingKeys.self)
    generado = try contenedor.decode(Date.self, forKey: .generado)
    app = try contenedor.decode(String.self, forKey: .app)
    maquina = try contenedor.decode(String.self, forKey: .maquina)
    nota = try contenedor.decodeIfPresent(String.self, forKey: .nota) ?? ""
    valores = try contenedor.decode([Metrica: Double].self, forKey: .valores)
    sinMedirEnEsteEntorno =
      try contenedor.decodeIfPresent([Metrica: String].self, forKey: .sinMedirEnEsteEntorno) ?? [:]
  }

  /// Los umbrales rotos y las métricas que faltan, en español y listos para
  /// imprimir. Vacío quiere decir que la corrida pasa.
  public var problemas: [String] {
    var salida: [String] = []
    for metrica in Metrica.allCases {
      guard let valor = valores[metrica] else {
        // Lo que este entorno no puede medir se cuenta aparte: sale en la
        // tabla con su razón, pero no tumba la corrida.
        if sinMedirEnEsteEntorno[metrica] != nil { continue }
        salida.append("\(metrica.titulo): no se midió (\(metrica.metodo))")
        continue
      }
      if !metrica.cumple(valor) {
        salida.append(
          "\(metrica.titulo): \(metrica.formatear(valor)), el umbral es \(metrica.umbralFormateado)"
        )
      }
    }
    return salida
  }

  public var cumple: Bool { problemas.isEmpty }

  /// La tabla que se pega en el plan y que el script imprime al terminar.
  public func tabla() -> String {
    var lineas = [
      "| Métrica | Medido | Umbral | ¿Pasa? | Cómo |",
      "| --- | --- | --- | --- | --- |",
    ]
    for metrica in Metrica.allCases {
      let medido = valores[metrica].map(metrica.formatear) ?? "—"
      let pasa: String
      var como = metrica.metodo
      if let valor = valores[metrica] {
        pasa = metrica.cumple(valor) ? "sí" : "**no**"
      } else if let razon = sinMedirEnEsteEntorno[metrica] {
        pasa = "no medible acá"
        como = "\(metrica.metodo) — \(razon)"
      } else {
        pasa = "**sin medir**"
      }
      lineas.append(
        "| \(metrica.titulo) | \(medido) | \(metrica.umbralFormateado) | \(pasa) | \(como) |"
      )
    }
    return lineas.joined(separator: "\n")
  }

  public static func leer(de url: URL) throws -> Reporte {
    let decodificador = JSONDecoder()
    decodificador.dateDecodingStrategy = .iso8601
    return try decodificador.decode(Reporte.self, from: Data(contentsOf: url))
  }

  public func escribir(en url: URL) throws {
    let codificador = JSONEncoder()
    codificador.dateEncodingStrategy = .iso8601
    codificador.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try codificador.encode(self).write(to: url)
  }
}

/// Para que el diccionario de valores se serialice como objeto y no como una
/// lista de pares: el JSON del reporte se lee a ojo en el plan y en el diff.
extension Metrica: CodingKeyRepresentable {}
