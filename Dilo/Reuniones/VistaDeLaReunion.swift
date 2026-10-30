import DiloReuniones
import SwiftUI
import UniformTypeIdentifiers

/// Lo que la ventana de la reunión muestra. Lo llena
/// `ControlDeLaVentanaDeReunion` desde `ControlDeReuniones` y el disco; el
/// render de Ajustes lo llena a mano, sin disco ni audio.
@MainActor
@Observable
final class ModeloDeLaReunion {
  enum Fase: Equatable {
    /// Fase 1: no hay guion en vivo; «Grabando. El guion sale al terminar».
    case grabando
    /// La pasada final, con su avance real.
    case afinando(AvanceDeLaPasada)
    case lista
    /// Sin guion: interrumpida, esperando el disco, o la pasada falló.
    case sinGuion
    /// Leyendo del disco.
    case cargando
  }

  var fase: Fase = .cargando
  var titulo = ""
  var inicio = Date()
  /// La reunión grabando, para el reloj y las marcas de la cabecera.
  var enVivo: ReunionEnLaMuesca?
  var reunion: Reunion?
  var estado: EstadoParaMostrar?
  var lineas: [LineaDelGuion] = []
  /// La línea a la que llegar: la de un resultado de la búsqueda.
  var lineaResaltada: Int?
  var reproduciendo: Int?
  var hayAudio = false
  var siempreEncima = true
  /// El hablante cuyas opciones de nombre están abiertas.
  var opcionesDe: String?
  /// Con «Otro nombre…» elegido: el campo abierto y lo escrito.
  var escribiendoNombre = false
  var nombreEscrito = ""
  var confirmandoBorrar = false
  /// «Copiado» un momento en el botón que se apretó.
  var copiado: Copia?

  enum Copia: Equatable {
    case texto
    case paraClaude
  }

  struct Acciones {
    var terminar: () -> Void = {}
    var cerrar: () -> Void = {}
    var afinarDeNuevo: () -> Void = {}
    var renombrar: (String, String?) -> Void = { _, _ in }
    var escribirNombre: (Bool) -> Void = { _ in }
    var juntar: (String, String) -> Void = { _, _ in }
    var reasignar: (Int, String?) -> Void = { _, _ in }
    var reproducir: (Int) -> Void = { _ in }
    var copiar: (Copia) -> Void = { _ in }
    var copiarLinea: (Int) -> Void = { _ in }
    var mostrarEnFinder: () -> Void = {}
    var borrar: () -> Void = {}
    var fijarSiempreEncima: (Bool) -> Void = { _ in }
  }

  @ObservationIgnored var acciones = Acciones()

  var hablantes: [Hablante] { reunion?.hablantes ?? [] }

  /// Los hablantes que tienen al menos una línea: los chips.
  var hablantesConLinea: [Hablante] {
    let conLinea = Set(lineas.compactMap(\.hablante))
    return hablantes.filter { conLinea.contains($0.id) }
  }

  func nombre(_ id: String?) -> String { LineasDelGuion.nombre(id, en: hablantes) }
}

/// La ventana de la reunión: el guion, no una libreta (spec, «Mientras
/// graba»). 380×520 con el vidrio ahumado de Ajustes; arriba el título, el
/// tiempo, las dos marcas y «Terminar»; abajo, según la fase, «Grabando»,
/// «Afinando el guion…» con el avance real, o el guion con sus hablantes
/// como chips y sus acciones.
struct VistaDeLaReunion: View {
  static let tamano = CGSize(width: 380, height: 520)

  @Bindable var modelo: ModeloDeLaReunion
  @Environment(\.accessibilityReduceMotion) private var reducirMovimiento

  var body: some View {
    VStack(spacing: 0) {
      cabecera
      Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
      cuerpo
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      if modelo.fase == .lista {
        Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
        pie
      }
    }
    .frame(width: Self.tamano.width, height: Self.tamano.height)
    .superficieDeDilo()
    .onExitCommand {
      if modelo.escribiendoNombre { modelo.acciones.escribirNombre(false) } else { modelo.acciones.cerrar() }
    }
  }

  private var cabecera: some View {
    HStack(alignment: .center, spacing: 8) {
      VStack(alignment: .leading, spacing: 3) {
        Text(verbatim: modelo.titulo)
          .font(.system(size: 13.5, weight: .semibold))
          .foregroundStyle(.white)
          .lineLimit(1)
        subtitulo
      }
      Spacer(minLength: 4)
      if let enVivo = modelo.enVivo, modelo.fase == .grabando {
        HStack(spacing: 2) {
          HUDMarcaDePista(simbolo: "mic.fill", tachado: "mic.slash.fill", marca: enVivo.microfono)
          HUDMarcaDePista(simbolo: "speaker.wave.2.fill", tachado: "speaker.slash.fill", marca: enVivo.parlante)
        }
        .help(Text("Micrófono y audio del Mac"))
        Button(action: modelo.acciones.terminar) {
          Text("Terminar")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule(style: .continuous).fill(PaletaDeDilo.actual.grabando.color.opacity(0.85)))
        }
        .buttonStyle(.plain)
        .help(Text("Terminar la reunión y armar su guion"))
      }
      Button {
        modelo.acciones.fijarSiempreEncima(!modelo.siempreEncima)
      } label: {
        Image(systemName: modelo.siempreEncima ? "pin.fill" : "pin")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(modelo.siempreEncima ? PaletaDeDilo.actual.acento.color : .white.opacity(0.5))
          .frame(width: 22, height: 22)
      }
      .buttonStyle(.plain)
      .help(Text("Siempre encima"))
      .accessibilityLabel(Text("Siempre encima"))
      .accessibilityValue(Text(modelo.siempreEncima ? "Sí" : "No"))
      Button(action: modelo.acciones.cerrar) {
        Image(systemName: "xmark")
          .font(.system(size: 10.5, weight: .semibold))
          .foregroundStyle(.white.opacity(0.55))
          .frame(width: 22, height: 22)
      }
      .buttonStyle(.plain)
      .help(Text("Cerrar: la reunión sigue grabando"))
      .accessibilityLabel(Text("Cerrar"))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
  }

  @ViewBuilder
  private var subtitulo: some View {
    let estilo = Font.system(size: 11, weight: .medium).monospacedDigit()
    if modelo.fase == .grabando {
      TimelineView(.periodic(from: modelo.inicio, by: 1)) { contexto in
        HStack(spacing: 5) {
          Circle().fill(PaletaDeDilo.actual.grabando.color).frame(width: 6, height: 6)
          Text(verbatim: RelojDeLaReunion.texto(contexto.date.timeIntervalSince(modelo.inicio)))
        }
      }
      .font(estilo)
      .foregroundStyle(.white.opacity(0.6))
    } else if let reunion = modelo.reunion {
      Text(verbatim: Self.fechaYDuracion(reunion))
        .font(estilo)
        .foregroundStyle(.white.opacity(0.5))
    }
  }

  static func fechaYDuracion(_ reunion: Reunion) -> String {
    let fecha = LineasDelGuion.fecha(reunion.inicio)
    return "\(fecha) · \(LineasDelGuion.duracion(reunion.duracion(ahora: reunion.fin ?? Date())))"
  }

  @ViewBuilder
  private var cuerpo: some View {
    switch modelo.fase {
    case .grabando:
      aviso(
        simbolo: "waveform",
        titulo: "Grabando. El guion sale al terminar",
        detalle: Text("Tu micrófono y el audio del Mac, cada uno en su pista. Puedes cerrar esta ventana: la reunión sigue grabando.")
      )
    case let .afinando(avance):
      afinando(avance)
    case .lista:
      guion
    case .sinGuion:
      sinGuion
    case .cargando:
      ProgressView().controlSize(.small)
    }
  }

  private func aviso(simbolo: String, titulo: LocalizedStringKey, detalle: Text) -> some View {
    VStack(spacing: 10) {
      Image(systemName: simbolo)
        .font(.system(size: 26, weight: .medium))
        .foregroundStyle(PaletaDeDilo.actual.acento.color)
      Text(titulo)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
      detalle
        .font(.system(size: 11.5))
        .foregroundStyle(.white.opacity(0.55))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 36)
  }

  private func afinando(_ avance: AvanceDeLaPasada) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Afinando el guion…")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
      ProgressView(value: avance.total)
        .progressViewStyle(.linear)
        .tint(PaletaDeDilo.actual.acento.color)
      HStack {
        Text(LocalizedStringKey(avance.etapa.descripcion))
        Spacer()
        Text(verbatim: "\(Int((avance.total * 100).rounded())) %").monospacedDigit()
      }
      .font(.system(size: 11))
      .foregroundStyle(.white.opacity(0.55))
      if avance.compilandoPorPrimeraVez {
        Label {
          Text("La primera vez, el separador de voces se prepara para el Neural Engine: puede tardar varios minutos. Después tarda menos de un segundo.")
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "hourglass")
        }
        .font(.system(size: 11))
        .foregroundStyle(PaletaDeDilo.actual.aviso.color.opacity(0.9))
      }
    }
    .padding(.horizontal, 28)
  }

  private var sinGuion: some View {
    VStack(spacing: 12) {
      switch modelo.estado {
      case .esperandoElDisco:
        aviso(
          simbolo: "externaldrive.badge.exclamationmark",
          titulo: "Esperando el disco",
          detalle: Text("La reunión quedó en el Mac porque el disco de las reuniones no estaba. Se muda y se afina sola cuando vuelva.")
        )
      case .interrumpida:
        aviso(
          simbolo: "exclamationmark.triangle",
          titulo: "La reunión se interrumpió",
          detalle: Text("Dilo se cerró grabando. El audio quedó en disco: afínala para armar el guion.")
        )
      default:
        aviso(
          simbolo: "text.badge.xmark",
          titulo: "Todavía no hay guion",
          detalle: Text(verbatim: modelo.reunion?.falla ?? String(localized: "Afínala para armar el guion."))
        )
      }
      if modelo.estado != .esperandoElDisco {
        Button(action: modelo.acciones.afinarDeNuevo) {
          Text("Afinar de nuevo")
        }
        .controlSize(.small)
      }
    }
  }

  private var guion: some View {
    VStack(spacing: 0) {
      chips
      if let id = modelo.opcionesDe {
        opcionesDeNombre(id)
      }
      ScrollViewReader { lector in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 9) {
            if modelo.lineas.isEmpty {
              Text("Sin palabras en el guion.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
            }
            ForEach(Array(modelo.lineas.enumerated()), id: \.offset) { indice, linea in
              fila(indice, linea).id(indice)
            }
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
        }
        .onChange(of: modelo.lineaResaltada, initial: true) { _, linea in
          guard let linea else { return }
          withAnimation(reducirMovimiento ? nil : .easeInOut(duration: 0.3)) {
            lector.scrollTo(linea, anchor: UnitPoint(x: 0.5, y: 0.25))
          }
        }
      }
    }
  }

  private var chips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 5) {
        ForEach(modelo.hablantesConLinea) { hablante in
          chip(hablante)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
    }
  }

  /// Un hablante como chip: un clic abre sus nombres; arrastrarlo sobre otro
  /// los junta (el modelo partió a alguien en dos). Yo es Yo: no se renombra
  /// ni se junta.
  private func chip(_ hablante: Hablante) -> some View {
    let abierto = modelo.opcionesDe == hablante.id
    let color = Self.color(de: hablante)
    let esYo = !NombresParaRenombrar.sePuedeRenombrar(hablante.id)
    return Text(verbatim: hablante.nombreVisible)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(abierto ? .black : color)
      .padding(.horizontal, 9)
      .frame(height: 22)
      .background(Capsule(style: .continuous).fill(abierto ? color : color.opacity(0.14)))
      .overlay(Capsule(style: .continuous).strokeBorder(color.opacity(0.3), lineWidth: 1))
      .contentShape(Capsule())
      .onTapGesture {
        guard !esYo else { return }
        modelo.escribiendoNombre = false
        modelo.opcionesDe = abierto ? nil : hablante.id
      }
      .draggable(hablante.id) {
        Text(verbatim: hablante.nombreVisible).font(.system(size: 11, weight: .semibold)).padding(4)
      }
      .dropDestination(for: String.self) { ids, _ in
        guard !esYo, let origen = ids.first, origen != hablante.id, origen != Hablante.yo.id else { return false }
        modelo.acciones.juntar(origen, hablante.id)
        return true
      }
      .help(esYo ? Text("Tu micrófono: siempre eres tú") : Text("Clic para ponerle nombre; arrástralo sobre otro para juntarlos"))
      .accessibilityAddTraits(.isButton)
  }

  /// Los nombres que se ofrecen: los asistentes del evento que no son de
  /// nadie, «Otro nombre…» y, si ya tiene uno, quitarlo.
  private func opcionesDeNombre(_ id: String) -> some View {
    let ofrecidos = modelo.reunion.map { NombresParaRenombrar.ofrecidos(para: id, en: $0) } ?? []
    let tieneNombre = modelo.hablantes.first { $0.id == id }?.nombre != nil
    return VStack(alignment: .leading, spacing: 6) {
      if modelo.escribiendoNombre {
        HStack(spacing: 6) {
          TextField(text: $modelo.nombreEscrito, prompt: Text("Nombre")) { EmptyView() }
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(maxWidth: 250)
            .onSubmit { modelo.acciones.renombrar(id, modelo.nombreEscrito) }
          Button("Listo") { modelo.acciones.renombrar(id, modelo.nombreEscrito) }
            .controlSize(.small)
        }
      } else {
        FlowDeNombres {
          ForEach(ofrecidos, id: \.self) { nombre in
            opcion(nombre) { modelo.acciones.renombrar(id, nombre) }
          }
          opcion(String(localized: "Otro nombre…")) { modelo.acciones.escribirNombre(true) }
          if tieneNombre {
            opcion(String(localized: "Quitar el nombre")) { modelo.acciones.renombrar(id, nil) }
          }
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.bottom, 8)
  }

  private func opcion(_ texto: String, accion: @escaping () -> Void) -> some View {
    Button(action: accion) {
      Text(verbatim: texto)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.08)))
    }
    .buttonStyle(.plain)
  }

  /// Una línea: quién y cuándo arriba, lo dicho abajo. Un solape —alguien
  /// dijo algo encima de otro— va en su propia línea, corrida y con su marca.
  /// Un clic la reproduce; clic derecho la reasigna.
  private func fila(_ indice: Int, _ linea: LineaDelGuion) -> some View {
    let hablante = modelo.hablantes.first { $0.id == linea.hablante }
    let color = hablante.map(Self.color(de:)) ?? .white.opacity(0.6)
    let suena = modelo.reproduciendo == indice
    let resaltada = modelo.lineaResaltada == indice
    return VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 5) {
        if linea.solape {
          Image(systemName: "arrow.turn.down.right")
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.4))
            .help(Text("Se dijo a la vez que otra voz"))
        }
        Text(verbatim: modelo.nombre(linea.hablante))
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(color)
        Text(verbatim: LineasDelGuion.hora(linea.desde, inicio: modelo.inicio))
          .font(.system(size: 10.5).monospacedDigit())
          .foregroundStyle(.white.opacity(0.4))
        if suena {
          Image(systemName: "speaker.wave.2.fill")
            .font(.system(size: 9))
            .foregroundStyle(PaletaDeDilo.actual.acento.color)
        }
      }
      Text(verbatim: linea.texto)
        .font(.system(size: 12.5))
        .foregroundStyle(.white.opacity(linea.solape ? 0.72 : 0.92))
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
    .padding(.leading, linea.solape ? 14 : 0)
    .padding(.vertical, 3)
    .padding(.horizontal, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(PaletaDeDilo.actual.acento.color.opacity(resaltada ? 0.14 : (suena ? 0.08 : 0)))
    )
    .contentShape(Rectangle())
    .onTapGesture { modelo.acciones.reproducir(indice) }
    .contextMenu { menuDeLaLinea(indice, linea) }
    .help(modelo.hayAudio ? Text("Clic para escuchar desde aquí") : Text(""))
  }

  @ViewBuilder
  private func menuDeLaLinea(_ indice: Int, _ linea: LineaDelGuion) -> some View {
    Button("Copiar la línea") { modelo.acciones.copiarLinea(indice) }
    // Las líneas de Yo salen de tu micrófono: no hay a quién reasignarlas.
    if linea.hablante != Hablante.yo.id {
      Divider()
      Menu("Reasignar a") {
        ForEach(modelo.hablantes.filter { $0.id != linea.hablante && $0.pista == .ellos }) { otro in
          Button(otro.nombreVisible) { modelo.acciones.reasignar(indice, otro.id) }
        }
        Button("Un hablante nuevo") { modelo.acciones.reasignar(indice, nil) }
      }
    }
  }

  private var pie: some View {
    HStack(spacing: 4) {
      botonDelPie(
        modelo.copiado == .texto ? "Copiado" : "Copiar",
        simbolo: modelo.copiado == .texto ? "checkmark" : "doc.on.doc"
      ) { modelo.acciones.copiar(.texto) }
      botonDelPie(
        modelo.copiado == .paraClaude ? "Copiado" : "Copiar para Claude",
        simbolo: modelo.copiado == .paraClaude ? "checkmark" : "sparkle"
      ) { modelo.acciones.copiar(.paraClaude) }
      Spacer(minLength: 0)
      Button(action: modelo.acciones.mostrarEnFinder) {
        Image(systemName: "folder").frame(width: 24, height: 22)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.white.opacity(0.7))
      .help(Text("Mostrar en Finder"))
      .accessibilityLabel(Text("Mostrar en Finder"))
      if modelo.confirmandoBorrar {
        Button("Cancelar") { modelo.confirmandoBorrar = false }
          .controlSize(.small)
        Button(role: .destructive, action: modelo.acciones.borrar) { Text("A la Papelera") }
          .controlSize(.small)
      } else {
        Button { modelo.confirmandoBorrar = true } label: {
          Image(systemName: "trash").frame(width: 24, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.7))
        .help(Text("Borrar: la reunión va a la Papelera"))
        .accessibilityLabel(Text("Borrar"))
      }
    }
    .font(.system(size: 11, weight: .medium))
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
  }

  private func botonDelPie(_ titulo: LocalizedStringKey, simbolo: String, accion: @escaping () -> Void) -> some View {
    Button(action: accion) {
      Label(titulo, systemImage: simbolo)
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.07)))
    }
    .buttonStyle(.plain)
  }

  /// Un color por hablante, estable por su número: Yo en el acento, los
  /// demás en una rueda que se distingue sobre el vidrio oscuro.
  static func color(de hablante: Hablante) -> Color {
    guard hablante.id != Hablante.yo.id else { return PaletaDeDilo.actual.acento.color }
    let rueda: [Color] = [
      Color(red: 0.49, green: 0.98, blue: 0.77),
      Color(red: 0.65, green: 0.65, blue: 0.98),
      Color(red: 1.0, green: 0.80, blue: 0.42),
      Color(red: 1.0, green: 0.55, blue: 0.62),
      Color(red: 0.55, green: 0.85, blue: 1.0),
      Color(red: 0.85, green: 0.70, blue: 1.0),
      Color(red: 0.72, green: 0.92, blue: 0.45),
    ]
    return rueda[((hablante.numero ?? 2) - 2) % rueda.count]
  }
}

/// Las opciones de nombre en renglones que se acomodan al ancho.
private struct FlowDeNombres: Layout {
  var espacio: CGFloat = 5

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let ancho = proposal.width ?? 340
    var x: CGFloat = 0
    var y: CGFloat = 0
    var alto: CGFloat = 0
    for vista in subviews {
      let t = vista.sizeThatFits(.unspecified)
      if x > 0, x + t.width > ancho {
        x = 0
        y += alto + espacio
        alto = 0
      }
      x += t.width + espacio
      alto = max(alto, t.height)
    }
    return CGSize(width: ancho, height: y + alto)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    var y = bounds.minY
    var alto: CGFloat = 0
    for vista in subviews {
      let t = vista.sizeThatFits(.unspecified)
      if x > bounds.minX, x + t.width > bounds.maxX {
        x = bounds.minX
        y += alto + espacio
        alto = 0
      }
      vista.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(t))
      x += t.width + espacio
      alto = max(alto, t.height)
    }
  }
}
