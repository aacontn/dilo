import Foundation

/// Quién lee en voz alta. El `rawValue` se guarda en Ajustes
/// (`readAloudMotor`): no se renombra.
public enum MotorDeLectura: String, CaseIterable, Sendable {
  /// Phonon 40m en español, de Gradium, en el Mac. La de fábrica: ganó en el
  /// banco de voces (`scripts/taller-voces.sh`).
  case phonon
  /// Las voces de Apple, `AVSpeechSynthesizer`. El respaldo mientras Phonon
  /// no está instalado, y la que lee lo que no está en español.
  case apple

  public static let deFabrica: MotorDeLectura = .phonon

  /// Lo guardado; vacío o desconocido, el de fábrica.
  public init(guardado: String) {
    self = MotorDeLectura(rawValue: guardado) ?? Self.deFabrica
  }
}

/// Qué hace «Leer» con una selección, decidido sin tocar nada: quién lee y,
/// si no es el elegido, por qué.
public enum DecisionDeLectura: Equatable, Sendable {
  case phonon
  case apple(PorQueApple?)

  public enum PorQueApple: Equatable, Sendable {
    /// Falta el runtime o la voz, que se bajan solos; mientras, lee Apple.
    case bajandoPhonon
    /// Falta el modelo, que no se puede bajar desde la app (términos de
    /// Hugging Face): lo instala `scripts/instalar-phonon.sh`.
    case faltaElModelo
    /// Phonon sólo habla español y lo seleccionado está en otro idioma (y no
    /// se tradujo).
    case otroIdioma
  }

  /// - Parameters:
  ///   - idioma: el código del idioma de lo que se va a leer —ya traducido,
  ///     si se tradujo—, o nil si no se pudo saber con confianza. Sin saber,
  ///     se le cree a la persona que eligió Phonon.
  public static func decidir(
    elegido: MotorDeLectura,
    estado: InstalacionDePhonon.Estado,
    idioma: String?
  ) -> DecisionDeLectura {
    guard elegido == .phonon else { return .apple(nil) }
    if let idioma, idioma != "es" { return .apple(.otroIdioma) }
    if !estado.modelo { return .apple(.faltaElModelo) }
    if !estado.runtime || !estado.voz { return .apple(.bajandoPhonon) }
    return .phonon
  }

  /// Si «Leer» tiene que arrancar la descarga de lo que falta.
  public var bajaPhonon: Bool {
    if case .apple(.bajandoPhonon) = self { return true }
    return false
  }
}
