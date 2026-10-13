// Técnica observada en Ocelli 2.1 (sonda de los últimos 24 caracteres, valor
// leído sólo hasta 20 000, «el conteo bajó» = no se sabe) y FluidVoice (sólo
// la idea de contar apariciones y el avance exacto del cursor); implementación
// propia.
import Foundation

/// Un rango de texto en unidades UTF-16, que es como cuenta Accesibilidad.
public struct RangoDeTexto: Equatable, Sendable {
  public var ubicacion: Int
  public var largo: Int

  public init(ubicacion: Int, largo: Int) {
    self.ubicacion = ubicacion
    self.largo = largo
  }
}

/// Lo que se pudo leer de un campo, aplanado a valores para compararlo sin
/// una app viva. Cada parte es opcional: nil es «no se pudo leer», nunca
/// «vacío».
public struct FotoDelCampo: Equatable, Sendable {
  /// `AXNumberOfCharacters`.
  public var conteo: Int?
  /// `AXValue`, sólo si el campo mide hasta `largoMaximo`.
  public var valor: String?
  /// `AXSelectedTextRange`.
  public var seleccion: RangoDeTexto?

  /// Un documento de más de esto se cuenta pero no se lee entero: leer un
  /// libro por Accesibilidad para pegar una frase es trabar a la app.
  public static let largoMaximo = 20_000

  public init(conteo: Int? = nil, valor: String? = nil, seleccion: RangoDeTexto? = nil) {
    self.conteo = conteo
    self.valor = valor
    self.seleccion = seleccion
  }

  /// Si hay algo que comparar.
  public var esLegible: Bool { conteo != nil || valor != nil || seleccion != nil }
}

/// Si el dictado entró al campo, comparando una foto de antes del ⌘V con una
/// de después.
///
/// **Ante la duda, `noSeSabe`.** Decir «no entró» cuando sí entró provoca un
/// segundo intento: el texto repetido es peor que una tarjeta de más.
public enum VeredictoDelCampo: Equatable, Sendable {
  case entro
  case noCambio
  case noSeSabe

  /// Cuántos caracteres del final se buscan en el valor. El final es lo
  /// último en entrar: si está, entró entero.
  public static let largoDeLaSonda = 24

  public static func comparar(
    antes: FotoDelCampo,
    despues: FotoDelCampo,
    texto: String
  ) -> VeredictoDelCampo {
    guard !texto.isEmpty, antes.esLegible, despues.esLegible else { return .noSeSabe }
    let largo = texto.utf16.count

    // 1. El final del dictado aparece más veces que antes. Contar, y no sólo
    //    «antes no estaba», es lo que sirve cuando se dicta dos veces lo
    //    mismo.
    let sonda = String(texto.suffix(largoDeLaSonda))
    if let valorDespues = despues.valor, !sonda.isEmpty {
      let antesVeces = antes.valor.map { apariciones(de: sonda, en: $0) } ?? 0
      if apariciones(de: sonda, en: valorDespues) > antesVeces { return .entro }
    }

    // 2. El cursor quedó justo después de lo pegado, sin selección.
    if let previa = antes.seleccion, let ahora = despues.seleccion,
      ahora.largo == 0, ahora.ubicacion == previa.ubicacion + largo {
      return .entro
    }

    // 3. El conteo.
    if let conteoAntes = antes.conteo, let conteoDespues = despues.conteo {
      if conteoDespues > conteoAntes { return .entro }
      // Bajó: el pegado reemplazó una selección más larga que el dictado, o
      // la app recortó. No prueba nada.
      if conteoDespues < conteoAntes { return .noSeSabe }
    }

    // 4. Nada se movió, y había con qué saberlo.
    let mismoValor = antes.valor != nil && antes.valor == despues.valor
    let mismaSeleccion = antes.seleccion != nil && antes.seleccion == despues.seleccion
    let mismoConteo = antes.conteo != nil && antes.conteo == despues.conteo
    if mismoValor || (mismoConteo && mismaSeleccion) { return .noCambio }
    return .noSeSabe
  }

  static func apariciones(de sonda: String, en valor: String) -> Int {
    var cuenta = 0
    var desde = valor.startIndex
    while let rango = valor.range(of: sonda, range: desde..<valor.endIndex) {
      cuenta += 1
      desde = rango.upperBound
    }
    return cuenta
  }
}
