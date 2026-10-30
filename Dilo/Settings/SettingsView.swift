import DiloModes
import SwiftUI

/// The fixed Settings surface: header, sidebar navigation, and the selected
/// section's scrolling pane. Preferences persist through AppSettings, active
/// sessions keep their snapshot, and Insights reads aggregate usage.
///
/// Desde el 2026-10-19 (Alfonso: «está muy simple y básica y no se condice
/// con todas las funciones»): vidrio ahumado como la muesca, barra lateral
/// con íconos de color por familia, búsqueda de ajustes con ⌘F que lleva a
/// la fila (`IndiceDeAjustes`), y la ventana recuerda dónde quedó
/// (`SeccionAlAbrir`). Lo que vivía escondido en desplegables —idiomas,
/// sonidos, leer en voz alta, actividad— ahora está a la vista en su
/// sección, con un rótulo.
struct SettingsView: View {
  static let tamano = CGSize(width: 900, height: 640)

  @Bindable var settings: AppSettings
  let sounds: HUDSounds
  let runtimeState: SettingsRuntimeState
  let usageTracker: UsageTracker
  let updater: SparkleUpdaterService
  let launchAtLogin: LaunchAtLoginService
  let onClose: () -> Void

  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var selectedSection: SettingsSection
  @State private var busqueda: String
  /// La fila a la que hay que llegar después de cambiar de sección.
  @State private var filaAEnfocar: AjusteID?
  /// La fila que se ilumina un momento al llegar.
  @State private var resaltado: AjusteID?
  @FocusState private var buscando: Bool
  /// Para los renders de la sección entera: una ventana más alta que la de
  /// verdad, para que el `ScrollView` muestre todo.
  private let alto: CGFloat?

  /// - Parameters:
  ///   - seccionInicial: para los renders; en la app la elige
  ///     `SeccionAlAbrir` y llega por `runtimeState.seccionPedida`.
  ///   - busquedaInicial: para los renders: la búsqueda abierta.
  init(
    settings: AppSettings,
    sounds: HUDSounds,
    runtimeState: SettingsRuntimeState,
    usageTracker: UsageTracker,
    updater: SparkleUpdaterService,
    launchAtLogin: LaunchAtLoginService,
    onClose: @escaping () -> Void,
    seccionInicial: SettingsSection = .portada,
    busquedaInicial: String = "",
    alto: CGFloat? = nil
  ) {
    self.settings = settings
    self.sounds = sounds
    self.runtimeState = runtimeState
    self.usageTracker = usageTracker
    self.updater = updater
    self.launchAtLogin = launchAtLogin
    self.onClose = onClose
    _selectedSection = State(initialValue: seccionInicial)
    _busqueda = State(initialValue: busquedaInicial)
    self.alto = alto
  }

  private var busquedaAbierta: Bool {
    !busqueda.trimmingCharacters(in: .whitespaces).isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      SettingsHeader(onClose: onClose)

      if runtimeState.isDictating && selectedSection != .insights {
        ActiveSessionNotice()
      }

      HStack(spacing: 0) {
        BarraLateral(
          seleccion: busquedaAbierta ? nil : selectedSection,
          busqueda: $busqueda,
          buscando: $buscando,
          alElegir: { seccion in
            busqueda = ""
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
              selectedSection = seccion
            }
          },
          alConfirmar: {
            if let primero = IndiceDeAjustes.buscar(busqueda).first { ir(a: primero) }
          }
        )

        Rectangle()
          .fill(.white.opacity(contrast == .increased ? 0.18 : 0.07))
          .frame(width: 1)

        ZStack(alignment: .topLeading) {
          // Con la ventana cerrada no queda nada vivo adentro: una ventana
          // que sólo se ordena afuera no cancela las `.task` de sus vistas.
          if runtimeState.ventanaAbierta {
            if busquedaAbierta {
              ResultadosDeLaBusqueda(consulta: busqueda, alElegir: ir(a:))
                .transition(.opacity)
            } else {
              SettingsContent(
                section: selectedSection,
                settings: settings,
                sounds: sounds,
                usageTracker: usageTracker,
                runtimeState: runtimeState,
                updater: updater,
                launchAtLogin: launchAtLogin,
                filaAEnfocar: $filaAEnfocar,
                resaltado: $resaltado
              )
              .id(selectedSection)
              .transition(.opacity)
            }
          }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: selectedSection)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: busquedaAbierta)
      }
    }
    .frame(width: Self.tamano.width, height: alto ?? Self.tamano.height)
    .environment(\.ajusteResaltado, resaltado)
    // ⌘F: el atajo de buscar de toda app de Mac. Un botón invisible y no
    // `hidden()`, que se lleva el atajo con él.
    .background {
      Button("Buscar ajustes") { buscando = true }
        .keyboardShortcut("f", modifiers: .command)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    // Above the section switch on purpose. Sections are identified by their
    // selection, so changing section replaces the whole content and would take
    // this with it — cancelling the one call that drives Apple's download.
    .background(TranslationDownloadTask(pair: runtimeState.installingTranslation?.pair))
    .superficieDeDilo()
    // Escape cierra la búsqueda primero y la ventana después.
    .onExitCommand {
      if busquedaAbierta || buscando {
        busqueda = ""
        buscando = false
      } else {
        onClose()
      }
    }
    .onChange(of: selectedSection, initial: true) { _, seccion in
      runtimeState.seccionActual = seccion
    }
    // Abrir Ajustes en una sección concreta: el panel de la barra y el
    // arranque después de actualizar piden Novedades. Se consume al aplicarla
    // para que volver a abrir la ventana no vuelva a saltar ahí.
    .onChange(of: runtimeState.seccionPedida, initial: true) { _, pedida in
      guard let pedida else { return }
      busqueda = ""
      selectedSection = pedida
      runtimeState.seccionPedida = nil
    }
    // Y en una fila: «Abrir Claude» desde otra sección lleva a la clave.
    .onChange(of: runtimeState.filaPedida, initial: true) { _, fila in
      guard let fila else { return }
      ir(a: fila)
      runtimeState.filaPedida = nil
    }
  }

  private func ir(a ajuste: AjusteID) {
    busqueda = ""
    buscando = false
    selectedSection = ajuste.seccion
    filaAEnfocar = ajuste.ancla
  }
}

struct SettingsHeader: View {
  let onClose: () -> Void

  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    ZStack {
      // Close sits on the leading edge, where native macOS windows
      // keep their window controls.
      HStack {
        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(contrast == .increased ? 0.92 : 0.7))
            .frame(width: 24, height: 24)
            .background(.white.opacity(0.08), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Cerrar")
        .accessibilityLabel(Text("Cerrar"))
        Spacer()
      }

      // La identidad de Dilo, centrada pase lo que pase con el botón de cerrar.
      HStack(spacing: 8) {
        Image("MenuBarIcon")
          .renderingMode(.template)
          .resizable()
          .scaledToFit()
          .frame(width: 13, height: 13)
          .foregroundStyle(.white.opacity(0.92))
          .frame(width: 22, height: 22)
          .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

        Text(verbatim: "Dilo")
          .font(.system(size: 13.5, weight: .semibold, design: .rounded))
      }
    }
    .padding(.horizontal, 14)
    .frame(height: 46)
    .background(SettingsWindowDragHandle())
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(.white.opacity(contrast == .increased ? 0.18 : 0.07))
        .frame(height: 1)
    }
  }
}

private struct ActiveSessionNotice: View {
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "info.circle.fill")
        .foregroundStyle(SettingsTheme.accent)
      Text("Lo que cambies aplica al próximo dictado.")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(contrast == .increased ? 0.92 : 0.72))
      Spacer()
    }
    .padding(.horizontal, 18)
    .frame(height: 32)
    .background(SettingsTheme.accent.opacity(0.08))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(SettingsTheme.accent.opacity(contrast == .increased ? 0.35 : 0.18))
        .frame(height: 1)
    }
  }
}

/// La barra lateral: la búsqueda arriba y las secciones por familia, cada
/// una con su ícono de color.
private struct BarraLateral: View {
  /// Nil mientras la búsqueda está abierta: ninguna sección está «elegida».
  let seleccion: SettingsSection?
  @Binding var busqueda: String
  var buscando: FocusState<Bool>.Binding
  let alElegir: (SettingsSection) -> Void
  let alConfirmar: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      CampoDeBusqueda(texto: $busqueda, buscando: buscando, alConfirmar: alConfirmar)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(SettingsSectionGroup.allCases) { grupo in
            VStack(alignment: .leading, spacing: 1) {
              if !grupo.title.isEmpty {
                Text(grupo.title)
                  .font(.system(size: 10, weight: .semibold))
                  .tracking(0.7)
                  .foregroundStyle(.white.opacity(0.36))
                  .padding(.horizontal, 10)
                  .padding(.bottom, 4)
              }
              ForEach(grupo.sections) { seccion in
                FilaDeLaBarra(seccion: seccion, elegida: seleccion == seccion) {
                  alElegir(seccion)
                }
              }
            }
          }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 16)
      }
      .scrollIndicators(.never)
    }
    .frame(width: 214)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(.black.opacity(0.16))
  }
}

private struct FilaDeLaBarra: View {
  let seccion: SettingsSection
  let elegida: Bool
  let alElegir: () -> Void

  @State private var encima = false
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    Button(action: alElegir) {
      HStack(spacing: 9) {
        IconoDeSeccion(seccion: seccion, tamano: 22, llena: elegida)
        Text(seccion.title)
          .font(.system(size: 12.5, weight: elegida ? .semibold : .medium))
          .foregroundStyle(
            elegida ? .white : .white.opacity(contrast == .increased ? 0.86 : 0.7)
          )
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 7)
      .padding(.vertical, 5)
      .background {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(.white.opacity(elegida ? 0.1 : (encima ? 0.05 : 0)))
      }
      .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { encima = $0 }
    .accessibilityAddTraits(elegida ? [.isSelected] : [])
  }
}

/// El campo de buscar: lupa, texto y, vacío, la pista de ⌘F.
private struct CampoDeBusqueda: View {
  @Binding var texto: String
  var buscando: FocusState<Bool>.Binding
  let alConfirmar: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white.opacity(0.45))
      TextField("Buscar ajustes", text: $texto)
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .focused(buscando)
        .onSubmit(alConfirmar)
      if texto.isEmpty {
        Text(verbatim: "⌘F")
          .font(.system(size: 10, weight: .medium, design: .rounded))
          .foregroundStyle(.white.opacity(0.32))
      } else {
        Button {
          texto = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.45))
        }
        .buttonStyle(.plain)
        .help("Borrar la búsqueda")
        .accessibilityLabel(Text("Borrar la búsqueda"))
      }
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(
          buscando.wrappedValue ? SettingsTheme.accent.opacity(0.7) : .white.opacity(0.08),
          lineWidth: 1
        )
    }
  }
}

/// Lo que calza con la búsqueda, por sección y en el orden de pertinencia.
/// Un clic —o Intro, para el primero— lleva a la fila.
private struct ResultadosDeLaBusqueda: View {
  let consulta: String
  let alElegir: (AjusteID) -> Void

  private var resultados: [AjusteID] { IndiceDeAjustes.buscar(consulta) }

  /// Agrupados por sección, las secciones en el orden de su primer
  /// resultado: la más pertinente arriba.
  private var grupos: [(seccion: SettingsSection, ajustes: [AjusteID])] {
    var orden: [SettingsSection] = []
    var porSeccion: [SettingsSection: [AjusteID]] = [:]
    for ajuste in resultados {
      if porSeccion[ajuste.seccion] == nil { orden.append(ajuste.seccion) }
      porSeccion[ajuste.seccion, default: []].append(ajuste)
    }
    return orden.map { ($0, porSeccion[$0] ?? []) }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Buscar en Ajustes")
            .font(.system(size: 22, weight: .semibold, design: .rounded))
          Text(resumen)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.5))
        }

        if resultados.isEmpty {
          AvisoDeDilo(
            icono: "magnifyingglass",
            texto: String(localized: "Nada calza. Prueba con otra palabra: «micrófono», «clave», «muesca», «idioma».")
          )
        }

        ForEach(grupos, id: \.seccion) { grupo in
          VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
              IconoDeSeccion(seccion: grupo.seccion, tamano: 18)
              Text(grupo.seccion.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            }
            VStack(spacing: 0) {
              ForEach(grupo.ajustes) { ajuste in
                FilaDeResultado(
                  ajuste: ajuste,
                  esElPrimero: ajuste == resultados.first,
                  esUltima: ajuste == grupo.ajustes.last
                ) { alElegir(ajuste) }
              }
            }
            .padding(.horizontal, 6)
            .background(FondoDeTarjeta())
          }
        }
      }
      .frame(maxWidth: 640, alignment: .leading)
      .padding(.horizontal, 30)
      .padding(.vertical, 26)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var resumen: String {
    switch resultados.count {
    case 0: String(localized: "Sin resultados para «\(consulta)»")
    case 1: String(localized: "Un ajuste para «\(consulta)». Intro lo abre.")
    default: String(localized: "\(resultados.count) ajustes para «\(consulta)». Intro abre el primero.")
    }
  }
}

private struct FilaDeResultado: View {
  let ajuste: AjusteID
  let esElPrimero: Bool
  let esUltima: Bool
  let alElegir: () -> Void

  @State private var encima = false

  var body: some View {
    Button(action: alElegir) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(ajuste.titulo)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
          Text(ajuste.seccion.subtitle)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.45))
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        if esElPrimero {
          Text(verbatim: "↩")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.4))
        }
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.white.opacity(encima ? 0.7 : 0.3))
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 9)
      .background {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(.white.opacity(encima ? 0.06 : 0))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { encima = $0 }
    .overlay(alignment: .bottom) {
      if !esUltima {
        Rectangle()
          .fill(.white.opacity(0.06))
          .frame(height: 1)
          .padding(.horizontal, 10)
      }
    }
  }
}

private struct SettingsContent: View {
  let section: SettingsSection
  @Bindable var settings: AppSettings
  let sounds: HUDSounds
  let usageTracker: UsageTracker
  let runtimeState: SettingsRuntimeState
  let updater: SparkleUpdaterService
  let launchAtLogin: LaunchAtLoginService
  @Binding var filaAEnfocar: AjusteID?
  @Binding var resaltado: AjusteID?

  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ScrollViewReader { lector in
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          encabezado
            .padding(.bottom, 4)
          contenido
        }
        .frame(maxWidth: 640, alignment: .leading)
        .padding(.horizontal, 30)
        .padding(.vertical, 26)
        // Los controles compactos de Droppy: interruptores, selectores y
        // campos un punto más chicos que los de una ventana de documento.
        .controlSize(.small)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      // Llegar a la fila que pidió la búsqueda, después de que la sección
      // se dibujó, e iluminarla un momento.
      .task(id: filaAEnfocar) {
        guard let fila = filaAEnfocar else { return }
        try? await Task.sleep(for: .milliseconds(90))
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
          lector.scrollTo(fila, anchor: UnitPoint(x: 0.5, y: 0.2))
        }
        resaltado = fila
        filaAEnfocar = nil
        try? await Task.sleep(for: .seconds(1.8))
        if resaltado == fila { resaltado = nil }
      }
    }
  }

  private var encabezado: some View {
    HStack(spacing: 12) {
      IconoDeSeccion(seccion: section, tamano: 36)
      VStack(alignment: .leading, spacing: 3) {
        Text(section.title)
          .font(.system(size: 22, weight: .semibold, design: .rounded))
        Text(section.subtitle)
          .font(.system(size: 12))
          .foregroundStyle(.white.opacity(contrast == .increased ? 0.76 : 0.5))
      }
    }
  }

  @ViewBuilder
  private var contenido: some View {
    switch section {
    case .inicio:
      InicioSettingsView(settings: settings, runtimeState: runtimeState, tracker: usageTracker)
    case .reuniones:
      ReunionesSettingsView(runtimeState: runtimeState)
    case .grabarReuniones:
      AjustesDeReunionesView(runtimeState: runtimeState)
    case .claude:
      ClaudeSettingsView(settings: settings, runtimeState: runtimeState)
    case .general:
      GeneralSettingsView(launchAtLogin: launchAtLogin)
      if SettingsSection.readAloud.isAvailable {
        SubtituloDeSeccion(titulo: "Leer en voz alta", detalle: "La voz que lee lo que seleccionas")
        ReadAloudSettingsView(settings: settings)
      }
    case .appearance:
      AppearanceSettingsView(settings: settings)
      SubtituloDeSeccion(titulo: "Sonidos", detalle: "Los sonidos de empezar y terminar")
      SoundsSettingsView(settings: settings, sounds: sounds)
    case .datosDeLaMuesca:
      DatosDeLaMuescaSettingsView(settings: settings, probarAgente: runtimeState.probarAgente)
    case .sounds:
      SoundsSettingsView(settings: settings, sounds: sounds)
    case .motor:
      MotorSettingsView(settings: settings)
    case .dictation:
      DictationSettingsView(settings: settings)
      SubtituloDeSeccion(titulo: "Idiomas y traducción", detalle: "En qué idiomas dictas y a cuál traduce la tecla de traducir")
      LanguageSettingsView(settings: settings, runtimeState: runtimeState)
    case .modos:
      ModosSettingsView(
        settings: settings,
        claves: runtimeState.claves,
        abrirClaude: { runtimeState.filaPedida = .modeloDeLosModos }
      )
    case .palabras:
      PalabrasSettingsView(settings: settings, runtimeState: runtimeState)
    case .historial:
      HistorialSettingsView(settings: settings)
      SubtituloDeSeccion(titulo: "Actividad de dictado", detalle: "Cuánto dictaste, guardado sólo acá")
      InsightsSettingsView(tracker: usageTracker)
        .anclaDeAjuste(.actividad)
      LatenciasSettingsView()
        .anclaDeAjuste(.latencias)
    case .dropTranscription:
      DropTranscriptionSettingsView(settings: settings)
    case .readAloud:
      ReadAloudSettingsView(settings: settings)
    case .language:
      LanguageSettingsView(settings: settings, runtimeState: runtimeState)
    case .shortcuts:
      ShortcutsSettingsView(settings: settings)
    case .updates:
      UpdatesSettingsView(updater: updater)
    case .novedades:
      NovedadesSettingsView()
        .anclaDeAjuste(.novedades)
    case .insights:
      InsightsSettingsView(tracker: usageTracker)
      LatenciasSettingsView()
    case .about:
      AboutSettingsView()
      if SettingsSection.updates.isAvailable {
        UpdatesSettingsView(updater: updater)
      }
    }
  }
}

#Preview {
  let settings = AppSettings.previewStore()
  // Sin tocar el Llavero de nadie: la vista previa dice que hay clave.
  let claves = ClavesDeLosProveedores(almacen: AlmacenEnMemoria())
  claves.fijar(true, para: SettingsRuntimeState.cuentaDeAnthropic)
  let runtime = SettingsRuntimeState(claves: claves)
  runtime.ventanaAbierta = true
  return SettingsView(
    settings: settings,
    sounds: HUDSounds(),
    runtimeState: runtime,
    usageTracker: UsageTracker(store: UsageStore(
      fileURL: FileManager.default.temporaryDirectory
        .appending(path: "DiloSettingsPreview-usage.json")
    )),
    // Never started, so the preview shows the pane's disabled state rather
    // than reaching for the network.
    updater: SparkleUpdaterService(),
    launchAtLogin: LaunchAtLoginService(),
    onClose: {}
  )
}
