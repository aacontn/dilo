import AppKit
import DiloConsumo
import SwiftUI
@testable import Dilo

/// Renders fuera de pantalla de la sección «Datos en la muesca» y del hover
/// con detalle. Enlaza contra el `Dilo.debug.dylib` de un build-for-testing:
/// no lanza la app, no abre ventanas visibles y no toca el escritorio.
@main
enum RenderDatos {
  static let destino = URL(filePath: CommandLine.arguments.dropFirst().first
    ?? "/Volumes/SSD2/scratch/dilo-mac/datos-muesca")

  @MainActor
  static func main() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    try FileManager.default.createDirectory(at: destino, withIntermediateDirectories: true)

    // Ajustes: Claude a la izquierda con el plan, Codex a la derecha, CPU
    // esperando a la izquierda (no cabe), RAM apagada. Codex «no encontrado»
    // para mostrar el cómo.
    let settings = AppSettings.previewStore()
    settings.hudDisposicion.encender(.claude, en: .izquierdo)
    settings.hudDisposicion.encender(.codex, en: .derecho)
    settings.hudDisposicion.encender(.cpu, en: .izquierdo)
    settings.hudPorcentajeDeClaude = true
    let estados: [DatoDeLaMuesca: EstadoDeLaFuente] = [
      .claude: .listo, .codex: .noEncontrado, .cpu: .listo, .ram: .listo,
    ]
    for oscuro in [true, false] {
      try escribir(
        seccion(settings: settings, estados: estados, admiteIA: true, abierta: false),
        tamaño: CGSize(width: 688, height: 1500),
        oscuro: oscuro,
        como: "ajustes-\(oscuro ? "oscuro" : "claro")"
      )
    }
    // La vista previa con el hover abierto, para ver el detalle en Ajustes.
    try escribir(
      seccion(settings: settings, estados: estados, admiteIA: true, abierta: true),
      tamaño: CGSize(width: 688, height: 420),
      oscuro: true,
      como: "ajustes-previa-hover"
    )

    // App Store: Claude y Codex no disponibles; CPU y RAM sí.
    let tienda = AppSettings.previewStore()
    tienda.hudDisposicion.encender(.cpu, en: .izquierdo)
    tienda.hudDisposicion.encender(.ram, en: .derecho)
    try escribir(
      seccion(
        settings: tienda,
        estados: [.claude: .noDisponibleEnEstaVersion, .codex: .noDisponibleEnEstaVersion, .cpu: .listo, .ram: .listo],
        admiteIA: false,
        abierta: false
      ),
      tamaño: CGSize(width: 688, height: 1100),
      oscuro: true,
      como: "ajustes-app-store"
    )

    // Sin nada encendido: lo de fábrica.
    try escribir(
      seccion(
        settings: AppSettings.previewStore(),
        estados: [.claude: .listo, .codex: .listo, .cpu: .listo, .ram: .listo],
        admiteIA: true,
        abierta: false
      ),
      tamaño: CGSize(width: 688, height: 1000),
      oscuro: true,
      como: "ajustes-de-fabrica"
    )

    // El hover con detalle, en la pantalla de Alfonso (1080p con notch
    // simulado) y en un MacBook con notch real.
    let ahora = Date()
    for (nombre, pantallaBase) in [("simulado", pantallaSimulada), ("notch", HUDPreviewScreen.notched)] {
      var pantalla = pantallaBase
      pantalla.anchoDeLosLados = HUDNotchGeometry.anchoDeUnLado
      for encima in [false, true] {
        let content = DictationHUDContent()
        VistaPreviaDeLosDatos.posar(
          content, izquierdo: .claude, derecho: .codex, conPlan: true, encima: encima, ahora: ahora)
        if encima { content.contexto = "Mándale el informe a Carla antes del viernes" }
        for oscuro in [true, false] {
          try escribir(
            escritorio(pantalla: pantalla, oscuro: oscuro) {
              DictationHUDShellView(
                screen: pantalla,
                settings: settings.sessionSettings,
                content: content
              )
            },
            tamaño: CGSize(width: 640, height: 150),
            oscuro: oscuro,
            como: "\(encima ? "hover" : "reposo")-\(nombre)-\(oscuro ? "oscuro" : "claro")"
          )
        }
      }
    }
    // El panel del hover completo (2026-09-24): recientes, datos, la próxima
    // reunión con enlace y los modos, con uno elegido.
    var conPanel = pantallaSimulada
    conPanel.anchoDeLosLados = HUDNotchGeometry.anchoDeUnLado
    conPanel.seccionesPosibles = .todas
    let panel = DictationHUDContent()
    VistaPreviaDeLosDatos.posar(panel, izquierdo: .claude, derecho: .codex, conPlan: true, encima: true, ahora: ahora)
    panel.agregarReciente("Quedamos el martes a las diez en la oficina de Carla", origen: .dictado, cuando: ahora)
    panel.agregarReciente("https://github.com/aacontn/dilo/pull/8", origen: .copiado, cuando: ahora)
    panel.agregarReciente("Mándale el informe a Carla antes del viernes", origen: .dictado, cuando: ahora)
    panel.recienteCopiadoID = panel.recientes[1].id
    panel.proximaReunion = ProximaReunion(
      titulo: "Revisión semanal con Espacio Digital",
      empieza: ahora.addingTimeInterval(8 * 60),
      termina: ahora.addingTimeInterval(38 * 60),
      enlace: URL(string: "https://meet.google.com/abc-defg-hij")
    )
    panel.modosDelPanel = [
      ModoDelPanel(id: "correo", nombre: "Correo"),
      ModoDelPanel(id: "mensaje", nombre: "Mensaje"),
      ModoDelPanel(id: "notas", nombre: "Notas"),
    ]
    panel.modoDelPanelID = "correo"
    panel.ofreceNota = true
    for oscuro in [true, false] {
      try escribir(
        escritorio(pantalla: conPanel, oscuro: oscuro, alto: 280) {
          DictationHUDShellView(screen: conPanel, settings: settings.sessionSettings, content: panel)
        },
        tamaño: CGSize(width: 640, height: 280),
        oscuro: oscuro,
        como: "hover-panel-completo-\(oscuro ? "oscuro" : "claro")"
      )
    }

    // Dictando una nota rápida: la línea lleva el ícono de nota adelante.
    let nota = DictationHUDContent()
    nota.estado = .dictando
    nota.isRevealed = true
    nota.showsVoiceVisual = true
    nota.esNota = true
    nota.text = "Comprar pan, leche y "
    nota.volatileText = "café"
    try escribir(
      escritorio(pantalla: pantallaSimulada, oscuro: true) {
        DictationHUDShellView(screen: pantallaSimulada, settings: settings.sessionSettings, content: nota)
      },
      tamaño: CGSize(width: 640, height: 150),
      oscuro: true,
      como: "dictando-nota"
    )

    // CPU y RAM, que tienen una sola fila.
    var pantalla = pantallaSimulada
    pantalla.anchoDeLosLados = HUDNotchGeometry.anchoDeUnLado
    let sistema = DictationHUDContent()
    VistaPreviaDeLosDatos.posar(sistema, izquierdo: .cpu, derecho: .ram, conPlan: false, encima: true, ahora: ahora)
    try escribir(
      escritorio(pantalla: pantalla, oscuro: true) {
        DictationHUDShellView(screen: pantalla, settings: settings.sessionSettings, content: sistema)
      },
      tamaño: CGSize(width: 640, height: 150),
      oscuro: true,
      como: "hover-cpu-ram"
    )
  }

  static let pantallaSimulada = HUDScreenSnapshot(
    id: 1,
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    safeAreaTop: 0,
    auxiliaryTopLeftArea: nil,
    auxiliaryTopRightArea: nil,
    menuBarHeight: 24,
    estiloSinNotch: .notchSimulado
  )

  @MainActor
  static func seccion(
    settings: AppSettings,
    estados: [DatoDeLaMuesca: EstadoDeLaFuente],
    admiteIA: Bool,
    abierta: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 24) {
      VStack(alignment: .leading, spacing: 6) {
        Text(SettingsSection.datosDeLaMuesca.title)
          .font(.system(size: 26, weight: .semibold, design: .rounded))
        Text(SettingsSection.datosDeLaMuesca.subtitle)
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.52))
      }
      DatosDeLaMuescaSettingsView(
        settings: settings,
        estadosFijos: estados,
        admiteIA: admiteIA,
        previaAbierta: abierta
      )
    }
    .frame(width: 620, alignment: .leading)
    .padding(.horizontal, 34)
    .padding(.vertical, 30)
    .superficieDeDilo()
  }

  /// Una franja de escritorio con su barra de menús, como en
  /// `render-muesca.swift`: la muesca cuelga del borde de arriba.
  @MainActor
  static func escritorio<C: View>(
    pantalla: HUDScreenSnapshot,
    oscuro: Bool,
    alto: CGFloat = 150,
    @ViewBuilder hud: () -> C
  ) -> some View {
    ZStack(alignment: .top) {
      (oscuro ? Color(red: 0.12, green: 0.14, blue: 0.2) : Color(red: 0.78, green: 0.84, blue: 0.93))
      Rectangle()
        .fill(oscuro ? Color.black.opacity(0.35) : Color.white.opacity(0.6))
        .frame(height: max(pantalla.menuBarHeight, 24))
      hud()
        .frame(width: 640, height: alto, alignment: .top)
    }
  }

  /// Dibuja con un `NSHostingView` fuera de pantalla y no con
  /// `ImageRenderer`: los interruptores y los selectores de Ajustes son de
  /// AppKit, y `ImageRenderer` los reemplaza por un cartel amarillo. La vista
  /// no entra a ninguna ventana.
  @MainActor
  static func escribir<C: View>(_ vista: C, tamaño: CGSize, oscuro: Bool, como nombre: String) throws {
    let anfitrion = NSHostingView(rootView: vista.frame(width: tamaño.width).fixedSize(horizontal: false, vertical: true))
    // Oscuro: la vista suelta con apariencia oscura, que es como se ve
    // Ajustes con la ventana activa. Claro: un Mac en modo claro, con la vista
    // dentro de una ventana que nunca se muestra —sin `orderFront`, fuera de
    // toda pantalla—, porque es la ventana la que recibe el
    // `preferredColorScheme(.dark)` de Ajustes. Ahí los controles salen como
    // en una ventana de fondo: la app del render no está activa.
    var ventana: NSWindow?
    if oscuro {
      anfitrion.appearance = NSAppearance(named: .darkAqua)
    } else {
      let v = VentanaInvisible(
        contentRect: CGRect(x: -20_000, y: -20_000, width: tamaño.width, height: tamaño.height),
        styleMask: [.borderless],
        backing: .buffered,
        defer: true
      )
      v.isReleasedWhenClosed = false
      v.appearance = NSAppearance(named: .aqua)
      v.contentView = anfitrion
      ventana = v
    }
    _ = ventana
    anfitrion.frame = CGRect(origin: .zero, size: tamaño)
    anfitrion.layoutSubtreeIfNeeded()
    // El alto que el contenido pide de verdad.
    let alto = max(anfitrion.fittingSize.height, 1)
    anfitrion.frame = CGRect(origin: .zero, size: CGSize(width: tamaño.width, height: alto))
    anfitrion.layoutSubtreeIfNeeded()
    // A 2x, como una pantalla Retina: sin ventana el anfitrión dibujaría a 1x.
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(tamaño.width * 2),
      pixelsHigh: Int(alto * 2),
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
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try png.write(to: destino.appending(path: "\(nombre).png"))
    print("\(nombre).png \(Int(tamaño.width))×\(Int(alto))")
  }
}

/// Una ventana que se cree activa sin estarlo: sin esto los interruptores se
/// dibujan grises, como en una ventana de fondo. Nunca se muestra.
final class VentanaInvisible: NSWindow {
  override var isKeyWindow: Bool { true }
  override var isMainWindow: Bool { true }
  override var canBecomeKey: Bool { true }
}
