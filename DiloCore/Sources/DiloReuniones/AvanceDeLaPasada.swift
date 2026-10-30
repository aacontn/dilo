import Foundation

/// En qué va la pasada final, para que la ventana diga «Afinando el guion…»
/// con el avance real y no con una barra que inventa.
public struct AvanceDeLaPasada: Sendable, Equatable {
  public enum Etapa: String, Sendable, CaseIterable {
    /// Bajando o cargando un modelo.
    case preparando
    case transcribiendoYo
    case transcribiendoEllos
    case separandoVoces
    case armandoElGuion

    /// Cuánto pesa cada etapa en el total. Medido a ojo sobre una reunión de
    /// prueba: Parakeet va a ~60× tiempo real por pista y Nemotron 3 algo
    /// más rápido; armar el guion es instantáneo. Se corrige con la Fase 0.
    var peso: Double {
      switch self {
      case .preparando: 0.05
      case .transcribiendoYo: 0.35
      case .transcribiendoEllos: 0.35
      case .separandoVoces: 0.22
      case .armandoElGuion: 0.03
      }
    }

    /// En palabras, para la ventana. El catálogo de la app las traduce.
    public var descripcion: String {
      switch self {
      case .preparando: "Preparando los modelos"
      case .transcribiendoYo: "Transcribiendo tu micrófono"
      case .transcribiendoEllos: "Transcribiendo la llamada"
      case .separandoVoces: "Separando las voces"
      case .armandoElGuion: "Armando el guion"
      }
    }
  }

  public var etapa: Etapa
  /// Cuánto de la etapa va, 0…1.
  public var fraccionDeLaEtapa: Double
  /// Si la etapa está esperando que el separador de voces se compile para el
  /// Neural Engine por primera vez (`PrecalentadoDelDiarizador`): son minutos
  /// sin avance que medir, y la ventana lo dice en vez de quedarse quieta
  /// como si se hubiera colgado.
  public var compilandoPorPrimeraVez: Bool

  public init(etapa: Etapa, fraccionDeLaEtapa: Double = 0, compilandoPorPrimeraVez: Bool = false) {
    self.etapa = etapa
    self.fraccionDeLaEtapa = min(max(fraccionDeLaEtapa, 0), 1)
    self.compilandoPorPrimeraVez = compilandoPorPrimeraVez
  }

  /// El avance total, 0…1. Nunca retrocede al pasar de una etapa a la
  /// siguiente, porque cada etapa empieza donde terminó la anterior.
  public var total: Double {
    let etapas = Etapa.allCases
    guard let indice = etapas.firstIndex(of: etapa) else { return 0 }
    let antes = etapas[..<indice].reduce(0) { $0 + $1.peso }
    return min(1, antes + etapa.peso * fraccionDeLaEtapa)
  }
}
