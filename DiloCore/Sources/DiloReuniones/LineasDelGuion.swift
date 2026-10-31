import Foundation

/// Una línea del **Guion**: una intervención, con quién la dijo y cuándo.
///
/// ```
/// Camila · 15:31 — Ya, te cuento lo que conversamos con Pedro.
/// ```
public struct LineaDelGuion: Codable, Sendable, Equatable {
  /// El id del hablante, o nil si nadie lo pudo decir.
  public var hablante: String?
  public var desde: Double
  public var hasta: Double
  public var texto: String
  /// Si alguna palabra de la línea se dijo encima de otra voz.
  public var solape: Bool
  /// Dónde empieza en `guion.jsonl`: lo que abre el guion en esa línea desde
  /// una búsqueda.
  public var primeraPalabra: Int

  public init(hablante: String?, desde: Double, hasta: Double, texto: String, solape: Bool, primeraPalabra: Int) {
    self.hablante = hablante
    self.desde = desde
    self.hasta = hasta
    self.texto = texto
    self.solape = solape
    self.primeraPalabra = primeraPalabra
  }
}

/// Arma las líneas desde las palabras y las escribe para leer.
///
/// Las palabras se recorren en orden de tiempo y cada cambio de hablante abre
/// una línea: cuando dos hablan a la vez, la interjección queda en su propia
/// línea, en su lugar, aunque parta la del otro (spec, «El guion»). Entre Yo
/// y Ellos ese solape sale gratis, porque son pistas distintas.
public enum LineasDelGuion {
  /// Una pausa así de larga del mismo hablante abre otra línea: es otra
  /// intervención aunque nadie haya hablado entremedio.
  public static let pausaQueParte: Double = 4
  /// Una línea más larga que esto se parte en el próximo punto: un monólogo
  /// de cinco minutos en una sola línea no se lee ni se cita.
  public static let largoQueParte: Double = 45

  public static func armar(_ palabras: [PalabraDelGuion]) -> [LineaDelGuion] {
    var lineas: [LineaDelGuion] = []
    var actual: LineaDelGuion?
    var textos: [String] = []

    func cerrar() {
      guard var linea = actual else { return }
      linea.texto = textos.joined(separator: " ")
      lineas.append(linea)
      actual = nil
      textos = []
    }

    for (indice, palabra) in palabras.enumerated() where palabra.vaAlGuion {
      let texto = palabra.texto.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !texto.isEmpty else { continue }
      if let linea = actual {
        let otroHablante = linea.hablante != palabra.hablante
        let pausa = palabra.desde - linea.hasta > pausaQueParte
        let larga = linea.hasta - linea.desde > largoQueParte && terminaFrase(textos.last)
        if otroHablante || pausa || larga { cerrar() }
      }
      if actual == nil {
        actual = LineaDelGuion(
          hablante: palabra.hablante, desde: palabra.desde, hasta: palabra.hasta, texto: "",
          solape: false, primeraPalabra: indice
        )
      }
      let hasta = max(actual?.hasta ?? palabra.hasta, palabra.hasta)
      actual?.hasta = hasta
      if palabra.tiene(.solape) { actual?.solape = true }
      textos.append(texto)
    }
    cerrar()
    return lineas
  }

  private static func terminaFrase(_ texto: String?) -> Bool {
    guard let ultimo = texto?.last else { return false }
    return ".?!…".contains(ultimo)
  }

  /// El nombre de quien dijo una línea.
  public static func nombre(_ id: String?, en hablantes: [Hablante]) -> String {
    guard let id else { return "Sin identificar" }
    return hablantes.first { $0.id == id }?.nombreVisible ?? Hablante(id: id, pista: .ellos).nombreVisible
  }

  /// `15:31`, en la hora del Mac.
  public static func hora(_ segundos: Double, inicio: Date, zona: TimeZone = .current) -> String {
    var calendario = Calendar(identifier: .gregorian)
    calendario.timeZone = zona
    let c = calendario.dateComponents([.hour, .minute], from: inicio.addingTimeInterval(segundos))
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
  }

  /// `21 oct 2026, 15:30`. Escrito a mano y no con un `DateFormatter`: el
  /// archivo es el mismo en un Mac en inglés, y un test lo puede comparar.
  public static func fecha(_ fecha: Date, zona: TimeZone = .current) -> String {
    let meses = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sept", "oct", "nov", "dic"]
    var calendario = Calendar(identifier: .gregorian)
    calendario.timeZone = zona
    let c = calendario.dateComponents([.year, .month, .day, .hour, .minute], from: fecha)
    let mes = meses[max(0, min(11, (c.month ?? 1) - 1))]
    return String(format: "%d %@ %d, %02d:%02d", c.day ?? 0, mes, c.year ?? 0, c.hour ?? 0, c.minute ?? 0)
  }

  /// `42 min`, o `1 h 05 min`.
  public static func duracion(_ segundos: TimeInterval) -> String {
    let minutos = Int((segundos / 60).rounded())
    if minutos < 60 { return "\(max(minutos, segundos > 0 ? 1 : 0)) min" }
    return String(format: "%d h %02d min", minutos / 60, minutos % 60)
  }

  /// Quiénes hablaron, en el orden de la reunión: Yo primero, después los de
  /// la llamada por orden de llegada.
  public static func quienesHablaron(_ lineas: [LineaDelGuion], hablantes: [Hablante]) -> [String] {
    let conLinea = Set(lineas.map(\.hablante))
    var nombres = hablantes.filter { conLinea.contains($0.id) }.map(\.nombreVisible)
    if conLinea.contains(nil) { nombres.append(nombre(nil, en: hablantes)) }
    return nombres
  }

  /// `guion.md`: la vista para leer y para agentes. Se genera de
  /// `reunion.json` y `guion.jsonl`; nadie lo edita a mano. Es también lo que
  /// «Copiar para Claude» deja en el portapapeles.
  ///
  /// Las notas van al final y no entre las líneas: la búsqueda abre el guion
  /// por el número de línea de este archivo, y una nota en medio lo correría.
  /// Tienen la misma forma de renglón, así que también se encuentran.
  public static func markdown(
    reunion: Reunion, lineas: [LineaDelGuion], notas: [NotaDeLaReunion] = [], zona: TimeZone = .current
  ) -> String {
    var partes = ["# \(reunion.titulo)", ""]
    var cabecera = "\(fecha(reunion.inicio, zona: zona)) · \(duracion(reunion.duracion(ahora: reunion.fin ?? reunion.inicio)))"
    let quienes = quienesHablaron(lineas, hablantes: reunion.hablantes)
    if !quienes.isEmpty { cabecera += " · Hablan: \(quienes.joined(separator: ", "))" }
    partes.append(cabecera)
    partes.append("")
    if lineas.isEmpty {
      partes.append("_Sin palabras en el guion._")
    }
    for linea in lineas {
      partes.append(texto(de: linea, reunion: reunion, zona: zona))
      partes.append("")
    }
    if !notas.isEmpty { partes += ["## Notas", ""] }
    for nota in notas {
      partes.append(texto(de: nota, reunion: reunion, zona: zona))
      partes.append("")
    }
    return partes.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
  }

  /// `Nota · 15:32 — Revisar el contrato`
  public static func texto(de nota: NotaDeLaReunion, reunion: Reunion, zona: TimeZone = .current) -> String {
    "Nota · \(hora(nota.en, inicio: reunion.inicio, zona: zona)) — \(nota.texto)"
  }

  /// `Camila · 15:31 — Ya, te cuento…`
  public static func texto(de linea: LineaDelGuion, reunion: Reunion, zona: TimeZone = .current) -> String {
    "\(nombre(linea.hablante, en: reunion.hablantes)) · \(hora(linea.desde, inicio: reunion.inicio, zona: zona)) — \(linea.texto)"
  }
}
