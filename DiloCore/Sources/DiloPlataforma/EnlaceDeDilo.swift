import Foundation

/// Lo que Dilo entiende de una URL `dilo://` (`CFBundleURLTypes` de
/// `Dilo/Info.plist`, 2026-10-15).
///
/// **Hoy hay una sola ruta, `agente`, y es a propósito.** Un URL scheme lo
/// abre cualquiera: un *hook*, un script, pero también una página web con un
/// enlace o un correo. Por eso por acá sólo entra lo que **muestra** algo en
/// la muesca y se puede quitar con un clic. Lo que abre el micrófono, escribe
/// Ajustes o toca el portapapeles —dictar, elegir un modo, copiar lo
/// último— va por App Intents (`Dilo/Atajos/`), que pide un atajo que la
/// persona armó o a Siri, nunca por una URL que una página puede disparar.
public enum EnlaceDeDilo: Equatable, Sendable {
  case agente(EventoDeAgente)

  public static let esquema = "dilo"

  /// Por qué una URL no se entendió. Va al log, a nivel notice, para que
  /// quien pegó mal un *hook* lo encuentre con `log show` en vez de mirar
  /// una muesca que no cambia.
  public enum Rechazo: Error, Equatable, Sendable {
    case otroEsquema
    /// La ruta (el host de la URL) que no existe, en minúsculas.
    case rutaDesconocida(String)
    /// `fase=` falta o no es una de las de `EventoDeAgente.Fase`.
    case faseDesconocida(String?)
    /// Más larga de lo que un *hook* necesita: no se lee.
    case demasiadoLarga
  }

  /// Ninguna línea de *hook* llega a esto; una URL más larga es otra cosa y
  /// no se mira entera.
  public static let largoMaximo = 1024

  public static func leer(_ url: URL) -> Result<EnlaceDeDilo, Rechazo> {
    guard url.scheme?.lowercased() == esquema else { return .failure(.otroEsquema) }
    guard url.absoluteString.utf8.count <= largoMaximo else { return .failure(.demasiadoLarga) }
    guard let partes = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return .failure(.rutaDesconocida(""))
    }
    // `dilo://agente?…` trae la ruta en el host; `dilo:agente?…`, en el
    // path. Las dos son la misma URL para quien la escribe a mano.
    let ruta = (partes.host ?? partes.path)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      .lowercased()
    guard ruta == "agente" else { return .failure(.rutaDesconocida(ruta)) }

    func valor(_ nombre: String) -> String? {
      partes.queryItems?.first { $0.name.lowercased() == nombre }?.value
    }
    let textoDeFase = valor("fase")?.trimmingCharacters(in: .whitespaces).lowercased()
    guard let fase = textoDeFase.flatMap(EventoDeAgente.Fase.init(rawValue:)) else {
      return .failure(.faseDesconocida(textoDeFase.map { String($0.prefix(24)) }))
    }
    let agente = valor("de")
      .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
      .flatMap(EventoDeAgente.Agente.init(rawValue:)) ?? .otro
    return .success(.agente(EventoDeAgente(agente: agente, fase: fase, proyecto: valor("proyecto") ?? "")))
  }
}
