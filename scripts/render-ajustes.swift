import AppKit
import DiloCapabilities
import DiloModes
import DiloText
import SwiftUI
@testable import Dilo

/// Renders fuera de pantalla de la ventana de Ajustes entera: cada sección
/// del rediseño del 2026-10-19 y la búsqueda abierta. Enlaza contra el
/// `Dilo.debug.dylib` de un build-for-testing: no lanza la app, no abre
/// ventanas visibles, no toca el Llavero (las claves van fijadas en un
/// almacén en memoria) ni el historial de nadie.
///
/// Dibuja con `NSHostingView` y no con `ImageRenderer`, que cambia los
/// interruptores y selectores de AppKit por un cartel amarillo. El vidrio no
/// sale en un PNG: la ventana se pinta con el gris que el vidrio deja en la
/// pantalla (`MaterialDeAjustes.imitacion`).
@main
enum RenderAjustes {
  static let destino = URL(filePath: CommandLine.arguments.dropFirst().first
    ?? "/Volumes/SSD 1/Dilo/taller/ajustes")

  @MainActor
  static func main() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    try FileManager.default.createDirectory(at: destino, withIntermediateDirectories: true)

    // Ajustes en un plist de /private/tmp, nunca en las preferencias de
    // nadie; el historial, en una carpeta vacía de /private/tmp.
    let dominio = "/private/tmp/dilo-render-ajustes"
    let defaults = UserDefaults(suiteName: dominio)!
    defaults.removePersistentDomain(forName: dominio)
    let settings = AppSettings(defaults: defaults)
    let historial = URL(filePath: "/private/tmp/dilo-render-ajustes-historial", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: historial, withIntermediateDirectories: true)
    settings.dictationHistoryFolder = historial
    settings.palabrasPropias = ["Espacio Digital", "Kubernetes", "PostHog", "Switchboard", "Dilo"]
    settings.reemplazos = [
      Reemplazo(dice: "chat ge pe te", escribe: "ChatGPT"),
      Reemplazo(dice: "cuba netes", escribe: "Kubernetes", aprendido: true),
    ]
    settings.dictationHistoryEnabled = true

    let uso = try usoDeEjemplo()
    let ahora = Date()

    for (nombre, seccion, conClave) in secciones {
      let runtime = estado(conClave: conClave, ahora: ahora)
      try escribir(
        ventana(settings: settings, runtime: runtime, uso: uso, seccion: seccion),
        tamaño: SettingsView.tamano,
        como: "ventana-\(nombre)"
      )
      try escribir(
        ventana(settings: settings, runtime: runtime, uso: uso, seccion: seccion, alto: 2_400),
        tamaño: CGSize(width: SettingsView.tamano.width, height: 2_400),
        como: "entera-\(nombre)",
        recortar: true
      )
    }

    for (nombre, consulta) in [("clave", "clave"), ("microfono", "micro"), ("muesca", "muesca")] {
      try escribir(
        ventana(
          settings: settings, runtime: estado(conClave: true, ahora: ahora), uso: uso,
          seccion: .portada, busqueda: consulta
        ),
        tamaño: SettingsView.tamano,
        como: "busqueda-\(nombre)"
      )
    }
  }

  /// Las secciones que se miran, con y sin clave de Anthropic donde la
  /// diferencia se ve.
  @MainActor
  static var secciones: [(String, SettingsSection, Bool)] {
    var lista: [(String, SettingsSection, Bool)] = []
    // Datos en la muesca tiene su propio render (`render-datos-de-la-muesca`),
    // con los estados de cada fuente fijados: acá miraría el disco de verdad.
    for seccion in SettingsSectionGroup.allCases.flatMap(\.sections) where seccion != .datosDeLaMuesca {
      lista.append((seccion.rawValue, seccion, true))
    }
    lista.append(("modos-sin-clave", .modos, false))
    lista.append(("palabras-sin-clave", .palabras, false))
    if let inicio = SettingsSection(rawValue: "inicio") { lista.append(("inicio-sin-clave", inicio, false)) }
    if let claude = SettingsSection(rawValue: "claude") { lista.append(("claude-sin-clave", claude, false)) }
    return lista
  }

  @MainActor
  static func estado(conClave: Bool, ahora: Date) -> SettingsRuntimeState {
    let claves = ClavesDeLosProveedores(almacen: AlmacenEnMemoria())
    claves.fijar(conClave, para: SettingsRuntimeState.cuentaDeAnthropic)
    let runtime = SettingsRuntimeState(claves: claves)
    runtime.ventanaAbierta = true
    // Sin preguntarle a TCC por el proceso del render: con clave, todo
    // concedido; sin clave, también falta Accesibilidad, para ver los avisos.
    runtime.permisosQueFaltanFijos = conClave ? [] : [.accesibilidad]
    runtime.ultimoDictado = UltimoDictado(
      original: "eh mándale el informe a Carla antes del viernes",
      limpio: "Mándale el informe a Carla antes del viernes.",
      cuando: ahora.addingTimeInterval(-4 * 60)
    )
    return runtime
  }

  /// Un historial de uso de dos semanas, en un archivo temporal.
  @MainActor
  static func usoDeEjemplo() throws -> UsageTracker {
    let archivo = URL(filePath: "/private/tmp/dilo-render-ajustes-uso-\(UUID().uuidString).json")
    let tracker = UsageTracker(store: UsageStore(fileURL: archivo))
    let calendario = UsageMetrics.localCalendar()
    let grupo = DispatchGroup()
    grupo.enter()
    Task { @MainActor in
      for dia in 0..<14 {
        let fecha = Date().addingTimeInterval(-Double(dia) * 86_400)
        for vez in 0..<(3 + (dia * 7) % 9) {
          await tracker.recordSession(
            wordCount: 18 + (dia * 13 + vez * 7) % 60,
            speakingDuration: 9 + Double((dia + vez) % 12),
            at: fecha, calendar: calendario
          )
        }
      }
      grupo.leave()
    }
    while grupo.wait(timeout: .now()) == .timedOut {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return tracker
  }

  @MainActor
  static func ventana(
    settings: AppSettings,
    runtime: SettingsRuntimeState,
    uso: UsageTracker,
    seccion: SettingsSection,
    busqueda: String = "",
    alto: CGFloat? = nil
  ) -> some View {
    SettingsView(
      settings: settings,
      sounds: HUDSounds(),
      runtimeState: runtime,
      usageTracker: uso,
      updater: SparkleUpdaterService(),
      launchAtLogin: LaunchAtLoginService(),
      onClose: {},
      seccionInicial: seccion,
      busquedaInicial: busqueda,
      alto: alto
    )
    .environment(\.materialDeAjustes, .imitacion)
  }

  /// Dibuja dentro de una ventana que nunca se muestra —sin `orderFront`,
  /// fuera de toda pantalla— para que los controles salgan como en una
  /// ventana activa y con la apariencia oscura de Ajustes.
  @MainActor
  static func escribir<C: View>(_ vista: C, tamaño: CGSize, como nombre: String, recortar: Bool = false) throws {
    let anfitrion = NSHostingView(rootView: vista)
    let ventana = VentanaInvisible(
      contentRect: CGRect(x: -20_000, y: -20_000, width: tamaño.width, height: tamaño.height),
      styleMask: [.borderless],
      backing: .buffered,
      defer: true
    )
    ventana.isReleasedWhenClosed = false
    ventana.appearance = NSAppearance(named: .darkAqua)
    ventana.contentView = anfitrion
    anfitrion.frame = CGRect(origin: .zero, size: tamaño)
    // Dos vueltas de layout y de run loop: los `.task` no corren fuera de
    // pantalla, pero los `onChange(initial:)` y los `@State` sí se asientan.
    for _ in 0..<3 {
      anfitrion.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(tamaño.width * 2),
      pixelsHigh: Int(tamaño.height * 2),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else { return }
    rep.size = anfitrion.bounds.size
    anfitrion.cacheDisplay(in: anfitrion.bounds, to: rep)
    var imagen = rep
    if recortar, let recortada = recortarAbajo(rep) { imagen = recortada }
    guard let png = imagen.representation(using: .png, properties: [:]) else { return }
    try png.write(to: destino.appending(path: "\(nombre).png"))
    print("\(nombre).png \(imagen.pixelsWide / 2)×\(imagen.pixelsHigh / 2)")
  }

  /// Quita el fondo vacío de abajo de un render alto: corta donde termina el
  /// último pixel que no es del color del fondo.
  static func recortarAbajo(_ rep: NSBitmapImageRep) -> NSBitmapImageRep? {
    let ancho = rep.pixelsWide
    let alto = rep.pixelsHigh
    let fondo = rep.colorAt(x: ancho - 40, y: alto - 40)
    // La columna del contenido: a la derecha de la barra lateral.
    var ultimo = 0
    for y in stride(from: alto - 60, to: 0, by: -4) {
      var distinto = false
      for x in stride(from: 460, to: ancho - 40, by: 12) {
        if let c = rep.colorAt(x: x, y: y), let f = fondo,
          abs(c.brightnessComponent - f.brightnessComponent) > 0.02
        {
          distinto = true
          break
        }
      }
      if distinto {
        ultimo = y
        break
      }
    }
    let corte = min(alto, ultimo + 80)
    guard corte < alto, let cg = rep.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: ancho, height: corte)) else {
      return nil
    }
    let nuevo = NSBitmapImageRep(cgImage: cg)
    nuevo.size = CGSize(width: ancho / 2, height: corte / 2)
    return nuevo
  }
}

/// Una ventana que se cree activa sin estarlo: sin esto los interruptores se
/// dibujan grises, como en una ventana de fondo. Nunca se muestra.
final class VentanaInvisible: NSWindow {
  override var isKeyWindow: Bool { true }
  override var isMainWindow: Bool { true }
  override var canBecomeKey: Bool { true }
}
