import DiloModes
import Foundation

/// Un bloque de la respuesta de Claude, tal como hay que devolverlo en el
/// turno siguiente.
///
/// Los bloques `thinking` vuelven **intactos**, con su firma, aunque su texto
/// venga vacío: los modelos 5.5 los atan a la conversación que los produjo, y
/// una herramienta a mitad de turno los necesita para seguir pensando donde
/// quedó. Nunca se dicen ni se muestran.
public enum BloqueDeClaude: Equatable, Sendable {
  case texto(String)
  case pensamiento(texto: String, firma: String)
  case pensamientoOculto(datos: String)
  /// Un `tool_use`: los argumentos como llegaron, en JSON sin interpretar.
  /// Con `eager_input_streaming` la API no los valida: los valida quien corre
  /// la herramienta.
  case herramienta(id: String, nombre: String, argumentos: String)

  /// Como va en `content` del mensaje `assistant` que se devuelve. Un texto
  /// vacío no va (la API rechaza bloques de texto vacíos); unos argumentos
  /// que no son un objeto JSON vuelven como `{}`.
  public var comoJSON: ValorJSON? {
    switch self {
    case let .texto(texto):
      return texto.isEmpty ? nil : .objeto(["type": .texto("text"), "text": .texto(texto)])
    case let .pensamiento(texto, firma):
      return .objeto(["type": .texto("thinking"), "thinking": .texto(texto), "signature": .texto(firma)])
    case let .pensamientoOculto(datos):
      return .objeto(["type": .texto("redacted_thinking"), "data": .texto(datos)])
    case let .herramienta(id, nombre, argumentos):
      return .objeto([
        "type": .texto("tool_use"), "id": .texto(id), "name": .texto(nombre),
        "input": Self.argumentos(argumentos) ?? .objeto([:]),
      ])
    }
  }

  /// Los argumentos de un `tool_use`, leídos estrictos: un objeto JSON o
  /// nada. Vacío es `{}`: una herramienta sin argumentos no manda deltas.
  public static func argumentos(_ texto: String) -> ValorJSON? {
    let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !limpio.isEmpty else { return .objeto([:]) }
    guard let valor = ValorJSON.leer(limpio), case .objeto = valor else { return nil }
    return valor
  }
}

/// Lo que va llegando de una respuesta con herramientas.
public enum EventoConHerramientas: Equatable, Sendable {
  /// Un pedazo de texto para decir.
  case texto(String)
  /// La respuesta entera: sus bloques en orden, por qué paró y lo que costó.
  case fin(bloques: [BloqueDeClaude], razon: String?, uso: UsoDeTokens)
}

/// Lee el stream SSE de `POST /v1/messages` cuando hay herramientas: además
/// del texto (`text_delta`), arma los bloques `tool_use` con sus
/// `input_json_delta`, y los `thinking` con su `signature_delta`, para
/// devolverlos tal cual.
///
/// Como `LectorDeLaRespuesta`, interpreta cada `data:` al llegar: Anthropic
/// manda un evento por línea. Puro: entran líneas, salen eventos.
public struct LectorDeBloques: Sendable {
  private enum EnCurso: Sendable {
    case texto(String)
    case pensamiento(texto: String, firma: String)
    case oculto(String)
    case herramienta(id: String, nombre: String, argumentos: String)
    case otro
  }

  private var bloques: [Int: EnCurso] = [:]
  private var orden: [Int] = []
  private var uso = UsoDeTokens()
  private var razon: String?
  public private(set) var termino = false

  public init() {}

  public mutating func leer(_ linea: String) throws(FallaDeClaude) -> EventoConHerramientas? {
    guard linea.hasPrefix("data:") else { return nil }
    let json = linea.dropFirst(5).trimmingCharacters(in: .whitespaces)
    guard let evento = ValorJSON.leer(json), let tipo = evento["type"]?.comoTexto else { return nil }

    switch tipo {
    case "message_start":
      sumar(evento["message"]?["usage"])
    case "content_block_start":
      guard let indice = evento["index"]?.comoEntero, let bloque = evento["content_block"] else { return nil }
      if bloques[indice] == nil { orden.append(indice) }
      switch bloque["type"]?.comoTexto {
      case "text": bloques[indice] = .texto(bloque["text"]?.comoTexto ?? "")
      case "thinking":
        bloques[indice] = .pensamiento(
          texto: bloque["thinking"]?.comoTexto ?? "", firma: bloque["signature"]?.comoTexto ?? ""
        )
      case "redacted_thinking": bloques[indice] = .oculto(bloque["data"]?.comoTexto ?? "")
      case "tool_use":
        bloques[indice] = .herramienta(
          id: bloque["id"]?.comoTexto ?? "", nombre: bloque["name"]?.comoTexto ?? "", argumentos: ""
        )
      default: bloques[indice] = .otro
      }
    case "content_block_delta":
      guard let indice = evento["index"]?.comoEntero, let delta = evento["delta"] else { return nil }
      switch (bloques[indice], delta["type"]?.comoTexto) {
      case let (.texto(previo), "text_delta"):
        let pedazo = delta["text"]?.comoTexto ?? ""
        bloques[indice] = .texto(previo + pedazo)
        return pedazo.isEmpty ? nil : .texto(pedazo)
      case let (.pensamiento(texto, firma), "thinking_delta"):
        bloques[indice] = .pensamiento(texto: texto + (delta["thinking"]?.comoTexto ?? ""), firma: firma)
      case let (.pensamiento(texto, firma), "signature_delta"):
        bloques[indice] = .pensamiento(texto: texto, firma: firma + (delta["signature"]?.comoTexto ?? ""))
      case let (.herramienta(id, nombre, argumentos), "input_json_delta"):
        bloques[indice] = .herramienta(
          id: id, nombre: nombre, argumentos: argumentos + (delta["partial_json"]?.comoTexto ?? "")
        )
      default: break
      }
    case "message_delta":
      sumar(evento["usage"])
      if let parada = evento["delta"]?["stop_reason"]?.comoTexto {
        // Un rechazo puede cortar un `tool_use` a medias: nada de ese turno
        // se corre ni se devuelve.
        if parada == "refusal" { throw .seNego }
        razon = parada
      }
    case "message_stop":
      termino = true
      return .fin(bloques: cerrados, razon: razon, uso: uso)
    case "error":
      throw LectorDeLaRespuesta.falla(deTipo: evento["error"]?["type"]?.comoTexto)
    default:
      break
    }
    return nil
  }

  private var cerrados: [BloqueDeClaude] {
    orden.compactMap { indice in
      switch bloques[indice] {
      case let .texto(texto): .texto(texto)
      case let .pensamiento(texto, firma): .pensamiento(texto: texto, firma: firma)
      case let .oculto(datos): .pensamientoOculto(datos: datos)
      case let .herramienta(id, nombre, argumentos): .herramienta(id: id, nombre: nombre, argumentos: argumentos)
      case .otro, nil: nil
      }
    }
  }

  /// Igual que `LectorDeLaRespuesta`: `message_delta` trae el uso
  /// acumulado, así que se toma el mayor de cada campo.
  private mutating func sumar(_ usage: ValorJSON?) {
    guard let usage else { return }
    func valor(_ clave: String) -> Int? { usage[clave]?.comoEntero }
    if let v = valor("input_tokens") { uso.entrada = max(uso.entrada, v) }
    if let v = valor("output_tokens") { uso.salida = max(uso.salida, v) }
    if let v = valor("cache_creation_input_tokens") { uso.escritosEnCache = max(uso.escritosEnCache, v) }
    if let v = valor("cache_read_input_tokens") { uso.leidosDeCache = max(uso.leidosDeCache, v) }
  }
}
