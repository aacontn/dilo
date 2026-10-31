import AppKit
import DiloReuniones
import Observation
import SwiftUI
import os

/// El panel de la reunión: **nunca toma el foco** —mirarlo no le roba el
/// teclado a Zoom—, como el panel de la barra (`.nonactivatingPanel`). La
/// excepción es escribir una nota u «Otro nombre…»: ahí, y sólo mientras dura
/// el campo, el panel acepta el teclado sin activar Dilo; la app de la reunión
/// sigue siendo la activa.
final class VentanaDeLaReunion: NSPanel {
  /// Verdadero sólo con un campo abierto.
  var aceptaElTeclado = false
  /// Un clic en otra app le quitó el teclado.
  var alPerderElTeclado: (() -> Void)?

  init() {
    super.init(
      contentRect: NSRect(origin: .zero, size: VistaDeLaReunion.tamano),
      styleMask: [.borderless, .nonactivatingPanel, .resizable],
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
    minSize = VistaDeLaReunion.tamanoMinimo
    title = String(localized: "Reunión")
    identifier = NSUserInterfaceItemIdentifier("DiloVentanaDeLaReunion")
    setAccessibilityLabel(String(localized: "Dilo, la reunión"))
  }

  override var canBecomeKey: Bool { aceptaElTeclado }
  override var canBecomeMain: Bool { false }

  override func resignKey() {
    super.resignKey()
    alPerderElTeclado?()
  }

  /// Dilo no tiene menú Edición, que es donde macOS busca ⌘V: sin esto, en el
  /// campo no se puede pegar, y el dictado pega con ⌘V.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let teclas: [String: Selector] = [
      "v": #selector(NSText.paste(_:)), "c": #selector(NSText.copy(_:)), "x": #selector(NSText.cut(_:)),
      "a": #selector(NSText.selectAll(_:)),
    ]
    if aceptaElTeclado, event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
      let accion = event.charactersIgnoringModifiers.flatMap({ teclas[$0] }), firstResponder?.tryToPerform(accion, with: self) == true
    {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}

/// El primer clic sobre una ventana que no es key ya es un clic.
private final class HospedajeDeLaReunion<Contenido: View>: NSHostingView<Contenido> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Abre la ventana de la reunión y la mantiene al día: lo que se va diciendo
/// y tus notas mientras graba, afinando con su avance real, y el guion al
/// terminar. Las ediciones —renombrar,
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
    control.antesDeTerminar = { [weak self] in self?.guardarLaNota() }
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
    soltarElTeclado()
    modelo.confirmandoBorrar = false
    modelo.notaEscrita = ""
    modelo.notas = []
    modelo.elementosEnVivo = []
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
    hospedaje.autoresizingMask = [.width, .height]
    panel.contentView = hospedaje
    hospedaje.frame = NSRect(origin: .zero, size: VistaDeLaReunion.tamano)
    panel.alPerderElTeclado = { [weak self] in self?.soltarElTeclado() }
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
    soltarElTeclado()
    panel?.orderOut(nil)
  }

  /// Sigue al control mientras la ventana está abierta: el paso de grabando
  /// a afinando a lista, las marcas, lo que se va diciendo y las notas. Con
  /// la ventana cerrada no cuesta nada: al abrirla se lee lo que haya.
  private func seguir() {
    guard !observando else { return }
    observando = true
    withObservationTracking {
      _ = control.enCurso
      _ = control.pasada
      _ = control.vivo
      _ = control.notas
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
      modelo.faltaElPermisoDelAudio = enCurso.ellos.vigia == .sinAudio && enCurso.ellos.pareceFaltarPermiso
      reflejarLoEnVivo()
      return
    }
    modelo.enVivo = nil
    modelo.faltaElPermisoDelAudio = false
    if let pasada = control.pasada, pasada.id == id {
      modelo.titulo = pasada.titulo
      modelo.fase = .afinando(pasada.avance)
      reflejarLoEnVivo()
      return
    }
    guard let id else { return }
    Task { [weak self] in await self?.recargar(id) }
  }

  private func reflejarLoEnVivo() {
    guard control.idDelVivo == id else { return }
    modelo.notas = control.notas
    modelo.sinMotorEnVivo = control.vivo.sinMotor
    modelo.elementosEnVivo = ElementoEnVivo.armar(lineas: control.vivo.lineas, notas: control.notas)
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
    modelo.notas = leida.notas
    modelo.elementosEnVivo = []
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
      guard let self else { return }
      if abrir {
        modelo.nombreEscrito = ""
        modelo.escribiendoNombre = true
        tomarElTeclado()
      } else {
        soltarElTeclado()
      }
    }
    a.escribirNota = { [weak self] abrir in
      guard let self else { return }
      if abrir {
        modelo.escribiendoNota = true
        tomarElTeclado()
      } else {
        soltarElTeclado()
      }
    }
    a.guardarNota = { [weak self] in self?.guardarLaNota() }
    a.abrirElPermiso = {
      guard let url = URL(string: ControlDeReuniones.panelDelAudioDelSistema) else { return }
      NSWorkspace.shared.open(url)
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
    soltarElTeclado()
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

  /// Guarda lo escrito y devuelve el teclado: se escribe una nota sin dejar
  /// de estar en la llamada.
  private func guardarLaNota() {
    if control.anotar(modelo.notaEscrita) { modelo.notaEscrita = "" }
    soltarElTeclado()
  }

  private func tomarElTeclado() {
    panel?.aceptaElTeclado = true
    panel?.makeKey()
  }

  private func soltarElTeclado() {
    modelo.escribiendoNombre = false
    modelo.escribiendoNota = false
    guard let panel, panel.aceptaElTeclado else { return }
    panel.aceptaElTeclado = false
    // `resignKey` sólo avisa: quien vuelve a tener el teclado es la app activa,
    // y eso pasa cuando la ventana key deja de estar en pantalla.
    if panel.isKeyWindow {
      panel.orderOut(nil)
      panel.orderFrontRegardless()
    }
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
      ? GuionParaCopiar.texto(reunion: reunion, lineas: modelo.lineas, notas: modelo.notas)
      : GuionParaCopiar.paraClaude(reunion: reunion, lineas: modelo.lineas, notas: modelo.notas)
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
