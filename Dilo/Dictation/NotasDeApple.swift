import Foundation

/// Cómo terminó guardar una nota en Apple Notas.
enum ResultadoDeLaNota: Equatable, Sendable {
  case guardada
  /// macOS no dejó a Dilo controlar Notas: la persona dijo que no, o todavía
  /// no le preguntó.
  case sinPermiso
  case fallo
}

/// Guarda lo dictado como una nota en Apple Notas, en la carpeta «Dilo».
///
/// Pedido del 2026-09-24 (el 7 de la lista): «dictar una nota sin abrir
/// ninguna app», y que quede en Apple Notas —así llega al iPhone por iCloud—.
///
/// **Por `osascript` y con el texto como argumento.** Notas no tiene otra API
/// que Apple Events. Correrlo como proceso aparte deja a Dilo libre mientras
/// Notas arranca, que puede tardar segundos; y pasar el título y el cuerpo
/// como argumentos —no pegados dentro del script— es lo que evita que un
/// dictado con comillas rompa el script o, peor, se ejecute como parte de él.
/// La primera vez macOS pregunta «Dilo quiere controlar Notas»; sin eso
/// (`-1743`) la nota no se guarda y el texto se copia al portapapeles.
enum NotasDeApple {
  static let carpeta = "Dilo"

  static let script = """
  on run argv
    set elTitulo to item 1 of argv
    set elCuerpo to item 2 of argv
    tell application "Notes"
      set laCuenta to default account
      if not (exists folder "\(carpeta)" of laCuenta) then
        make new folder at laCuenta with properties {name:"\(carpeta)"}
      end if
      make new note at folder "\(carpeta)" of laCuenta with properties {name:elTitulo, body:elCuerpo}
    end tell
  end run
  """

  static func guardar(_ texto: String, cuando: Date = Date()) async -> ResultadoDeLaNota {
    let titulo = titulo(para: cuando)
    let cuerpo = cuerpoHTML(titulo: titulo, texto: texto)
    return await Task.detached(priority: .userInitiated) {
      correr(argumentos: [titulo, cuerpo])
    }.value
  }

  /// «Nota · 24 sep, 14:32». La fecha y no la primera línea: una primera
  /// línea larga se repetiría arriba del cuerpo, y la fecha es lo que alguien
  /// busca después («lo que dicté el martes»).
  static func titulo(para fecha: Date) -> String {
    let cuando = fecha.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    return String(localized: "Nota · \(cuando)")
  }

  /// Notas guarda HTML: el título en negrita arriba —es lo que lista como
  /// nombre— y cada párrafo en su `div`, escapado.
  static func cuerpoHTML(titulo: String, texto: String) -> String {
    let parrafos = texto
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? "<div><br></div>" : "<div>\(escapar(String($0)))</div>" }
      .joined()
    return "<div><b>\(escapar(titulo))</b></div>\(parrafos)"
  }

  static func escapar(_ texto: String) -> String {
    texto
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }

  private static func correr(argumentos: [String]) -> ResultadoDeLaNota {
    let proceso = Process()
    proceso.executableURL = URL(filePath: "/usr/bin/osascript")
    proceso.arguments = ["-e", script, "--"] + argumentos
    let errores = Pipe()
    proceso.standardError = errores
    proceso.standardOutput = Pipe()
    do {
      try proceso.run()
    } catch {
      return .fallo
    }
    proceso.waitUntilExit()
    guard proceso.terminationStatus != 0 else { return .guardada }
    let salida = String(decoding: errores.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return resultado(deLaSalidaDeError: salida)
  }

  /// `-1743` es «no autorizado a enviar Apple Events»; `-1744`, que la
  /// persona todavía tiene el diálogo abierto.
  static func resultado(deLaSalidaDeError salida: String) -> ResultadoDeLaNota {
    salida.contains("-1743") || salida.contains("-1744") ? .sinPermiso : .fallo
  }
}
