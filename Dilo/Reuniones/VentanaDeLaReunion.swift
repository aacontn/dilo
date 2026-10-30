import AppKit
import DiloReuniones
import Observation
import SwiftUI
import os

/// El panel de la reunión: **nunca toma el foco** —mirarlo no le roba el
/// teclado a Zoom—, como el panel de la barra (`.nonactivatingPanel`). La
/// única excepción es escribir «Otro nombre…»: ahí, y sólo mientras dura el
/// campo, el panel acepta el teclado sin activar Dilo.
final class VentanaDeLaReunion: NSPanel {
  /// Verdadero sólo con el campo de «Otro nombre…» abierto.
  var aceptaElTeclado = false

  init() {
    super.init(
      contentRect: NSRect(origin: .zero, size: VistaDeLaReunion.tamano),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    isMovableByWindowBackground = true
    title = String(localized: "Reunión")
    identifier = NSUserInterfaceItemIdentifier("DiloVentanaDeLaReunion")
    setAccessibilityLabel(String(localized: "Dilo, la reunión"))
  }

  override var canBecomeKey: Bool { aceptaElTeclado }
  override var canBecomeMain: Bool { false }
}

/// El primer clic sobre una ventana que no es key ya es un clic.
private final class HospedajeDeLaReunion<Contenido: View>: NSHostingView<Contenido> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Abre la ventana de la reunión y la mantiene al día: grabando, afinando
/// con su avance real, y el guion al terminar. Las ediciones —renombrar,
/// juntar, reasignar— pasan por `ControlDeReuniones` y se vuelven a leer del
/// disco: el guion es el de los archivos, no una copia en la ventana.
///
/// Cerrar la ventana no termina la reunión (contrato del notch).
@MainActor
final class ControlDeLaVentanaDeReunion {
  private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "reuniones")
  /// La preferencia de «Siempre encima». Encendida de fábrica: un panel que
  /// no activa Dilo queda detrás de la llamada al primer clic en ella.
  static let claveSiempreEncima = "diloReunionesSiempreEncima"

  let control: ControlDeReuniones
  let modelo = ModeloDeLaReunion()
  private let defaults: UserDefaults
  private var panel: VentanaDeLaReunion?
  /// La reunión a la vista.
  private var id: String?
  private var enDisco: ReunionEnDisco?
  private let reproductor = ReproductorDelGuion()
  private var observando = false

  init(control: ControlDeReuniones, defaults: UserDefaults = .standard) {
    self.control = control
    self.defaults = defaults
    modelo.siempreEncima = defaults.object(forKey: Self.claveSiempreEncima) as? Bool ?? true
    modelo.acciones = acciones
  }

  /// Muestra una reunión: la que se pide, o la que graba, o la que se afina,
  /// o la última. `linea` lleva el guion a esa línea (un resultado de la
  /// búsqueda).
  func mostrar(id pedido: String? = nil, linea: Int? = nil) {
    let elegido = pedido ?? control.enCurso?.id ?? control.pasada?.id
    if elegido != id { cambiar(a: elegido) } else { reflejar() }
    modelo.lineaResaltada = linea
    abrirElPanel()
    seguir()
    if elegido == nil {
      // Sin reunión en curso: la última, leída fuera del hilo principal.
      Task { [weak self] in
        guard let self, let ultima = await control.reunionesRecientes(maximo: 1).first else {
          self?.modelo.fase = .sinGuion
          return
        }
        cambiar(a: ultima.id)
      }
    }
  }

  private func cambiar(a nuevo: String?) {
    reproductor.parar()
    id = nuevo
    enDisco = nil
    modelo.reproduciendo = nil
    modelo.opcionesDe = nil
    modelo.escribiendoNombre = false
    modelo.confirmandoBorrar = false
    modelo.lineas = []
    modelo.reunion = nil
    modelo.fase = .cargando
    reflejar()
  }

  private func abrirElPanel() {
    let panel = self.panel ?? crearElPanel()
    self.panel = panel
    panel.level = modelo.siempreEncima ? .floating : .normal
    panel.orderFrontRegardless()
  }

  private func crearElPanel() -> VentanaDeLaReunion {
    let panel = VentanaDeLaReunion()
    let hospedaje = HospedajeDeLaReunion(rootView: VistaDeLaReunion(modelo: modelo))
    hospedaje.sizingOptions = []
    panel.contentView = hospedaje
    hospedaje.frame = NSRect(origin: .zero, size: VistaDeLaReunion.tamano)
    // Arriba a la derecha de la pantalla principal, bajo la barra; después
    // se queda donde la persona la deje.
    if !panel.setFrameUsingName("DiloVentanaDeLaReunion"), let pantalla = NSScreen.main?.visibleFrame {
      panel.setFrameTopLeftPoint(NSPoint(x: pantalla.maxX - VistaDeLaReunion.tamano.width - 16, y: pantalla.maxY - 12))
    }
    panel.setFrameAutosaveName("DiloVentanaDeLaReunion")
    return panel
  }

  func cerrar() {
    reproductor.parar()
    modelo.reproduciendo = nil
    dejarDeEscribir()
    panel?.orderOut(nil)
  }

  /// Sigue al control mientras la ventana está abierta: el paso de grabando
  /// a afinando a lista, y las marcas.
  private func seguir() {
    guard !observando else { return }
    observando = true
    withObservationTracking {
      _ = control.enCurso
      _ = control.pasada
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.observando = false
        guard self.panel?.isVisible == true else { return }
        self.reflejar()
        self.seguir()
      }
    }
  }

  private func reflejar() {
    if let enCurso = control.enCurso, enCurso.id == id || id == nil {
      id = enCurso.id
      modelo.fase = .grabando
      modelo.titulo = enCurso.titulo
      modelo.inicio = enCurso.inicio
      modelo.enVivo = ReunionEnLaMuesca(enCurso)
      return
    }
    modelo.enVivo = nil
    if let pasada = control.pasada, pasada.id == id {
      modelo.titulo = pasada.titulo
      modelo.fase = .afinando(pasada.avance)
      return
    }
    guard let id else { return }
    Task { [weak self] in await self?.recargar(id) }
  }

  /// Lee la reunión del disco y la pone en la ventana.
  private func recargar(_ id: String) async {
    guard let leida = await control.leer(id: id), self.id == id else {
      if self.id == id { modelo.fase = .sinGuion }
      return
    }
    // Si mientras leía empezó a afinarse, manda el avance.
    if control.pasada?.id == id || control.enCurso?.id == id { return }
    enDisco = leida.reunion
    let reunion = leida.reunion.reunion
    modelo.reunion = reunion
    modelo.estado = leida.reunion.estado
    modelo.titulo = reunion.titulo
    modelo.inicio = reunion.inicio
    modelo.lineas = leida.lineas
    modelo.hayAudio = ReproduccionDelGuion.hayAudio(reunion)
    modelo.fase = reunion.estado == .lista && !leida.reunion.enElRespaldo ? .lista : .sinGuion
  }

  private var acciones: ModeloDeLaReunion.Acciones {
    var a = ModeloDeLaReunion.Acciones()
    a.terminar = { [weak self] in self?.control.terminar() }
    a.cerrar = { [weak self] in self?.cerrar() }
    a.afinarDeNuevo = { [weak self] in
      guard let self, let id else { return }
      control.afinarDeNuevo(id: id)
    }
    a.renombrar = { [weak self] hablante, nombre in self?.renombrar(hablante, a: nombre) }
    a.escribirNombre = { [weak self] abrir in
      if abrir { self?.empezarAEscribir() } else { self?.dejarDeEscribir() }
    }
    a.juntar = { [weak self] origen, destino in
      self?.editar { control, id in try await control.juntar(origen, en: destino, id: id) }
    }
    a.reasignar = { [weak self] indice, destino in
      guard let self, modelo.lineas.indices.contains(indice) else { return }
      let linea = modelo.lineas[indice]
      editar { control, id in try await control.reasignar(linea, a: destino, id: id) }
    }
    a.reproducir = { [weak self] indice in self?.reproducir(indice) }
    a.copiar = { [weak self] copia in self?.copiar(copia) }
    a.copiarLinea = { [weak self] indice in
      guard let self, let reunion = modelo.reunion, modelo.lineas.indices.contains(indice) else { return }
      alPortapapeles(LineasDelGuion.texto(de: modelo.lineas[indice], reunion: reunion))
    }
    a.mostrarEnFinder = { [weak self] in
      guard let carpeta = self?.enDisco?.carpeta else { return }
      NSWorkspace.shared.activateFileViewerSelecting([carpeta])
    }
    a.borrar = { [weak self] in self?.borrar() }
    a.fijarSiempreEncima = { [weak self] encima in
      guard let self else { return }
      modelo.siempreEncima = encima
      defaults.set(encima, forKey: Self.claveSiempreEncima)
      panel?.level = encima ? .floating : .normal
    }
    return a
  }

  private func renombrar(_ hablante: String, a nombre: String?) {
    dejarDeEscribir()
    modelo.opcionesDe = nil
    editar { control, id in try await control.renombrar(hablante: hablante, a: nombre, en: id) }
  }

  private func editar(_ cambio: @escaping (ControlDeReuniones, String) async throws -> Void) {
    guard let id else { return }
    Task { [weak self] in
      guard let self else { return }
      do {
        try await cambio(control, id)
      } catch {
        Self.logger.error("No se pudo editar el guion: \(error.localizedDescription, privacy: .public)")
      }
      await recargar(id)
    }
  }

  private func empezarAEscribir() {
    modelo.nombreEscrito = ""
    modelo.escribiendoNombre = true
    panel?.aceptaElTeclado = true
    panel?.makeKey()
  }

  private func dejarDeEscribir() {
    modelo.escribiendoNombre = false
    panel?.aceptaElTeclado = false
    panel?.resignKey()
  }

  private func reproducir(_ indice: Int) {
    guard let enDisco, modelo.lineas.indices.contains(indice) else { return }
    if modelo.reproduciendo == indice, reproductor.sonando {
      reproductor.parar()
      modelo.reproduciendo = nil
      return
    }
    modelo.reproduciendo = reproductor.reproducir(enDisco, desde: modelo.lineas[indice].desde) ? indice : nil
  }

  private func copiar(_ copia: ModeloDeLaReunion.Copia) {
    guard let reunion = modelo.reunion else { return }
    let texto = copia == .texto
      ? GuionParaCopiar.texto(reunion: reunion, lineas: modelo.lineas)
      : GuionParaCopiar.paraClaude(reunion: reunion, lineas: modelo.lineas)
    alPortapapeles(texto)
    modelo.copiado = copia
    Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(1_200))
      if self?.modelo.copiado == copia { self?.modelo.copiado = nil }
    }
  }

  private func alPortapapeles(_ texto: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(texto, forType: .string)
  }

  private func borrar() {
    guard let id else { return }
    modelo.confirmandoBorrar = false
    Task { [weak self] in
      guard let self else { return }
      do {
        try await control.borrar(id: id)
        cerrar()
        self.id = nil
      } catch {
        Self.logger.error("No se pudo mandar la reunión a la Papelera: \(error.localizedDescription, privacy: .public)")
      }
    }
  }
}
