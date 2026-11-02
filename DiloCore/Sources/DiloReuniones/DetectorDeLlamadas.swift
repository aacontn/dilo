import Foundation

// Técnica observada en Muesli: preguntarle a Core Audio qué proceso tiene la
// entrada abierta y compararlo con apps de llamadas conocidas; implementación
// y reglas propias.

/// Una app de llamadas, por el nombre que se le dice a la persona.
public struct AppDeLlamada: Sendable, Hashable {
  public let nombre: String

  public init(nombre: String) {
    self.nombre = nombre
  }
}

/// Qué procesos cuentan como una llamada. Un helper de Electron o de un
/// navegador abre el micrófono con el id de su app más un sufijo
/// (`com.google.Chrome.helper`), así que se compara por prefijo. FaceTime lo
/// abre `avconferenced` y Safari, `com.apple.WebKit.GPU`.
public enum AppsDeLlamadas {
  static let conocidas: [(paquete: String, nombre: String)] = [
    ("us.zoom.xos", "Zoom"),
    ("com.microsoft.teams2", "Teams"),
    ("com.microsoft.teams", "Teams"),
    ("com.cisco.webexmeetingsapp", "Webex"),
    ("com.webex.meetingmanager", "Webex"),
    ("com.apple.avconferenced", "FaceTime"),
    ("com.apple.FaceTime", "FaceTime"),
    ("com.tinyspeck.slackmacgap", "Slack"),
    ("net.whatsapp.WhatsApp", "WhatsApp"),
    ("com.hnc.Discord", "Discord"),
    ("ru.keepcoder.Telegram", "Telegram"),
    ("com.google.Chrome", "Chrome"),
    ("com.brave.Browser", "Brave"),
    ("company.thebrowser.Browser", "Arc"),
    ("com.microsoft.edgemac", "Edge"),
    ("org.mozilla.firefox", "Firefox"),
    ("com.apple.WebKit.GPU", "Safari"),
    ("com.apple.Safari", "Safari"),
  ]

  public static func app(dePaquete paquete: String) -> AppDeLlamada? {
    conocidas
      .first { paquete == $0.paquete || paquete.hasPrefix($0.paquete + ".") }
      .map { AppDeLlamada(nombre: $0.nombre) }
  }
}

/// Cuándo ofrecer grabar una llamada. Puro: recibe qué apps tienen el micrófono
/// abierto cada vez que algo cambia y nunca empieza a grabar.
///
/// Se ofrece una vez por llamada, y lo ignorado no insiste. Una app que suelta
/// el micrófono y lo retoma antes de `descanso` sigue en la misma llamada: Meet
/// lo cierra al silenciarte.
public struct DetectorDeLlamadas: Sendable {
  /// Cuánto tiene que seguir abierto para contar: una prueba de micrófono o
  /// una nota de voz corta no son una llamada. De partida, sin medir.
  public static let firmeza: TimeInterval = 3
  /// Cuánto sin micrófono separa una llamada de la siguiente. De partida, sin
  /// medir.
  public static let descanso: TimeInterval = 300
  /// Cada cuánto se vuelve a mirar si la muesca está ocupada.
  static let esperaConLaMuescaOcupada: TimeInterval = 1

  public enum Decision: Sendable, Equatable {
    case nada
    case revisarEn(TimeInterval)
    case ofrecer(AppDeLlamada)
  }

  private var vistaDesde: [AppDeLlamada: Date] = [:]
  private var ofrecidas: Set<AppDeLlamada> = []
  private var salieron: [AppDeLlamada: Date] = [:]

  public init() {}

  public mutating func observar(
    activas: Set<AppDeLlamada>, ahora: Date, grabando: Bool, ocupado: Bool
  ) -> Decision {
    vistaDesde = vistaDesde.filter { activas.contains($0.key) }
    for app in activas where vistaDesde[app] == nil { vistaDesde[app] = ahora }
    for app in ofrecidas {
      if activas.contains(app) {
        if let salio = salieron.removeValue(forKey: app), ahora.timeIntervalSince(salio) >= Self.descanso {
          ofrecidas.remove(app)
        }
      } else if salieron[app] == nil {
        salieron[app] = ahora
      }
    }
    // Lo que ya se graba no se ofrece, tampoco al terminar la grabación con la
    // llamada todavía abierta.
    if grabando {
      ofrecidas.formUnion(activas)
      return .nada
    }
    let pendientes = activas.subtracting(ofrecidas).sorted { $0.nombre < $1.nombre }
    guard !pendientes.isEmpty else { return .nada }
    func faltan(_ app: AppDeLlamada) -> TimeInterval {
      Self.firmeza - ahora.timeIntervalSince(vistaDesde[app] ?? ahora)
    }
    guard let firme = pendientes.first(where: { faltan($0) <= 0 }) else {
      return .revisarEn(pendientes.map(faltan).min() ?? Self.firmeza)
    }
    guard !ocupado else { return .revisarEn(Self.esperaConLaMuescaOcupada) }
    ofrecidas.insert(firme)
    return .ofrecer(firme)
  }
}
