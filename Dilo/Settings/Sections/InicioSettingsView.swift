import AppKit
import DiloCapabilities
import DiloEngines
import DiloModes
import SwiftUI

/// Inicio: la portada de Ajustes, la que abre el clic izquierdo en el ícono.
///
/// Alfonso, 2026-10-19: la ventana «no se condice con todas las funciones»
/// de Dilo. Esta sección dice de un vistazo si se puede dictar y qué falta,
/// con el arreglo al lado; qué hace Claude y con qué modelo; lo último
/// dictado con su «Copiar»; las cifras de la semana; y los accesos a lo que
/// más se toca. **Cada tarjeta lleva a algo**: el resto de Ajustes, el panel
/// de Ajustes del Sistema, o el portapapeles. Lo que se calcula vive en
/// `PortadaDeAjustes`, que es puro.
///
/// No sondea nada. Los permisos se leen al aparecer y cada vez que Dilo
/// vuelve a estar al frente —que es lo que pasa cuando la persona vuelve de
/// Ajustes del Sistema—, no una vez por segundo como en los Primeros pasos.
struct InicioSettingsView: View {
  @Bindable var settings: AppSettings
  let runtimeState: SettingsRuntimeState
  let tracker: UsageTracker

  @State private var permisos: EstadoDePermisos?
  @State private var descargas = DescargaDeParakeet.compartida
  @State private var latencias: RegistroDeLatencias?
  @State private var copiado = false

  private var portada: PortadaDeAjustes {
    var entrada = PortadaDeAjustes.Entrada()
    let motorEsApple = settings.motorDeVoz == .apple
    entrada.permisosPedidos = Permiso.pasos(anfitrion: Anfitrion.actual, motorEsApple: motorEsApple)
    if let fijos = runtimeState.permisosQueFaltanFijos {
      entrada.permisosQueFaltan = fijos
    } else if let permisos {
      entrada.permisosQueFaltan = Set(Permiso.allCases.filter { permisos.estado(de: $0) == .falta })
    }
    entrada.motorElegido = settings.motorDeVoz
    entrada.parakeetListo = descargas.listo
    entrada.parakeetBajando = descargas.progreso != nil
    switch runtimeState.claves.estado(de: SettingsRuntimeState.cuentaDeAnthropic) {
    case .hay: entrada.hayClave = true
    case .falta: entrada.hayClave = false
    case .sinLeer, .leyendo: entrada.hayClave = nil
    }
    let general = settings.proveedores.proveedor(settings.proveedorGeneralID)
    entrada.modosConClaude = general?.dialecto == .anthropic
    entrada.modeloDeLosModos = general?.modelo ?? ""
    entrada.nombreDelGeneral = general.map { $0.esLocal ? String(localized: "Apple, en el Mac") : $0.nombre } ?? ""
    entrada.motorDeTraduccion = settings.motorDeTraduccion
    entrada.aprenderConClaude = settings.aprenderConClaude
    entrada.modeloParaRevisar = settings.modeloParaRevisar
    entrada.modeloParaOrdenar = settings.modeloParaOrdenar
    return PortadaDeAjustes(entrada)
  }

  var body: some View {
    let portada = portada
    VStack(alignment: .leading, spacing: 16) {
      estado(portada)

      if !portada.avisos.isEmpty {
        VStack(spacing: 8) {
          ForEach(portada.avisos) { aviso in
            filaDeAviso(aviso)
          }
        }
      }

      HStack(alignment: .top, spacing: 14) {
        ultimoDictado
        cifras
      }

      tarjetaDeClaude(portada)

      accesos
    }
    .task {
      await runtimeState.claves.mirar(SettingsRuntimeState.cuentaDeAnthropic)
    }
    .task {
      if permisos == nil, runtimeState.permisosQueFaltanFijos == nil {
        permisos = EstadoDePermisos(motorEsApple: settings.motorDeVoz == .apple)
      }
      descargas.refrescar()
      await tracker.load()
      latencias = await AlmacenDeLatencias().registro()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      permisos?.refrescar()
    }
  }

  // El estado de arriba

  private func estado(_ portada: PortadaDeAjustes) -> some View {
    HStack(alignment: .center, spacing: 16) {
      ZStack {
        Circle()
          .fill((portada.listo ? PaletaDeDilo.actual.exito : PaletaDeDilo.actual.aviso).color.opacity(0.16))
        Image(systemName: portada.listo ? "checkmark" : "exclamationmark")
          .font(.system(size: 20, weight: .bold))
          .foregroundStyle((portada.listo ? PaletaDeDilo.actual.exito : PaletaDeDilo.actual.aviso).color)
      }
      .frame(width: 50, height: 50)

      VStack(alignment: .leading, spacing: 5) {
        Text(portada.listo ? "Listo para dictar" : "A Dilo le falta algo para dictar")
          .font(.system(size: 17, weight: .semibold, design: .rounded))
        HStack(spacing: 6) {
          Text("Mantén")
          TeclaDeInicio(texto: settings.dictationTriggerBinding.label)
          Text("y habla; suelta para pegar.")
        }
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.6))
      }

      Spacer(minLength: 8)

      Button {
        runtimeState.filaPedida = .motorDeVoz
      } label: {
        VStack(alignment: .trailing, spacing: 3) {
          Text("Motor de voz")
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.white.opacity(0.42))
          HStack(spacing: 5) {
            Circle()
              .fill(PaletaDeDilo.actual.exito.color)
              .frame(width: 6, height: 6)
            Text(verbatim: portada.motorEnUso.title)
              .font(.system(size: 12.5, weight: .semibold))
          }
          Text("Local, en este Mac")
            .font(.system(size: 10.5))
            .foregroundStyle(.white.opacity(0.42))
        }
      }
      .buttonStyle(.plain)
      .help("Abrir Motor de voz")
    }
    .padding(16)
    .background(FondoDeTarjeta(radio: 16))
  }

  private func filaDeAviso(_ aviso: PortadaDeAjustes.Aviso) -> some View {
    let color = aviso.bloquea ? PaletaDeDilo.actual.alerta.color : PaletaDeDilo.actual.aviso.color
    return HStack(alignment: .center, spacing: 12) {
      Image(systemName: aviso.icono)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(color)
        .frame(width: 26, height: 26)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: aviso.titulo)
          .font(.system(size: 12.5, weight: .semibold))
        Text(verbatim: aviso.detalle)
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(0.52))
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Button(aviso.boton) { actuar(aviso.accion) }
        .buttonStyle(SettingsButtonStyle(compacto: true))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(color.opacity(0.25), lineWidth: 1)
    }
  }

  private func actuar(_ accion: PortadaDeAjustes.Accion) {
    switch accion {
    case let .pedirPermiso(permiso):
      let estado = permisos ?? EstadoDePermisos(motorEsApple: settings.motorDeVoz == .apple)
      permisos = estado
      estado.pedir(permiso)
    case let .ir(ajuste):
      runtimeState.filaPedida = ajuste
    }
  }

  // Lo último dictado

  private var ultimoDictado: some View {
    TarjetaDeInicio(titulo: "Lo último que dictaste", icono: "text.quote") {
      if let ultimo = runtimeState.ultimoDictado {
        VStack(alignment: .leading, spacing: 10) {
          Text(verbatim: ultimo.texto(.entregado))
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.88))
            .lineLimit(4)
            .frame(maxWidth: .infinity, alignment: .leading)
          HStack {
            Text(verbatim: [
              ultimo.cuando.formatted(.relative(presentation: .named)),
              ultimo.modo,
            ].compactMap { $0 }.joined(separator: " · "))
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.45))
            Spacer()
            Button {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(ultimo.texto(.entregado), forType: .string)
              copiado = true
            } label: {
              Label(copiado ? "Copiado" : "Copiar", systemImage: copiado ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(SettingsButtonStyle(compacto: true))
          }
        }
      } else {
        Text("Lo que dictes aparece acá, con «Copiar». Vive en la memoria: al cerrar Dilo se va.")
          .font(.system(size: 11.5))
          .foregroundStyle(.white.opacity(0.5))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .onChange(of: runtimeState.ultimoDictado?.cuando) { copiado = false }
  }

  // Las cifras

  private var cifras: some View {
    let hoy = tracker.timeline(dayCount: 1).first
    let semana = tracker.momentum()
    let tipica = latencias?.percentiles(.total)?.p50
    return TarjetaDeInicio(titulo: "Tu semana", icono: "chart.bar.fill", accion: ("Ver actividad", { runtimeState.filaPedida = .actividad })) {
      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
        GridRow {
          Cifra(valor: "\(hoy?.sessionCount ?? 0)", nombre: "dictados hoy")
          Cifra(valor: "\(semana.sessionCount)", nombre: "esta semana")
        }
        GridRow {
          Cifra(valor: semana.currentWordCount.formatted(), nombre: "palabras")
          Cifra(valor: tipica.map { "\($0) ms" } ?? "—", nombre: "soltar → texto")
        }
      }
    }
  }

  // Claude

  private func tarjetaDeClaude(_ portada: PortadaDeAjustes) -> some View {
    let hayClave = runtimeState.hayClaveDeAnthropic
    return TarjetaDeInicio(
      titulo: "Claude",
      icono: "sparkle",
      accion: ("Abrir Claude", { runtimeState.seccionPedida = .claude })
    ) {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 6) {
          Image(systemName: hayClave ? "checkmark.seal.fill" : "key.slash")
            .foregroundStyle(hayClave ? PaletaDeDilo.actual.exito.color : PaletaDeDilo.actual.aviso.color)
          Text(hayClave ? "Clave de Anthropic guardada en el Llavero" : "Sin clave de Anthropic: todo corre en el Mac")
            .foregroundStyle(.white.opacity(0.7))
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.bottom, 8)

        ForEach(portada.tareas) { tarea in
          Button {
            runtimeState.filaPedida = tarea.ajuste
          } label: {
            HStack {
              Text(verbatim: tarea.nombre)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.88))
              Spacer()
              if tarea.sinClave {
                Text("sin clave")
                  .font(.system(size: 10, weight: .semibold))
                  .foregroundStyle(PaletaDeDilo.actual.aviso.color)
              }
              Text(verbatim: tarea.quien)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(
                  tarea.conClaude && !tarea.sinClave
                    ? PaletaDeDilo.actual.iconosDeAjustes.claude.color : .white.opacity(0.5)
                )
              Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
          }
        }
      }
    }
  }

  // Accesos

  private var accesos: some View {
    let conTecla = settings.modos.filter { $0.gatillo != nil }.count
    let elementos: [(SettingsSection, String)] = [
      (.modos, String(localized: "\(settings.modos.count) modos, \(conTecla) con tecla")),
      (.palabras, String(localized: "\(settings.palabrasPropias.count) palabras, \(settings.reemplazos.count) reglas")),
      (.historial, settings.dictationHistoryEnabled
        ? String(localized: "Guardando lo que dictas")
        : String(localized: "Apagado: no se guarda nada")),
      (.shortcuts, String(localized: "Dictar con \(settings.dictationTriggerBinding.label)")),
      (.datosDeLaMuesca, String(localized: "Lo que va a los costados")),
      (.appearance, PaletaDeDilo.actual.nombre.titulo),
    ]
    return VStack(alignment: .leading, spacing: 8) {
      Text("Ir a")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white.opacity(0.5))
      LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
        ForEach(elementos, id: \.0) { seccion, detalle in
          Button {
            runtimeState.seccionPedida = seccion
          } label: {
            HStack(spacing: 10) {
              IconoDeSeccion(seccion: seccion, tamano: 28)
              VStack(alignment: .leading, spacing: 2) {
                Text(seccion.title)
                  .font(.system(size: 12.5, weight: .semibold))
                  .foregroundStyle(.white.opacity(0.92))
                Text(verbatim: detalle)
                  .font(.system(size: 10.5))
                  .foregroundStyle(.white.opacity(0.48))
                  .lineLimit(1)
              }
              Spacer(minLength: 0)
            }
            .padding(10)
            .background(FondoDeTarjeta(radio: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          }
          .buttonStyle(.plain)
        }
      }
    }
  }
}

/// Una tarjeta de Inicio: título con ícono, un vínculo opcional a la
/// derecha y el contenido. Más aire que las de las secciones: acá se mira,
/// no se configura.
private struct TarjetaDeInicio<Contenido: View>: View {
  let titulo: LocalizedStringKey
  let icono: String
  var accion: (LocalizedStringKey, () -> Void)?
  @ViewBuilder let contenido: Contenido

  init(
    titulo: LocalizedStringKey,
    icono: String,
    accion: (LocalizedStringKey, () -> Void)? = nil,
    @ViewBuilder contenido: () -> Contenido
  ) {
    self.titulo = titulo
    self.icono = icono
    self.accion = accion
    self.contenido = contenido()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 7) {
        Image(systemName: icono)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(SettingsTheme.accent)
        Text(titulo)
          .font(.system(size: 12.5, weight: .semibold))
        Spacer()
        if let accion {
          Button(action: accion.1) {
            HStack(spacing: 3) {
              Text(accion.0)
              Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(SettingsTheme.accent)
          }
          .buttonStyle(.plain)
        }
      }
      contenido
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(FondoDeTarjeta(radio: 16))
  }
}

/// Un número grande con su nombre en gris.
private struct Cifra: View {
  let valor: String
  let nombre: LocalizedStringKey

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(verbatim: valor)
        .font(.system(size: 20, weight: .semibold, design: .rounded))
        .monospacedDigit()
      Text(nombre)
        .font(.system(size: 10.5))
        .foregroundStyle(.white.opacity(0.48))
    }
  }
}

/// La tecla del gatillo, como una tecla.
private struct TeclaDeInicio: View {
  let texto: String

  var body: some View {
    Text(verbatim: texto)
      .font(.system(size: 11, weight: .semibold, design: .rounded))
      .foregroundStyle(.white.opacity(0.9))
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .strokeBorder(.white.opacity(0.14), lineWidth: 1)
      }
  }
}
