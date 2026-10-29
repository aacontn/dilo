/// Si Dilo aprieta ↩ después de pegar, cuando la persona terminó el dictado
/// con «envía» (`EnvioHablado`).
///
/// **Mandar un mensaje no se deshace**, y por eso la regla es estrecha y vive
/// pura acá, con su test: ↩ sólo si el texto entró y se supo que entró
/// —un ⌘V sin confirmar puede haber caído en otra parte—, nunca en una
/// terminal (un ↩ ahí **ejecuta**), nunca en un campo seguro, nunca si la
/// persona pidió sólo copiar, nunca si el modo falló o se rechazó (quería
/// revisar ese texto), y nunca donde Dilo no puede pegar directo. Que no haya
/// modificadores apretados lo mira `AtajoSimulado` al momento de apretar.
public enum PoliticaDelEnvio {
  public enum Decision: Equatable, Sendable {
    case enviar
    /// No se dijo «envía»: no hay nada que avisar.
    case noSePidio
    case enUnaTerminal
    case campoSeguro
    case sinConfirmar
    case soloCopiar
    case modoSinTerminar
    case sinPegadoDirecto

    /// Lo que dice la muesca cuando se pidió mandar y no se mandó. Nil
    /// cuando no hay nada que decir.
    public var aviso: String? {
      switch self {
      case .enviar, .noSePidio: nil
      case .enUnaTerminal: "Pegado sin mandar: en una terminal ↩ ejecuta"
      case .campoSeguro: "Pegado sin mandar: es un campo de contraseña"
      case .sinConfirmar: "No mandé el mensaje: no supe si se pegó"
      case .soloCopiar: "Copiado sin mandar"
      case .modoSinTerminar: "Pegado sin mandar: revisa el texto"
      case .sinPegadoDirecto: "Pegado sin mandar"
      }
    }
  }

  /// Lo que dice la muesca cuando todo estaba en orden pero la persona
  /// siguió sosteniendo una tecla y no se apretó ↩.
  public static let avisoConTeclasApretadas = "No mandé el mensaje: tenías una tecla apretada"

  /// - Parameters:
  ///   - textoVacio: el dictado era sólo «Envía.». Entonces no hay nada que
  ///     pegar y lo que se manda es lo que ya estaba escrito en el campo.
  ///   - modoSinTerminar: el modo dijo «salió tal cual» o fue rechazado.
  public static func decidir(
    pidio: Bool,
    entrega: ResultadoDeEntrega,
    textoVacio: Bool,
    clase: ClaseDeDestino,
    campoSeguro: Bool,
    modoSinTerminar: Bool,
    admitePegadoDirecto: Bool
  ) -> Decision {
    guard pidio else { return .noSePidio }
    guard admitePegadoDirecto else { return .sinPegadoDirecto }
    guard clase != .terminal else { return .enUnaTerminal }
    guard !campoSeguro else { return .campoSeguro }
    guard !modoSinTerminar else { return .modoSinTerminar }
    switch entrega {
    case .pegado:
      return .enviar
    case .nadaQueEntregar where textoVacio:
      return .enviar
    case .copiado:
      return .soloCopiar
    case .pegadoSinConfirmar, .retenido, .nadaQueEntregar:
      return .sinConfirmar
    }
  }
}
