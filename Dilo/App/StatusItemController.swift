import AppKit
import DiloCapabilities
import DiloModes

/// El ícono de Dilo en la barra de menús.
///
/// **Clic izquierdo abre la app; clic derecho (o ⌃clic), el panel de la
/// barra** (Alfonso, 2026-10-15: «con botón izquierdo que abra la app de
/// Dilo, con botón derecho alguna ventana como la de ahora pero que sea
/// linda, así como la de Switchboard»). Hasta la 0.4.8 cualquier clic abría
/// un `NSMenu` gris; el panel (`ControlDelPanelDeLaBarra`) ofrece todo lo que
/// ofrecía, con jerarquía, y el modo del atajo general. Qué hace cada clic lo
/// decide `ClicEnLaBarra`, puro.
///
/// Mientras se dicta el ícono sigue latiendo, y mientras se transcribe un
/// archivo se llena como una batería: eso no cambió.
@MainActor
final class StatusItemController: NSObject {
  private let statusItem: NSStatusItem
  private let toggleDictation: () -> Void
  private let toggleReadAloud: () -> Void
  private let transcribeFile: () -> Void
  private let openSettings: () -> Void
  private let openOnboarding: () -> Void
  private let openNovedades: () -> Void
  private let checkForUpdates: () -> Void
  private var ultimoDictado: UltimoDictado?
  /// Reintentar o botar la toma que quedó en RAM cuando un dictado no sacó
  /// texto. Las cablea `AppDelegate`.
  let tomaFallida = EntradasDeTomaFallida()
  /// Empieza una nota rápida que termina en Apple Notas. Lo cablea
  /// `AppDelegate`; sin él la fila no hace nada.
  var dictarNota: (() -> Void)?
  /// Los modos que el panel ofrece y cuál usa el atajo general. Lo cablea
  /// `AppDelegate`, que es quien tiene los ajustes; se lee cada vez que el
  /// panel se abre, así que un modo nuevo aparece sin avisar a nadie.
  var leerModos: () -> (modos: [PanelDeLaBarra.Modo], elegido: String?) = { ([], nil) }
  /// Deja puesto el modo del atajo general (nil, el dictado normal).
  var alElegirModo: ((String?) -> Void)?
  /// El panel se abrió o se cerró. Lo escucha la muesca, que mientras tanto
  /// no abre su propio panel encima (`HUDStage.panelDeLaBarraAbierto`).
  var alCambiarElPanel: ((Bool) -> Void)?
  /// Si el panel lleva vidrio: el mismo interruptor «Panel con vidrio» que
  /// el panel de la muesca.
  var leerVidrio: () -> Bool = { true }
  /// Deja un texto en el portapapeles. Es una costura para poder afirmar en
  /// un test qué se copió sin tocar el portapapeles de verdad.
  var copiarAlPortapapeles: (String) -> Void = { texto in
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(texto, forType: .string)
  }
  /// El panel del clic derecho, y lo que necesita saber para dibujarse.
  private let panel: ControlDelPanelDeLaBarra
  private var entrada = PanelDeLaBarra.Entrada(
    admiteNota: Anfitrion.actual.admite(.notasDeApple),
    // Leer en voz alta es releer la selección de otra app, y eso el sandbox
    // no lo da. Lo que no se puede hacer se esconde.
    admiteLeer: Anfitrion.actual.admite(.relecturaDelFoco)
  )
  /// Si el panel abierto cuelga del ícono —y no de la muesca—: sólo entonces
  /// el ícono se resalta.
  private var panelDesdeElIcono = false
  private var blinkTimer: Timer?
  private var blinkDimmed = false
  private let templateIcon = NSImage(named: "MenuBarIcon")
  /// Pre-tinted session icons. NSStatusBarButton renders custom
  /// contentTintColor values as black (FB8530353), so palette tinting
  /// swaps in non-template images instead.
  private var sessionIcons: (full: NSImage, dim: NSImage)?
  /// Remembered so a dictation session that interrupts a running file job can
  /// hand the ghost back to it afterwards.
  private var transcriptionProgress: Double?
  private var transcriptionAccent = SettingsTheme.accentColor

  init(
    toggleDictation: @escaping () -> Void,
    toggleReadAloud: @escaping () -> Void,
    transcribeFile: @escaping () -> Void,
    openSettings: @escaping () -> Void,
    openOnboarding: @escaping () -> Void,
    openNovedades: @escaping () -> Void,
    checkForUpdates: @escaping () -> Void
  ) {
    self.toggleDictation = toggleDictation
    self.toggleReadAloud = toggleReadAloud
    self.transcribeFile = transcribeFile
    self.openSettings = openSettings
    self.openOnboarding = openOnboarding
    self.openNovedades = openNovedades
    self.checkForUpdates = checkForUpdates
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    panel = ControlDelPanelDeLaBarra(marca: NSImage(named: "MenuBarIcon"))
    super.init()

    if let button = statusItem.button {
      button.image = templateIcon
      button.image?.accessibilityDescription = "Dilo"
      button.imagePosition = .imageOnly
      // Sin `menu`: con un menú puesto, AppKit lo abre en cualquier clic y
      // la acción nunca llega. Los dos botones llegan como acción, al
      // soltar, y `ClicEnLaBarra` decide.
      button.target = self
      button.action = #selector(clicEnElIcono)
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
      button.setAccessibilityLabel(String(localized: "Dilo"))
      button.setAccessibilityHelp(String(localized: "Clic: abre Dilo. Clic derecho: el panel con las acciones."))
    }

    panel.alElegir = { [weak self] accion in self?.hacer(accion) }
    // El ícono se queda resaltado mientras el panel cuelga de él, como con
    // el menú gris.
    panel.alCambiarLaVisibilidad = { [weak self] abierto in
      guard let self else { return }
      self.statusItem.button?.highlight(abierto && self.panelDesdeElIcono)
      self.alCambiarElPanel?(abierto)
    }
    tomaFallida.alCambiar = { [weak self] reloj in
      self?.entrada.tomaGuardada = reloj
      self?.refrescarElPanel()
    }
  }

  @objc private func clicEnElIcono(_ sender: NSStatusBarButton) {
    // Sólo cuenta como clic un evento de mouse sobre este botón y de ahora:
    // apretado por Accesibilidad no hay evento propio, y `currentEvent`
    // puede ser uno viejo de otra ventana.
    let evento = NSApp.currentEvent.flatMap { evento in
      evento.window === sender.window
        && ProcessInfo.processInfo.systemUptime - evento.timestamp < 1 ? evento : nil
    }
    let boton: ClicEnLaBarra.Boton =
      switch evento?.type {
      case .leftMouseUp, .leftMouseDown: .izquierdo
      case .rightMouseUp, .rightMouseDown: .derecho
      default: .otro
      }
    let conControl = evento?.modifierFlags.contains(.control) ?? false
    switch ClicEnLaBarra.decidir(boton: boton, conControl: conControl) {
    case .abrirDilo:
      panel.cerrar()
      openSettings()
    case .abrirPanel:
      guard let ancla = anclaDelIcono else { return }
      prepararLaEntrada()
      panelDesdeElIcono = true
      panel.alternar(colgandoDe: ancla.icono, en: ancla.pantalla)
    }
  }

  /// El marco del ícono y el de su pantalla, en coordenadas de pantalla: de
  /// ahí cuelga el panel.
  private var anclaDelIcono: (icono: CGRect, pantalla: CGRect)? {
    guard let button = statusItem.button, let window = button.window,
      let pantalla = window.screen ?? NSScreen.main
    else { return nil }
    let icono = window.convertToScreen(button.convert(button.bounds, to: nil))
    return (icono, pantalla.frame)
  }

  /// Abre el panel bajo la muesca, que es donde la persona acaba de hacer
  /// clic. **Es el mismo panel del ícono, no una copia**: dos listas con las
  /// mismas acciones se desincronizan al primer ítem que alguien agrega a una
  /// sola. Un segundo clic en la muesca lo cierra.
  func mostrarAcciones(bajo silueta: CGRect) {
    let pantalla = NSScreen.screens.first { $0.frame.intersects(silueta) } ?? NSScreen.main
    guard let pantalla else { return }
    prepararLaEntrada()
    panelDesdeElIcono = false
    panel.alternar(colgandoDe: silueta, en: pantalla.frame, centrado: true)
  }

  /// Copia lo último dictado sin pasar por el panel, para el clic sobre el
  /// resultado en el notch.
  func copiarLoUltimo() {
    guard let ultimoDictado else { return }
    copiarAlPortapapeles(ultimoDictado.texto(.entregado))
  }

  /// Lo que se lee al abrir y no se empuja: los modos, el vidrio y la hora,
  /// para el «hace 2 min».
  private func prepararLaEntrada() {
    let modos = leerModos()
    entrada.modos = modos.modos
    entrada.modoElegido = modos.elegido
    entrada.ahora = Date()
    panel.estado.material = leerVidrio() ? .vidrio : .negro
    panel.estado.entrada = entrada
  }

  /// Con el panel abierto, lo que cambia se ve: el estado del encabezado, un
  /// dictado que llega, la toma que se va.
  private func refrescarElPanel() {
    guard panel.estaAbierto else { return }
    entrada.ahora = Date()
    panel.estado.entrada = entrada
  }

  /// Lo que pidió el panel. El panel ya decidió si cerrarse
  /// (`PanelDeLaBarra.Accion.cierre`).
  private func hacer(_ accion: PanelDeLaBarra.Accion) {
    switch accion {
    case .abrirDilo: openSettings()
    case .dictar: toggleDictation()
    case .dictarNota: dictarNota?()
    case .leerSeleccion: toggleReadAloud()
    case .transcribirArchivo: transcribeFile()
    case let .copiar(copia): copiar(copia)
    case .reintentarToma: tomaFallida.reintentar?()
    case .descartarToma: tomaFallida.descartar?()
    case let .elegirModo(id):
      alElegirModo?(id)
      entrada.modoElegido = id
      refrescarElPanel()
    case .primerosPasos: openOnboarding()
    case .novedades: openNovedades()
    case .buscarActualizaciones: checkForUpdates()
    case .salir: NSApp.terminate(nil)
    }
  }

  private func copiar(_ copia: PanelDeLaBarra.Accion.Copia) {
    guard let ultimoDictado else { return }
    switch copia {
    case .entregado: copiarAlPortapapeles(ultimoDictado.texto(.entregado))
    case .original: copiarAlPortapapeles(ultimoDictado.texto(.original))
    case .propuesta:
      guard ultimoDictado.tienePropuesta else { return }
      copiarAlPortapapeles(ultimoDictado.texto(.propuesta))
    }
  }

  /// Mirrors the session state on the shell: the ghost pulses between
  /// full and dimmed tint while recording, and the panel says so.
  /// An Edge Glow session passes its palette accent so the pulse speaks
  /// the session's color; nil keeps the theme tint.
  func setRecording(_ isRecording: Bool, accent: NSColor? = nil) {
    entrada.dictando = isRecording
    refrescarElPanel()
    sessionIcons = isRecording ? accent.flatMap(makeSessionIcons) : nil
    if isRecording {
      startBlinking()
    } else {
      stopBlinking()
    }
  }

  /// Las teclas, para que el panel las diga; el tap de eventos hace el
  /// trabajo, esto sólo las muestra.
  func setKeyBindings(trigger: KeyBinding, readAloud: KeyBinding) {
    entrada.atajoDeDictar = trigger.label
    entrada.atajoDeLeer = readAloud.label
    refrescarElPanel()
  }

  private func startBlinking() {
    guard blinkTimer == nil else { return }
    if let sessionIcons {
      statusItem.button?.image = sessionIcons.full
    }
    blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.blinkDimmed.toggle()
        if let icons = self.sessionIcons {
          self.statusItem.button?.image = self.blinkDimmed ? icons.dim : icons.full
        } else {
          self.statusItem.button?.contentTintColor =
            self.blinkDimmed ? .tertiaryLabelColor : .labelColor
        }
      }
    }
  }

  private func stopBlinking() {
    blinkTimer?.invalidate()
    blinkTimer = nil
    blinkDimmed = false
    statusItem.button?.contentTintColor = nil
    statusItem.button?.image = templateIcon
    // A file job can outlast the dictation that interrupted it, so the ghost
    // goes back to reporting it rather than to idle.
    if let transcriptionProgress {
      setTranscriptionProgress(transcriptionProgress, accent: transcriptionAccent)
    }
  }

  /// Renders the template ghost filled with the accent, full and dimmed;
  /// the results are plain images the status bar shows as-is.
  private func makeSessionIcons(for accent: NSColor) -> (full: NSImage, dim: NSImage)? {
    guard let templateIcon else { return nil }
    let full = NSImage(size: templateIcon.size, flipped: false) { rect in
      templateIcon.draw(in: rect)
      accent.set()
      rect.fill(using: .sourceAtop)
      return true
    }
    let dim = NSImage(size: templateIcon.size, flipped: false) { rect in
      full.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.4)
      return true
    }
    full.isTemplate = false
    dim.isTemplate = false
    return (full, dim)
  }

  /// A Drop Transcription's progress, 0…1, or nil once it ends.
  ///
  /// The ghost fills from the bottom like a battery rather than growing a ring
  /// or a bar: it reads at 16 points, needs no extra chrome, and it is the
  /// app's own mark doing the work. A dictation session outranks it — the
  /// pulse is the more urgent thing to say.
  ///
  /// `accent` is the same colour the HUD's drop surfaces wear, so a glow
  /// palette shows in the menu bar too.
  func setTranscriptionProgress(_ fraction: Double?, accent: NSColor) {
    transcriptionProgress = fraction
    transcriptionAccent = accent
    entrada.progresoDeArchivo = fraction
    refrescarElPanel()
    guard blinkTimer == nil else { return }
    if let fraction {
      statusItem.button?.contentTintColor = nil
      statusItem.button?.image = makeProgressIcon(fraction: fraction, accent: accent) ?? templateIcon
    } else {
      statusItem.button?.image = templateIcon
    }
  }

  private func makeProgressIcon(fraction: Double, accent: NSColor) -> NSImage? {
    guard let templateIcon else { return nil }
    return Self.progressIcon(from: templateIcon, fraction: fraction, accent: accent)
  }

  /// The ghost drawn twice in the accent: faint for the whole silhouette, solid
  /// for the filled part, split at the progress line.
  ///
  /// Not a template image — a template is recoloured by the menu bar and would
  /// come back white, which is the whole thing this replaces. Drawing the
  /// unfilled part in the same colour at low alpha keeps it legible in either
  /// menu bar theme.
  static func progressIcon(
    from templateIcon: NSImage,
    fraction: Double,
    accent: NSColor = SettingsTheme.accentColor
  ) -> NSImage {
    let clamped = min(max(fraction, 0), 1)
    let icon = NSImage(size: templateIcon.size, flipped: false) { rect in
      // The unfilled part is the accent at low opacity, not the artwork with
      // a wash of accent over it: `sourceAtop` with an opaque colour replaces
      // the colour and keeps the alpha, so the whole silhouette is one hue and
      // only its weight changes at the progress line.
      templateIcon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.32)
      accent.set()
      rect.fill(using: .sourceAtop)

      let filled = NSRect(
        x: rect.minX,
        y: rect.minY,
        width: rect.width,
        height: rect.height * clamped
      )
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(rect: filled).setClip()
      templateIcon.draw(in: rect)
      accent.set()
      rect.fill(using: .sourceAtop)
      NSGraphicsContext.restoreGraphicsState()
      return true
    }
    icon.isTemplate = false
    return icon
  }

  /// La lectura en voz alta, en el panel: «Dejar de leer» mientras suena.
  func setSpeaking(_ isSpeaking: Bool) {
    entrada.leyendo = isSpeaking
    refrescarElPanel()
  }

  /// Lo último que se dictó, o nil para que el panel no ofrezca copiar.
  ///
  /// Lo dicho sin el modo y lo que el modo propuso sólo aparecen cuando son
  /// otra cosa que lo entregado: dos filas que copian el mismo texto es
  /// ruido (`PanelDeLaBarra.contenido`).
  func setUltimoDictado(_ dictado: UltimoDictado?) {
    ultimoDictado = dictado
    entrada.ultimo = dictado.map {
      PanelDeLaBarra.Ultimo(
        entregado: $0.texto(.entregado),
        original: $0.texto(.original),
        propuesta: $0.tienePropuesta ? $0.texto(.propuesta) : nil,
        modo: $0.modo,
        cuando: $0.cuando
      )
    }
    refrescarElPanel()
  }
}
