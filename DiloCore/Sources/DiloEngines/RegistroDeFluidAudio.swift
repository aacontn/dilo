import FluidAudio

/// Lo que FluidAudio puede escribir en la consola y en el log de macOS.
///
/// FluidAudio anota a nivel debug e info lo que transcribe —el texto de cada
/// ventana, los reemplazos de Tus palabras («'de camerún' → 'Decameron'»)—
/// y, en un build Debug, lo espeja a la consola. Lo dicho vive en RAM hasta
/// que hay texto y nunca en disco (AGENTS.md), y el log de macOS es disco.
/// Desde la 0.17.4 se apaga en dos perillas: sólo pasan advertencias o peor,
/// y nada va a la consola (lo que llega al log de macOS sale con el texto
/// privado, como cualquier interpolación de `Logger`).
public enum RegistroDeFluidAudio {
  /// El nivel desde el que FluidAudio escribe algo. Advertencia: las fallas
  /// de carga y de red se siguen viendo, las transcripciones no.
  public static let nivelMinimo: AppLogger.Level = .warning

  /// Se llama una vez, al arrancar y antes de crear cualquier motor; también
  /// lo llaman las herramientas de taller que cargan modelos.
  public static func callar() {
    AppLogger.minimumLevel = nivelMinimo
    AppLogger.mirrorsToConsole = false
  }

  /// Si FluidAudio quedó callado. Para el test y para el log de arranque.
  public static var callado: Bool {
    AppLogger.minimumLevel >= nivelMinimo && !AppLogger.mirrorsToConsole
  }
}
