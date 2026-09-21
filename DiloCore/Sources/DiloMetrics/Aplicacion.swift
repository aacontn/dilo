import AppKit
import Darwin
import Foundation

/// Un `.app` de Dilo visto desde afuera: se lanza, se le mide y se le mata.
///
/// **Siempre con `open`, nunca ejecutando el binario.** TCC atribuye los
/// permisos al proceso responsable: un binario lanzado desde el terminal hereda
/// los permisos del terminal, y entonces el micrófono y el tap de audio
/// devuelven silencio sin decir por qué. Es la trampa que documenta el spike
/// del sandbox y la razón de que esta clase exista.
public struct Aplicacion: Sendable {
  public let ruta: URL
  public let identificadorDeBundle: String
  public let nombreDelEjecutable: String

  public init(ruta: URL) throws {
    self.ruta = ruta
    let plist = ruta.appending(path: "Contents/Info.plist")
    guard let datos = try? Data(contentsOf: plist),
      let info = try? PropertyListSerialization.propertyList(from: datos, format: nil)
        as? [String: Any],
      let bundle = info["CFBundleIdentifier"] as? String,
      let ejecutable = info["CFBundleExecutable"] as? String
    else {
      throw ErrorDeMedicion("No pude leer \(plist.path): ¿es un .app?")
    }
    identificadorDeBundle = bundle
    nombreDelEjecutable = ejecutable
  }

  /// El bundle completo en disco, en bytes.
  ///
  /// Suma el tamaño real de cada archivo (no los bloques que ocupa): lo que
  /// pesa la descarga es el contenido, no el relleno del sistema de archivos.
  public func tamanoEnBytes() throws -> Int {
    guard
      let enumerador = FileManager.default.enumerator(
        at: ruta,
        includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey],
        options: []
      )
    else { throw ErrorDeMedicion("No pude recorrer \(ruta.path)") }

    var total = 0
    for caso in enumerador {
      guard let url = caso as? URL,
        let valores = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
        valores.isRegularFile == true
      else { continue }
      total += valores.fileSize ?? 0
    }
    return total
  }

  /// Si este bundle es un build Debug, o sea uno que nadie descarga.
  ///
  /// Xcode 26 saca todo el código de la app a un `*.debug.dylib` aparte para
  /// poder recargarlo en caliente, y le suma un `__preview.dylib`. Eso son
  /// doce megas que no viajan en el release: medir ahí el "tamaño de la
  /// descarga" es medir otra app. El tamaño se mide contra Release.
  public var esBuildDebug: Bool {
    let ejecutables =
      (try? FileManager.default.contentsOfDirectory(
        atPath: ruta.appending(path: "Contents/MacOS").path
      )) ?? []
    return ejecutables.contains { $0.hasSuffix(".debug.dylib") || $0 == "__preview.dylib" }
  }

  public func corriendo() -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: identificadorDeBundle)
  }

  /// Mata todas las instancias y espera a que de verdad se hayan ido.
  public func matar(esperando limite: TimeInterval = 10) {
    for instancia in corriendo() { instancia.terminate() }
    let vence = Date().addingTimeInterval(limite)
    while Date() < vence, !corriendo().isEmpty {
      dormir(0.02)
    }
    for instancia in corriendo() { instancia.forceTerminate() }
    while Date() < vence.addingTimeInterval(2), !corriendo().isEmpty {
      dormir(0.02)
    }
  }

  /// Lanza con `open` y devuelve el instante en que la app terminó de lanzar.
  ///
  /// **El criterio de "ya arrancó" es `isFinishedLaunching`**, o sea que
  /// `applicationDidFinishLaunching` volvió. Es ahí, y no antes, donde
  /// `AppDelegate` construye el `StatusItemController`: cuando esta bandera se
  /// levanta, el ítem de la barra ya existe. Se elige esta señal y no leer el
  /// ítem por Accesibilidad porque no pide permisos, no depende de que haya
  /// una sesión gráfica con barra visible, y no mide el tiempo del cliente de
  /// Accesibilidad en vez del de la app.
  @discardableResult
  public func lanzar(
    ambiente: [String: String] = [:],
    nuevaInstancia: Bool = true,
    limite: TimeInterval = 30
  ) throws -> (proceso: NSRunningApplication, segundos: TimeInterval) {
    var argumentos = ["-a", ruta.path, "-g"]
    if nuevaInstancia { argumentos.append("-n") }
    for (clave, valor) in ambiente.sorted(by: { $0.key < $1.key }) {
      argumentos.append(contentsOf: ["--env", "\(clave)=\(valor)"])
    }

    let partida = Date()
    let resultado = try Concha.correr("/usr/bin/open", argumentos)
    guard resultado.codigo == 0 else {
      throw ErrorDeMedicion("open falló (\(resultado.codigo)): \(resultado.error)")
    }

    let vence = partida.addingTimeInterval(limite)
    while Date() < vence {
      if let instancia = corriendo().first(where: { $0.isFinishedLaunching }) {
        return (instancia, Date().timeIntervalSince(partida))
      }
      dormir(0.002)
    }
    throw ErrorDeMedicion("\(identificadorDeBundle) no terminó de lanzar en \(limite) s")
  }
}

/// Duerme dejando correr el run loop.
///
/// `NSRunningApplication` se actualiza por notificaciones del espacio de
/// trabajo: un `usleep` a secas congela el run loop y las propiedades se quedan
/// pegadas en el valor que tenían al arrancar el sondeo.
public func dormir(_ segundos: TimeInterval) {
  RunLoop.current.run(until: Date().addingTimeInterval(segundos))
}
