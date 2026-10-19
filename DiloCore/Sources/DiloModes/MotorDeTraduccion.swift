import Foundation

/// Quién traduce un dictado: Claude por la API de Anthropic, o el traductor
/// de Apple, que corre en este Mac.
///
/// Lo que se guarda en Ajustes es la elección de la persona, y nil es la de
/// fábrica: **Claude si hay clave de Anthropic en el Llavero; si no, Apple**
/// (2026-10-19). Quien ya pegó la clave para sus modos la quiere usar, y
/// quien no la tiene sigue traduciendo como siempre sin configurar nada.
///
/// El `rawValue` se guarda en `UserDefaults`: no se renombra.
public enum MotorDeTraduccion: String, CaseIterable, Sendable {
  case claude
  case apple

  /// Con qué traduce una sesión, ya resuelto contra la clave, el idioma de
  /// dictado y el destino. Se resuelve **al apretar la tecla** y la sesión lo
  /// congela (ADR-0004): cambiar Ajustes a mitad de dictado aplica al
  /// siguiente.
  public enum Resuelto: Equatable, Sendable {
    case claude(DestinoDeTraduccion)
    case apple
    /// Se eligió Claude a mano y no hay clave. No cae a Apple en silencio: la
    /// persona pidió Claude, y la muesca le dice qué falta.
    case faltaLaClave(DestinoDeTraduccion)
  }

  /// El destino que Claude puede traducir, o nil si este par es de Apple.
  ///
  /// Claude traduce **desde el español**: el prompt está escrito para un
  /// dictado chileno, y con otro idioma de dictado sus ejemplos enseñan lo
  /// que no es. Y **hacia inglés o chino simplificado**; el resto de los
  /// destinos ya los tiene Apple.
  public static func destinoDeClaude(origen: String?, destino: String) -> DestinoDeTraduccion? {
    guard let origen, Locale.Language(identifier: origen).languageCode?.identifier == "es" else {
      return nil
    }
    return DestinoDeTraduccion(identificador: destino)
  }

  /// Si resolver este par necesita saber si hay clave. Es lo que evita una
  /// consulta al Llavero cuando la respuesta no la cambia: con Apple elegido
  /// a mano, o con un par que Claude no traduce, no se pregunta nada.
  public static func necesitaSaberSiHayClave(
    elegido: MotorDeTraduccion?, origen: String?, destino: String
  ) -> Bool {
    elegido != .apple && destinoDeClaude(origen: origen, destino: destino) != nil
  }

  /// Con qué se traduce este par.
  public static func resolver(
    elegido: MotorDeTraduccion?, origen: String?, destino: String, hayClave: Bool
  ) -> Resuelto {
    guard elegido != .apple, let claude = destinoDeClaude(origen: origen, destino: destino) else {
      return .apple
    }
    if hayClave { return .claude(claude) }
    return elegido == .claude ? .faltaLaClave(claude) : .apple
  }

  /// Lo que muestra el selector de Ajustes: la elección, o la de fábrica ya
  /// decidida. Sin clave y sin elegir, dice Apple, que es lo que de verdad
  /// traduce.
  public static func enElSelector(elegido: MotorDeTraduccion?, hayClave: Bool) -> MotorDeTraduccion {
    elegido ?? (hayClave ? .claude : .apple)
  }
}

public extension Proveedor {
  /// El Anthropic del catálogo de fábrica. La traducción con Claude usa
  /// **su** ítem del Llavero (`proveedor.anthropic`): una sola clave de
  /// Anthropic para los modos y para traducir, nunca un segundo almacén.
  static var anthropicDeFabrica: Proveedor {
    Proveedor.deFabrica.proveedor("anthropic")!
  }
}
