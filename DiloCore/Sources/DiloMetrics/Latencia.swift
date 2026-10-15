import AppKit
import Foundation

/// El número que la gente siente: cuánto pasa entre soltar la tecla y ver el
/// texto.
///
/// Medirlo de verdad exige que alguien hable, y un número que depende de una
/// persona no entra en CI. Por eso existe el gancho **`DILO_METRICS_WAV`**
/// (`Dilo/Dictation/MicrophoneInput+MetricasWAV.swift`, sólo en builds
/// Debug): con esa variable apuntando a un WAV, la sesión de dictado escucha el
/// archivo en vez del micrófono, al ritmo real, y cuando el controlador manda a
/// parar —que es exactamente lo que hace soltar la tecla— anota el instante en
/// `<wav>.soltado`. De ahí sale el t0. El t1 es el `changeCount` del
/// portapapeles cambiando en este proceso.
///
/// Lo que queda fuera de la medición a propósito: mandar a empezar y a parar.
/// Eso es de quien mide, no de Dilo, y por eso el t0 se toma adentro de la
/// app. Desde el 2026-10-15 se manda con una notificación distribuida que
/// sólo escucha una copia Debug con el gancho (`DisparadorDeMetricas`): el
/// ícono de la barra ya no tiene un menú que un AppleScript pueda apretar.
public enum Latencia {
  public struct Resultado: Sendable {
    public let segundos: TimeInterval
    public let texto: String
  }

  /// Frase de prueba. Español chileno de trabajo, ~5 s dicha por `say`, con
  /// spanglish técnico adentro porque es justo lo que Dilo no puede romper.
  public static let frase =
    "Oye, anota esto: hay que revisar el deploy de la landing antes del viernes "
    + "y avisarle al equipo."

  /// Genera el WAV con `say`. Mono, 16 kHz, entero de 16 bits: el formato que
  /// pide el reconocedor, así que el conversor del gancho no inventa nada.
  public static func generarWAV(en url: URL, voz: String = "Mónica") throws -> TimeInterval {
    try? FileManager.default.removeItem(at: url)
    let resultado = try Concha.correr(
      "/usr/bin/say",
      [
        "-v", voz,
        "-o", url.path,
        "--file-format=WAVE",
        "--data-format=LEI16@16000",
        frase,
      ]
    )
    guard resultado.codigo == 0, FileManager.default.fileExists(atPath: url.path) else {
      throw ErrorDeMedicion("say falló (\(resultado.codigo)): \(resultado.error)")
    }
    return try duracion(de: url)
  }

  public static func duracion(de url: URL) throws -> TimeInterval {
    let resultado = try Concha.correr("/usr/bin/afinfo", [url.path])
    guard let segundos = Reposo.primerNumero(en: resultado.salida, tras: "estimated duration:")
    else {
      throw ErrorDeMedicion("afinfo no dijo la duración de \(url.lastPathComponent)")
    }
    return max(1, segundos)
  }

  /// Dónde deja el gancho el instante de "soltar". Tiene que coincidir con
  /// `EntradaWAVDeMetricas.marcaDeSoltado`.
  public static func rutaDelSoltado(de wav: URL) -> URL {
    URL(fileURLWithPath: wav.path + ".soltado")
  }

  /// Corre una medición completa contra una app ya lanzada con el gancho.
  ///
  /// - Parameters:
  ///   - app: el `.app` bajo medición, ya lanzado con `DILO_METRICS_WAV`.
  ///   - wav: el archivo que el gancho va a reproducir.
  ///   - duracionDelWav: cuánto dura, para saber cuándo mandar a parar.
  public static func medir(
    pid: pid_t,
    wav: URL,
    duracionDelWav: TimeInterval,
    limite: TimeInterval = 20
  ) throws -> Resultado {
    let soltado = rutaDelSoltado(de: wav)
    try? FileManager.default.removeItem(at: soltado)
    ponerAlFinderAdelante()

    let portapapeles = NSPasteboard.general
    let cuentaInicial = portapapeles.changeCount

    // Cuarenta intentos —un minuto largo— y no tres: con Parakeet elegido y su
    // modelo en disco, la primera sesión espera a que Core ML compile y cargue
    // el modelo. En un M1 ocioso son unos veinte segundos; con la máquina
    // ocupada, bastante más. Con el motor de Apple estaba lista en tres. El que
    // se rinde antes no mide nada: sólo miente sobre por qué no midió.
    let bundle = try bundleDe(pid: pid)
    try alternarDictado(bundle: bundle, wav: wav, esperando: "dictando", intentos: 40)
    // El gancho reproduce el WAV en tiempo real; medio segundo de sobra para
    // que el reconocedor reciba la última palabra antes de que se suelte.
    dormir(duracionDelWav + 0.5)
    // Soltar: se manda a parar y se empieza a mirar el portapapeles en el
    // acto.
    mandarAAlternar(bundle: bundle)

    let vence = Date().addingTimeInterval(limite)
    var texto = ""
    while Date() < vence {
      if portapapeles.changeCount != cuentaInicial {
        texto = portapapeles.string(forType: .string) ?? ""
        break
      }
      usleep(500)
    }
    let llegada = Date()
    guard !texto.isEmpty else {
      throw ErrorDeMedicion(
        "el texto nunca llegó al portapapeles en \(Int(limite)) s: "
          + "¿la app tiene el gancho (build Debug), micrófono concedido y el modelo de es?"
      )
    }
    guard let marca = try? String(contentsOf: soltado, encoding: .utf8),
      let t0 = Double(marca.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
      throw ErrorDeMedicion(
        "no apareció \(soltado.lastPathComponent): el .app medido no trae el gancho "
          + "DILO_METRICS_WAV (¿es un build Release?)"
      )
    }

    return Resultado(
      segundos: llegada.timeIntervalSince1970 - t0,
      texto: texto.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  /// Deja al Finder adelante antes de medir.
  ///
  /// Dilo pega con Cmd+V en lo que esté al frente, y lo que esté al frente
  /// mientras corre el script es la ventana de quien lo lanzó. El Finder ignora
  /// un pegado de texto: la medición no le escribe encima a nadie. Lo que se
  /// mide es el portapapeles, que se llena igual.
  static func ponerAlFinderAdelante() {
    _ = try? Concha.correr(
      "/usr/bin/osascript", ["-e", "tell application \"Finder\" to activate"]
    )
    dormir(0.5)
  }

  /// Dónde deja la app si hay sesión: «dictando» o «listo». Tiene que
  /// coincidir con `DisparadorDeMetricas` en la app.
  public static func rutaDelEstado(de wav: URL) -> URL {
    URL(fileURLWithPath: wav.path + ".estado")
  }

  /// El nombre de la notificación que escucha la copia medida. Tiene que
  /// coincidir con `DisparadorDeMetricas.nombre(paraElBundle:)`.
  static func notificacion(paraElBundle bundle: String) -> Notification.Name {
    Notification.Name("\(bundle).debug.metricas")
  }

  /// Se apunta **por bundle id, sacado del pid**: la copia instalada y la de
  /// prueba se llaman las dos "Dilo". Mandarle la orden a la equivocada mide
  /// otra app.
  static func bundleDe(pid: pid_t) throws -> String {
    guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else {
      throw ErrorDeMedicion("no encontré la app con pid \(pid): ¿se cerró?")
    }
    return bundle
  }

  /// Si hay sesión en curso, según el archivo que deja la app.
  static func estado(de wav: URL) -> String {
    (try? String(contentsOf: rutaDelEstado(de: wav), encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  /// Empieza o para el dictado, según el estado: lo mismo que el ítem
  /// «Empezar a dictar» del menú de antes. Es el único disparador que no exige
  /// que alguien mantenga una tecla apretada. `deliverImmediately`, porque
  /// Dilo es una app accesoria que nunca está activa, y a una app inactiva el
  /// sistema le retiene las notificaciones distribuidas.
  static func mandarAAlternar(bundle: String) {
    DistributedNotificationCenter.default().postNotificationName(
      notificacion(paraElBundle: bundle),
      object: "alternar",
      userInfo: nil,
      deliverImmediately: true
    )
  }

  /// Aprieta y comprueba que el estado cambió. Un clic que no cambia nada
  /// significa que la app no está lista —falta un permiso, o el modelo del
  /// idioma— y da un error que dice eso en vez de un timeout de veinte
  /// segundos sin explicación.
  static func alternarDictado(
    bundle: String,
    wav: URL,
    esperando esperado: String,
    intentos: Int = 3
  ) throws {
    for intento in 1...intentos {
      if estado(de: wav) == esperado { return }
      mandarAAlternar(bundle: bundle)
      dormir(0.3)
      if estado(de: wav) == esperado { return }
      if intento < intentos { dormir(1.5) }
    }
    if estado(de: wav).isEmpty {
      throw ErrorDeMedicion(
        "Dilo no dejó \(rutaDelEstado(de: wav).lastPathComponent): el .app medido no trae "
          + "el disparador de métricas (¿es un build Release?)"
      )
    }
    throw ErrorDeMedicion(
      "Dilo no llegó a “\(esperado)”: la app no está lista para dictar "
        + "(¿micrófono, reconocimiento de voz, modelo de español?)"
    )
  }
}
