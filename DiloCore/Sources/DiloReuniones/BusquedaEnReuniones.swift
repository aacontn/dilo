import Foundation

/// Una línea de una reunión que coincide con lo buscado.
public struct ResultadoDeBusqueda: Codable, Sendable, Equatable {
  public var reunion: String
  public var titulo: String
  /// El número de línea en el guion, desde 0: lo que abre el guion ahí.
  public var linea: Int
  public var hablante: String
  /// `15:31`: el momento, para citarlo (lo que Wispr llama «enlace al
  /// momento»).
  public var hora: String
  public var texto: String
  public var recortado: Bool?

  public init(
    reunion: String, titulo: String, linea: Int, hablante: String, hora: String, texto: String,
    recortado: Bool? = nil
  ) {
    self.reunion = reunion
    self.titulo = titulo
    self.linea = linea
    self.hablante = hablante
    self.hora = hora
    self.texto = texto
    self.recortado = recortado
  }
}

/// Una línea de `guion.md` leída de vuelta: quién, cuándo y qué.
public struct LineaLegible: Sendable, Equatable {
  public var hablante: String
  public var hora: String
  public var texto: String

  public init(hablante: String, hora: String, texto: String) {
    self.hablante = hablante
    self.hora = hora
    self.texto = texto
  }
}

/// Buscar por lo dicho y por quién lo dijo, sin tildes ni mayúsculas, como el
/// historial (spec, «Dónde quedan, y buscar»).
///
/// «Camila despacho» encuentra las líneas de Camila que dicen «despacho»:
/// cada palabra de la consulta tiene que estar en el texto de la línea **o**
/// en el nombre de quien la dijo. Se busca sobre `guion.md`, que ya trae los
/// nombres y se lee en una pasada; con 500 reuniones se mide antes de pensar
/// en un índice.
public enum BusquedaEnReuniones {
  /// Las líneas de un `guion.md`, en orden. Lo que no tiene la forma
  /// `Nombre · 15:31 — texto` (el título, la cabecera) no es línea.
  public static func lineas(de markdown: String) -> [LineaLegible] {
    markdown.split(whereSeparator: \.isNewline).compactMap { renglon in
      let renglon = String(renglon)
      guard let raya = renglon.range(of: " — ") else { return nil }
      let cabeza = renglon[..<raya.lowerBound]
      guard let punto = cabeza.range(of: " · ", options: .backwards) else { return nil }
      let hora = String(cabeza[punto.upperBound...])
      guard hora.count == 5, hora.dropFirst(2).first == ":" else { return nil }
      return LineaLegible(
        hablante: String(cabeza[..<punto.lowerBound]), hora: hora, texto: String(renglon[raya.upperBound...])
      )
    }
  }

  /// Si una línea coincide. La consulta vacía no coincide con nada: buscar
  /// sin decir qué es pedir los recientes, que es otra herramienta.
  public static func coincide(_ linea: LineaLegible, palabras: [String], hablante: String?) -> Bool {
    let nombre = TextoPlegado.plegar(linea.hablante)
    if let hablante {
      let buscado = TextoPlegado.plegar(hablante).trimmingCharacters(in: .whitespaces)
      if !buscado.isEmpty, !nombre.contains(buscado) { return false }
    }
    guard !palabras.isEmpty else { return hablante != nil }
    let texto = TextoPlegado.plegar(linea.texto)
    return palabras.allSatisfy { texto.contains($0) || nombre.contains($0) }
  }

  public static let largoDelExtracto = 280

  /// Busca en reuniones ya leídas, de la más nueva a la más vieja, y devuelve
  /// a lo más `maximo` líneas.
  public static func buscar(
    _ consulta: String,
    hablante: String? = nil,
    en reuniones: [(reunion: Reunion, markdown: String)],
    maximo: Int
  ) -> [ResultadoDeBusqueda] {
    let palabras = TextoPlegado.palabras(consulta)
    var salida: [ResultadoDeBusqueda] = []
    for (reunion, markdown) in reuniones {
      for (numero, linea) in lineas(de: markdown).enumerated()
      where coincide(linea, palabras: palabras, hablante: hablante) {
        let largo = linea.texto.count > largoDelExtracto
        salida.append(
          ResultadoDeBusqueda(
            reunion: reunion.id, titulo: reunion.titulo, linea: numero, hablante: linea.hablante, hora: linea.hora,
            texto: largo ? String(linea.texto.prefix(largoDelExtracto)) + "…" : linea.texto,
            recortado: largo ? true : nil
          )
        )
        if salida.count >= maximo { return salida }
      }
    }
    return salida
  }
}
