/// Qué dato puede vivir a un costado de la muesca en reposo.
///
/// Nace del pedido del 2026-09-23: «mostrar cosas más entretenidas de forma
/// permanente, alargar un poquito el notch y poner stats, como los consumos de
/// IA o los stats del computador […] y que todo sea personalizable». Cada
/// fuente se enciende en su tarjeta de Ajustes y elige costado
/// (`DisposicionDeLaMuesca`); sin ninguna encendida es la muesca de siempre.
///
/// El `rawValue` es lo que se guarda en Ajustes: no se renombra.
public enum DatoDeLaMuesca: String, CaseIterable, Sendable {
  case ninguno
  /// Cuánto va de la ventana de cinco horas de Claude Code.
  case claude
  /// Cuánto va de la ventana de cinco horas de Codex.
  case codex
  /// El uso de CPU de todo el sistema.
  case cpu
  /// La memoria ocupada de todo el sistema.
  case ram
  /// Cuánto trabaja la GPU.
  case gpu
  /// Cuánto está bajando la red, en bytes por segundo.
  case red
  /// Cuánto del disco de arranque está ocupado.
  case disco

  /// Las fuentes de verdad, en el orden de sus tarjetas en Ajustes: sin
  /// `ninguno`, que es la ausencia de dato y no una fuente.
  public static var fuentes: [DatoDeLaMuesca] {
    allCases.filter { $0 != .ninguno }
  }

  /// Si el dato sale de los archivos de otra app. El sandbox de App Store no
  /// deja leerlos, y ahí estas opciones se esconden en vez de mostrar un
  /// guion para siempre (`Capacidad.consumoDeIADeOtrasApps`).
  public var leeArchivosDeOtraApp: Bool {
    switch self {
    case .claude, .codex: true
    case .ninguno, .cpu, .ram, .gpu, .red, .disco: false
    }
  }
}
