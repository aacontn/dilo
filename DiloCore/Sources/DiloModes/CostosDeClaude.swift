import Foundation

/// Cuánto cuesta, más o menos, lo que Dilo le pide a Claude: para que
/// Ajustes → Claude diga el precio al lado del modelo que se elige.
///
/// Los precios son los de lista de Anthropic por millón de tokens
/// (entrada/salida), los mismos de `AGENTS.md` («Costos de referencia»). Los
/// tokens de cada tarea son **supuestos con nombre**, no mediciones: lo que
/// suman el prompt, lo dictado y lo que el modelo piensa a su esfuerzo, para
/// un dictado típico de una o dos frases. Si alguien mide, se cambian acá.
/// El número que sale es una referencia de orden de magnitud —«una fracción
/// de centavo», «unos centavos»—, no una factura.
public enum CostosDeClaude {
  /// Dólares por millón de tokens.
  public struct Precio: Equatable, Sendable {
    public let entrada: Double
    public let salida: Double
  }

  /// Lo que pide una tarea, en tokens.
  public struct Consumo: Equatable, Sendable {
    public let entrada: Int
    public let salida: Int
  }

  public enum Tarea: String, CaseIterable, Sendable {
    /// Reescribir un dictado con un modo.
    case modo
    /// Traducir un dictado.
    case traducir
    /// Revisar una corrección antes de ofrecerla.
    case revisar
    /// Ordenar Tus palabras, una pasada.
    case ordenar

    /// Supuestos: el prompt del modo con sus instrucciones y el contexto
    /// recortado; el de traducir con sus tres ejemplos por destino; el de
    /// revisar con unos pocos candidatos; ordenar, un diccionario de unas
    /// cien entradas a esfuerzo `medium`. La salida incluye lo que se piensa.
    public var consumo: Consumo {
      switch self {
      case .modo: Consumo(entrada: 900, salida: 400)
      case .traducir: Consumo(entrada: 1_500, salida: 500)
      case .revisar: Consumo(entrada: 900, salida: 300)
      case .ordenar: Consumo(entrada: 6_000, salida: 4_000)
      }
    }

    /// Si se cuenta por mil usos o por cada uso: un modo corre en cada
    /// dictado; ordenar, una vez por semana.
    public var porMil: Bool { self != .ordenar }
  }

  public static func precio(_ modelo: String) -> Precio? {
    switch ModelosDeAnthropic.conocido(modelo)?.id {
    case ModelosDeAnthropic.haiku.id: Precio(entrada: 0.10, salida: 0.50)
    case ModelosDeAnthropic.sonnet.id: Precio(entrada: 2, salida: 10)
    case ModelosDeAnthropic.opus.id: Precio(entrada: 4, salida: 20)
    default: nil
    }
  }

  /// Dólares por uso de esa tarea con ese modelo, o nil para un modelo que
  /// Dilo no conoce.
  public static func porUso(_ tarea: Tarea, modelo: String) -> Double? {
    guard let precio = precio(modelo) else { return nil }
    let consumo = tarea.consumo
    return (Double(consumo.entrada) * precio.entrada + Double(consumo.salida) * precio.salida) / 1_000_000
  }

  /// Lo que costó de verdad una respuesta, con lo que Anthropic contó en
  /// `usage`: la entrada normal, lo que se escribió en la caché (1,25 veces
  /// la entrada) y lo que se leyó de ella (un décimo), y la salida, que
  /// incluye lo que el modelo pensó. Nil para un modelo que Dilo no conoce.
  public static func costo(de uso: UsoDeTokens, modelo: String) -> Double? {
    guard let precio = precio(modelo) else { return nil }
    let entrada = Double(uso.entrada) * precio.entrada
      + Double(uso.escritosEnCache) * precio.entrada * 1.25
      + Double(uso.leidosDeCache) * precio.entrada * 0.1
    return (entrada + Double(uso.salida) * precio.salida) / 1_000_000
  }

  /// Lo que se muestra: dólares por mil usos, o por uso para ordenar.
  public static func referencia(_ tarea: Tarea, modelo: String) -> Double? {
    porUso(tarea, modelo: modelo).map { tarea.porMil ? $0 * 1_000 : $0 }
  }
}

/// Los tokens de una respuesta, como los cuenta `usage` de la API.
public struct UsoDeTokens: Equatable, Sendable {
  /// `input_tokens`: la entrada que no vino de la caché.
  public var entrada: Int
  /// `output_tokens`: lo dicho y lo pensado.
  public var salida: Int
  /// `cache_creation_input_tokens`.
  public var escritosEnCache: Int
  /// `cache_read_input_tokens`.
  public var leidosDeCache: Int

  public init(entrada: Int = 0, salida: Int = 0, escritosEnCache: Int = 0, leidosDeCache: Int = 0) {
    self.entrada = entrada
    self.salida = salida
    self.escritosEnCache = escritosEnCache
    self.leidosDeCache = leidosDeCache
  }
}
