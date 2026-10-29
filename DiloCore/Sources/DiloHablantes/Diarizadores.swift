import DiloReuniones
import FluidAudio
import Foundation

/// Los diarizadores que Dilo sabe correr, con el preset de cada uno. La app
/// usa dos —Nemotron 3 `fast32`, el de fábrica, y Sortformer, el elegible y
/// el respaldo—; el banco de la Fase 0 corre todos.
public enum Diarizador: String, CaseIterable, Sendable, Codable {
  /// Nemotron 3, 2,88 s de latencia y 2,56 s por llamada: el recomendado por
  /// FluidAudio, 190 MB. Hasta 8 hablantes con solapes.
  case nemotron3Fast32 = "nemotron3-fast32"
  /// El mismo grafo partido y en W8A8: 95 MB y todo en el Neural Engine. El
  /// candidato para un M1, donde el `monolithic/v2` puede caer a la GPU.
  case nemotron3Fast32W8A8 = "nemotron3-fast32-split-w8a8"
  /// Trozos de 10 s: más contexto, mismo tamaño.
  case nemotron3C128W8A8 = "nemotron3-c128-split-w8a8"
  /// 30 s de contexto, sólo GPU. La mejor calidad sobre un archivo.
  case nemotron3Offline = "nemotron3-offline"
  /// Sortformer v2.1, la mejor calidad en AMI SDM. Hasta 4 hablantes.
  case sortformer = "sortformer-v2.1"
  /// LS-EEND entrenado en DIHARD III, hasta 10.
  case lseend = "ls-eend-dihard3"
  /// VBx, la pasada pyannote completa: sin tope de hablantes, sólo archivo.
  case vbx = "vbx"

  /// El que la app usa para cada preferencia.
  public static func para(_ preferencia: PreferenciasDeReuniones.Diarizador) -> Diarizador {
    switch preferencia {
    case .nemotron3: .nemotron3Fast32
    case .sortformer: .sortformer
    }
  }

  /// Si es de la familia de Nemotron 3: a esos, si fallan, los releva
  /// Sortformer.
  public var esNemotron: Bool {
    switch self {
    case .nemotron3Fast32, .nemotron3Fast32W8A8, .nemotron3C128W8A8, .nemotron3Offline: true
    case .sortformer, .lseend, .vbx: false
    }
  }

  var configDeNemotron: Nemotron3Config? {
    switch self {
    case .nemotron3Fast32: .fast32
    case .nemotron3Fast32W8A8: Nemotron3Config.preset(named: "fast32-split-w8a8")
    case .nemotron3C128W8A8: Nemotron3Config.preset(named: "c128-split-w8a8")
    case .nemotron3Offline: .offline
    case .sortformer, .lseend, .vbx: nil
    }
  }

  /// La versión que queda escrita en `reunion.json`.
  public var version: String { "\(rawValue) (FluidAudio 0.18.0)" }
}

/// Por qué no se pudo separar voces, en una frase con qué hacer.
public enum FallaDeLaSeparacion: Error, Equatable, Sendable, LocalizedError {
  case sinAudio
  case modeloNoDisponible(String)
  case procesando(String)

  public var errorDescription: String? {
    switch self {
    case .sinAudio: "La pista de la llamada no tiene audio que separar."
    case let .modeloNoDisponible(detalle):
      "No pude preparar el modelo que separa las voces (\(detalle)). Revisa la conexión y vuelve a afinar."
    case let .procesando(detalle): "El modelo que separa las voces falló (\(detalle))."
    }
  }
}
