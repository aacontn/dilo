// Propio de Dilo. Idea, sin código: BetterWispr Domain/WritingMode.swift,
// derivado de VoiceInk (GPL-3): prioridad palabra > sitio > app, calce de
// sitio por host y ruta por segmentos, palabra disparadora sólo al principio
// o al final, la más larga primero.
import Foundation

/// ¿Esta página es de este sitio? Host igual o subdominio, y la ruta del
/// patrón como prefijo **por segmentos**: `x.com` no calza con `dropbox.com`,
/// y `mail.google.com/mail` no calza con `mail.google.com/mailbox`.
public enum CalceDeSitio {
  public static func calza(_ sitio: String, con patron: String) -> Bool {
    let (hostSitio, rutaSitio) = partir(sitio)
    let (hostPatron, rutaPatron) = partir(patron)
    guard !hostPatron.isEmpty, !hostSitio.isEmpty else { return false }
    let mismoHost = hostSitio == hostPatron || hostSitio.hasSuffix("." + hostPatron)
    return mismoHost && rutaSitio.starts(with: rutaPatron)
  }

  /// Sin esquema, sin `www.` ni `*.`, sin consulta: lo que la persona
  /// escribió en Ajustes y lo que leyó `LectorDeSitio` quedan comparables.
  static func partir(_ texto: String) -> (host: String, ruta: [Substring]) {
    var limpio = texto.trimmingCharacters(in: .whitespaces).lowercased()
    for prefijo in ["https://", "http://"] where limpio.hasPrefix(prefijo) {
      limpio.removeFirst(prefijo.count)
    }
    for prefijo in ["*.", "www."] where limpio.hasPrefix(prefijo) {
      limpio.removeFirst(prefijo.count)
    }
    if let corte = limpio.firstIndex(where: { $0 == "?" || $0 == "#" }) {
      limpio = String(limpio[..<corte])
    }
    let partes = limpio.split(separator: "/", omittingEmptySubsequences: true)
    guard let host = partes.first else { return ("", []) }
    return (String(host), Array(partes.dropFirst()))
  }
}

/// Una frase dicha al principio o al final que elige el modo y se va del
/// texto: «como correo: mañana no llego» → modo Correo, «Mañana no llego».
///
/// En medio no cuenta: «mándale un correo a Pedro» es contenido.
public enum PalabraDisparadora {
  public struct Hallazgo: Equatable, Sendable {
    public var modoID: String
    public var disparadora: String
    public var textoSinElla: String
  }

  public static func buscar(en texto: String, modos: [Modo]) -> Hallazgo? {
    let palabras = texto.split(whereSeparator: \.isWhitespace).map(String.init)
    let llaves = palabras.map(llave)
    // La más larga primero: «como correo formal» le gana a «como correo».
    let candidatas = modos.flatMap { modo in modo.disparadoras.map { (modo.id, $0) } }
      .map { ($0.0, $0.1, $0.1.split(whereSeparator: \.isWhitespace).map { llave(String($0)) }) }
      .filter { !$0.2.isEmpty && !$0.2.contains("") }
      .sorted { $0.2.count > $1.2.count }

    for (modoID, disparadora, partes) in candidatas where partes.count < palabras.count {
      if Array(llaves.prefix(partes.count)) == partes {
        let resto = palabras.dropFirst(partes.count).joined(separator: " ")
        return Hallazgo(
          modoID: modoID, disparadora: disparadora, textoSinElla: conMayuscula(resto)
        )
      }
      if Array(llaves.suffix(partes.count)) == partes {
        // Se conserva el cierre que llevaba la disparadora: «…mañana, como
        // correo.» sigue terminando en punto.
        let cierre = palabras.last?.last.flatMap { ".?!".contains($0) ? String($0) : nil } ?? ""
        var resto = palabras.dropLast(partes.count).joined(separator: " ")
        while let ultimo = resto.last, ",;:".contains(ultimo) { resto.removeLast() }
        if let ultimo = resto.last, ".?!".contains(ultimo) {
          return Hallazgo(modoID: modoID, disparadora: disparadora, textoSinElla: resto)
        }
        return Hallazgo(modoID: modoID, disparadora: disparadora, textoSinElla: resto + cierre)
      }
    }
    return nil
  }

  /// Sin tildes, sin mayúsculas y sin la puntuación pegada: el motor escribe
  /// «Correo:» o «correo,» según cómo pausaste.
  static func llave(_ palabra: String) -> String {
    palabra.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
      .filter { $0.isLetter || $0.isNumber }
  }

  /// Lo que queda arranca la frase: la primera letra en mayúscula, y lo que
  /// la disparadora dejaba colgando al frente («: mañana») se va.
  static func conMayuscula(_ texto: String) -> String {
    var limpio = Substring(texto)
    while let primero = limpio.first, ",;:".contains(primero) || primero == " " {
      limpio = limpio.dropFirst()
    }
    return limpio.prefix(1).uppercased() + limpio.dropFirst()
  }
}

/// Las señales que eligen un modo sin tecla, en su orden, y lo que la muesca
/// y el historial dicen de cada una.
public enum EleccionAutomatica {
  public enum Senal: Equatable, Sendable {
    case palabra(String)
    case sitio(String)
    case app(String)
    case palabrasClave
  }

  /// El modo cuyos sitios calzan con esta página, si es uno solo. Dos modos
  /// con el mismo sitio no deciden nada: pasa a la app.
  public static func porSitio(_ sitio: String?, modos: [Modo]) -> Modo? {
    guard let sitio, !sitio.isEmpty else { return nil }
    let calzan = modos.filter { $0.sitios.contains { CalceDeSitio.calza(sitio, con: $0) } }
    return calzan.count == 1 ? calzan[0] : nil
  }

  /// Lo que va al lado del nombre del modo en la muesca, para que se vea
  /// por qué apareció y se pueda corregir la regla.
  public static func enLaMuesca(_ senal: Senal) -> String {
    switch senal {
    case .palabra: "lo dijiste"
    case .sitio: "por el sitio"
    case .app: "por la app"
    case .palabrasClave: "por lo que dijiste"
    }
  }
}
