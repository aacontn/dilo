import SwiftUI

/// Lo que la barra de llamada dibuja, en valores sueltos: así la vista no
/// sabe nada del controlador ni del paquete, y el render de la muesca
/// (`scripts/render-muesca.sh`) dibuja esta misma vista y no una copia.
struct FotoDeLaConversacion: Equatable {
  enum Fase: Equatable {
    case escuchando
    case pensando
    case hablando
  }

  struct Linea: Equatable, Identifiable {
    let id: Int
    /// Del lado del agente: lo que contestó, o una nota suya.
    let deDilo: Bool
    let texto: String
    /// Quién lo dijo, si no es Dilo: «Switchboard». Nil es «Dilo» o «Tú».
    var quien: String?
    /// Una nota y no algo dicho: una herramienta, una aprobación. Va en gris.
    var nota = false
  }

  /// Lo que espera un clic: «Dilo quiere crear una nota en Apple Notas».
  struct AprobacionEnLaBarra: Equatable {
    let descripcion: String
    let detalle: String
  }

  /// Un chip que se elige: los modelos de la barra de ajustes.
  struct Opcion: Equatable, Identifiable {
    let id: String
    let titulo: String
    let elegida: Bool
  }

  var fase = Fase.escuchando
  var silenciada = false
  /// El modelo que contestó el turno: «Sonnet». Nil antes del primero.
  var modelo: String?
  /// Lo que vas diciendo, en vivo.
  var parcial = ""
  /// Lo conversado, sólo en RAM: lo último que cabe.
  var lineas: [Linea] = []
  var verTranscripcion = false
  var verAjustes = false
  /// El nivel del micrófono, 0 a 1, mientras escucha.
  var nivel: Float = 0
  /// «US$0,02»: lo que lleva la sesión.
  var costo: String?
  /// Una línea de aviso en vez del estado: «Sin conexión con Anthropic».
  var aviso: String?
  var modelos: [Opcion] = []
  var voz = ""
  var velocidad = ""
  var microfono = ""
  /// A quién se le habla ahora: «Dilo», «Switchboard».
  var agente = "Dilo"
  /// Los agentes para elegir en el menú de destino.
  var agentes: [Opcion] = []
  var verDestinos = false
  /// La herramienta que corre: «Buscando en tus reuniones…».
  var herramienta: String?
  /// Lo que espera un clic. Mientras está, ocupa lo desplegado.
  var aprobacion: AprobacionEnLaBarra?

  /// Si debajo de los controles va algo desplegado.
  var desplegada: Bool { verTranscripcion || verAjustes || verDestinos || aprobacion != nil }
}

extension FotoDeLaConversacion {
  /// Las escenas de la barra de llamada, las mismas en el arnés
  /// (`EscenaDeMuestra`) y en el render (`scripts/render-muesca.sh`).
  enum Muestra: String, CaseIterable {
    case escucha
    case piensa
    case habla
    case transcripcion
    case ajustes
    case silenciada
    case aviso
    case herramienta
    case aprobacion
    case destinos
  }

  static func deMuestra(_ muestra: Muestra) -> FotoDeLaConversacion {
    var foto = FotoDeLaConversacion()
    foto.modelo = "Sonnet"
    foto.costo = "US$0,004"
    foto.modelos = [
      Opcion(id: "automatico", titulo: String(localized: "Automático"), elegida: true),
      Opcion(id: "haiku", titulo: "Haiku", elegida: false),
      Opcion(id: "sonnet", titulo: "Sonnet", elegida: false),
      Opcion(id: "opus", titulo: "Opus", elegida: false),
    ]
    foto.agentes = [
      Opcion(id: "dilo", titulo: "Dilo", elegida: true),
      Opcion(id: "claude-code", titulo: "Claude Code", elegida: false),
      Opcion(id: "switchboard", titulo: "Switchboard", elegida: false),
    ]
    foto.voz = "Paulina (MX)"
    foto.velocidad = String(localized: "Normal")
    foto.microfono = String(localized: "Automático")
    foto.lineas = [
      Linea(id: 1, deDilo: false, texto: "¿Qué me recomiendas para el fin de semana en Valparaíso?"),
      Linea(id: 2, deDilo: true, texto: "Sube al cerro Alegre temprano y baja por el ascensor Reina Victoria."),
      Linea(id: 3, deDilo: false, texto: "¿Y si llueve?"),
    ]
    switch muestra {
    case .escucha:
      foto.parcial = "y si vamos el sábado temprano"
      foto.nivel = 0.6
    case .piensa:
      foto.fase = .pensando
      foto.modelo = "Opus"
    case .habla:
      foto.fase = .hablando
    case .transcripcion:
      foto.fase = .hablando
      foto.verTranscripcion = true
    case .ajustes:
      foto.verAjustes = true
    case .silenciada:
      foto.silenciada = true
    case .aviso:
      foto.fase = .hablando
      foto.aviso = String(localized: "Sin conexión con Anthropic")
    case .herramienta:
      foto.fase = .pensando
      foto.herramienta = String(localized: "Buscando en tus reuniones…")
    case .aprobacion:
      foto.fase = .pensando
      foto.aprobacion = AprobacionEnLaBarra(
        descripcion: "Dilo quiere crear una nota en Apple Notas",
        detalle: "Llamar a Marta el lunes por la cotización de las banderas"
      )
    case .destinos:
      foto.verDestinos = true
    }
    return foto
  }
}

/// Lo que se puede apretar en la barra. Vacío de fábrica: el arnés y el
/// render la dibujan con los botones apagados.
struct AccionesDeLaLlamada {
  var silenciar: () -> Void = {}
  var colgar: () -> Void = {}
  var alternarTranscripcion: () -> Void = {}
  var alternarAjustes: () -> Void = {}
  var elegirModelo: (String) -> Void = { _ in }
  var siguienteVoz: () -> Void = {}
  var siguienteVelocidad: () -> Void = {}
  var siguienteMicrofono: () -> Void = {}
  var alternarDestinos: () -> Void = {}
  var elegirDestino: (String) -> Void = { _ in }
  var aprobar: () -> Void = {}
  var rechazar: () -> Void = {}
}

/// La barra de llamada de la **Conversación**, dentro de la muesca.
///
/// Arriba, en la cabecera, en qué está —te escucho, pensando, hablando— y el
/// modelo que contestó el turno, chico y en gris. Debajo, los controles:
/// silenciar, la transcripción y los ajustes a la izquierda, lo que vas
/// diciendo al medio y colgar a la derecha, en coral. La transcripción y los
/// ajustes se despliegan abajo, a pedido; nunca los dos a la vez.
///
/// Referencia de ideas, no de código: el «Voice Chat» de aicss.dev. La
/// jerarquía y la letra son las del panel del hover (10,5 a 12,5 puntos), y
/// el color va sólo en un detalle: el punto del estado y colgar.
struct BarraDeLlamada: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let foto: FotoDeLaConversacion
  var acciones = AccionesDeLaLlamada()
  /// El alto de la cabecera de la forma: la silueta en reposo
  /// (`HUDNotchGeometry.alturaDeCabecera`).
  let altoDeCabecera: CGFloat

  static let altoDeLosControles = HUDNotchGeometry.altoDeLosControlesDeLaLlamada
  static let altoDelDesplegable = HUDNotchGeometry.altoDelDesplegableDeLaLlamada

  var body: some View {
    VStack(spacing: 0) {
      cabecera
        .frame(height: altoDeCabecera)
      controles
        .frame(height: Self.altoDeLosControles)
      if foto.desplegada {
        Group {
          if let aprobacion = foto.aprobacion {
            aprobar(aprobacion)
          } else if foto.verAjustes {
            ajustes
          } else if foto.verDestinos {
            destinos
          } else {
            transcripcion
          }
        }
        .frame(height: Self.altoDelDesplegable, alignment: .top)
        .transition(.opacity)
      }
    }
    .padding(.horizontal, 14)
    .foregroundStyle(.white)
  }

  // La cabecera

  private var cabecera: some View {
    HStack(spacing: 6) {
      indicador
      Text(foto.aviso ?? textoDelEstado)
        .contentTransition(.opacity)
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(foto.aviso == nil ? .white.opacity(0.92) : PaletaDeDilo.actual.aviso.color)
        .lineLimit(1)
      Spacer(minLength: 8)
      if let costo = foto.costo {
        Text(costo)
          .font(.system(size: 9.5, weight: .medium, design: .rounded).monospacedDigit())
          .foregroundStyle(.white.opacity(0.4))
      }
      if let modelo = foto.modelo {
        Text(modelo)
          .font(.system(size: 9.5, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.62))
          .padding(.horizontal, 6)
          .frame(height: 15)
          .background(Capsule().fill(.white.opacity(0.1)))
          .accessibilityLabel(Text("Contestó \(modelo)"))
      }
    }
    .padding(.top, 2)
  }

  private var textoDelEstado: String {
    if foto.aprobacion != nil { return String(localized: "Espera tu clic") }
    if let herramienta = foto.herramienta { return herramienta }
    if foto.silenciada { return String(localized: "Silenciado") }
    switch foto.fase {
    case .escuchando: return String(localized: "Te escucho")
    case .pensando: return String(localized: "Pensando…")
    case .hablando: return String(localized: "Hablando")
    }
  }

  /// El punto del estado: crece con tu voz mientras escucha, y un ícono que
  /// se mueve mientras piensa o habla. Con Reducir movimiento, quieto.
  @ViewBuilder private var indicador: some View {
    let paleta = PaletaDeDilo.actual
    if foto.silenciada {
      Image(systemName: "mic.slash.fill")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(paleta.aviso.color)
    } else {
      switch foto.fase {
      case .escuchando:
        Circle()
          .fill(paleta.acento.color)
          .frame(width: 7, height: 7)
          .scaleEffect(1 + CGFloat(min(max(foto.nivel, 0), 1)) * 0.7)
          .frame(width: 12, height: 12)
      case .pensando:
        Image(systemName: "ellipsis")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(paleta.acento.color)
          .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
      case .hablando:
        Image(systemName: "speaker.wave.2.fill")
          .font(.system(size: 9.5, weight: .semibold))
          .foregroundStyle(paleta.acento.color)
          .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
      }
    }
  }

  // Los controles

  private var controles: some View {
    HStack(spacing: 6) {
      boton(
        foto.silenciada ? "mic.slash.fill" : "mic.fill",
        encendido: foto.silenciada,
        tinte: foto.silenciada ? PaletaDeDilo.actual.aviso.color : nil,
        etiqueta: foto.silenciada ? String(localized: "Volver a escuchar") : String(localized: "Silenciar"),
        accion: acciones.silenciar
      )
      boton(
        "text.bubble",
        encendido: foto.verTranscripcion,
        etiqueta: foto.verTranscripcion
          ? String(localized: "Esconder la transcripción") : String(localized: "Ver la transcripción"),
        accion: acciones.alternarTranscripcion
      )
      boton(
        "slider.horizontal.3",
        encendido: foto.verAjustes,
        etiqueta: foto.verAjustes
          ? String(localized: "Esconder los ajustes") : String(localized: "Voz, velocidad, modelo y micrófono"),
        accion: acciones.alternarAjustes
      )
      destino
      // Lo que vas diciendo, recortado por la izquierda para que nunca se
      // pierda el final, como la línea del dictado.
      Text(foto.parcial)
        .font(.system(size: 11, weight: .regular, design: .rounded).italic())
        .foregroundStyle(.white.opacity(0.62))
        .lineLimit(1)
        .truncationMode(.head)
        .frame(maxWidth: .infinity, alignment: .trailing)
      colgar
    }
  }

  /// A quién se le habla, y el menú para cambiarlo: abre los agentes abajo,
  /// como los ajustes. Sin menú de AppKit: la muesca nunca toma el teclado.
  private var destino: some View {
    Button(action: acciones.alternarDestinos) {
      HStack(spacing: 3) {
        Text(foto.agente)
          .lineLimit(1)
        Image(systemName: foto.verDestinos ? "chevron.up" : "chevron.down")
          .font(.system(size: 7.5, weight: .bold))
          .foregroundStyle(.white.opacity(0.45))
      }
      .font(.system(size: 10.5, weight: .semibold, design: .rounded))
      .foregroundStyle(.white.opacity(0.88))
      .padding(.horizontal, 8)
      .frame(height: 22)
      .fixedSize()
      .background(Capsule().fill(.white.opacity(foto.verDestinos ? 0.18 : 0.08)))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text("Hablándole a \(foto.agente). Cambiar a quién le hablas"))
    .help(Text("A quién le hablas"))
  }

  private var colgar: some View {
    Button(action: acciones.colgar) {
      HStack(spacing: 4) {
        Image(systemName: "phone.down.fill")
          .font(.system(size: 9.5, weight: .bold))
        Text("Colgar")
          .font(.system(size: 10.5, weight: .semibold, design: .rounded))
      }
      .padding(.horizontal, 9)
      .frame(height: 22)
      .background(Capsule().fill(PaletaDeDilo.actual.error.color.opacity(0.85)))
      .foregroundStyle(.white)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text("Colgar la conversación"))
    .help(Text("Colgar la conversación"))
  }

  private func boton(
    _ simbolo: String,
    encendido: Bool,
    tinte: Color? = nil,
    etiqueta: String,
    accion: @escaping () -> Void
  ) -> some View {
    Button(action: accion) {
      Image(systemName: simbolo)
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(tinte ?? .white.opacity(encendido ? 0.95 : 0.7))
        .frame(width: 24, height: 22)
        .background(
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(.white.opacity(encendido ? 0.18 : 0.08))
        )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(etiqueta))
    .help(Text(etiqueta))
  }

  // Lo desplegado

  /// Las últimas líneas de lo conversado, de la más vieja a la más nueva.
  private var transcripcion: some View {
    // El nombre de quien habla cabe en 26 puntos mientras son «Tú» y
    // «Dilo»; con otro agente en la llamada, el rótulo se ensancha.
    let anchoDelNombre: CGFloat = foto.lineas.suffix(3).contains { ($0.quien?.count ?? 0) > 4 } ? 70 : 26
    return VStack(alignment: .leading, spacing: 3) {
      if foto.lineas.isEmpty {
        Text("Lo que conversen aparece acá. No se guarda.")
          .font(.system(size: 10.5, design: .rounded))
          .foregroundStyle(.white.opacity(0.45))
      }
      ForEach(foto.lineas.suffix(3)) { linea in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(linea.quien ?? (linea.deDilo ? "Dilo" : String(localized: "Tú")))
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(linea.deDilo ? PaletaDeDilo.actual.acento.color : .white.opacity(0.5))
            .lineLimit(1)
            .frame(width: anchoDelNombre, alignment: .leading)
          Text(linea.texto)
            .font(.system(size: linea.nota ? 10.5 : 11, design: .rounded).italic(linea.nota))
            .foregroundStyle(.white.opacity(linea.nota ? 0.45 : (linea.deDilo ? 0.9 : 0.72)))
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 4)
  }

  /// Modelo, voz, velocidad y micrófono, cada uno a un clic: chips que se
  /// eligen o que pasan a la opción siguiente. Sin menús: la ventana de la
  /// muesca nunca toma el teclado.
  private var ajustes: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 4) {
        rotulo("Modelo")
        ForEach(foto.modelos) { opcion in
          Button { acciones.elegirModelo(opcion.id) } label: {
            Text(opcion.titulo)
              .font(.system(size: 10.5, weight: opcion.elegida ? .semibold : .regular, design: .rounded))
              .foregroundStyle(.white.opacity(opcion.elegida ? 0.95 : 0.6))
              .padding(.horizontal, 7)
              .frame(height: 18)
              .background(Capsule().fill(.white.opacity(opcion.elegida ? 0.18 : 0)))
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(opcion.elegida ? .isSelected : [])
        }
      }
      HStack(spacing: 4) {
        rotulo("Voz")
        chip(foto.voz, accion: acciones.siguienteVoz, etiqueta: String(localized: "Otra voz"))
        rotulo("Velocidad")
        chip(foto.velocidad, accion: acciones.siguienteVelocidad, etiqueta: String(localized: "Otra velocidad"))
      }
      HStack(spacing: 4) {
        rotulo("Micrófono")
        chip(foto.microfono, accion: acciones.siguienteMicrofono, etiqueta: String(localized: "Otro micrófono"))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 3)
  }

  /// Lo que un agente quiere hacer y espera un clic: qué, el detalle y los
  /// dos botones. No se dice en voz alta como pregunta: la voz no aprueba.
  private func aprobar(_ aprobacion: FotoDeLaConversacion.AprobacionEnLaBarra) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        Image(systemName: "hand.raised.fill")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(PaletaDeDilo.actual.acento.color)
        Text(aprobacion.descripcion)
          .font(.system(size: 11.5, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.95))
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Text(aprobacion.detalle)
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(.white.opacity(0.55))
        .lineLimit(1)
        .truncationMode(.middle)
      HStack(spacing: 6) {
        Spacer(minLength: 0)
        Button(action: acciones.rechazar) {
          Text("No")
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .padding(.horizontal, 12)
            .frame(height: 20)
            .background(Capsule().fill(.white.opacity(0.12)))
            .foregroundStyle(.white.opacity(0.9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("No aprobar"))
        Button(action: acciones.aprobar) {
          Text("Aprobar")
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .padding(.horizontal, 12)
            .frame(height: 20)
            .background(Capsule().fill(PaletaDeDilo.actual.acento.color.opacity(0.85)))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Aprobar: \(aprobacion.descripcion)"))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 4)
    .accessibilityElement(children: .contain)
  }

  /// Los agentes, a un clic cada uno: el elegido recibe lo que digas sin
  /// nombre. Decir el nombre al principio también sirve.
  private var destinos: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 4) {
        rotulo("Agente")
        ForEach(foto.agentes) { opcion in
          Button { acciones.elegirDestino(opcion.id) } label: {
            Text(opcion.titulo)
              .font(.system(size: 10.5, weight: opcion.elegida ? .semibold : .regular, design: .rounded))
              .foregroundStyle(.white.opacity(opcion.elegida ? 0.95 : 0.6))
              .lineLimit(1)
              .padding(.horizontal, 7)
              .frame(height: 18)
              .fixedSize()
              .background(Capsule().fill(.white.opacity(opcion.elegida ? 0.18 : 0)))
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(opcion.elegida ? .isSelected : [])
        }
      }
      Text("También sirve decir su nombre al principio: «Switchboard, ¿qué tengo hoy?».")
        .font(.system(size: 10, design: .rounded))
        .foregroundStyle(.white.opacity(0.42))
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 3)
  }

  private func rotulo(_ texto: LocalizedStringKey) -> some View {
    Text(texto)
      .font(.system(size: 9.5, weight: .medium, design: .rounded))
      .foregroundStyle(.white.opacity(0.42))
      .frame(width: 52, alignment: .leading)
  }

  private func chip(_ valor: String, accion: @escaping () -> Void, etiqueta: String) -> some View {
    Button(action: accion) {
      HStack(spacing: 3) {
        Text(valor)
          .lineLimit(1)
          .truncationMode(.middle)
        Image(systemName: "chevron.right")
          .font(.system(size: 7.5, weight: .bold))
          .foregroundStyle(.white.opacity(0.4))
      }
      .font(.system(size: 10.5, weight: .medium, design: .rounded))
      .foregroundStyle(.white.opacity(0.85))
      .padding(.horizontal, 7)
      .frame(height: 18)
      .fixedSize()
      .background(Capsule().fill(.white.opacity(0.08)))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(verbatim: "\(etiqueta): \(valor)"))
    .help(Text(etiqueta))
  }
}
