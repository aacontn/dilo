import DiloModes
import SwiftUI

/// Claude: la clave de Anthropic y lo que Claude hace en Dilo, tarea por
/// tarea, con su modelo y lo que cuesta.
///
/// Alfonso, 2026-10-19: juntar lo que estaba desparramado. La clave vivía en
/// Modos → Proveedor general → Anthropic → API key; quién traduce, en
/// Dictado → Idiomas; los modelos para revisar y ordenar, en Tus palabras.
/// Ahora viven acá y esas secciones enlazan a esta en vez de repetir campos.
/// La clave sigue siendo **una**, la del proveedor Anthropic de los modos
/// (`proveedor.anthropic` en el Llavero), y sirve para todo.
struct ClaudeSettingsView: View {
  @Bindable var settings: AppSettings
  let runtimeState: SettingsRuntimeState

  @Environment(\.colorSchemeContrast) private var contrast
  @State private var probando = false
  @State private var resultado: PruebaDeConexion.Resultado?
  /// «Otro…» en el modelo de los modos: aparece el campo para escribir el id.
  @State private var escribiendoOtro = false

  /// Lo que el selector guarda al elegir «Otro…». Nunca es un id.
  private static let otro = "otro"

  private var cuenta: String { SettingsRuntimeState.cuentaDeAnthropic }
  private var hayClave: Bool { runtimeState.hayClaveDeAnthropic }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsCard(
        title: "Tu clave de Anthropic",
        icono: "key.fill",
        detalle: "Una sola clave para los modos, traducir y aprender. Se cobra a tu cuenta de Anthropic."
      ) {
        SettingsRow(
          title: "Clave de Anthropic",
          description: "Se guarda en el Llavero de macOS y no se vuelve a mostrar. Dilo no la escribe en ningún archivo ni en el registro."
        ) {
          CampoDeClave(cuenta: cuenta, claves: runtimeState.claves, ancho: 290)
        }
        .anclaDeAjuste(.claveDeAnthropic)

        SettingsRow(
          title: "Probar conexión",
          description: "Le pregunta a Anthropic si la clave sirve y si Claude Haiku 5.5 está disponible para ella. No genera texto ni cuesta nada, y sólo pasa cuando lo aprietas."
        ) {
          HStack(spacing: 10) {
            if let resultado { etiqueta(resultado) }
            Button(probando ? "Probando…" : "Probar conexión") { Task { await probar() } }
              .buttonStyle(SettingsButtonStyle(compacto: true))
              .disabled(probando || !hayClave)
          }
        }
        .anclaDeAjuste(.probarConexion)
      }

      SettingsCard(
        title: "Qué hace Claude",
        icono: "sparkle",
        detalle: "Cada tarea con su modelo. El dictado sin modo no pasa por ninguna IA."
      ) {
        modos
        traducir
        SettingsRow(
          title: "Que Claude revise y ordene",
          description: "Claude revisa lo que corriges antes de ofrecértelo y de vez en cuando ordena Tus palabras, con deshacer. Sin clave o sin conexión, Dilo aprende como antes, solo."
        ) {
          Toggle("Que Claude revise y ordene", isOn: $settings.aprenderConClaude)
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .anclaDeAjuste(.aprenderConClaude)

        Group {
          SettingsPickerRow(
            title: "Revisar cada corrección",
            description: "\(Self.costo(.revisar, modelo: settings.modeloParaRevisar)) Una pregunta corta después de cada corrección: ¿esto se aprende? Haiku alcanza.",
            options: ModelosDeAnthropic.lista.map(\.id),
            optionLabel: { etiqueta($0, recomendado: ModelosDeAnthropic.deFabricaParaRevisar) },
            selection: $settings.modeloParaRevisar,
            controlWidth: 230
          )
          .anclaDeAjuste(.modeloParaRevisar)

          SettingsPickerRow(
            title: "Ordenar Tus palabras",
            description: "\(Self.costo(.ordenar, modelo: settings.modeloParaOrdenar)) Una vez por semana o tras diez palabras nuevas. Un error ahí se queda pegado: por eso Sonnet.",
            options: ModelosDeAnthropic.lista.map(\.id),
            optionLabel: { etiqueta($0, recomendado: ModelosDeAnthropic.deFabricaParaOrdenar) },
            selection: $settings.modeloParaOrdenar,
            controlWidth: 230
          )
          .anclaDeAjuste(.modeloParaOrdenar)
        }
        .disabled(!settings.aprenderConClaude)
      }

      Text(
        "Qué viaja a Anthropic: el dictado que pasa por un modo o por traducir; al revisar, la palabra corregida con unas ocho palabras alrededor; al ordenar, Tus palabras y «Cuando digo…». Nada de eso queda en el registro del sistema. Los costos son de referencia, con los precios de lista por millón de tokens: Haiku 5.5 US$0,10 de entrada y US$0,50 de salida, Sonnet 5.5 US$2 y US$10, Opus 5.5 US$4 y US$20."
      )
      .font(.caption)
      .foregroundStyle(.white.opacity(contrast == .increased ? 0.7 : 0.45))
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 6)
    }
    .task { await runtimeState.claves.mirar(cuenta) }
    .onChange(of: hayClave) { resultado = nil }
  }

  // Modos

  private var indiceDeAnthropic: Int? {
    settings.proveedores.firstIndex { $0.dialecto == .anthropic && $0.id == Proveedor.anthropicDeFabrica.id }
  }

  private var generalEsAnthropic: Bool {
    settings.proveedores.proveedor(settings.proveedorGeneralID)?.dialecto == .anthropic
  }

  @ViewBuilder
  private var modos: some View {
    if generalEsAnthropic, let indice = indiceDeAnthropic {
      let modelo = settings.proveedores[indice].modelo
      let aMano = escribiendoOtro || ModelosDeAnthropic.conocido(modelo) == nil
      SettingsPickerRow(
        title: "Modos",
        description: "\(Self.costo(.modo, modelo: modelo)) Reescribe lo que dictas con un modo. Haiku es el más rápido, y alcanza.",
        options: ModelosDeAnthropic.lista.map(\.id) + [Self.otro],
        optionLabel: { id in
          id == Self.otro ? String(localized: "Otro…") : etiqueta(id, recomendado: ModelosDeAnthropic.deFabrica)
        },
        selection: Binding(
          get: { aMano ? Self.otro : modelo },
          set: { elegido in
            escribiendoOtro = elegido == Self.otro
            guard elegido != Self.otro else { return }
            settings.proveedores[indice].modelo = elegido
          }
        ),
        controlWidth: 230
      )
      .anclaDeAjuste(.modeloDeLosModos)
      if aMano {
        SettingsRow(title: "Modelo a mano", description: "El id tal cual lo muestra la consola de Anthropic, sin fecha.") {
          TextField(
            "Modelo",
            text: Binding(
              get: { settings.proveedores[indice].modelo },
              set: { settings.proveedores[indice].modelo = $0 }
            )
          )
          .labelsHidden()
          .frame(width: 230)
        }
      }
    } else {
      let general = settings.proveedores.proveedor(settings.proveedorGeneralID)
      SettingsRow(
        title: "Modos",
        description: "Hoy los reescribe \(general?.nombre ?? String(localized: "otro proveedor")). Con Claude, el modo entiende mejor qué pediste; tu dictado viaja a Anthropic."
      ) {
        Button("Usar Claude") {
          settings.proveedorGeneralID = Proveedor.anthropicDeFabrica.id
        }
        .buttonStyle(SettingsButtonStyle(compacto: true))
      }
      .anclaDeAjuste(.modeloDeLosModos)
    }
  }

  // Traducir

  private var traducir: some View {
    SettingsPickerRow(
      title: "Traducir con",
      description: settings.motorDeTraduccion == .apple
        ? "Apple traduce en el Mac: lo que dictas no sale de él, pero más literal."
        : "\(Self.costo(.traducir, modelo: ModelosDeAnthropic.haiku.id)) Claude Haiku 5.5 traduce del español a inglés o chino como alguien nativo. Sin conexión traduce Apple.",
      options: MotorDeTraduccion.allCases,
      optionLabel: { motor in
        switch motor {
        case .claude: String(localized: "Claude (Haiku 5.5)")
        case .apple: String(localized: "Apple, en el Mac")
        }
      },
      selection: Binding(
        get: { MotorDeTraduccion.enElSelector(elegido: settings.motorDeTraduccion, hayClave: hayClave) },
        set: { settings.motorDeTraduccion = $0 }
      ),
      controlWidth: 230
    )
    .anclaDeAjuste(.traducirCon)
  }

  // Piezas

  private func etiqueta(_ id: String, recomendado: ModeloDeAnthropic) -> String {
    let nombre = ModelosDeAnthropic.conocido(id)?.nombre ?? id
    return id == recomendado.id ? String(localized: "\(nombre) (recomendado)") : nombre
  }

  /// «≈ US$0,29 cada mil dictados.», o por vez para ordenar.
  static func costo(_ tarea: CostosDeClaude.Tarea, modelo: String) -> String {
    guard let monto = CostosDeClaude.referencia(tarea, modelo: modelo) else {
      return String(localized: "Un modelo que Dilo no conoce: sin costo de referencia.")
    }
    let dolares = monto.formatted(.number.precision(.significantDigits(2...2)).locale(Locale(identifier: "es_CL")))
    switch tarea {
    case .modo: return String(localized: "≈ US$\(dolares) cada mil dictados con modo.")
    case .traducir: return String(localized: "≈ US$\(dolares) cada mil traducciones.")
    case .revisar: return String(localized: "≈ US$\(dolares) cada mil correcciones.")
    case .ordenar: return String(localized: "≈ US$\(dolares) cada vez que ordena.")
    }
  }

  @ViewBuilder
  private func etiqueta(_ resultado: PruebaDeConexion.Resultado) -> some View {
    switch resultado {
    case .lista:
      Label("Conectado", systemImage: "checkmark.circle.fill")
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(PaletaDeDilo.actual.exito.color)
    case let .falla(falla):
      Label(falla.aviso, systemImage: "exclamationmark.triangle.fill")
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(PaletaDeDilo.actual.aviso.color)
    }
  }

  /// La clave se trae del Llavero fuera del hilo principal, se usa en esta
  /// llamada y se suelta. Sólo pasa al apretar el botón.
  private func probar() async {
    probando = true
    defer { probando = false }
    resultado = nil
    let clave = await runtimeState.claves.secreto(cuenta)
    resultado = await PruebaDeConexion(clave: clave).probar()
  }
}
