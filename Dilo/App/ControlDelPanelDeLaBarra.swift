import AppKit
import Observation
import SwiftUI

/// La ventana del panel de la barra: sin marco, transparente —el vidrio lo
/// dibuja SwiftUI y la sombra la calcula AppKit con su forma—, sobre todo y
/// en todos los espacios, también sobre una app en pantalla completa.
///
/// **Nunca toma el teclado ni activa a Dilo.** Es lo que hacía bien el menú
/// gris y lo que el panel no puede perder: «Empezar a dictar» y «Leer lo
/// seleccionado» trabajan sobre el campo con foco de **otra** app, y una
/// ventana de Dilo que se vuelve key se lo quitaría justo antes. Switchboard
/// deja que su panel tome el teclado después de un clic adentro; su burbuja
/// de aprobar no lo toma nunca, y ése es el trato que sirve acá. Sin teclado
/// no hay Tab ni ⌘Q dentro del panel; VoiceOver sí lo recorre.
///
/// Técnica observada en Switchboard (`BarFloatingPanel`, `BubblePanel`):
/// nivel `.floating` y no `.statusBar`, para seguir encima del trabajo y al
/// alcance de Accesibilidad. Implementación propia.
@MainActor
final class VentanaDelPanelDeLaBarra: NSPanel {
  init() {
    super.init(
      contentRect: NSRect(origin: .zero, size: NSSize(width: VistaDelPanelDeLaBarra.ancho, height: 360)),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    isMovable = false
    isMovableByWindowBackground = false
    animationBehavior = .none
    title = "Dilo"
    identifier = NSUserInterfaceItemIdentifier("DiloPanelDeLaBarra")
    setAccessibilityLabel(String(localized: "Dilo, panel de la barra"))
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// La vista de hospedaje: el primer clic sobre una ventana que no es key ya
/// es un clic. Sin esto, con el panel encima de otra app, el primer botón
/// apretado sólo «despertaría» la ventana.
private final class HospedajeDelPanel<Contenido: View>: NSHostingView<Contenido> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Lo que el panel muestra ahora. Lo pone al día `StatusItemController`.
@MainActor
@Observable
final class EstadoDelPanelDeLaBarra {
  var entrada = PanelDeLaBarra.Entrada()
  var copiado: PanelDeLaBarra.Accion.Copia?
  var material: VistaDelPanelDeLaBarra.Material = .vidrio
  /// Sube cada vez que el panel aparece: vuelve a correr la entrada.
  var apariciones = 0
}

/// El panel con su entrada animada: aparece desde arriba, un poco más chico,
/// como un menú de macOS 26. Con «Reducir movimiento», sólo se funde.
private struct RaizDelPanelDeLaBarra: View {
  @Environment(\.accessibilityReduceMotion) private var reducirMovimiento
  let estado: EstadoDelPanelDeLaBarra
  let marca: NSImage?
  let alElegir: (PanelDeLaBarra.Accion) -> Void
  let alMedir: (CGSize) -> Void
  @State private var aparecio = false

  var body: some View {
    VistaDelPanelDeLaBarra(
      contenido: PanelDeLaBarra.contenido(estado.entrada),
      copiado: estado.copiado,
      marca: marca,
      material: estado.material,
      alElegir: alElegir
    )
    .fixedSize(horizontal: false, vertical: true)
    .onGeometryChange(for: CGSize.self) { $0.size } action: { alMedir($0) }
    .scaleEffect(aparecio || reducirMovimiento ? 1 : 0.96, anchor: .top)
    .opacity(aparecio ? 1 : 0)
    .frame(maxHeight: .infinity, alignment: .top)
    .onAppear(perform: entrar)
    .onChange(of: estado.apariciones) { entrar() }
  }

  private func entrar() {
    aparecio = false
    withAnimation(reducirMovimiento ? .easeOut(duration: 0.1) : .spring(response: 0.24, dampingFraction: 0.88)) {
      aparecio = true
    }
  }
}

/// **El panel del clic derecho** en el ícono de la barra (2026-10-15):
/// reemplaza al `NSMenu` gris. Su contenido es `PanelDeLaBarra` (probado sin
/// dibujar), su vista `VistaDelPanelDeLaBarra` y su ventana
/// `VentanaDelPanelDeLaBarra`.
///
/// **Se cierra como un menú**: con un clic afuera —en otra app o en otra
/// ventana de Dilo—, con Escape, al elegir algo, o con otro clic en lo que
/// lo abrió. Un clic sobre el ancla no lo cierra desde el monitor: lo maneja
/// el ícono (o la muesca), que alterna; si no, el monitor lo cerraría y el
/// mismo clic lo volvería a abrir.
///
/// Técnica observada en Switchboard (`BarPanelController`: monitores global y
/// local de clics, el ancla que se respeta, el alto que sigue al contenido);
/// implementación propia.
@MainActor
final class ControlDelPanelDeLaBarra {
  let estado = EstadoDelPanelDeLaBarra()
  /// Lo que el panel pide hacer. Lo cablea `StatusItemController`.
  var alElegir: (PanelDeLaBarra.Accion) -> Void = { _ in }
  /// El panel se abrió o se cerró: el ícono se resalta mientras está abierto.
  var alCambiarLaVisibilidad: (Bool) -> Void = { _ in }

  private let marca: NSImage?
  private var ventana: VentanaDelPanelDeLaBarra?
  /// De dónde cuelga ahora: el ícono o la muesca, en coordenadas de pantalla.
  private var ancla: (rect: CGRect, pantalla: CGRect, centrado: Bool)?
  private var alto: CGFloat = 360
  private var monitores: [Any] = []
  private var cierreDiferido: Task<Void, Never>?

  init(marca: NSImage?) {
    self.marca = marca
  }

  var estaAbierto: Bool { ventana?.isVisible == true }

  /// Abre o cierra, según cómo esté: lo que hace un segundo clic.
  func alternar(colgandoDe ancla: CGRect, en pantalla: CGRect, centrado: Bool = false) {
    if estaAbierto {
      cerrar()
    } else {
      abrir(colgandoDe: ancla, en: pantalla, centrado: centrado)
    }
  }

  func abrir(colgandoDe ancla: CGRect, en pantalla: CGRect, centrado: Bool = false) {
    cierreDiferido?.cancel()
    estado.copiado = nil
    self.ancla = (ancla, pantalla, centrado)
    let ventana = ventana ?? armarLaVentana()
    ubicar(ventana)
    estado.apariciones += 1
    // Sin activar la app ni tomar el teclado.
    ventana.orderFrontRegardless()
    instalarMonitores()
    alCambiarLaVisibilidad(true)
  }

  func cerrar() {
    cierreDiferido?.cancel()
    cierreDiferido = nil
    quitarMonitores()
    guard let ventana, ventana.isVisible else { return }
    ventana.orderOut(nil)
    alCambiarLaVisibilidad(false)
  }

  /// Lo que se eligió adentro: según la acción, cierra antes de hacerla, se
  /// queda, o muestra el ✓ y se va (`PanelDeLaBarra.Accion.cierre`).
  private func elegir(_ accion: PanelDeLaBarra.Accion) {
    switch accion.cierre {
    case .alTiro:
      // Primero se va el panel, y después lo pedido: un dictado que empieza
      // con el panel encima tapa la muesca, y Ajustes se abriría detrás.
      cerrar()
      alElegir(accion)
    case .seQueda:
      alElegir(accion)
    case .trasElAcuse:
      alElegir(accion)
      if case let .copiar(copia) = accion { estado.copiado = copia }
      cierreDiferido?.cancel()
      cierreDiferido = Task { @MainActor [weak self] in
        try? await Task.sleep(for: PanelDeLaBarra.duracionDelAcuse)
        guard !Task.isCancelled else { return }
        self?.cerrar()
      }
    }
  }

  private func armarLaVentana() -> VentanaDelPanelDeLaBarra {
    let ventana = VentanaDelPanelDeLaBarra()
    let raiz = RaizDelPanelDeLaBarra(
      estado: estado,
      marca: marca,
      alElegir: { [weak self] accion in self?.elegir(accion) },
      alMedir: { [weak self] tamaño in self?.medido(tamaño) }
    )
    let hospedaje = HospedajeDelPanel(rootView: raiz)
    // El tamaño de la ventana lo pone este controlador con lo que mide la
    // vista; si el hospedaje también lo empujara, pelearían al animar.
    hospedaje.sizingOptions = []
    ventana.contentView = hospedaje
    alto = max(hospedaje.fittingSize.height, 60)
    self.ventana = ventana
    return ventana
  }

  /// El contenido cambió de alto —llegó un dictado, se fue la toma—: la
  /// ventana lo sigue sin moverse de arriba.
  private func medido(_ tamaño: CGSize) {
    guard tamaño.height > 0, abs(tamaño.height - alto) > 0.5 else { return }
    alto = ceil(tamaño.height)
    if let ventana { ubicar(ventana) }
  }

  private func ubicar(_ ventana: VentanaDelPanelDeLaBarra) {
    guard let ancla else { return }
    let tamaño = CGSize(
      width: VistaDelPanelDeLaBarra.ancho,
      height: min(alto, ancla.pantalla.height - 40)
    )
    let marco = PanelDeLaBarra.marco(
      tamaño: tamaño,
      ancla: ancla.rect,
      pantalla: ancla.pantalla,
      centrado: ancla.centrado
    )
    ventana.setFrame(marco, display: ventana.isVisible)
    ventana.invalidateShadow()
  }

  /// Un clic afuera lo cierra, como un menú, y Escape también.
  ///
  /// El global ve los clics que van a otras apps; el local, los de las
  /// ventanas de Dilo —la muesca, Ajustes, el propio ícono—. El clic en el
  /// ancla se deja pasar: lo maneja quien abrió, que alterna.
  ///
  /// **Escape no se traga**: el panel no toma el teclado, así que la tecla
  /// también le llega a la app de adelante. Un monitor que la consumiera
  /// tendría que vivir en el tap de eventos del dictado, y eso es mucho
  /// aparato para cerrar un panel que también se cierra con un clic.
  private func instalarMonitores() {
    quitarMonitores()
    let clics: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    if let global = NSEvent.addGlobalMonitorForEvents(matching: clics, handler: { [weak self] _ in
      MainActor.assumeIsolated { self?.cerrar() }
    }) {
      monitores.append(global)
    }
    if let local = NSEvent.addLocalMonitorForEvents(matching: clics, handler: { [weak self] evento in
      MainActor.assumeIsolated {
        guard let self, let ventana = self.ventana else { return }
        let enElAncla = self.ancla?.rect.contains(NSEvent.mouseLocation) ?? false
        if evento.window !== ventana, !enElAncla { self.cerrar() }
      }
      return evento
    }) {
      monitores.append(local)
    }
    let escape: UInt16 = 53
    if let teclado = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] evento in
      guard evento.keyCode == escape else { return }
      MainActor.assumeIsolated { self?.cerrar() }
    }) {
      monitores.append(teclado)
    }
  }

  private func quitarMonitores() {
    monitores.forEach(NSEvent.removeMonitor)
    monitores.removeAll()
  }
}
