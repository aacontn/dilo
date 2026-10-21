import Foundation
import LocalAuthentication
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
/// quien la emitió.
///
/// **Dilo nunca abre el diálogo del Llavero por su cuenta** (2026-10-21). La
/// consulta de cada dos minutos lee sin interacción (`preguntar: false`): si
/// macOS quiere preguntar, falla con `faltaPermiso` y la muesca sigue con los
/// tokens de `LectorDeClaude`. Sólo «Probar ahora» en Ajustes —un clic de la
/// persona— lee preguntando. Antes la consulta automática preguntaba, y como
/// Claude Code reescribe su ítem al renovar la sesión cada pocas horas (y
/// macOS le borra el permiso a Dilo al reescribirlo), Alfonso veía «Dilo
/// quiere acceder a Claude Code-credentials» una y otra vez. Nunca se renueva el token: eso es de Claude Code, y dos
/// apps renovando la misma sesión terminan cerrándosela a la otra.
public struct ClienteDeUsoDeClaude: Sendable {
  public enum Falla: Error, Equatable {
    /// No hay sesión de Claude Code en el Llavero, o la persona no dejó leerla.
    case sinSesion
    /// La sesión está, pero macOS pide permiso para leerla y la lectura era
    /// sin preguntar. Pasa cada vez que Claude Code renueva su sesión.
    case faltaPermiso
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

  /// - Parameter preguntar: si macOS puede mostrar su diálogo del Llavero.
  ///   Sólo con un clic de la persona; la consulta automática nunca pregunta.
  public func leer(ahora: Date = Date(), preguntar: Bool = false) async throws -> ConsumoDeIA {
    let token = try Self.tokenDelLlavero(ahora: ahora, preguntar: preguntar)
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
  static func tokenDelLlavero(ahora: Date, preguntar: Bool) throws -> String {
    var resultado: CFTypeRef?
    let estado = preguntar
      ? SecItemCopyMatching(consulta(preguntar: true) as CFDictionary, &resultado)
      : sinDialogo { SecItemCopyMatching(consulta(preguntar: false) as CFDictionary, &resultado) }
    if let falla = falla(de: estado) { throw falla }
    guard let datos = resultado as? Data else { throw Falla.sinSesion }
    return try token(de: datos, ahora: ahora)
  }

  /// La consulta al Llavero. Sin preguntar lleva además las dos formas
  /// modernas de pedirle a macOS que falle en vez de preguntar (`LAContext`
  /// con `interactionNotAllowed` y `kSecUseAuthenticationUIFail`), por si el
  /// ítem algún día pasa al Llavero de protección de datos; hoy las que
  /// mandan son las de `sinDialogo`.
  static func consulta(preguntar: Bool) -> [String: Any] {
    var consulta: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: servicioDelLlavero,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnData as String: true,
    ]
    if !preguntar {
      let contexto = LAContext()
      contexto.interactionNotAllowed = true
      consulta[kSecUseAuthenticationContext as String] = contexto
      consulta[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    }
    return consulta
  }

  /// Corre `cuerpo` con la interacción del Llavero apagada para el proceso,
  /// y la deja como estaba. **Es lo único que de verdad evita el diálogo** en
  /// el Llavero de archivo donde vive el ítem de Claude Code: medido el
  /// 2026-10-21 en el Mac de Alfonso, con sólo `interactionNotAllowed` y
  /// `kSecUseAuthenticationUIFail` el diálogo salió igual (8,6 s esperando
  /// el clic); con esto, `errSecAuthFailed` en 0,02 s y sin ventana. La API
  /// está desaconsejada desde macOS 10.10, pero no hay otra para este
  /// Llavero. Es global al proceso: el candado la serializa, y mientras dura
  /// —unos milisegundos— ninguna otra lectura del Llavero de Dilo puede
  /// preguntar, que tampoco lo necesita (sus ítems los creó Dilo).
  static func sinDialogo(_ cuerpo: () -> OSStatus) -> OSStatus {
    candado.lock()
    defer { candado.unlock() }
    var antes: DarwinBoolean = true
    SecKeychainGetUserInteractionAllowed(&antes)
    SecKeychainSetUserInteractionAllowed(false)
    defer { SecKeychainSetUserInteractionAllowed(antes.boolValue) }
    return cuerpo()
  }

  private static let candado = NSLock()

  /// Lo que dice el Llavero, como falla; nil si leyó.
  static func falla(de estado: OSStatus) -> Falla? {
    switch estado {
    case errSecSuccess: nil
    case errSecInteractionNotAllowed, errSecAuthFailed: .faltaPermiso
    default: .sinSesion
    }
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
