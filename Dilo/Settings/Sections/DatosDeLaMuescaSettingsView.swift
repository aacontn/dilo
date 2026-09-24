import DiloCapabilities
import AppKit
import DiloConsumo
import SwiftUI

/// La sección «Datos en la muesca»: qué se puede tener a la vista a los
/// costados de la muesca, cómo se activa cada cosa y de dónde sale.
///
/// Nace del pedido del 2026-09-23 —«hay que poner en las configuraciones cómo
/// configurar y activar»—: hasta entonces los datos se elegían con dos pickers
/// en un rincón de Apariencia que no decían de dónde salía cada dato, si en
/// este Mac había de dónde sacarlo, ni qué pasaba con la sesión de Claude.
///
/// Arriba, qué es y una vista previa con los datos elegidos; abajo, **una
/// tarjeta por fuente**: si se detectó en vivo, el interruptor, el costado,
/// qué se lee y de dónde. Lo que se detecta lo calcula `DeteccionDeFuentes`,
/// que es puro y se prueba con `swift test`; esta vista sólo lo dibuja.
///
/// Gemini no tiene tarjeta, a propósito: una tarjeta «Próximamente» es un
/// panel que no puede hacer nada, y en Ajustes lo que no se puede hacer se
/// esconde (`SettingsSection.isAvailable`). Qué le falta para entrar está en
/// `docs/design/datos-en-la-muesca.md`.
struct DatosDeLaMuescaSettingsView: View {
  @Bindable var settings: AppSettings
  /// Lo detectado, fijo. Nil en la app, que detecta en vivo; los renders lo
  /// fijan para mostrar cada estado sin depender del disco de nadie.
  var estadosFijos: [DatoDeLaMuesca: EstadoDeLaFuente]?
  /// Si este anfitrión puede leer las carpetas de otras apps. Se inyecta por
  /// lo mismo.
  var admiteIA = Anfitrion.actual.admite(.consumoDeIADeOtrasApps)
  /// Deja la vista previa con el panel del hover abierto: para los renders.
  var previaAbierta: Bool?

  @State private var estadosDetectados: [DatoDeLaMuesca: EstadoDeLaFuente] = [:]

  /// Cada cuánto se vuelve a mirar el disco mientras la sección está abierta:
  /// lo bastante seguido para que instalar Claude Code con Ajustes abierto se
  /// vea sin cerrar nada, y lo bastante lento para no gastar nada.
  static let cadenciaDeLaDeteccion: Duration = .seconds(4)

  private var estados: [DatoDeLaMuesca: EstadoDeLaFuente] {
    estadosFijos ?? estadosDetectados
  }

  private var disponible: (DatoDeLaMuesca) -> Bool {
    let admite = admiteIA
    return { !$0.leeArchivosDeOtraApp || admite }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      (admiteIA
        ? Text("A los costados de la muesca puedes tener a la vista tu consumo de IA y cómo va el Mac. Al pasar el mouse, la muesca abre el detalle.")
        : Text("A los costados de la muesca puedes tener a la vista cómo va el Mac. Al pasar el mouse, la muesca abre el detalle."))
      .font(.system(size: 13))
      .foregroundStyle(.white.opacity(0.7))
      .fixedSize(horizontal: false, vertical: true)

      VistaPreviaDeLosDatos(settings: settings, disponible: disponible, encimaFijo: previaAbierta)

      ForEach(DatoDeLaMuesca.fuentes, id: \.self) { dato in
        TarjetaDeFuente(
          dato: dato,
          estado: estados[dato] ?? (disponible(dato) ? .listo : .noDisponibleEnEstaVersion),
          disponible: disponible,
          settings: settings
        )
      }

      if admiteIA {
        SettingsCard(title: "Avisos") {
          SettingsRow(
            title: "Avisar cerca del límite",
            description: "Cuando Codex o el plan de Claude pasan el 80 % y el 95 % de una ventana, la muesca se abre un momento a decírtelo. Una vez por umbral, y nunca mientras dictas."
          ) {
            Toggle("", isOn: $settings.hudAvisosDeLimite)
              .labelsHidden()
              .toggleStyle(.switch)
          }
        }
      }

      PanelDelHoverSettings(settings: settings)
    }
    .task(id: estadosFijos == nil) {
      guard estadosFijos == nil else { return }
      let deteccion = DeteccionDeFuentes(admiteArchivosDeOtrasApps: admiteIA)
      while !Task.isCancelled {
        estadosDetectados = await Task.detached(priority: .utility) {
          Dictionary(uniqueKeysWithValues: DatoDeLaMuesca.fuentes.map { ($0, deteccion.estado(de: $0)) })
        }.value
        try? await Task.sleep(for: Self.cadenciaDeLaDeteccion)
      }
    }
  }
}

// MARK: - La vista previa

/// La muesca de verdad —la misma vista que dibuja el escenario— en reposo y a
/// tamaño real, con valores de ejemplo en los costados elegidos. Al pasar el
/// mouse abre el panel del hover con el detalle, que es lo mismo que hace la
/// muesca.
struct VistaPreviaDeLosDatos: View {
  let settings: AppSettings
  let disponible: (DatoDeLaMuesca) -> Bool
  /// Deja el panel del hover abierto sin mouse: para los renders.
  var encimaFijo: Bool?

  @State private var encima = false

  /// El contenido se arma de nuevo en cada dibujo, y no en una `.task`: es
  /// barato, no guarda nada que haya que conservar, y así la vista previa
  /// sale igual en un render fuera de pantalla, donde las tareas no corren.
  private var content: DictationHUDContent {
    let content = DictationHUDContent()
    Self.posar(
      content,
      izquierdo: izquierdo,
      derecho: derecho,
      conPlan: settings.hudPorcentajeDeClaude,
      encima: encimaFijo ?? encima
    )
    return content
  }

  private var izquierdo: DatoDeLaMuesca {
    settings.hudDisposicion.dato(en: .izquierdo, disponible: disponible)
  }

  private var derecho: DatoDeLaMuesca {
    settings.hudDisposicion.dato(en: .derecho, disponible: disponible)
  }

  private var llevaDatos: Bool { izquierdo != .ninguno || derecho != .ninguno }

  private var pantalla: HUDScreenSnapshot {
    var pantalla = HUDPreviewScreen.notched
    pantalla.anchoDeLosLados = llevaDatos ? HUDNotchGeometry.anchoDeUnLado : 0
    return pantalla
  }

  var body: some View {
    SettingsPreviewStage(
      title: "Así se ve",
      subtitle: llevaDatos
        ? "Con valores de ejemplo. Pasa el mouse por encima para ver el detalle."
        : "Enciende un dato abajo y aparece acá.",
      escala: 1,
      altoDeLaPantalla: 112
    ) {
      DictationHUDShellView(
        screen: pantalla,
        settings: settings.sessionSettings,
        content: content
      )
    }
    .onHover { encima = $0 }
  }

  /// Deja el contenido en reposo con los datos de ejemplo. Estático para que
  /// los renders lo posen igual que la sección.
  @MainActor
  static func posar(
    _ content: DictationHUDContent,
    izquierdo: DatoDeLaMuesca,
    derecho: DatoDeLaMuesca,
    conPlan: Bool,
    encima: Bool,
    ahora: Date = Date()
  ) {
    content.estado = .reposo
    content.datoIzquierdo = ejemplo(izquierdo, conPlan: conPlan, ahora: ahora)
    content.datoDerecho = ejemplo(derecho, conPlan: conPlan, ahora: ahora)
    content.contexto = encima ? String(localized: "Tu último dictado") : nil
    content.punteroEncima = encima
  }

  /// Un valor creíble para cada dato, con su detalle.
  static func ejemplo(_ dato: DatoDeLaMuesca, conPlan: Bool, ahora: Date) -> LadoDeLaMuesca? {
    func ventana(_ porcentaje: Double? = nil, tokens: Int? = nil, en minutos: Double, horas: Double = 5) -> VentanaDeUso {
      VentanaDeUso(
        porcentaje: porcentaje,
        tokens: tokens,
        seReiniciaEn: ahora.addingTimeInterval(minutos * 60),
        duracion: horas * 3600
      )
    }
    switch dato {
    case .ninguno:
      return nil
    case .claude:
      let tokens = ConsumoDeIA(ventanaCorta: ventana(tokens: 1_240_000, en: 131))
      let plan = conPlan ? ConsumoDeIA(ventanaCorta: ventana(42, en: 131)) : nil
      let visible = (plan ?? tokens).ventanaCorta
      return LadoDeLaMuesca(
        dato: dato,
        valor: TextoDelDato.valor(visible) ?? "–",
        nivel: visible.porcentaje,
        detalle: DetalleDelDato.claude(tokens: tokens, plan: plan, ahora: ahora)
      )
    case .codex:
      let consumo = ConsumoDeIA(
        ventanaCorta: ventana(35, en: 134),
        ventanaSemanal: ventana(12, en: 4 * 24 * 60 + 260, horas: 168)
      )
      return LadoDeLaMuesca(
        dato: dato,
        valor: "35%",
        nivel: 35,
        detalle: DetalleDelDato.codex(consumo, ahora: ahora)
      )
    case .cpu:
      return LadoDeLaMuesca(dato: dato, valor: "23%", nivel: 23, detalle: DetalleDelDato.sistema(23))
    case .ram:
      return LadoDeLaMuesca(dato: dato, valor: "64%", nivel: 64, detalle: DetalleDelDato.sistema(64))
    case .gpu:
      return LadoDeLaMuesca(dato: dato, valor: "18%", nivel: 18, detalle: DetalleDelDato.sistema(18))
    case .red:
      let red = VelocidadDeRed(baja: 1_240_000, sube: 86_000)
      return LadoDeLaMuesca(dato: dato, valor: "1,2M", nivel: nil, detalle: DetalleDelDato.red(red))
    case .disco:
      let disco = EspacioEnDisco(ocupado: 71, libre: 142_000_000_000)
      return LadoDeLaMuesca(dato: dato, valor: "71%", nivel: 71, detalle: DetalleDelDato.disco(disco))
    }
  }
}

// MARK: - Una tarjeta por fuente

private struct TarjetaDeFuente: View {
  let dato: DatoDeLaMuesca
  let estado: EstadoDeLaFuente
  let disponible: (DatoDeLaMuesca) -> Bool
  @Bindable var settings: AppSettings

  private var encendido: Binding<Bool> {
    Binding(
      // Lo que este anfitrión no puede leer se ve apagado aunque haya quedado
      // encendido de antes: no ocupa costado (`DisposicionDeLaMuesca`).
      get: { sePuede && settings.hudDisposicion.costado(de: dato) != nil },
      set: { enciende in
        if enciende {
          settings.hudDisposicion.encender(dato, disponible: disponible)
        } else {
          settings.hudDisposicion.apagar(dato)
        }
      }
    )
  }

  private var costado: Binding<CostadoDeLaMuesca> {
    Binding(
      get: { settings.hudDisposicion.costado(de: dato) ?? .izquierdo },
      set: { settings.hudDisposicion.mover(dato, a: $0) }
    )
  }

  private var sePuede: Bool { estado != .noDisponibleEnEstaVersion }

  var body: some View {
    SettingsCard(title: DatosDeLaMuescaCopy.titulo(dato)) {
      SettingsRow(title: "Mostrar en la muesca", description: DatosDeLaMuescaCopy.queSeLee(dato)) {
        HStack(spacing: 12) {
          EtiquetaDeEstado(estado: estado)
          Toggle("", isOn: encendido)
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(!sePuede)
            .accessibilityLabel(Text(DatosDeLaMuescaCopy.titulo(dato)))
        }
      }

      switch estado {
      case .listo:
        EmptyView()
      case .noEncontrado:
        NotaDeLaTarjeta(icono: "magnifyingglass", texto: DatosDeLaMuescaCopy.comoConseguirlo(dato))
      case .noDisponibleEnEstaVersion:
        NotaDeLaTarjeta(icono: "lock", texto: DatosDeLaMuescaCopy.porQueNoEnAppStore(dato))
      }

      if sePuede, encendido.wrappedValue {
        SettingsRow(title: "Costado", description: "Cada costado lleva un dato.") {
          Picker("Costado", selection: costado) {
            Text("Izquierda").tag(CostadoDeLaMuesca.izquierdo)
            Text("Derecha").tag(CostadoDeLaMuesca.derecho)
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .frame(width: 170)
        }

        if let ocupa = settings.hudDisposicion.quienOcupa(elLugarDe: dato, disponible: disponible) {
          NotaDeLaTarjeta(
            icono: "exclamationmark.triangle.fill",
            texto: DatosDeLaMuescaCopy.noCabe(
              en: costado.wrappedValue,
              ocupa: ocupa,
              elOtroLleno: settings.hudDisposicion.dato(en: costado.wrappedValue.otro, disponible: disponible) != .ninguno
            ),
            color: DiloBrand.mango
          )
        }

        if dato == .claude {
          PorcentajeDelPlanDeClaude(settings: settings)
        }
      }
    }
  }
}

/// La sub-opción del plan de Claude, con la regla de las credenciales dicha
/// entera (`docs/design/datos-en-la-muesca.md`) y «Probar ahora».
private struct PorcentajeDelPlanDeClaude: View {
  @Bindable var settings: AppSettings

  @State private var probando = false
  @State private var resultado: DatosDeLaMuescaCopy.Prueba?

  var body: some View {
    SettingsRow(
      title: "Porcentaje de tu plan (opcional)",
      description: "Sin esto, Claude muestra los tokens de las últimas cinco horas, contados de sus archivos. Con esto, Dilo lee la sesión de Claude Code que guarda el Llavero y le pregunta tu porcentaje a api.anthropic.com. No la guarda, no la renueva y no la manda a nadie más. macOS te va a pedir permiso del Llavero una vez."
    ) {
      Toggle("", isOn: $settings.hudPorcentajeDeClaude)
        .labelsHidden()
        .toggleStyle(.switch)
        .accessibilityLabel(Text("Porcentaje de tu plan (opcional)"))
    }

    if settings.hudPorcentajeDeClaude {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Button(probando ? "Preguntando a Anthropic…" : "Probar ahora") { probar() }
          .disabled(probando)
        if let resultado {
          Text(resultado.texto)
            .font(.caption)
            .foregroundStyle(resultado.salioBien ? DiloBrand.menta : .white.opacity(0.72))
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .padding(.vertical, 12)
    }
  }

  private func probar() {
    probando = true
    resultado = nil
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    let cliente = ClienteDeUsoDeClaude(agente: "Dilo/\(version)")
    Task {
      let ahora = Date()
      do {
        resultado = .init(consumo: try await cliente.leer(ahora: ahora), ahora: ahora)
      } catch {
        resultado = .init(falla: .de(error), ahora: ahora)
      }
      probando = false
    }
  }
}

// MARK: - Piezas

/// Listo, No encontrado, No disponible en esta versión: un punto de color y
/// la palabra.
private struct EtiquetaDeEstado: View {
  let estado: EstadoDeLaFuente

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)
      Text(DatosDeLaMuescaCopy.estado(estado))
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.7))
        .lineLimit(1)
    }
    .fixedSize()
    .accessibilityElement(children: .combine)
  }

  private var color: Color {
    switch estado {
    case .listo: DiloBrand.menta
    case .noEncontrado: DiloBrand.mango
    case .noDisponibleEnEstaVersion: .white.opacity(0.35)
    }
  }
}

/// Una línea de ayuda dentro de una tarjeta: cómo conseguir el dato, por qué
/// no está, o que no cabe.
private struct NotaDeLaTarjeta: View {
  let icono: String
  let texto: String
  var color: Color = .white.opacity(0.55)

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: icono)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(color)
      Text(texto)
        .font(.caption)
        .foregroundStyle(.white.opacity(0.66))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.vertical, 11)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(.white.opacity(0.07))
        .frame(height: 1)
    }
  }
}

// MARK: - El copy

/// Todo lo que la sección dice, en un solo lugar y puro, para que un test lo
/// afirme sin dibujar.
enum DatosDeLaMuescaCopy {
  static func titulo(_ dato: DatoDeLaMuesca) -> LocalizedStringKey {
    switch dato {
    case .claude: "Claude Code"
    case .codex: "Codex"
    case .cpu: "CPU"
    case .ram: "Memoria"
    case .gpu: "GPU"
    case .red: "Red"
    case .disco: "Disco"
    case .ninguno: ""
    }
  }

  /// Qué se lee y de dónde, en una línea y sin jerga.
  static func queSeLee(_ dato: DatoDeLaMuesca) -> LocalizedStringKey {
    switch dato {
    case .claude: "Tus registros de Claude Code en este Mac: los tokens de tus últimas cinco horas. Nada sale de acá."
    case .codex: "Tus registros de Codex en este Mac: cuánto llevas de tu límite de cinco horas y del semanal. Nada sale de acá."
    case .cpu: "Cuánto trabaja el procesador de todo el Mac, como lo mide Monitor de Actividad. Nada sale de acá."
    case .ram: "Cuánta memoria está ocupando todo el Mac. Nada sale de acá."
    case .gpu: "Cuánto trabaja la tarjeta gráfica, como lo mide Monitor de Actividad. Nada sale de acá."
    case .red: "Cuánto está bajando tu conexión ahora; al pasar el mouse, también lo que sube. Nada sale de acá."
    case .disco: "Cuánto del disco de arranque está ocupado y cuánto queda libre. Nada sale de acá."
    case .ninguno: ""
    }
  }

  static func estado(_ estado: EstadoDeLaFuente) -> String {
    switch estado {
    case .listo: String(localized: "Listo para usar")
    case .noEncontrado: String(localized: "No encontrado")
    case .noDisponibleEnEstaVersion: String(localized: "No disponible en esta versión")
    }
  }

  static func comoConseguirlo(_ dato: DatoDeLaMuesca) -> String {
    switch dato {
    case .claude:
      String(localized: "Instala Claude Code y úsalo una vez; Dilo lee sus registros locales, sin clave.")
    case .codex:
      String(localized: "Instala Codex CLI y úsalo una vez; Dilo lee sus registros locales, sin clave.")
    case .cpu, .ram, .gpu, .red, .disco, .ninguno:
      ""
    }
  }

  static func porQueNoEnAppStore(_ dato: DatoDeLaMuesca) -> String {
    String(localized: "La versión de App Store no puede leer las carpetas de otras apps: el sandbox de Apple no lo deja. La versión que se descarga directo sí.")
  }

  /// Lo que no cabe se dice, con quién le ocupa el lugar y qué hacer.
  static func noCabe(en costado: CostadoDeLaMuesca, ocupa: DatoDeLaMuesca, elOtroLleno: Bool) -> String {
    let nombre = TextoDelDato.etiqueta(ocupa)
    switch (costado, elOtroLleno) {
    case (.izquierdo, false):
      return String(localized: "No cabe: a la izquierda ya va \(nombre). Elige la derecha o apaga \(nombre).")
    case (.derecho, false):
      return String(localized: "No cabe: a la derecha ya va \(nombre). Elige la izquierda o apaga \(nombre).")
    case (.izquierdo, true):
      return String(localized: "No cabe: a la izquierda ya va \(nombre) y la derecha también está ocupada. Apaga uno de los dos para ver este.")
    case (.derecho, true):
      return String(localized: "No cabe: a la derecha ya va \(nombre) y la izquierda también está ocupada. Apaga uno de los dos para ver este.")
    }
  }

  /// Lo que dice «Probar ahora»: la cifra, o la falla en palabras.
  struct Prueba: Equatable {
    let texto: String
    let salioBien: Bool

    init(consumo: ConsumoDeIA, ahora: Date) {
      let ventana = consumo.ventanaCorta.vigente(en: ahora)
      let valor = TextoDelDato.porcentaje(ventana.porcentaje ?? 0)
      if let reinicio = ventana.seReiniciaEn {
        let falta = TextoDelDato.faltaPara(reinicio, desde: ahora)
        texto = String(localized: "Listo: vas en \(valor) de tus cinco horas. Se reinicia en \(falta).")
      } else {
        texto = String(localized: "Listo: vas en \(valor) de tus cinco horas.")
      }
      salioBien = true
    }

    init(falla: ClienteDeUsoDeClaude.Falla, ahora: Date) {
      salioBien = false
      switch falla {
      case .sinSesion:
        texto = String(localized: "No encontré tu sesión de Claude Code en el Llavero, o no diste permiso para leerla. Inicia sesión en Claude Code y vuelve a probar.")
      case .sesionVencida:
        texto = String(localized: "Tu sesión de Claude Code venció. Abre Claude Code para que renueve su sesión.")
      case .esperar(let hasta):
        let falta = TextoDelDato.faltaPara(hasta, desde: ahora)
        texto = String(localized: "Anthropic pidió esperar. Vuelve a probar en \(falta).")
      case .respuesta(let codigo):
        texto = String(localized: "Anthropic respondió con un error (\(codigo)). Vuelve a probar más tarde.")
      case .formato:
        texto = String(localized: "Anthropic respondió algo que Dilo no entiende. Puede que haya cambiado su API.")
      case .sinRed:
        texto = String(localized: "No se pudo llegar a api.anthropic.com. Revisa tu conexión y vuelve a probar.")
      }
    }
  }
}


// MARK: - El panel del hover

/// Qué más abre el hover, además del detalle de los datos: lo último que
/// copiaste, la próxima reunión y los modos (2026-09-24).
private struct PanelDelHoverSettings: View {
  @Bindable var settings: AppSettings
  @State private var sinPermisoDeCalendario = LectorDelCalendario.permisoNegado

  var body: some View {
    SettingsCard(title: "Al pasar el mouse") {
      SettingsRow(
        title: "Lo último que copias",
        description: "Junto a tus dictados, lo último que copiaste, para volver a copiarlo con un clic. Lo que un gestor de contraseñas marca como secreto no entra, y nada se guarda al cerrar Dilo."
      ) {
        Toggle("", isOn: $settings.hudRecientesDelPortapapeles)
          .labelsHidden()
          .toggleStyle(.switch)
      }

      SettingsRow(
        title: "Próxima reunión",
        description: "La próxima reunión de tu calendario, y «Unirse» si trae un enlace de Zoom, Meet o Teams. Dilo te va a pedir permiso para leer el calendario."
      ) {
        Toggle("", isOn: reunion)
          .labelsHidden()
          .toggleStyle(.switch)
      }
      if sinPermisoDeCalendario {
        HStack(spacing: 8) {
          Text("Sin permiso para leer el calendario.")
            .font(.system(size: 12))
            .foregroundStyle(DiloBrand.mango)
          Button("Abrir Ajustes del Sistema") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
              NSWorkspace.shared.open(url)
            }
          }
          .buttonStyle(.link)
          .font(.system(size: 12))
        }
      }

      if Anfitrion.actual.admite(.notasDeApple) {
        SettingsRow(
          title: "Nota rápida",
          description: "Un botón «Nota»: dictas y queda en Apple Notas, en la carpeta «Dilo», sin abrir ninguna app. Termínala con tu tecla de dictado. La primera vez macOS te pide permiso para que Dilo use Notas."
        ) {
          Toggle("", isOn: $settings.hudNotaRapida)
            .labelsHidden()
            .toggleStyle(.switch)
        }
      }

      SettingsRow(
        title: "Cambiar de modo",
        description: "Tus modos, para elegir con un clic cuál usa el atajo de siempre. «Normal» es el dictado limpio, sin IA."
      ) {
        Toggle("", isOn: $settings.hudModosEnElPanel)
          .labelsHidden()
          .toggleStyle(.switch)
      }
    }
  }

  /// Encender la reunión es lo que pide el permiso: la pregunta de macOS
  /// llega cuando alguien la pidió, no al abrir Dilo.
  private var reunion: Binding<Bool> {
    Binding(
      get: { settings.hudProximaReunion },
      set: { encender in
        guard encender else {
          settings.hudProximaReunion = false
          return
        }
        Task { @MainActor in
          let concedido = LectorDelCalendario.tienePermiso ? true : await LectorDelCalendario().pedirPermiso()
          settings.hudProximaReunion = concedido
          sinPermisoDeCalendario = !concedido
        }
      }
    )
  }
}
