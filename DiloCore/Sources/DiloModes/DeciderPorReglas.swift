import Foundation

/// La implementación 0 del `Decider`: reglas, sin modelo y sin descarga.
///
/// Medido el 2026-09-20 contra 40 dictados chilenos: la app al frente acierta
/// el 100 % del set, las palabras clave el 85 % sin ella, en 0,013 ms. Laya
/// multilingüe zero-shot sacó 65 %. Por eso ésta es la de por defecto y
/// cualquier modelo tiene que ganarle antes de justificar su costo.
///
/// Es un valor puro: sin red, sin disco, sin reloj. Se testea entera.
public struct DeciderPorReglas: Decider {
  /// Una opción con sus señales. Se arma desde los modos, pero el tipo no
  /// sabe de modos: el mismo decididor responde "¿es una orden?" con otras
  /// reglas el día que exista la puerta de comandos.
  public struct Regla: Equatable, Sendable {
    public var opcion: String
    public var apps: [String]
    public var palabrasClave: [String]

    public init(opcion: String, apps: [String] = [], palabrasClave: [String] = []) {
      self.opcion = opcion
      self.apps = apps
      self.palabrasClave = palabrasClave
    }
  }

  public var reglas: [Regla]

  public init(reglas: [Regla]) {
    self.reglas = reglas
  }

  public init(modos: [Modo]) {
    reglas = modos.map {
      Regla(opcion: $0.id, apps: $0.apps, palabrasClave: $0.palabrasClave)
    }
  }

  public func decidir(
    _ texto: String,
    _ pregunta: PreguntaTipada,
    en contexto: ContextoDeDecision
  ) async -> RespuestaTipada {
    decidirAhora(texto, pregunta, en: contexto)
  }

  /// La versión síncrona. El protocolo es `async` porque las otras dos
  /// implementaciones sí esperan, pero éstas son reglas: hacerla esperar
  /// sería mentir sobre lo que cuesta, y el sitio de llamada que la quiere
  /// inmediata la tiene.
  public func decidirAhora(
    _ texto: String,
    _ pregunta: PreguntaTipada,
    en contexto: ContextoDeDecision
  ) -> RespuestaTipada {
    let opciones = pregunta.opciones
    guard !opciones.isEmpty else { return RespuestaTipada(valor: "", probabilidad: 0) }

    // Un puntaje no se saca de reglas: devolver el medio con probabilidad baja
    // es decir "no sé", que es la verdad. Lo responderá FoundationModels.
    if case .puntaje = pregunta {
      return RespuestaTipada(
        valor: opciones[opciones.count / 2], probabilidad: 1.0 / Double(opciones.count)
      )
    }

    let candidatas = reglas.filter { opciones.contains($0.opcion) }
    let app = Self.normalizar(contexto.appAlFrente ?? "")
    let porApp = app.isEmpty ? [] : candidatas.filter { regla in
      regla.apps.contains { !$0.isEmpty && app.contains(Self.normalizar($0)) }
    }

    // La app al frente decide. Es la señal que mide 100 % y no cuesta nada.
    if porApp.count == 1 {
      return RespuestaTipada(
        valor: porApp[0].opcion,
        probabilidad: 0.95,
        porQue: "la app al frente era \(contexto.appAlFrente ?? "")"
      )
    }

    // Empate entre apps, o ninguna: las palabras clave desempatan.
    let aDesempatar = porApp.isEmpty ? candidatas : porApp
    let palabras = Self.palabras(de: texto)
    let puntajes = aDesempatar.map { regla in
      (regla, regla.palabrasClave.reduce(into: 0) { total, clave in
        if palabras.contains(Self.normalizar(clave)) { total += 1 }
      })
    }
    let mejor = puntajes.max { $0.1 < $1.1 }

    if let mejor, mejor.1 > 0 {
      let empatados = puntajes.filter { $0.1 == mejor.1 }.count
      // Dos modos con la misma cantidad de aciertos no es una decisión: se
      // responde el primero, pero diciendo que se responde a medias.
      let base = porApp.isEmpty ? 0.6 : 0.85
      let probabilidad = empatados > 1 ? base / Double(empatados) : base
      let ganador = puntajes.first { $0.1 == mejor.1 }?.0 ?? mejor.0
      let acertadas = ganador.palabrasClave
        .filter { palabras.contains(Self.normalizar($0)) }
      return RespuestaTipada(
        valor: ganador.opcion,
        probabilidad: probabilidad,
        porQue: "dijiste \(acertadas.joined(separator: ", "))"
      )
    }

    // Ni app ni palabras: la primera opción, con la probabilidad de haberla
    // adivinado. Quien llama decide si con eso le basta.
    return RespuestaTipada(
      valor: opciones[0], probabilidad: 1.0 / Double(opciones.count)
    )
  }

  /// Minúsculas y sin tildes: "Código" y "codigo" son la misma señal, y el
  /// dictado escribe una u otra según el motor.
  static func normalizar(_ texto: String) -> String {
    texto.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
  }

  static func palabras(de texto: String) -> Set<String> {
    Set(
      normalizar(texto)
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map(String.init)
    )
  }
}
