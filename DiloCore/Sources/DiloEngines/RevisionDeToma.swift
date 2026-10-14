import DiloText
import Foundation

/// Qué se hace con lo que un motor devolvió al soltar, mirando también cómo
/// sonó la toma (`MedidaDeToma`).
///
/// Tres salidas, y ninguna es callar: hay texto que pegar, nadie habló (y se
/// dice), o alguien habló y no salió nada (y la toma se guarda para
/// reintentar). Antes de rendirse, le pide una segunda opinión al otro motor
/// sobre el **mismo** audio, que ya está en RAM.
public enum RevisionDeToma {
  public enum Veredicto: Sendable, Equatable {
    case texto(String)
    /// No hubo voz: se dice «No te escuché» y no se guarda nada.
    case nadieHablo
    /// No salió texto y el micrófono estuvo dormido una parte de la toma: no
    /// se puede afirmar que nadie habló, así que se dice por qué no se oyó.
    case microfonoDormido
    /// Hubo voz y no salió texto: la toma se queda en RAM para reintentar.
    case fallida
  }

  // Regla de la segunda pasada: técnica observada en Ocelli (Ghidra,
  // FUN_1004a9c60: al menos 2 s de voz que sean al menos el 10 % de la toma, y un
  // texto vacío, degenerado o con menos de 3 caracteres por segundo de voz;
  // FUN_1004994fc se queda con el más largo). Implementación propia.
  /// La voz mínima para sospechar de un texto pobre. Ocelli.
  public static let segundosDeVozParaSospechar = 2.0
  /// La fracción de la toma que tiene que ser voz. Ocelli.
  public static let fraccionDeVozParaSospechar = 0.1
  /// Por debajo de esto, el texto es demasiado corto para lo que se habló.
  /// Ocelli; en español se habla a 12–15 caracteres por segundo.
  public static let caracteresPorSegundoDeVoz = 3.0

  /// Si un texto que sí salió es demasiado pobre para la voz que hubo.
  public static func esPobre(_ medida: MedidaDeToma, texto: String, degenerado: Bool) -> Bool {
    guard medida.duracion > 0, medida.segundosConVoz >= segundosDeVozParaSospechar,
      medida.segundosConVoz / medida.duracion >= fraccionDeVozParaSospechar
    else { return false }
    return texto.isEmpty || degenerado
      || Double(texto.count) < caracteresPorSegundoDeVoz * medida.segundosConVoz
  }

  /// Si vale la pena preguntarle al otro motor. Siempre que no quedó texto y
  /// algo de la toma pasó el umbral de voz —es el rescate de un dictado que
  /// se iba a perder, y ante la duda se transcribe: el filtro de fantasmas
  /// cuida el otro lado—, y además cuando el texto salió pobre según la regla
  /// de Ocelli. Antes pedía medio segundo de voz, y una frase corta dicha
  /// cuando el Bluetooth recién despertaba terminaba en «No te escuché» sin
  /// preguntarle a nadie.
  public static func pedirSegundaOpinion(_ medida: MedidaDeToma, texto: String, degenerado: Bool) -> Bool {
    (texto.isEmpty && medida.segundosConVoz > 0) || esPobre(medida, texto: texto, degenerado: degenerado)
  }

  /// Lo que se puede pegar de lo que dijo un motor —sin tokens, sin firmas
  /// de subtítulos, sin fantasmas sobre silencio, sin bucles—, y si salió
  /// degenerado.
  public static func depurar(_ crudo: String, _ medida: MedidaDeToma) -> (texto: String, degenerado: Bool) {
    let texto = FrasesFantasma.quitarSiempre(FiltroDeArtefactos.aplicar(crudo))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if FrasesFantasma.esFantasma(texto, tomaCasiMuda: medida.casiMuda) { return ("", false) }
    switch DetectorDeBucles.motivo(texto) {
    case .puntuacion, .repeticionDeCaracteres:
      return ("", true)
    case .repeticionDePalabras:
      // La primera vuelta puede ser lo que se dijo: se queda, marcada para
      // que el otro motor tenga la oportunidad de dar algo mejor.
      return (DetectorDeBucles.colapsar(texto).0, true)
    case nil:
      return (DetectorDeBucles.colapsar(texto).0, false)
    }
  }

  /// `otroMotor` es la segunda opinión sobre el mismo audio: Apple si
  /// escuchó Parakeet, Parakeet si escuchó Apple. Devuelve nil si no pudo.
  public static func revisar(
    crudo: String,
    medida: MedidaDeToma,
    otroMotor: (@Sendable () async -> String?)?
  ) async -> Veredicto {
    var (texto, degenerado) = depurar(crudo, medida)
    if pedirSegundaOpinion(medida, texto: texto, degenerado: degenerado),
      let otroMotor, let otro = await otroMotor()
    {
      let segundo = depurar(otro, medida)
      // El más largo gana, como en Ocelli: el motor que se quedó corto es el
      // que se comió palabras. Uno degenerado sólo gana si el otro no tiene
      // nada.
      if !segundo.texto.isEmpty,
        segundo.texto.count > texto.count || (degenerado && !segundo.degenerado)
      {
        texto = segundo.texto
        degenerado = segundo.degenerado
      }
    }
    if !texto.isEmpty { return .texto(texto) }
    if medida.huboVoz { return .fallida }
    return medida.microfonoDormido ? .microfonoDormido : .nadieHablo
  }
}
