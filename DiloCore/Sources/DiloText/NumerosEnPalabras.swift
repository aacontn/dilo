import Foundation

/// Un número escrito en cifras, dicho con palabras en español de Chile.
///
/// Es el camino inverso de `NumerosHablados`: aquél junta «mil quinientos» y
/// «1.500» para compararlos; éste escribe «mil quinientos» para que una voz
/// sintética lo lea. Existe porque el motor neural de «Leer en voz alta» lee
/// lo que le pasan tal cual —el normalizador de FluidAudio es un trait que
/// pesa 8 MB y no entra en el `.app`—, y «$1.250.000» leído cifra por cifra
/// no lo entiende nadie.
///
/// El género importa: «doscientas personas», «veintiún años», «una UF».
/// Quien llama dice si el sustantivo que sigue es femenino y si hay
/// sustantivo (la apócope: «un peso», pero «el capítulo uno»).
public enum NumerosEnPalabras {
  /// El techo que se lee entero; más allá se dice cifra por cifra, que es
  /// como se lee un número de cuenta, y un billón casi nunca es un monto.
  public static let maximo = 999_999_999_999

  private static let unidades = [
    "cero", "uno", "dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho", "nueve",
    "diez", "once", "doce", "trece", "catorce", "quince", "dieciséis", "diecisiete",
    "dieciocho", "diecinueve", "veinte", "veintiuno", "veintidós", "veintitrés",
    "veinticuatro", "veinticinco", "veintiséis", "veintisiete", "veintiocho", "veintinueve",
  ]
  private static let decenas = [
    "", "", "", "treinta", "cuarenta", "cincuenta", "sesenta", "setenta", "ochenta", "noventa",
  ]
  private static let centenas = [
    "", "ciento", "doscientos", "trescientos", "cuatrocientos", "quinientos",
    "seiscientos", "setecientos", "ochocientos", "novecientos",
  ]

  /// «1250000» → «un millón doscientos cincuenta mil».
  ///
  /// - Parameters:
  ///   - femenino: el sustantivo que sigue es femenino («doscientas una»).
  ///   - apocopado: hay sustantivo después, así que «uno» pierde la o
  ///     («veintiún años»). Sin sustantivo, el número se nombra entero.
  public static func cardinal(_ n: Int, femenino: Bool = false, apocopado: Bool = false) -> String {
    guard n >= 0, n <= maximo else { return digitos(String(n)) }
    if n == 0 { return "cero" }
    var partes: [String] = []
    let millones = n / 1_000_000
    let miles = (n / 1000) % 1000
    let resto = n % 1000
    if millones > 0 {
      // «Millón» es masculino: «doscientos millones de personas».
      partes.append(millones == 1 ? "un millón" : hastaMil(millones, femenino: false, apocopado: true) + " millones")
    }
    if miles > 0 {
      // «Mil» no lleva «un» delante; lo de antes de «mil» concuerda con el
      // sustantivo («doscientas mil personas») y siempre va apocopado.
      partes.append(miles == 1 ? "mil" : hastaMil(miles, femenino: femenino, apocopado: true) + " mil")
    }
    if resto > 0 {
      partes.append(hastaMil(resto, femenino: femenino, apocopado: apocopado))
    }
    return partes.joined(separator: " ")
  }

  /// Si entre el número y el sustantivo va «de»: «un millón de pesos», pero
  /// «un millón doscientos mil pesos».
  public static func llevaDe(_ n: Int) -> Bool {
    n >= 1_000_000 && n % 1_000_000 == 0
  }

  /// Del 1 al 999 999 —los miles de millones se arman de dos tramos de
  /// éstos—.
  private static func hastaMil(_ n: Int, femenino: Bool, apocopado: Bool) -> String {
    if n >= 1000 {
      // Sólo pasa en los millones: «mil doscientos millones».
      let miles = n / 1000, resto = n % 1000
      let cabeza = miles == 1 ? "mil" : hastaMil(miles, femenino: femenino, apocopado: true) + " mil"
      return resto == 0 ? cabeza : cabeza + " " + hastaMil(resto, femenino: femenino, apocopado: apocopado)
    }
    var partes: [String] = []
    let c = n / 100, r = n % 100
    if c > 0 {
      if c == 1 {
        partes.append(r == 0 ? "cien" : "ciento")
      } else {
        var palabra = centenas[c]
        if femenino { palabra = String(palabra.dropLast(2)) + "as" }
        partes.append(palabra)
      }
    }
    if r > 0 { partes.append(menosDeCien(r, femenino: femenino, apocopado: apocopado)) }
    return partes.joined(separator: " ")
  }

  private static func menosDeCien(_ n: Int, femenino: Bool, apocopado: Bool) -> String {
    let palabra: String
    if n < 30 {
      palabra = unidades[n]
    } else {
      let u = n % 10
      palabra = u == 0 ? decenas[n / 10] : decenas[n / 10] + " y " + unidades[u]
    }
    guard palabra.hasSuffix("uno") else { return palabra }
    if femenino { return String(palabra.dropLast()) + "a" }
    if apocopado { return n == 21 ? "veintiún" : String(palabra.dropLast()) }
    return palabra
  }

  /// «1» → «primero», hasta el vigésimo. Más allá se dice el cardinal, que es
  /// como se dice en Chile («el piso treinta y dos»).
  public static func ordinal(_ n: Int, femenino: Bool = false) -> String {
    let lista = [
      "", "primero", "segundo", "tercero", "cuarto", "quinto", "sexto", "séptimo",
      "octavo", "noveno", "décimo", "undécimo", "duodécimo", "decimotercero",
      "decimocuarto", "decimoquinto", "decimosexto", "decimoséptimo", "decimoctavo",
      "decimonoveno", "vigésimo",
    ]
    guard n >= 1, n < lista.count else { return cardinal(n, femenino: femenino) }
    let palabra = lista[n]
    return femenino ? String(palabra.dropLast()) + "a" : palabra
  }

  /// «0912» → «cero nueve uno dos»: un teléfono, un código, una cuenta.
  public static func digitos(_ cifras: String) -> String {
    cifras.compactMap { $0.wholeNumberValue }.map { unidades[$0] }.joined(separator: " ")
  }

  /// La parte de después de la coma: «5» → «cinco», «25» → «veinticinco»,
  /// «05» → «cero cinco». Un cero adelante sólo se oye si se dice.
  public static func decimales(_ cifras: String) -> String {
    if cifras.hasPrefix("0") || cifras.count > 3 { return digitos(cifras) }
    return cardinal(Int(cifras) ?? 0)
  }
}
