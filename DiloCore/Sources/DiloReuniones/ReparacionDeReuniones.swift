import Foundation

/// Al abrir Dilo, una reunión que dice `grabando` sin un proceso vivo que la
/// grabe se interrumpió: pasa a `interrumpida`, se reparan sus WAV y se afina
/// igual (spec, «Nunca perder»). Matar la app pierde a lo más los segundos que
/// no alcanzaron a salir del búfer.
public enum ReparacionDeReuniones {
  /// Si una reunión quedó huérfana.
  ///
  /// - Parameters:
  ///   - estaVivo: si el proceso que dice la reunión sigue corriendo y es el
  ///     mismo (mismo pid y misma hora de arranque). Otra copia de Dilo —un
  ///     Debug abierto al lado— puede estar grabando de verdad.
  ///   - grabandoAhora: los ids que este proceso está grabando.
  public static func estaHuerfana(
    _ reunion: Reunion, grabandoAhora: Set<String>, estaVivo: (ProcesoQueGraba) -> Bool
  ) -> Bool {
    guard reunion.estado == .grabando, !grabandoAhora.contains(reunion.id) else { return false }
    guard let proceso = reunion.proceso else { return true }
    return !estaVivo(proceso)
  }

  /// La reunión marcada como interrumpida, con su fin en lo último que se
  /// escribió.
  public static func interrumpir(_ reunion: Reunion, fin: Date) -> Reunion {
    var nueva = reunion
    nueva.estado = .interrumpida
    nueva.seInterrumpio = true
    nueva.fin = nueva.fin ?? max(fin, reunion.inicio)
    nueva.proceso = nil
    return nueva
  }

  /// Repara una reunión huérfana en su carpeta: las cabeceras de cada WAV y
  /// el estado. El fin es la fecha del archivo de audio modificado más tarde:
  /// es lo último que se alcanzó a escribir.
  @discardableResult
  public static func reparar(_ enDisco: ReunionEnDisco) throws -> Reunion {
    let fm = FileManager.default
    var ultimaEscritura = enDisco.reunion.inicio
    for archivo in enDisco.reunion.archivosDeAudio {
      let url = enDisco.archivo(archivo)
      guard fm.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
      try CabeceraWAV.reparar(url)
      if let fecha = try? fm.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date {
        ultimaEscritura = max(ultimaEscritura, fecha)
      }
    }
    let reunion = interrumpir(enDisco.reunion, fin: ultimaEscritura)
    try EscritorDeReunion.guardar(reunion, en: enDisco.carpeta)
    return reunion
  }

  /// Las partes de audio que la reunión nombra y no están en su carpeta: con
  /// el disco desmontado a media reunión, la primera parte quedó en el SSD.
  /// Mientras falte alguna no se afina: el guion saldría con un hueco.
  public static func partesQueFaltan(_ enDisco: ReunionEnDisco) -> [String] {
    enDisco.reunion.archivosDeAudio.filter {
      !FileManager.default.fileExists(atPath: enDisco.archivo($0).path(percentEncoded: false))
    }
  }
}
