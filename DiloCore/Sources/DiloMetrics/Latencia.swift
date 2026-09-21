import AppKit
import Foundation

/// El número que la gente siente: cuánto pasa entre soltar la tecla y ver el
/// texto.
///
/// Medirlo de verdad exige que alguien hable, y un número que depende de una
/// persona no entra en CI. Por eso existe el gancho **`DILO_METRICS_WAV`**
/// (`Talkify/Dictation/MicrophoneInput+MetricasWAV.swift`, sólo en builds
/// Debug): con esa variable apuntando a un WAV, la sesión de dictado escucha el
/// archivo en vez del micrófono, al ritmo real, y cuando el controlador manda a
/// parar —que es exactamente lo que hace soltar la tecla— anota el instante en
/// `<wav>.soltado`. De ahí sale el t0. El t1 es el `changeCount` del
/// portapapeles cambiando en este proceso.
///
/// Lo que queda fuera de la medición a propósito: abrir el menú de la barra
/// para disparar y para parar. Esos cientos de milisegundos son del
/// AppleScript, no de Dilo, y por eso el t0 se toma adentro de la app.
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

    try alternarDictado(pid: pid, esperando: "Parar")
    // El gancho reproduce el WAV en tiempo real; medio segundo de sobra para
    // que el reconocedor reciba la última palabra antes de que se suelte.
    dormir(duracionDelWav + 0.5)
    // Soltar: se manda el clic y se empieza a mirar el portapapeles en el acto,
    // sin esperar a que `osascript` vuelva.
    let clicDeParada = try Concha.lanzar(
      "/usr/bin/osascript",
      ["-e", guion(pid: pid, cuerpo: cuerpoDelClic)]
    )
    defer { clicDeParada.waitUntilExit() }

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

  /// El menú de la barra de Dilo, escrito una sola vez.
  ///
  /// La barra se busca por forma —la que tiene un solo ítem— y no por índice:
  /// mientras Ajustes está abierta la app deja de ser accesoria y `menu bar 1`
  /// pasa a ser el menú principal (Dilo, Archivo, Edición…). Clicar ahí a
  /// ciegas abre Ajustes en vez de dictar, que fue exactamente lo que pasó la
  /// primera vez.
  ///
  /// Se apunta **por pid y no por nombre**: en este repo conviven `Dilo` y
  /// `Dilo-MAS`, y los dos se llaman "Dilo" para Accesibilidad. Pedir "el
  /// proceso Dilo" dicta con la app equivocada y el número medido es de otra.
  static func guion(pid: pid_t, cuerpo: String) -> String {
    """
    tell application "System Events" to tell (first application process whose unix id is \(pid))
      set barra to missing value
      repeat with b in menu bars
        if (count of menu bar items of b) is 1 then set barra to b
      end repeat
      if barra is missing value then error "no encontré la barra del status item de Dilo"
      \(cuerpo)
    end tell
    """
  }

  static func correrGuion(_ texto: String, queja: String) throws -> String {
    let resultado = try Concha.correr("/usr/bin/osascript", ["-e", texto])
    guard resultado.codigo == 0 else {
      throw ErrorDeMedicion(
        "\(queja): \(resultado.error.trimmingCharacters(in: .whitespacesAndNewlines)). "
          + "El terminal desde el que corres metrics.sh necesita Accesibilidad."
      )
    }
    return resultado.salida.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Cómo se llama ahora el primer ítem del menú: dice si hay sesión en curso.
  static func estadoDelItem(pid: pid_t) throws -> String {
    try correrGuion(
      guion(pid: pid, cuerpo: "return name of menu item 1 of menu 1 of menu bar item 1 of barra"),
      queja: "no pude leer el menú de Dilo"
    )
  }

  /// Aprieta el primer ítem del menú de la barra: "Empezar a dictar" o "Parar
  /// el dictado", según el estado. Es el único disparador que no exige que
  /// alguien mantenga una tecla apretada.
  static let cuerpoDelClic = """
    click menu bar item 1 of barra
      delay 0.15
      click menu item 1 of menu 1 of menu bar item 1 of barra
    """

  static func apretarElItemDeDictado(pid: pid_t) throws {
    _ = try correrGuion(
      guion(pid: pid, cuerpo: cuerpoDelClic),
      queja: "no pude apretar el menú de Dilo"
    )
  }

  /// Aprieta y comprueba que el estado cambió. Un clic que no cambia nada
  /// significa que la app no está lista —falta un permiso, o el modelo del
  /// idioma— y da un error que dice eso en vez de un timeout de veinte
  /// segundos sin explicación.
  static func alternarDictado(pid: pid_t, esperando esperado: String) throws {
    for intento in 1...3 {
      if try estadoDelItem(pid: pid).contains(esperado) { return }
      try apretarElItemDeDictado(pid: pid)
      dormir(0.3)
      if try estadoDelItem(pid: pid).contains(esperado) { return }
      if intento < 3 { dormir(1) }
    }
    throw ErrorDeMedicion(
      "el menú de Dilo no llegó a “\(esperado)”: la app no está lista para dictar "
        + "(¿micrófono, reconocimiento de voz, modelo de español?)"
    )
  }
}
