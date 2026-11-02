import AppKit
import DiloEngines
import DiloReuniones
import SwiftUI

/// **Reuniones**, el destino: la lista con fecha, duración, quiénes hablaron
/// y estado; la búsqueda por lo dicho y por quién lo dijo; y la reunión que
/// graba o se afina, arriba. No es una sección de ajustes (spec, «Dónde
/// quedan, y buscar»): los ajustes viven en «Grabar reuniones».
///
/// Todo se lee fuera del hilo principal (`ControlDeReuniones`), y nada de
/// reuniones se carga hasta que se abre esto.
struct ReunionesSettingsView: View {
  let runtimeState: SettingsRuntimeState

  @State private var reuniones: [ReunionEnDisco]?
  @State private var consulta = ""
  @State private var resultados: [ResultadoDeBusqueda] = []
  @Environment(\.colorSchemeContrast) private var contrast

  private var control: ControlDeReuniones? { runtimeState.reuniones }

  init(runtimeState: SettingsRuntimeState) {
    self.runtimeState = runtimeState
    _reuniones = State(initialValue: runtimeState.reunionesFijas)
  }

  /// Cambia cuando empieza, termina o se afina una: la lista se vuelve a leer.
  private var claveDeRecarga: String {
    "\(control?.enCurso?.id ?? "")|\(control?.pasada?.id ?? "")"
  }

  private var buscando: Bool { !consulta.trimmingCharacters(in: .whitespaces).isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      // Las piezas devuelven `AnyView`, como en la ventana de la reunión: el
      // `.app` tiene techo de 25 MB.
      if let enCurso = control?.enCurso {
        tarjetaEnCurso(enCurso)
      } else if let pasada = control?.pasada {
        tarjetaAfinando(pasada)
      }

      campoDeBusqueda
        .anclaDeAjuste(.buscarEnReuniones)

      if buscando {
        AnyView(listaDeResultados)
      } else {
        AnyView(listaDeReuniones)
      }

      Button {
        runtimeState.seccionPedida = .grabarReuniones
      } label: {
        Label("Carpeta, separador de voces y cuánto dura el audio", systemImage: "gearshape")
      }
      .buttonStyle(.link)
      .font(.system(size: 11.5))
    }
    .task(id: claveDeRecarga) {
      guard runtimeState.reunionesFijas == nil, let control else { return }
      reuniones = await control.reunionesRecientes(maximo: 500)
    }
    .task(id: consulta) {
      guard buscando, let control else {
        resultados = []
        return
      }
      // Un respiro entre tecla y tecla: buscar relee los guiones del disco.
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      resultados = await control.buscar(consulta, maximo: 100)
    }
  }

  private func tarjetaEnCurso(_ enCurso: ControlDeReuniones.EnCurso) -> AnyView {
    AnyView(
      SettingsCard(title: "Grabando ahora", icono: "record.circle") {
        SettingsRow(title: "\(enCurso.titulo)", description: "Tu micrófono y el audio del Mac, cada uno en su pista. El guion sale al terminar.") {
          HStack(spacing: 8) {
            TimelineView(.periodic(from: enCurso.inicio, by: 1)) { contexto in
              Text(verbatim: RelojDeLaReunion.texto(contexto.date.timeIntervalSince(enCurso.inicio)))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(PaletaDeDilo.actual.grabando.color)
            }
            Button("Abrir") { runtimeState.abrirReunion(enCurso.id, nil) }
              .buttonStyle(SettingsButtonStyle())
            Button("Terminar") { control?.terminar() }
              .buttonStyle(SettingsButtonStyle())
          }
        }
      }
    )
  }

  private func tarjetaAfinando(_ pasada: ControlDeReuniones.Pasada) -> AnyView {
    AnyView(
      SettingsCard(title: "Afinando el guion…", icono: "waveform.badge.magnifyingglass") {
        VStack(alignment: .leading, spacing: 6) {
          Text(verbatim: pasada.titulo)
            .font(.system(size: 12.5, weight: .medium))
          ProgressView(value: pasada.avance.total)
            .tint(SettingsTheme.accent)
          Text(LocalizedStringKey(pasada.avance.etapa.descripcion))
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.5))
          if pasada.avance.compilandoPorPrimeraVez {
            Text("La primera vez, el separador de voces se prepara para el Neural Engine: puede tardar varios minutos. Después tarda menos de un segundo.")
              .font(.system(size: 11))
              .foregroundStyle(PaletaDeDilo.actual.aviso.color.opacity(0.9))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { runtimeState.abrirReunion(pasada.id, nil) }
      }
    )
  }

  private var campoDeBusqueda: AnyView {
    AnyView(
      HStack(spacing: 7) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.white.opacity(0.5))
        TextField(text: $consulta, prompt: Text("Busca por lo dicho o por quién lo dijo: «Camila despacho»")) {
          Text("Buscar en tus reuniones")
        }
        .textFieldStyle(.plain)
        .font(.system(size: 12.5))
        if buscando {
          Button { consulta = "" } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.4))
          }
          .buttonStyle(.plain)
          .accessibilityLabel(Text("Borrar la búsqueda"))
        }
      }
      .padding(.horizontal, 11)
      .frame(height: 32)
      .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.06)))
      .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
    )
  }

  @ViewBuilder
  private var listaDeReuniones: some View {
    if let reuniones {
      if reuniones.isEmpty {
        SettingsCard(title: "Todavía no hay reuniones") {
          Text("Grábalas desde el panel de la barra, desde la próxima reunión en la muesca o con Atajos. Quedan en tu disco con el guion de quién dijo qué.")
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 10)
        }
      } else {
        SettingsCard(title: "Tus reuniones", detalle: "Un clic abre el guion.") {
          ForEach(reuniones) { enDisco in
            fila(enDisco)
          }
        }
        .anclaDeAjuste(.listaDeReuniones)
      }
    } else {
      ProgressView().controlSize(.small)
    }
  }

  private func fila(_ enDisco: ReunionEnDisco) -> AnyView {
    let reunion = enDisco.reunion
    let quienes = reunion.hablantes.map(\.nombreVisible).joined(separator: ", ")
    let estado = enDisco.estado
    let sePuedeAfinar = [.lista, .interrumpida].contains(estado) && control?.pasada?.id != reunion.id
    return AnyView(
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(verbatim: reunion.titulo)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
          Text(verbatim: "\(LineasDelGuion.fecha(reunion.inicio)) · \(LineasDelGuion.duracion(reunion.duracion())) · \(quienes)")
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        Text(Self.titulo(de: estado))
          .font(.system(size: 10.5, weight: .semibold))
          .foregroundStyle(Self.color(de: estado))
          .padding(.horizontal, 7)
          .frame(height: 18)
          .background(Capsule(style: .continuous).fill(Self.color(de: estado).opacity(0.14)))
        Menu {
          Button("Abrir el guion") { runtimeState.abrirReunion(reunion.id, nil) }
          if sePuedeAfinar {
            Button("Afinar de nuevo") { control?.afinarDeNuevo(id: reunion.id) }
          }
          Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([enDisco.carpeta]) }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Más"))
      }
      .padding(.vertical, 9)
      .contentShape(Rectangle())
      .onTapGesture { runtimeState.abrirReunion(reunion.id, nil) }
      .overlay(alignment: .bottom) {
        Rectangle().fill(.white.opacity(contrast == .increased ? 0.16 : 0.06)).frame(height: 1)
      }
    )
  }

  @ViewBuilder
  private var listaDeResultados: some View {
    if resultados.isEmpty {
      Text("Nada todavía con eso. La búsqueda no distingue tildes ni mayúsculas, y mira también quién lo dijo.")
        .font(.system(size: 11.5))
        .foregroundStyle(.white.opacity(0.5))
    } else {
      SettingsCard(title: "En tus reuniones", detalle: "Un clic abre el guion en esa línea.") {
        ForEach(Array(resultados.enumerated()), id: \.offset) { _, resultado in
          VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: resultado.titulo)
              .font(.system(size: 10.5, weight: .medium))
              .foregroundStyle(.white.opacity(0.45))
              .lineLimit(1)
            Text(verbatim: "\(resultado.hablante) · \(resultado.hora) — \(resultado.texto)")
              .font(.system(size: 12))
              .foregroundStyle(.white.opacity(0.9))
              .lineLimit(2)
          }
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
          .onTapGesture { runtimeState.abrirReunion(resultado.reunion, resultado.linea) }
        }
      }
    }
  }

  static func titulo(de estado: EstadoParaMostrar) -> LocalizedStringKey {
    switch estado {
    case .grabando: "Grabando"
    case .afinando: "Afinando"
    case .lista: "Lista"
    case .interrumpida: "Interrumpida"
    case .esperandoElDisco: "Esperando el disco"
    }
  }

  static func color(de estado: EstadoParaMostrar) -> Color {
    let paleta = PaletaDeDilo.actual
    switch estado {
    case .grabando: return paleta.grabando.color
    case .afinando: return paleta.acento.color
    case .lista: return paleta.exito.color
    case .interrumpida, .esperandoElDisco: return paleta.aviso.color
    }
  }
}

/// **Grabar reuniones**, los ajustes: dónde se guardan, quién separa las
/// voces, cuánto dura el audio y con qué micrófono. Cada fila entra a
/// `AjusteID` con su ancla. Lo elegido se lee al grabar la próxima reunión.
struct AjustesDeReunionesView: View {
  let runtimeState: SettingsRuntimeState

  @State private var preferencias: PreferenciasDeReuniones
  @State private var microfonos = MicrofonosConectados()

  init(runtimeState: SettingsRuntimeState) {
    self.runtimeState = runtimeState
    _preferencias = State(initialValue: PreferenciasDeReuniones.leer(runtimeState.defaultsDeReuniones))
  }

  private func guardar(_ cambio: (inout PreferenciasDeReuniones) -> Void) {
    cambio(&preferencias)
    preferencias.guardar(en: runtimeState.defaultsDeReuniones)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsCard(title: "Dónde se guardan", icono: "externaldrive") {
        SettingsRow(
          title: "Carpeta de las reuniones",
          description: "\(preferencias.carpeta.path(percentEncoded: false))"
        ) {
          HStack(spacing: 6) {
            if preferencias.carpeta.standardizedFileURL != CarpetaDeReunion.raizDeFabrica.standardizedFileURL {
              Button("La de fábrica") { guardar { $0.carpeta = CarpetaDeReunion.raizDeFabrica } }
                .buttonStyle(SettingsButtonStyle())
            }
            Button("Elegir…") { elegirCarpeta() }
              .buttonStyle(SettingsButtonStyle())
          }
        }
        .anclaDeAjuste(.carpetaDeReuniones)
        Text("Si el disco no está al grabar, la reunión queda en el Mac y se muda sola cuando vuelva.")
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(0.45))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 8)
      }

      SettingsCard(title: "Quién separa las voces", icono: "person.2.wave.2") {
        SettingsPickerRow(
          title: "Separador de voces",
          description: "Corre al terminar, sobre el audio de la llamada, en tu Mac. Nemotron 3 separa hasta 8 voces con solapes; Sortformer, hasta 4. Si Nemotron 3 falla, separa Sortformer.",
          options: PreferenciasDeReuniones.Diarizador.allCases,
          optionLabel: Self.titulo(de:),
          selection: Binding(get: { preferencias.diarizador }, set: { valor in guardar { $0.diarizador = valor } }),
          controlWidth: 160
        )
        .anclaDeAjuste(.diarizador)
        SettingsRow(title: "Preparado para tu Mac", description: Self.detalle(de: separador)) {
          if Self.sePuedePreparar(separador) {
            Button("Preparar ahora") { runtimeState.reuniones?.prepararElSeparador(bajarSiFalta: true) }
              .buttonStyle(SettingsButtonStyle())
          } else if separador == .bajando || separador == .preparando {
            ProgressView().controlSize(.small)
          }
        }
        .anclaDeAjuste(.prepararElSeparador)
      }

      SettingsCard(title: "El audio", icono: "waveform") {
        SettingsPickerRow(
          title: "Cuánto se guarda el audio",
          description: "El guion se queda para siempre; esto es sólo el audio. Al quedar listo pasa a AAC, unos 30 MB por hora, y lo que se borra va a la Papelera.",
          options: PoliticaDelAudio.allCases,
          optionLabel: Self.titulo(de:),
          selection: Binding(get: { preferencias.audio }, set: { valor in guardar { $0.audio = valor } }),
          controlWidth: 160
        )
        .anclaDeAjuste(.retencionDelAudio)
      }

      SettingsCard(title: "Micrófono", icono: "mic") {
        SettingsPickerRow(
          title: "Tu pista",
          description: "El micrófono de la pista «Yo». En automático usa la entrada del sistema, salvo que sean audífonos Bluetooth y haya otro, para que no bajen a calidad de llamada. No cambia la entrada del sistema ni el micrófono de dictar.",
          options: [nil] + microfonos.conectadas.map { Optional($0.uid) } + faltante,
          optionLabel: etiquetaDelMicrofono,
          selection: Binding(get: { preferencias.microfonoUID }, set: { valor in guardar { $0.microfonoUID = valor } }),
          controlWidth: 210
        )
        .anclaDeAjuste(.microfonoDeReuniones)
      }
    }
    .onAppear {
      microfonos.mirar()
      runtimeState.reuniones?.revisarElSeparador()
    }
    .onDisappear { microfonos.dejarDeMirar() }
  }

  private var separador: ControlDeReuniones.EstadoDelSeparador {
    runtimeState.reuniones?.separador ?? runtimeState.separadorFijo
  }

  static func sePuedePreparar(_ estado: ControlDeReuniones.EstadoDelSeparador) -> Bool {
    switch estado {
    case .sinBajar, .porPreparar, .fallo: true
    case .sinRevisar, .bajando, .preparando, .listo: false
    }
  }

  /// La verdad sobre la primera vez: compilar para el Neural Engine tarda
  /// minutos (412 s en un M1) y Dilo lo hace solo, en reposo, nunca dictando.
  static func detalle(de estado: ControlDeReuniones.EstadoDelSeparador) -> LocalizedStringKey {
    switch estado {
    case .sinRevisar: ""
    case .sinBajar:
      "Todavía no está en este Mac. Se baja solo al grabar tu primera reunión (unos 190 MB), o ahora."
    case .bajando: "Bajando el separador de voces…"
    case .porPreparar:
      "Bajado. La primera vez se prepara para el Neural Engine y puede tardar varios minutos: Dilo lo hace solo cuando no estás dictando."
    case .preparando:
      "Preparándolo para el Neural Engine. La primera vez tarda varios minutos; después, menos de un segundo."
    case .listo: "Listo: la próxima pasada lo carga en menos de un segundo."
    case let .fallo(motivo): "No se pudo preparar (\(motivo)). Vuelve a intentarlo."
    }
  }

  /// Lo elegido que no está conectado se queda en la lista, dicho: si
  /// desapareciera, el selector pisaría la elección en silencio.
  private var faltante: [String?] {
    guard let uid = preferencias.microfonoUID, !microfonos.conectadas.contains(where: { $0.uid == uid }) else { return [] }
    return [uid]
  }

  private func etiquetaDelMicrofono(_ uid: String?) -> String {
    guard let uid else { return String(localized: "Automático") }
    if let entrada = microfonos.conectadas.first(where: { $0.uid == uid }) { return entrada.nombre }
    return String(localized: "\(uid) (no conectado)")
  }

  static func titulo(de diarizador: PreferenciasDeReuniones.Diarizador) -> String {
    switch diarizador {
    case .nemotron3: String(localized: "Nemotron 3")
    case .sortformer: String(localized: "Sortformer")
    }
  }

  static func titulo(de politica: PoliticaDelAudio) -> String {
    switch politica {
    case .borrarAlTerminar: String(localized: "Borrar al terminar")
    case .treintaDias: String(localized: "30 días")
    case .siempre: String(localized: "Guardarlo siempre")
    }
  }

  private func elegirCarpeta() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = String(localized: "Elegir")
    panel.message = String(localized: "Elige dónde se guardan las reuniones.")
    panel.directoryURL = preferencias.carpeta
    NSApp.activate()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guardar { $0.carpeta = url }
  }
}
