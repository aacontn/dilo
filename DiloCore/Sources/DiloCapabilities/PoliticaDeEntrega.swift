// Tiempos: técnica observada en AeriVoice 0.2.5 (sondeo, ventana y gracias) y
// Spokenly 2.31 (escritorios remotos que leen tarde). Lecturas del campo:
// Ocelli 2.1 y FluidVoice (sólo la idea de releer a los 150, 500 y 1 500 ms).
// Implementación propia.
import Foundation

/// Los tiempos de un pegado. Uno por familia de destino, no uno por app.
public struct TiemposDePegado: Equatable, Sendable {
  /// Cada cuánto se mira el acuse y el portapapeles.
  public var sondeo: Duration
  /// Cuánto se espera un acuse o un cambio en el campo.
  public var ventana: Duration
  /// Del acuse a devolver el portapapeles. La app ya tiene el texto: lo que
  /// se cuida es que una segunda lectura de la misma app (Electron lee dos
  /// veces) no se encuentre con lo de la persona.
  public var graciaTrasLectura: Duration
  /// Del «entró» por Accesibilidad a devolver.
  public var graciaTrasElCampo: Duration
  /// Cuándo se relee el campo después del ⌘V, contadas desde el ⌘V. Sólo
  /// con la última hecha se puede concluir «no cambió»: un editor que
  /// actualiza Accesibilidad tarde no puede provocar un segundo pegado.
  public var lecturasDelCampo: [Duration]
  /// Sin ninguna señal, el dictado se queda en el portapapeles este tiempo
  /// —lo que dura la tarjeta— por si la persona pega a mano, y recién ahí
  /// vuelve lo suyo.
  public var esperaSinSenal: Duration
  /// Tras teclear, cuándo se vuelve a mirar el campo.
  public var lecturaTrasTeclear: Duration

  public init(
    sondeo: Duration = .milliseconds(50),
    ventana: Duration = .seconds(2),
    graciaTrasLectura: Duration = .milliseconds(500),
    graciaTrasElCampo: Duration = .milliseconds(100),
    lecturasDelCampo: [Duration] = [.milliseconds(150), .milliseconds(500), .milliseconds(1_500)],
    esperaSinSenal: Duration = .seconds(8),
    lecturaTrasTeclear: Duration = .milliseconds(250)
  ) {
    self.sondeo = sondeo
    self.ventana = ventana
    self.graciaTrasLectura = graciaTrasLectura
    self.graciaTrasElCampo = graciaTrasElCampo
    self.lecturasDelCampo = lecturasDelCampo
    self.esperaSinSenal = esperaSinSenal
    self.lecturaTrasTeclear = lecturaTrasTeclear
  }

  public static let deFabrica = TiemposDePegado()
  /// Los escritorios remotos mandan el portapapeles al otro equipo y la app
  /// de allá lo lee tarde (Spokenly usa 1,5 s y 3 s para Jump Desktop).
  public static let remoto = TiemposDePegado(
    ventana: .seconds(3),
    graciaTrasLectura: .milliseconds(1_500)
  )
}

/// Qué clase de destino es, por su bundle id.
public enum ClaseDeDestino: Equatable, Sendable {
  case normal
  /// Shells: verificar por el campo no sirve —el eco es asíncrono y el valor
  /// es todo el historial— y teclear un salto de línea **ejecuta**.
  case terminal
  /// Compartir pantalla, Windows App, Jump Desktop, iPhone Mirroring: leen el
  /// teclado a bajo nivel, así que el ⌘V va al HID como un teclado de verdad
  /// y no al proceso. Lo que cada uno pide de más (devolverle el foco,
  /// teclear en vez de pegar) todavía no está: hoy reciben el pegado de
  /// siempre, que es lo que ya recibían.
  case escritorioRemoto

  public static func de(bundleID: String?) -> ClaseDeDestino {
    guard let bundleID else { return .normal }
    if terminales.contains(bundleID) { return .terminal }
    if escritoriosRemotos.contains(bundleID) { return .escritorioRemoto }
    return .normal
  }

  /// Una lista sola y probada: Warp y Ghostty cambian de id entre canales, y
  /// es acá donde se agrega el próximo.
  static let terminales: Set<String> = [
    "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
    "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty",
    "co.zeit.hyper", "com.github.wez.wezterm",
  ]

  static let escritoriosRemotos: Set<String> = [
    "com.apple.ScreenSharing", "com.microsoft.rdc.macos",
    "com.apple.ScreenContinuity", "com.p5sys.jump.mac.viewer",
  ]
}

/// Cómo se entrega a cada clase. Una tabla y no `if` repartidos por el
/// servicio: sumar Parsec o Chrome Remote Desktop es una línea acá.
public struct PoliticaDeEntrega: Equatable, Sendable {
  public var tiempos: TiemposDePegado
  /// Si se puede reintentar tecleando cuando el ⌘V no entró.
  public var reintentarTecleando: Bool
  /// Si sirve leer el campo por Accesibilidad para confirmar, y exigir que
  /// el cursor siga donde estaba.
  public var verificarElCampo: Bool
  /// Si el ⌘V va al proceso o al HID.
  public var alProceso: Bool

  public init(
    tiempos: TiemposDePegado,
    reintentarTecleando: Bool,
    verificarElCampo: Bool,
    alProceso: Bool
  ) {
    self.tiempos = tiempos
    self.reintentarTecleando = reintentarTecleando
    self.verificarElCampo = verificarElCampo
    self.alProceso = alProceso
  }

  /// - Parameter alProcesoSePuede: lo que dice el anfitrión
  ///   (`Capacidad.atajoAlProceso`). En el sandbox no está medido, y ahí el
  ///   ⌘V sigue yendo al HID, que sí lo está.
  public static func para(_ clase: ClaseDeDestino, alProcesoSePuede: Bool = true) -> PoliticaDeEntrega {
    switch clase {
    case .normal:
      PoliticaDeEntrega(
        tiempos: .deFabrica, reintentarTecleando: true, verificarElCampo: true,
        alProceso: alProcesoSePuede)
    case .terminal:
      PoliticaDeEntrega(
        tiempos: .deFabrica, reintentarTecleando: false, verificarElCampo: false,
        alProceso: alProcesoSePuede)
    case .escritorioRemoto:
      PoliticaDeEntrega(
        tiempos: .remoto, reintentarTecleando: false, verificarElCampo: false,
        alProceso: false)
    }
  }
}
