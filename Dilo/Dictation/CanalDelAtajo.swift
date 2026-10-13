import CoreGraphics

/// A quién le llegan las teclas que Dilo aprieta por la persona.
///
/// La secuencia es la misma por los dos canales —la arma `AtajoSimulado`—;
/// lo que cambia es la puerta.
enum CanalDelAtajo: Equatable, Sendable {
  /// Sólo al proceso del destino (`CGEvent.postToPid`). No pasa por el estado
  /// global de modificadores, así que no puede dejar ⌘ colgada aunque algo
  /// salga mal a mitad de camino, y ningún otro tap lo ve: ni un gestor de
  /// atajos ni el propio gatillo de Dilo.
  case alProceso(pid_t)
  /// Al tap del HID, como un teclado de verdad. Lo necesitan las apps que
  /// leen el teclado a bajo nivel —escritorios remotos— y el sandbox, donde
  /// el envío al proceso todavía no está medido.
  case alSistema

  static func para(pid: pid_t, alProceso: Bool) -> CanalDelAtajo {
    alProceso && pid > 0 ? .alProceso(pid) : .alSistema
  }

  var publicar: (CGEvent) -> Void {
    switch self {
    case let .alProceso(pid): { $0.postToPid(pid) }
    case .alSistema: { $0.post(tap: .cghidEventTap) }
    }
  }
}
