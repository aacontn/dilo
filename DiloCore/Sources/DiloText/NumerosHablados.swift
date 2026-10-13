import Foundation

/// Los números del español, dichos con palabras o escritos con cifras, en una
/// forma comparable: «mil quinientos», «1.500» y «1500» son la misma clave.
///
/// Existe para el validador: el modo Limpio pasa números a cifras, así que
/// comparar texto contra texto daría por cambiado lo que sólo cambió de forma.
/// Formato de Chile: punto de miles y coma decimal. «Un», «una» y «uno»
/// sueltos no cuentan: casi siempre son artículo o pronombre.
public enum NumerosHablados {
  enum Clase { case unidad, especial, decena, centena, mil, millon }

  /// Las palabras ya plegadas (minúsculas, sin tildes).
  static let lexico: [String: (Clase, Decimal)] = {
    var l: [String: (Clase, Decimal)] = [:]
    let unidades = ["cero", "uno", "dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho", "nueve"]
    for (i, p) in unidades.enumerated() { l[p] = (.unidad, Decimal(i)) }
    l["un"] = (.unidad, 1); l["una"] = (.unidad, 1)
    let especiales = [
      "diez", "once", "doce", "trece", "catorce", "quince", "dieciseis", "diecisiete",
      "dieciocho", "diecinueve", "veinte", "veintiuno", "veintidos", "veintitres",
      "veinticuatro", "veinticinco", "veintiseis", "veintisiete", "veintiocho", "veintinueve",
    ]
    for (i, p) in especiales.enumerated() { l[p] = (.especial, Decimal(10 + i)) }
    l["veintiun"] = (.especial, 21); l["veintiuna"] = (.especial, 21)
    let decenas = ["treinta", "cuarenta", "cincuenta", "sesenta", "setenta", "ochenta", "noventa"]
    for (i, p) in decenas.enumerated() { l[p] = (.decena, Decimal(30 + 10 * i)) }
    l["cien"] = (.centena, 100); l["ciento"] = (.centena, 100)
    let centenas = ["dos", "tres", "cuatro", "quin", "seis", "sete", "ocho", "nove"]
    for (i, raiz) in centenas.enumerated() {
      let valor = Decimal(100 * (i + 2))
      let base = raiz == "quin" ? "quinient" : raiz + "cient"
      l[base + "os"] = (.centena, valor); l[base + "as"] = (.centena, valor)
    }
    l["mil"] = (.mil, 1000)
    l["millon"] = (.millon, 1_000_000); l["millones"] = (.millon, 1_000_000)
    return l
  }()

  static func puedeSeguir(_ siguiente: Clase, a anterior: Clase, huboMil: Bool) -> Bool {
    switch siguiente {
    case .unidad, .especial, .decena: [.centena, .mil, .millon].contains(anterior)
    case .centena: anterior == .mil || anterior == .millon
    case .mil: !huboMil && [.unidad, .especial, .decena, .centena].contains(anterior)
    case .millon: anterior != .millon
    }
  }

  /// Lee un número que empieza en `palabras[i]` y devuelve su clave
  /// («1500», «2.5», «5:30») y cuántas palabras consumió.
  /// - Parameter unido: si la palabra `k` está pegada a la anterior sólo por
  ///   espacios. Una coma entre medio separa dos números: «dos, tres».
  static func leer(
    _ palabras: [String], desde i: Int, unido: (Int) -> Bool
  ) -> (clave: String, consumidas: Int)? {
    var valor: Decimal
    var k: Int
    if let cifra = cifras(palabras[i]) {
      if case let .hora(h, m) = cifra { return (clave(hora: h, minutos: m), 1) }
      guard case let .valor(v) = cifra else { return nil }
      valor = v; k = i + 1
      // «2 mil», «1,5 millones».
      if k < palabras.count, unido(k), let (c, m) = lexico[palabras[k]], c == .mil || c == .millon {
        valor *= m; k += 1
      }
    } else if let (v, n) = leerPalabras(palabras, desde: i, unido: unido) {
      valor = v; k = i + n
    } else {
      return nil
    }
    func sigue(_ a: String, _ b: String) -> Bool {
      k + 1 < palabras.count && unido(k) && unido(k + 1) && palabras[k] == a && palabras[k + 1] == b
    }
    // «cinco y media» es una hora; «veinte por ciento» es un porcentaje.
    if valor <= 24, valor == valor.rounded0 {
      if sigue("y", "media") { return (clave(hora: valor, minutos: 30), k + 2 - i) }
      if sigue("y", "cuarto") { return (clave(hora: valor, minutos: 15), k + 2 - i) }
    }
    if sigue("por", "ciento") { k += 2 }
    return (NSDecimalNumber(decimal: valor).stringValue, k - i)
  }

  enum Cifra { case valor(Decimal), hora(Decimal, Decimal) }

  /// «1.500» → 1500, «2,5» → 2.5, «15:30» → hora. Una versión «1.2.3» no
  /// es número: sigue siendo palabra y la protege el resto del validador.
  static func cifras(_ token: String) -> Cifra? {
    guard token.first?.isNumber == true else { return nil }
    if token.wholeMatch(of: /\d{1,2}:\d{2}/) != nil {
      let partes = token.split(separator: ":")
      return .hora(Decimal(string: String(partes[0]))!, Decimal(string: String(partes[1]))!)
    }
    if token.wholeMatch(of: /\d{1,3}(\.\d{3})+/) != nil {
      return Decimal(string: token.replacingOccurrences(of: ".", with: "")).map(Cifra.valor)
    }
    if token.wholeMatch(of: /\d+([.,]\d+)?/) != nil {
      return Decimal(string: token.replacingOccurrences(of: ",", with: ".")).map(Cifra.valor)
    }
    return nil
  }

  static func clave(hora: Decimal, minutos: Decimal) -> String {
    let m = NSDecimalNumber(decimal: minutos).intValue
    return "\(NSDecimalNumber(decimal: hora).intValue):" + (m < 10 ? "0\(m)" : "\(m)")
  }

  static func leerPalabras(
    _ p: [String], desde i: Int, unido: (Int) -> Bool
  ) -> (Decimal, Int)? {
    guard lexico[p[i]] != nil else { return nil }
    if p[i] == "cero" { return (0, 1) }
    // «un archivo» no es un número; «un millón» sí.
    if ["un", "una", "uno"].contains(p[i]) {
      guard i + 1 < p.count, unido(i + 1), let (c, _) = lexico[p[i + 1]],
        c == .mil || c == .millon
      else { return nil }
    }
    var total: Decimal = 0, actual: Decimal = 0
    var anterior: Clase?
    var huboMil = false
    var k = i
    while k < p.count {
      if k > i, !unido(k) { break }
      var palabra = p[k], salto = 0
      if palabra == "y" {
        // La «y» sólo une decena y unidad: «treinta y cinco», no «cinco y treinta».
        guard anterior == .decena, k + 1 < p.count, unido(k + 1),
          let (c, _) = lexico[p[k + 1]], c == .unidad, p[k + 1] != "cero"
        else { break }
        palabra = p[k + 1]; salto = 1
      }
      guard let (clase, valor) = lexico[palabra], palabra != "cero" else { break }
      if salto == 0, let anterior, !puedeSeguir(clase, a: anterior, huboMil: huboMil) { break }
      switch clase {
      case .unidad, .especial, .decena, .centena:
        actual += valor
      case .mil:
        total += (actual == 0 ? 1 : actual) * 1000; actual = 0; huboMil = true
      case .millon:
        total = (total + (actual == 0 ? 1 : actual)) * 1_000_000; actual = 0; huboMil = false
      }
      anterior = clase
      k += 1 + salto
    }
    return k > i ? (total + actual, k - i) : nil
  }
}

extension Decimal {
  var rounded0: Decimal {
    var copia = self, r = Decimal()
    NSDecimalRound(&r, &copia, 0, .plain)
    return r
  }
}
