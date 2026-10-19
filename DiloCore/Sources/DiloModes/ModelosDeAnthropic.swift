import Foundation

/// Un modelo de Claude que Ajustes ofrece por su nombre.
public struct ModeloDeAnthropic: Equatable, Identifiable, Sendable {
  /// El id exacto de la API, sin sufijo de fecha.
  public let id: String
  public let nombre: String
}

/// Los modelos de Anthropic que Dilo conoce, y lo que se les manda.
///
/// Alfonso, 2026-10-19: los modos y la traducción van por Claude Haiku 5.5 de
/// fábrica cuando hay clave de Anthropic. Antes el proveedor traía el modelo
/// vacío y había que escribir el id a mano; ahora se elige de esta lista, con
/// «Otro…» para lo que no esté en ella.
///
/// Sólo `Foundation`: `scripts/probar-traduccion.sh` lo compila junto con el
/// traductor.
public enum ModelosDeAnthropic {
  public static let haiku = ModeloDeAnthropic(id: "claude-haiku-5-5", nombre: "Claude Haiku 5.5")
  public static let sonnet = ModeloDeAnthropic(id: "claude-sonnet-5-5", nombre: "Claude Sonnet 5.5")
  public static let opus = ModeloDeAnthropic(id: "claude-opus-5-5", nombre: "Claude Opus 5.5")

  /// En el orden del selector: el recomendado primero.
  public static let lista = [haiku, sonnet, opus]

  /// El de fábrica, para los modos y para traducir: rápido y barato, y de
  /// sobra para reescribir o traducir un dictado.
  public static let deFabrica = haiku

  public static func conocido(_ id: String) -> ModeloDeAnthropic? {
    let limpio = id.trimmingCharacters(in: .whitespacesAndNewlines)
    return lista.first { $0.id == limpio }
  }

  /// Cuánto piensa un modelo de la lista antes de reescribir un modo. `low`
  /// por latencia: el modo se espera con la muesca abierta. Haiku 5.5 y Opus
  /// 5.5 traen `medium` por omisión y Sonnet 5.5 `high`; si un modo largo
  /// sale flojo, el siguiente escalón es `medium`, acá.
  public static let esfuerzoDeLosModos = "low"

  /// Lo que lleva el request de un modo según el modelo.
  ///
  /// A los tres de la lista: `output_config.effort` y un techo holgado, porque
  /// piensan antes de contestar y lo pensado cuenta contra `max_tokens`. A un
  /// modelo escrito a mano, lo de siempre y nada más: Haiku 4.5, por ejemplo,
  /// devuelve error ante `effort`, y Dilo no puede saber qué acepta cada id.
  ///
  /// A ninguno van `temperature`, `top_p`, `top_k` ni `thinking`: los tres de
  /// la lista devuelven 400 ante muestreo que no sea el suyo, y Sonnet 5.5
  /// además ante `thinking: {type: "disabled"}`.
  public static func opciones(para modelo: String) -> (maximoDeTokens: Int, esfuerzo: String?) {
    conocido(modelo) == nil ? (4_096, nil) : (8_000, esfuerzoDeLosModos)
  }
}
