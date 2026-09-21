import Foundation

/// Cuál **Motor de voz** corre. El `rawValue` se guarda en `UserDefaults` y
/// no se traduce ni se renombra nunca: cambiarlo le borra la elección a la
/// persona en silencio (AGENTS.md). El nombre visible vive en `title`.
public enum SpeechEngineKind: String, CaseIterable, Sendable {
  case parakeet
  case apple

  /// **El motor por defecto de Dilo, en un solo lugar.**
  ///
  /// Parakeet v3 gana hoy porque el dictado sale igual en cualquier Mac y no
  /// depende de qué modelo de voz tenga instalado el sistema. El spec lo deja
  /// marcado como ambigüedad: si la segunda prueba de Alfonso con
  /// SpeechAnalyzer en `es_CL` sale mejor, esto pasa a `.apple` y no hay nada
  /// más que tocar.
  public static let porDefecto: SpeechEngineKind = .parakeet

  public var title: String {
    switch self {
    case .parakeet: "Parakeet v3"
    case .apple: "Apple"
    }
  }

  /// Lo que dice la tarjeta. Los dos motores son LOCAL; el tercero del spec
  /// (Gemini 3.5 Transcribe) va a ser el primero EN LÍNEA y por eso la
  /// etiqueta existe desde ya.
  public var etiqueta: String { "LOCAL" }

  public var descripcion: String {
    switch self {
    case .parakeet:
      "Rápido y preciso en español. Se descarga una vez y después no necesita internet nunca más."
    case .apple:
      "El dictado que trae macOS. No ocupa disco y te muestra el texto mientras hablas."
    }
  }

  /// Lo que la persona gana o paga por elegirlo, en una línea cada uno. Es la
  /// honestidad de la tarjeta: nada de "el mejor".
  public var detalles: [String] {
    switch self {
    case .parakeet:
      ["Ocupa 1 descarga en disco", "El audio no sale de este Mac", "El texto aparece al soltar"]
    case .apple:
      ["0 MB en disco", "El audio no sale de este Mac", "Ves el texto mientras hablas"]
    }
  }
}
