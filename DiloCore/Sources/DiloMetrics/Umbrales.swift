import Foundation

/// Los cinco números no negociables del spec §3, en código.
///
/// Están acá y no en el script para que `swift test` pueda fallar por ellos:
/// un umbral que sólo vive en bash se relaja en silencio la primera vez que
/// molesta. Si uno de estos cambia, cambia el spec primero.
public enum Umbrales {
  /// Un "MB" acá es el de macOS: `footprint`, `vmmap` y el Finder cuentan
  /// 1024, así que el reporte cuenta igual y no hay que explicar por qué el
  /// número del script no coincide con el del Monitor de Actividad.
  public static let bytesPorMB = 1_048_576.0

  /// RAM en reposo < 60 MB. Yap lo logra con el mismo motor (spec §3).
  public static let ramEnReposoMB = 60.0

  /// CPU en reposo "~0 %". El spec dice "~", y un umbral no puede ser "~":
  /// **1 %** es la tolerancia elegida acá. El tap de teclado despierta al
  /// proceso unas pocas veces por segundo; por encima del 1 % ya no es el tap,
  /// es un timer que alguien dejó corriendo.
  public static let cpuEnReposoPorcentaje = 1.0

  /// Arranque en frío < 1 s (spec §3).
  public static let arranqueEnFrioSegundos = 1.0

  /// Del "soltar" al texto en el portapapeles < 300 ms. Es la ventaja contra
  /// los que transcriben en la nube (spec §3).
  public static let latenciaSoltarTextoSegundos = 0.300

  /// El `.app` sin modelos < 20 MB (spec §3: "descarga").
  public static let tamanoDelAppMB = 20.0
}
