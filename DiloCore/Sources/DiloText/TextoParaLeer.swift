import Foundation

/// Lo escrito, pasado a lo que se dice, para que lo lea una voz neural.
///
/// Las voces de Apple traen su propio normalizador y leen «$1.250.000» bien;
/// las neurales de «Leer en voz alta» (PocketTTS, Kokoro) leen lo que reciben.
/// FluidAudio trae uno —`NemoTextProcessing`—, pero es un staticlib de Rust de
/// ~8 MB por slice que no cabe en los 25 MB del `.app` (spec §3). Éste cubre lo
/// que aparece en lo que se selecciona para escuchar en Chile: montos en pesos,
/// dólares y UF, fechas, horas, porcentajes, ordinales, RUT, teléfonos,
/// abreviaturas y siglas.
///
/// Es puro y conservador: lo que no reconoce lo deja como estaba. Una regla
/// que se equivoca hace leer algo que no estaba escrito, y eso es peor que
/// leer una cifra cifra por cifra.
public enum TextoParaLeer {
  public static func preparar(_ texto: String) -> String {
    var t = texto
    t = abreviaturas(t)
    t = rut(t)
    t = fechas(t)
    t = horas(t)
    t = montos(t)
    t = porcentajes(t)
    t = ordinales(t)
    t = unidadesDeMedida(t)
    t = telefonos(t)
    t = numeros(t)
    t = siglas(t)
    t = simbolos(t)
    return espacios(t)
  }

  // Las abreviaturas van primero: «N° 47» tiene que llegar a los números como
  // «número 47», y el punto de «Sr.» no tiene que cortar la oración después.
  static let tablaDeAbreviaturas: [(String, String)] = [
    ("EE.UU.", "Estados Unidos"), ("EE. UU.", "Estados Unidos"), ("EEUU", "Estados Unidos"),
    ("Srta.", "señorita"), ("Sra.", "señora"), ("Sr.", "señor"), ("Sres.", "señores"),
    ("Dra.", "doctora"), ("Dr.", "doctor"), ("Ud.", "usted"), ("Uds.", "ustedes"),
    ("Av.", "avenida"), ("Avda.", "avenida"), ("Depto.", "departamento"), ("Dpto.", "departamento"),
    ("Stgo.", "Santiago"), ("aprox.", "aproximadamente"), ("etc.", "etcétera"),
    ("pág.", "página"), ("págs.", "páginas"), ("Nro.", "número"), ("nro.", "número"),
    ("N°", "número"), ("Nº", "número"), ("n°", "número"), ("nº", "número"),
    ("Ltda.", "limitada"), ("S.A.", "ese a"), ("SpA", "ese pe a"),
  ]

  static func abreviaturas(_ t: String) -> String {
    var t = t
    for (corta, larga) in tablaDeAbreviaturas {
      // Sólo como palabra entera: «Sr.» dentro de «USr.» no es un señor.
      let patron = "(?<![\\p{L}\\d])" + NSRegularExpression.escapedPattern(for: corta)
      t = reemplazar(patron, en: t) { _ in larga }
    }
    return t
  }

  /// «12.345.678-9» → «doce millones … guion nueve». La K es «ka».
  static func rut(_ t: String) -> String {
    reemplazar("\\b(\\d{1,2}\\.\\d{3}\\.\\d{3})-([\\dkK])\\b", en: t) { g in
      let numero = Int(g[1].replacingOccurrences(of: ".", with: "")) ?? 0
      let verificador = g[2].lowercased() == "k" ? "ka" : NumerosEnPalabras.digitos(g[2])
      return NumerosEnPalabras.cardinal(numero) + " guion " + verificador
    }
  }

  static let meses = [
    "", "enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto",
    "septiembre", "octubre", "noviembre", "diciembre",
  ]

  /// «15/03/2026», «15-3-26», «2026-03-15» y «15/03» → «quince de marzo de
  /// dos mil veintiséis». El 1 es «primero», como se dice en Chile. Una barra
  /// con un mes imposible no es fecha y se deja.
  static func fechas(_ t: String) -> String {
    var t = reemplazar("\\b(\\d{4})-(\\d{1,2})-(\\d{1,2})\\b", en: t) { g in
      fecha(dia: Int(g[3]) ?? 0, mes: Int(g[2]) ?? 0, anio: g[1]) ?? g[0]
    }
    t = reemplazar("\\b(\\d{1,2})[/-](\\d{1,2})(?:[/-](\\d{4}|\\d{2}))?\\b(?![/-]?\\d)", en: t) { g in
      fecha(dia: Int(g[1]) ?? 0, mes: Int(g[2]) ?? 0, anio: g[3].isEmpty ? nil : g[3]) ?? g[0]
    }
    return t
  }

  private static func fecha(dia: Int, mes: Int, anio: String?) -> String? {
    guard (1...31).contains(dia), (1...12).contains(mes) else { return nil }
    var frase = (dia == 1 ? "primero" : NumerosEnPalabras.cardinal(dia)) + " de " + meses[mes]
    if let anio, var n = Int(anio) {
      // «15/03/26» es 2026: nadie escribe así una fecha del siglo pasado.
      if anio.count == 2 { n += 2000 }
      frase += " de " + NumerosEnPalabras.cardinal(n)
    }
    return frase
  }

  /// «14:30» → «catorce treinta», «9:05» → «nueve y cinco», «14:00 hrs» →
  /// «catorce horas».
  static func horas(_ t: String) -> String {
    reemplazar("\\b([01]?\\d|2[0-3]):([0-5]\\d)(?:\\s*(?:hrs?\\.?|horas|h)(?![\\p{L}]))?", en: t) { g in
      let h = Int(g[1]) ?? 0, m = Int(g[2]) ?? 0
      let hora = NumerosEnPalabras.cardinal(h, femenino: true)
      if m == 0 { return hora + (h == 1 ? " hora" : " horas") }
      if m < 10 { return hora + " y " + NumerosEnPalabras.cardinal(m) }
      return hora + " " + NumerosEnPalabras.cardinal(m)
    }
  }

  /// Un número como se escribe en Chile: punto de miles, coma decimal.
  static let numero = "\\d{1,3}(?:\\.\\d{3})+(?:,\\d+)?|\\d+(?:,\\d+)?"

  /// «$1.250.000» → «un millón doscientos cincuenta mil pesos»; «$3
  /// millones» → «tres millones de pesos»; «US$ 300» → «trescientos dólares».
  static func montos(_ t: String) -> String {
    let patron = "(US\\$|USD|CLP|\\$|€)\\s?(\(numero))(?:\\s+(mil millones|millones|millón|mil)\\b)?"
    return reemplazar(patron, en: t) { g in
      let moneda: String
      switch g[1] {
      case "US$", "USD": moneda = "dólares"
      case "€": moneda = "euros"
      default: moneda = "pesos"
      }
      let multiplo = g[3]
      let leido = cantidad(g[2], apocopado: true)
      if !multiplo.isEmpty {
        let palabraDelMultiplo = multiplo == "millón" ? "millón" : multiplo
        let conDe = multiplo != "mil"
        return leido + " " + palabraDelMultiplo + (conDe ? " de " : " ") + moneda
      }
      // «Un peso», no «un pesos».
      if g[2] == "1" { return "un " + String(moneda.dropLast()) }
      let entero = Int(g[2].replacingOccurrences(of: ".", with: "")) ?? 0
      let de = !g[2].contains(",") && NumerosEnPalabras.llevaDe(entero) ? " de " : " "
      return leido + de + moneda
    }
  }

  static func porcentajes(_ t: String) -> String {
    reemplazar("(\(numero))\\s?%", en: t) { g in
      cantidad(g[1]) + " por ciento"
    }
  }

  /// «1°», «2ª», «3er», «5to» → ordinal. El grado sólo es ordinal hasta el 20
  /// y sin C o F detrás: «25°» y «15 °C» son temperatura.
  static func ordinales(_ t: String) -> String {
    var t = reemplazar("\\b(\\d{1,3})\\s?°\\s?([CF])\\b", en: t) { g in
      NumerosEnPalabras.cardinal(Int(g[1]) ?? 0, apocopado: true) + " grados"
        + (g[2] == "C" ? " Celsius" : " Fahrenheit")
    }
    t = reemplazar("\\b(\\d{1,2})(°|º|ª|ero|er|ra|ro|do|da|to|ta|vo|va|no|na|mo|ma)(?![\\p{L}\\d])", en: t) { g in
      let n = Int(g[1]) ?? 0
      let sufijo = g[2]
      if sufijo == "°", n > 20 { return NumerosEnPalabras.cardinal(n, apocopado: true) + " grados" }
      let femenino = ["ª", "ra", "da", "ta", "va", "na", "ma"].contains(sufijo)
      return NumerosEnPalabras.ordinal(n, femenino: femenino)
    }
    return reemplazar("\\b(\\d{1,3})\\s?°", en: t) { g in
      NumerosEnPalabras.cardinal(Int(g[1]) ?? 0, apocopado: true) + " grados"
    }
  }

  static let tablaDeUnidades: [(String, String)] = [
    ("km/h", "kilómetros por hora"), ("km", "kilómetros"), ("kg", "kilos"), ("gr", "gramos"),
    ("cm", "centímetros"), ("mm", "milímetros"), ("m²", "metros cuadrados"), ("m2", "metros cuadrados"),
    ("ml", "mililitros"), ("lt", "litros"), ("GB", "gigas"), ("MB", "megas"), ("TB", "teras"),
  ]

  static func unidadesDeMedida(_ t: String) -> String {
    var t = t
    for (corta, larga) in tablaDeUnidades {
      let patron = "(\(numero))\\s?" + NSRegularExpression.escapedPattern(for: corta) + "(?![\\p{L}\\d])"
      t = reemplazar(patron, en: t) { g in
        g[1] == "1" ? "un " + String(larga.dropLast()) : cantidad(g[1], apocopado: true) + " " + larga
      }
    }
    return t
  }

  /// «+56 9 1234 5678» y «912345678» se dicen cifra por cifra: nadie lee un
  /// teléfono como «novecientos doce millones…».
  static func telefonos(_ t: String) -> String {
    var t = reemplazar("\\+(\\d{1,3})", en: t) { g in
      "más " + NumerosEnPalabras.digitos(g[1])
    }
    t = reemplazar("(?<![\\d.,])(0\\d+|\\d{7,})(?![\\d.,]\\d)", en: t) { g in
      NumerosEnPalabras.digitos(g[1])
    }
    return t
  }

  /// Lo que dice qué género lleva el número que va antes. No es un
  /// diccionario: son los sustantivos femeninos que aparecen al lado de una
  /// cifra en lo que uno lee —y la UF—. Uno que no está se lee en masculino.
  static let femeninos: Set<String> = [
    "persona", "personas", "vez", "veces", "hora", "horas", "semana", "semanas",
    "cuota", "cuotas", "unidad", "unidades", "página", "páginas", "cuadra", "cuadras",
    "uf", "utm", "tonelada", "toneladas", "hectárea", "hectáreas", "casa", "casas",
    "cosa", "cosas", "empresa", "empresas", "mujer", "mujeres", "clase", "clases",
    "sesión", "sesiones", "reunión", "reuniones", "caja", "cajas", "copia", "copias",
    "foto", "fotos", "línea", "líneas", "noche", "noches", "opción", "opciones",
    "pregunta", "preguntas", "palabra", "palabras", "cuenta", "cuentas", "factura",
    "facturas", "boleta", "boletas", "oficina", "oficinas", "sucursal", "sucursales",
    "parte", "partes", "etapa", "etapas", "versión", "versiones", "llamada", "llamadas",
    "visita", "visitas", "entrada", "entradas", "botella", "botellas", "niña", "niñas",
    "tarde", "tardes", "mañana", "mañanas", "fila", "filas", "vuelta", "vueltas",
  ]

  /// Las palabras detrás de las que un número no se apocopa: «son veintiuno
  /// y no veintidós», pero «veintiún años».
  static let noSustantivos: Set<String> = [
    "y", "o", "u", "e", "ni", "de", "del", "en", "a", "al", "con", "que", "por", "para",
    "sin", "sobre", "entre", "hasta", "desde", "más", "menos", "es", "son", "fue",
    "era", "está", "están", "el", "la", "los", "las", "lo", "se", "no", "si", "sí",
    "como", "pero", "mil", "millones", "millón",
  ]

  /// Lo que quedó: números sueltos. Concuerdan con la palabra que sigue.
  static func numeros(_ t: String) -> String {
    // «2.5» no es un número chileno (el punto es de miles, de a tres); es el
    // decimal de una versión o de un texto en inglés, y se dice «punto».
    let t = reemplazar("(?<![\\d.,])(\\d+)\\.(\\d{1,2})(?![\\d.])", en: t) { g in
      cantidad(g[1]) + " punto " + NumerosEnPalabras.decimales(g[2])
    }
    let patron = "(?<![\\p{L}\\d])(\(numero))(?![\\d])(?=(\\s+([\\p{L}]+))?)"
    return reemplazar(patron, en: t) { g in
      let siguiente = g[3].lowercased()
      let femenino = femeninos.contains(siguiente)
      let apocopado = !siguiente.isEmpty && !noSustantivos.contains(siguiente)
      let entero = Int(g[1].replacingOccurrences(of: ".", with: "")) ?? 0
      let leido = cantidad(g[1], femenino: femenino, apocopado: apocopado)
      // «Un millón de habitantes».
      if apocopado, !g[1].contains(","), NumerosEnPalabras.llevaDe(entero) { return leido + " de" }
      return leido
    }
  }

  /// Una cantidad como se escribe en Chile —«1.250.000», «3,5», «12»—, dicha.
  static func cantidad(_ cifras: String, femenino: Bool = false, apocopado: Bool = false) -> String {
    let partes = cifras.split(separator: ",", maxSplits: 1).map(String.init)
    let enteroTexto = partes[0].replacingOccurrences(of: ".", with: "")
    guard let entero = Int(enteroTexto), entero <= NumerosEnPalabras.maximo else {
      return NumerosEnPalabras.digitos(enteroTexto)
    }
    if partes.count == 2 {
      return NumerosEnPalabras.cardinal(entero, femenino: femenino) + " coma "
        + NumerosEnPalabras.decimales(partes[1])
    }
    return NumerosEnPalabras.cardinal(entero, femenino: femenino, apocopado: apocopado)
  }

  static let letras: [Character: String] = [
    "A": "a", "B": "be", "C": "ce", "D": "de", "E": "e", "F": "efe", "G": "ge", "H": "hache",
    "I": "i", "J": "jota", "K": "ka", "L": "ele", "M": "eme", "N": "ene", "Ñ": "eñe", "O": "o",
    "P": "pe", "Q": "cu", "R": "erre", "S": "ese", "T": "te", "U": "u", "V": "ve",
    "W": "doble ve", "X": "equis", "Y": "i griega", "Z": "zeta",
  ]

  /// Las que se deletrean aunque se puedan pronunciar, y las que se dicen
  /// como palabra aunque la regla las deletrearía.
  static let siglasDeletreadas: Set<String> = ["SII", "OK", "UDP", "UC", "UF"]
  static let siglasPalabra: Set<String> = ["IVA", "RUT", "PYME", "PYMES", "ONU", "OTAN"]

  /// Una sigla que no se puede pronunciar como palabra se deletrea: «CMF» →
  /// «ce eme efe», «AFP» → «a efe pe». La que sí se puede —«RUT», «IVA»,
  /// «CORFO», «FONASA»— se deja, que la voz la lee como palabra. Si el texto
  /// entero viene en mayúsculas no es una sigla, es alguien gritando.
  static func siglas(_ t: String) -> String {
    let palabras = t.split(whereSeparator: { !$0.isLetter })
    let enMayusculas = palabras.filter { $0.count > 1 && $0 == $0.uppercased() }.count
    guard palabras.count < 4 || enMayusculas * 2 <= palabras.count else { return t }

    return reemplazar("(?<![\\p{L}\\d])([A-ZÑ]{2,6})(?![\\p{L}\\d])", en: t) { g in
      let sigla = g[1]
      guard deletrear(sigla) else { return sigla }
      return sigla.map { letras[$0] ?? String($0) }.joined(separator: " ")
    }
  }

  static func deletrear(_ sigla: String) -> Bool {
    if siglasDeletreadas.contains(sigla) { return true }
    if siglasPalabra.contains(sigla) { return false }
    if sigla.count == 2 { return true }
    return !pronunciable(sigla)
  }

  /// Si una tira de letras se puede leer como palabra del español: una o
  /// dos consonantes de ataque (las dobles, las de verdad: «tr», «pl»…),
  /// vocales, y a lo más una consonante de cierre entre sílabas o al final.
  static func pronunciable(_ palabra: String) -> Bool {
    let vocales: Set<Character> = ["A", "E", "I", "O", "U"]
    let ataquesDobles: Set<String> = [
      "BL", "BR", "CL", "CR", "DR", "FL", "FR", "GL", "GR", "PL", "PR", "TR", "CH", "LL", "RR",
    ]
    let letras = Array(palabra)
    // La Y entre consonantes suena como vocal: «PYME».
    func esVocal(_ i: Int) -> Bool {
      if vocales.contains(letras[i]) { return true }
      if letras[i] == "Y" {
        let antes = i > 0 && !vocales.contains(letras[i - 1])
        let despues = i + 1 < letras.count && !vocales.contains(letras[i + 1])
        return antes && (despues || i + 1 == letras.count)
      }
      return false
    }
    guard letras.indices.contains(where: esVocal) else { return false }
    // Dos vocales iguales seguidas («SII») no se leen como palabra.
    for i in 1..<letras.count where letras[i] == letras[i - 1] && esVocal(i) {
      return false
    }
    var i = 0
    var primera = true
    while i < letras.count {
      var consonantes = ""
      while i < letras.count, !esVocal(i) {
        consonantes.append(letras[i]); i += 1
      }
      let alFinal = i == letras.count
      if primera {
        if consonantes.count > 2 { return false }
        if consonantes.count == 2, !ataquesDobles.contains(consonantes) { return false }
      } else if alFinal {
        if consonantes.count > 1 { return false }
      } else {
        // Entre vocales: cierre + ataque. «NT», «RT», «ST» y una sola valen;
        // tres, o dos que no se reparten, no.
        if consonantes.count > 3 { return false }
        if consonantes.count == 3, !ataquesDobles.contains(String(consonantes.suffix(2))) { return false }
        if consonantes.count == 2 {
          let cierres: Set<Character> = ["N", "S", "R", "L", "M", "D", "C", "B", "P", "T", "X", "G"]
          if !ataquesDobles.contains(consonantes), !cierres.contains(consonantes.first!) {
            return false
          }
        }
      }
      primera = false
      while i < letras.count, esVocal(i) { i += 1 }
    }
    return true
  }

  static func simbolos(_ t: String) -> String {
    var t = t.replacingOccurrences(of: "&", with: " y ")
    t = t.replacingOccurrences(of: "@", with: " arroba ")
    t = reemplazar("#(?=\\s?\\d)", en: t) { _ in "número " }
    // Las rayas y los guiones largos son pausas, no palabras.
    t = t.replacingOccurrences(of: "—", with: ", ").replacingOccurrences(of: "–", with: ", ")
    return t
  }

  static func espacios(_ t: String) -> String {
    var t = reemplazar("[ \\t]+", en: t) { _ in " " }
    t = reemplazar(" +([,.;:!?)])", en: t) { g in g[1] }
    t = reemplazar(",\\s*,", en: t) { _ in "," }
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Reemplaza de atrás para adelante para que los rangos de cada calce
  /// sigan valiendo. `g[0]` es el calce entero; un grupo que no calzó es "".
  static func reemplazar(_ patron: String, en texto: String, con hacer: ([String]) -> String) -> String {
    guard let regex = try? NSRegularExpression(pattern: patron) else { return texto }
    let ns = texto as NSString
    var resultado = texto as NSString
    for calce in regex.matches(in: texto, range: NSRange(location: 0, length: ns.length)).reversed() {
      let grupos = (0..<calce.numberOfRanges).map { i -> String in
        let r = calce.range(at: i)
        return r.location == NSNotFound ? "" : ns.substring(with: r)
      }
      resultado = resultado.replacingCharacters(in: calce.range, with: hacer(grupos)) as NSString
    }
    return resultado as String
  }
}
