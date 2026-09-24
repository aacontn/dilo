import Foundation
import Security

/// El porcentaje del plan de Claude, preguntado a Anthropic con la sesión que
/// Claude Code ya tiene abierta.
///
/// Es el método de CodexBar (MIT, `ClaudeOAuthUsageFetcher`), leído y escrito
/// de nuevo acá, no copiado: `GET api.anthropic.com/api/oauth/usage` con el
/// token OAuth que Claude Code guarda en el Llavero bajo
/// «Claude Code-credentials». Devuelve la ventana de cinco horas
/// (`five_hour`) y la semanal (`seven_day`), cada una con `utilization` —el
/// porcentaje usado— y `resets_at`.
///
/// **Cómo se trata la credencial.** Se lee del Llavero en cada consulta y se
/// suelta al terminar: no se guarda en ningún lado, no se escribe en el
/// registro y no sale hacia ningún servidor que no sea el de Anthropic, que es
/// quien la emitió. La primera lectura la autoriza la persona en el diálogo
/// del sistema; si dice que no, la muesca sigue con los tokens de
/// `LectorDeClaude`. Nunca se renueva el token: eso es de Claude Code, y dos
/// apps renovando la misma sesión terminan cerrándosela a la otra.
public struct ClienteDeUsoDeClaude: Sendable {
  public enum Falla: Error, Equatable {
    /// No hay sesión de Claude Code en el Llavero, o la persona no dejó leerla.
    case sinSesion
    /// El token venció; se renueva la próxima vez que se use Claude Code.
    case sesionVencida
    /// Anthropic pidió esperar. Se respeta.
    case esperar(hasta: Date)
    case respuesta(codigo: Int)
    case formato
    /// No se llegó a Anthropic: sin red, o la red no deja pasar.
    case sinRed

    /// Cualquier error de una consulta, dicho como una de estas fallas. Es lo
    /// que Ajustes traduce a palabras en «Probar ahora».
    public static func de(_ error: Error) -> Falla {
      if let falla = error as? Falla { return falla }
      if error is URLError { return .sinRed }
      return .respuesta(codigo: 0)
    }
  }

  static let servicioDelLlavero = "Claude Code-credentials"
  static let direccion = URL(string: "https://api.anthropic.com/api/oauth/usage")!
  static let cabeceraBeta = "oauth-2025-04-20"

  /// Cómo se presenta Dilo al pedirlo.
  public var agente: String

  public init(agente: String) {
    self.agente = agente
  }

  public func leer(ahora: Date = Date()) async throws -> ConsumoDeIA {
    let token = try Self.tokenDelLlavero(ahora: ahora)
    var pedido = URLRequest(url: Self.direccion, timeoutInterval: 20)
    pedido.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    pedido.setValue("application/json", forHTTPHeaderField: "Accept")
    pedido.setValue(Self.cabeceraBeta, forHTTPHeaderField: "anthropic-beta")
    pedido.setValue(agente, forHTTPHeaderField: "User-Agent")
    let datos: Data
    let respuesta: URLResponse
    do {
      (datos, respuesta) = try await URLSession.shared.data(for: pedido)
    } catch {
      throw Falla.de(error)
    }
    let codigo = (respuesta as? HTTPURLResponse)?.statusCode ?? 0
    switch codigo {
    case 200:
      guard let consumo = Self.decodificar(datos) else { throw Falla.formato }
      return consumo
    case 401, 403:
      throw Falla.sesionVencida
    case 429:
      let segundos = (respuesta as? HTTPURLResponse)?
        .value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 300
      throw Falla.esperar(hasta: ahora.addingTimeInterval(segundos))
    default:
      throw Falla.respuesta(codigo: codigo)
    }
  }

  /// El token de acceso de Claude Code, o una falla que dice por qué no.
  static func tokenDelLlavero(ahora: Date) throws -> String {
    let consulta: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: servicioDelLlavero,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnData as String: true,
    ]
    var resultado: CFTypeRef?
    guard SecItemCopyMatching(consulta as CFDictionary, &resultado) == errSecSuccess,
      let datos = resultado as? Data
    else { throw Falla.sinSesion }
    return try token(de: datos, ahora: ahora)
  }

  /// Lo que Claude Code guarda: `{"claudeAiOauth":{"accessToken":…,
  /// "expiresAt": milisegundos}}`.
  static func token(de datos: Data, ahora: Date) throws -> String {
    struct Guardado: Decodable {
      struct Sesion: Decodable {
        let accessToken: String?
        let expiresAt: Double?
      }
      let claudeAiOauth: Sesion?
    }
    guard let sesion = (try? JSONDecoder().decode(Guardado.self, from: datos))?.claudeAiOauth,
      let token = sesion.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
      !token.isEmpty
    else { throw Falla.sinSesion }
    if let vence = sesion.expiresAt, Date(timeIntervalSince1970: vence / 1000) <= ahora {
      throw Falla.sesionVencida
    }
    return token
  }

  static func decodificar(_ datos: Data) -> ConsumoDeIA? {
    struct Respuesta: Decodable {
      struct Ventana: Decodable {
        let utilization: Double?
        let resets_at: String?
      }
      let five_hour: Ventana?
      let seven_day: Ventana?
    }
    guard let respuesta = try? JSONDecoder().decode(Respuesta.self, from: datos),
      let corta = respuesta.five_hour
    else { return nil }
    func ventana(_ v: Respuesta.Ventana, horas: Double) -> VentanaDeUso {
      VentanaDeUso(
        porcentaje: v.utilization ?? 0,
        seReiniciaEn: v.resets_at.flatMap(fecha),
        duracion: horas * 3600
      )
    }
    return ConsumoDeIA(
      ventanaCorta: ventana(corta, horas: 5),
      ventanaSemanal: respuesta.seven_day.map { ventana($0, horas: 168) }
    )
  }

  static func fecha(_ texto: String) -> Date? {
    let conFraccion = ISO8601DateFormatter()
    conFraccion.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return conFraccion.date(from: texto) ?? ISO8601DateFormatter().date(from: texto)
  }
}
