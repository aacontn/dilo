import DiloAgentes
import Foundation
import os

/// El mismo binario de Dilo, sin ventanas: servidor MCP por stdio
/// (`Dilo --mcp`) o CLI (`dilo …`, o `Dilo spec|dictados|palabras|--help`).
///
/// Se decide en la primera línea de `AppDelegate.main()`, **antes** de tocar
/// `NSApplication`: en estos modos no existe la app de AppKit, así que no hay
/// muesca, ni ícono en la barra, ni tap de teclado, ni micrófono, ni Sparkle,
/// ni un diálogo de TCC por nada de eso. Lo único que se lee son ajustes y
/// los archivos del historial (`FuenteDelHistorial`). Si la carpeta del
/// historial está en Documentos, macOS puede preguntarle a la persona si
/// deja leerla a quien lanzó el proceso —el terminal o el cliente del
/// agente—; eso es TCC haciendo su trabajo, y pasa una vez.
///
/// Un binario aparte habría obligado a abrir `project.pbxproj` para un
/// target nuevo y a firmarlo por separado; desde el mismo, el comando que se
/// registra en un cliente es la ruta de la app que ya está instalada.
enum ArranqueParaAgentes {
  /// No vuelve si el modo es MCP o CLI: el proceso termina ahí, con el código
  /// del comando. Con el arranque normal vuelve en el acto y no hace nada.
  @MainActor
  static func correrSinVentanasSiCorresponde(_ argv: [String] = CommandLine.arguments) {
    let modo = ModoDeArranque.decidir(argv)
    guard modo != .app else { return }

    let app = bundleDeLaApp
    let fuente = FuenteDelHistorial(dominio: app == .main ? nil : app.bundleIdentifier)
    let version = app.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    Task {
      switch modo {
      case .servidorMCP:
        // stdout es el protocolo: este aviso va al log del sistema, nunca a
        // stdout. Sin texto dictado, sólo que arrancó.
        AppLog.agentes.notice("Servidor MCP por stdio, Dilo \(version, privacy: .public)")
        await ServidorMCP(fuente: fuente, version: version).correrPorStdio()
        AppLog.agentes.notice("Servidor MCP: stdin cerrado, salgo")
        exit(0)
      case let .cli(argumentos):
        let salida = await CLIDeDilo.correr(
          argumentos, herramientas: HerramientasDeDilo(fuente: fuente), version: version
        )
        try? FileHandle.standardOutput.write(contentsOf: Data(salida.texto.utf8))
        exit(salida.codigo)
      case .app:
        return
      }
    }
    // La cola principal sin `NSApplication.run()`: el `Task` de arriba corre
    // en el actor principal y termina el proceso con `exit`.
    dispatchMain()
  }

  /// El bundle de Dilo aunque el proceso haya entrado por el enlace
  /// `~/.local/bin/dilo`. Por el enlace, Foundation toma como bundle la
  /// carpeta del enlace: sin identificador, `UserDefaults.standard` mira un
  /// dominio vacío —el historial se ve apagado— y la versión no existe
  /// (visto el 2026-10-15). Se sigue el enlace hasta el ejecutable real,
  /// `Dilo.app/Contents/MacOS/Dilo`, y de ahí al `.app`.
  static var bundleDeLaApp: Bundle {
    if Bundle.main.bundleIdentifier != nil { return .main }
    var largo = UInt32(PATH_MAX)
    var ruta = [CChar](repeating: 0, count: Int(largo))
    guard _NSGetExecutablePath(&ruta, &largo) == 0 else { return .main }
    let ejecutable = URL(filePath: String(decoding: ruta.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self))
      .resolvingSymlinksInPath()
    let app = ejecutable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard app.pathExtension == "app", let bundle = Bundle(url: app), bundle.bundleIdentifier != nil else {
      return .main
    }
    return bundle
  }
}
