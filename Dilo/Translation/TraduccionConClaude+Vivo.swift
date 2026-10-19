import DiloModes
import Foundation

extension TranslationCoordinator {
  /// Claude de verdad: la clave se lee del Llavero en el momento de traducir
  /// —la misma de los modos, `proveedor.anthropic`— y no se guarda en ninguna
  /// otra parte. Sin clave, `TraductorConClaude` lo dice sin armar nada.
  static let claudeEnVivo: TraductorDeClaude = { texto, destino in
    let clave = Llavero().clave(para: Proveedor.anthropicDeFabrica.cuentaEnElLlavero)
    return try await TraductorConClaude(clave: clave).traducir(texto, a: destino)
  }
}

extension FallaDeTraduccion {
  /// Lo que dice la muesca cuando Claude no tradujo y Apple tampoco pudo: el
  /// dictado quedó en el portapapeles en el idioma en que se dijo. Una línea
  /// de unos treinta caracteres, como los bloqueos.
  var aviso: String {
    switch self {
    case .faltaLaClave: String(localized: "Falta la clave de Anthropic")
    case .claveRechazada: String(localized: "Anthropic no aceptó la clave")
    case .demasiadosPedidos: String(localized: "Anthropic pidió esperar")
    case .anthropicNoResponde: String(localized: "Anthropic no está respondiendo")
    case .pedidoRechazado: String(localized: "Anthropic rechazó el pedido")
    case .sinConexion: String(localized: "Sin conexión con Anthropic")
    case .tardoDemasiado: String(localized: "Claude tardó demasiado")
    case .seNego: String(localized: "Claude no quiso traducir esto")
    case .cortada: String(localized: "Muy largo para traducir de una")
    case .respuestaInutil: String(localized: "Claude no devolvió la traducción")
    }
  }

  /// Lo que dice la muesca cuando Claude falló y tradujo Apple: el porqué en
  /// dos o tres palabras, y quién tradujo.
  var avisoConApple: String {
    let porque = switch self {
    case .faltaLaClave: String(localized: "Sin clave")
    case .claveRechazada: String(localized: "Clave rechazada")
    case .demasiadosPedidos, .anthropicNoResponde: String(localized: "Anthropic saturado")
    case .pedidoRechazado, .respuestaInutil: String(localized: "Claude falló")
    case .sinConexion: String(localized: "Sin conexión")
    case .tardoDemasiado: String(localized: "Claude tardó")
    case .seNego: String(localized: "Claude se negó")
    case .cortada: String(localized: "Muy largo")
    }
    return String(localized: "\(porque): tradujo Apple")
  }
}
