import Foundation

/// Cuánto se guarda el audio de una reunión (spec, «Cuánto dura»). El guion,
/// los nombres y los resúmenes se guardan para siempre; esto es sólo el audio.
///
/// El `rawValue` se guarda en `UserDefaults`: no se renombra.
public enum PoliticaDelAudio: String, CaseIterable, Sendable {
  case borrarAlTerminar
  case treintaDias
  case siempre

  public static let porDefecto: PoliticaDelAudio = .treintaDias

  /// Lo que se espera antes de mandar el audio a la Papelera.
  public static let plazo: TimeInterval = 30 * 24 * 3600
}

/// Qué hacer con el audio de una reunión ahora.
public enum AccionSobreElAudio: Equatable, Sendable {
  case nada
  /// Los WAV pasan a AAC de 32 kbps: ~30 MB por hora las dos pistas, contra
  /// ~230 MB en WAV.
  case pasarAAAC
  /// A la Papelera, nunca un borrado definitivo desde Dilo.
  case aLaPapelera
}

public enum RetencionDelAudio {
  /// La decisión, pura. Sólo una reunión lista se toca: una que graba, afina
  /// o espera el disco todavía necesita sus WAV enteros, y una interrumpida
  /// se afina antes.
  public static func accion(
    para reunion: Reunion, politica: PoliticaDelAudio, enElRespaldo: Bool, ahora: Date
  ) -> AccionSobreElAudio {
    guard reunion.estado == .lista, !enElRespaldo, reunion.audio != .borrado else { return .nada }
    switch politica {
    case .borrarAlTerminar:
      return .aLaPapelera
    case .siempre:
      return reunion.audio == .wav ? .pasarAAAC : .nada
    case .treintaDias:
      let desde = reunion.afinadaEl ?? reunion.fin ?? reunion.inicio
      if ahora.timeIntervalSince(desde) >= PoliticaDelAudio.plazo { return .aLaPapelera }
      return reunion.audio == .wav ? .pasarAAAC : .nada
    }
  }

  /// El nombre del archivo AAC de una parte: `yo.wav` → `yo.m4a`.
  public static func nombreAAC(de wav: String) -> String {
    (wav as NSString).deletingPathExtension + ".m4a"
  }
}

/// Las preferencias de reuniones, sus claves y sus valores de fábrica.
///
/// Viven acá, como `PreferenciaDeReposo`, para que la app, el CLI y el MCP lean
/// lo mismo sin crear `AppSettings`. Las claves se guardan en `UserDefaults`
/// y no se renombran nunca (AGENTS.md).
public struct PreferenciasDeReuniones: Sendable, Equatable {
  public enum Clave {
    public static let carpeta = "diloReunionesCarpeta"
    public static let diarizador = "diloReunionesDiarizador"
    public static let audio = "diloReunionesAudio"
    public static let microfonoUID = "diloReunionesMicrofonoUID"
    public static let detectarLlamadas = "diloReunionesDetectarLlamadas"
  }

  /// Quién separa las voces de `ellos` al terminar.
  public enum Diarizador: String, CaseIterable, Sendable {
    /// Nemotron 3, `fast32`: hasta 8 voces con solapes. El de fábrica,
    /// aprobado por Alfonso sin esperar la Fase 0.
    case nemotron3
    /// Sortformer v2.1: hasta 4, ya probado en Dilo. La alternativa elegible,
    /// y el respaldo si Nemotron 3 falla.
    case sortformer

    public static let porDefecto: Diarizador = .nemotron3
  }

  public var carpeta: URL
  public var diarizador: Diarizador
  public var audio: PoliticaDelAudio
  /// El micrófono de la pista `yo` por UID, o nil para la entrada del
  /// sistema, que es la que con más probabilidad usa la llamada.
  public var microfonoUID: String?
  /// Si la muesca ofrece grabar cuando una app de llamadas abre el micrófono.
  /// Prendido de fábrica: mirar no abre el micrófono y grabar sigue siendo un
  /// clic de la persona.
  public var detectarLlamadas: Bool

  public init(
    carpeta: URL = CarpetaDeReunion.raizDeFabrica,
    diarizador: Diarizador = .porDefecto,
    audio: PoliticaDelAudio = .porDefecto,
    microfonoUID: String? = nil,
    detectarLlamadas: Bool = true
  ) {
    self.carpeta = carpeta
    self.diarizador = diarizador
    self.audio = audio
    self.microfonoUID = microfonoUID
    self.detectarLlamadas = detectarLlamadas
  }

  /// Un valor que no se reconoce cae al de fábrica: una versión vieja o un
  /// disco a medio escribir no deja reuniones sin carpeta.
  public static func leer(_ defaults: UserDefaults) -> PreferenciasDeReuniones {
    let ruta = defaults.string(forKey: Clave.carpeta)?.trimmingCharacters(in: .whitespaces) ?? ""
    return PreferenciasDeReuniones(
      carpeta: ruta.isEmpty ? CarpetaDeReunion.raizDeFabrica : URL(filePath: ruta, directoryHint: .isDirectory),
      diarizador: defaults.string(forKey: Clave.diarizador).flatMap(Diarizador.init(rawValue:)) ?? .porDefecto,
      audio: defaults.string(forKey: Clave.audio).flatMap(PoliticaDelAudio.init(rawValue:)) ?? .porDefecto,
      microfonoUID: defaults.string(forKey: Clave.microfonoUID).flatMap { $0.isEmpty ? nil : $0 },
      detectarLlamadas: defaults.object(forKey: Clave.detectarLlamadas) as? Bool ?? true
    )
  }

  public func guardar(en defaults: UserDefaults) {
    if carpeta.standardizedFileURL == CarpetaDeReunion.raizDeFabrica.standardizedFileURL {
      defaults.removeObject(forKey: Clave.carpeta)
    } else {
      defaults.set(carpeta.path(percentEncoded: false), forKey: Clave.carpeta)
    }
    defaults.set(diarizador.rawValue, forKey: Clave.diarizador)
    defaults.set(audio.rawValue, forKey: Clave.audio)
    if let microfonoUID { defaults.set(microfonoUID, forKey: Clave.microfonoUID) } else {
      defaults.removeObject(forKey: Clave.microfonoUID)
    }
    defaults.set(detectarLlamadas, forKey: Clave.detectarLlamadas)
  }
}
