import DiloEngines
import SwiftUI

/// La sección Motor: cuál **Motor de voz** convierte la voz en texto, con la
/// misma honestidad de tarjeta que Dilo 0.3.2 — cada motor dice si es LOCAL o
/// EN LÍNEA y qué se gana y qué se paga por elegirlo.
///
/// Los dos de hoy son LOCAL. La etiqueta existe igual porque el tercero del
/// spec (Gemini 3.5 Transcribe) va a ser el primero al que el audio se le va
/// de este Mac, y esa diferencia no se explica cuando llega: se explica desde
/// antes.
struct MotorSettingsView: View {
  @Bindable var settings: AppSettings

  var body: some View {
    VStack(spacing: 16) {
      SelectorDeMotor(settings: settings)

      TusPalabrasEnParakeet(settings: settings)

      SettingsCard(title: "La memoria") {
        SettingsPickerRow(
          title: "Soltar el modelo de la RAM",
          description: "Sin dictar por un rato, Dilo devuelve la memoria. El dictado siguiente lo vuelve a cargar mientras hablas.",
          options: DescargaPorReposo.allCases,
          optionLabel: \.title,
          selection: $settings.descargarModeloTras,
          controlWidth: 170
        )
        .anclaDeAjuste(.soltarElModelo)
      }
    }
  }
}

/// Las tarjetas de motor, la descarga del modelo de Parakeet y el aviso de a
/// qué se cae mientras ese modelo no está.
///
/// Vive aparte de la sección porque el onboarding elige motor con esta misma
/// pantalla: la primera vez y la número cien tienen que verse igual, o los
/// primeros pasos enseñan una app que después no existe.
struct SelectorDeMotor: View {
  @Bindable var settings: AppSettings

  @State private var descargas = DescargaDeParakeet.compartida

  /// Qué motor está elegido, cuál va a dictar de verdad y, si es Parakeet,
  /// cuál de los dos modelos. Elegido y en uso son distintos mientras
  /// Parakeet esté elegido sin ningún modelo en disco, y ésa es justamente la
  /// confusión que Alfonso reportó el 2026-09-22: no podía saber con cuál
  /// estaba dictando.
  private var seleccion: EngineSelection {
    EngineResolver.resolver(
      elegido: settings.motorDeVoz,
      parakeetEnDisco: descargas.enDisco,
      varianteElegida: settings.varianteDeParakeet
    )
  }

  /// La variante que dictaría si el motor es Parakeet, aunque hoy esté
  /// elegido Apple: es la que la tarjeta del modelo marca.
  private var varianteEnUso: VarianteDeParakeet? {
    ResolucionDeParakeet.enUso(enDisco: descargas.enDisco, elegida: settings.varianteDeParakeet)
  }

  var body: some View {
    VStack(spacing: 16) {
      SettingsCard(title: "Motor de voz") {
        ForEach(Array(SpeechEngineKind.allCases.enumerated()), id: \.element) { indice, motor in
          MotorCard(
            motor: motor,
            elegido: settings.motorDeVoz == motor,
            enUso: seleccion.efectivo == motor,
            esUltima: indice == SpeechEngineKind.allCases.count - 1
          ) {
            settings.motorDeVoz = motor
          }
        }
      }
      .anclaDeAjuste(.motorDeVoz)

      SettingsCard(title: "El modelo de Parakeet") {
        // Ultra arriba: es la que se recomienda, y la que una instalación
        // nueva ve primero.
        ForEach([VarianteDeParakeet.ultra, .v3], id: \.self) { variante in
          filaDelModelo(variante)
        }

        if let avance = descargas.progreso {
          VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: avance.fraccion)
              .progressViewStyle(.linear)
              .tint(SettingsTheme.accent)
            Text(verbatim: avance.fase)
              .font(.caption)
              .foregroundStyle(.white.opacity(0.48))
          }
          .padding(.vertical, 12)
        }

        if let error = descargas.error, let fallida = descargas.fallida {
          SettingsRow(title: "No se pudo descargar", description: "\(error)") {
            Button("Reintentar") { bajar(fallida) }
              .buttonStyle(SettingsButtonStyle())
          }
        }

        // Ultra terminó de bajar y v3 quedó sobrando: se ofrece, nunca se
        // borra solo.
        if let sobra = ResolucionDeParakeet.paraBorrar(enDisco: descargas.enDisco, enUso: varianteEnUso),
          let enUso = varianteEnUso
        {
          SettingsRow(
            title: "Ya dictas con \(enUso.nombre)",
            description: "\(String(localized: "\(sobra.nombre) ocupa \(descargas.megas(de: sobra)) MB y ya no se usa. Va a la Papelera: si quieres volver, lo sacas de ahí."))"
          ) {
            Button("Mandar \(sobra.nombre) a la Papelera") { descargas.moverALaPapelera(sobra) }
              .buttonStyle(SettingsButtonStyle())
          }
        }
      }
      .anclaDeAjuste(.modeloDeParakeet)

      if settings.motorDeVoz == .parakeet, !descargas.listo, descargas.progreso == nil {
        AvisoDeDilo(
          texto: String(localized: "Mientras no descargues el modelo, Dilo dicta con Apple. No te vas a quedar sin dictar.")
        )
      }
    }
    .task { descargas.refrescar() }
  }

  /// Una fila por variante: qué es, si está y cuánto ocupa, si dicta, y qué
  /// se puede hacer con ella.
  private func filaDelModelo(_ variante: VarianteDeParakeet) -> some View {
    let enDisco = descargas.enDisco.contains(variante)
    let bajandoEsta = descargas.bajando == variante
    let dicta = enDisco && varianteEnUso == variante
    return SettingsRow(
      title: "\(variante.nombre)",
      description: "\(detalle(de: variante, enDisco: enDisco, bajando: bajandoEsta, dicta: dicta))"
    ) {
      HStack(spacing: 8) {
        if bajandoEsta {
          Button("Cancelar") { descargas.cancelar() }
            .buttonStyle(SettingsButtonStyle())
        } else if enDisco {
          if !dicta {
            Button("Usar este") { settings.varianteDeParakeet = variante }
              .buttonStyle(SettingsButtonStyle())
          }
          Button("A la Papelera") { descargas.moverALaPapelera(variante) }
            .buttonStyle(SettingsButtonStyle())
        } else {
          Button(variante == .recomendada ? "Bajar \(variante.nombre)" : "Descargar") { bajar(variante) }
            .buttonStyle(SettingsButtonStyle())
            .disabled(descargas.bajando != nil)
        }
      }
    }
  }

  private func detalle(
    de variante: VarianteDeParakeet, enDisco: Bool, bajando: Bool, dicta: Bool
  ) -> String {
    if bajando {
      return String(localized: "Puedes cancelar cuando quieras; lo bajado se borra.")
    }
    if enDisco {
      let megas = descargas.megas(de: variante)
      return dicta
        ? String(localized: "Dicta con este. Ocupa \(megas) MB; borrarlo no borra nada de lo que dictaste.")
        : String(localized: "Está en esta compu (\(megas) MB), pero no dicta.")
    }
    switch variante {
    case .ultra:
      return String(localized: "Recomendado: se equivoca menos que v3 y es igual de rápido. Son \(variante.megasDeDescarga) MB y se bajan una sola vez.")
    case .v3:
      return String(localized: "El modelo de antes. Son \(variante.megasDeDescarga) MB y se bajan una sola vez.")
    }
  }

  /// Bajar una variante. Si es la recomendada, al terminar se deja de fijar
  /// otra a mano: «al terminar la descarga, pasa a Ultra».
  private func bajar(_ variante: VarianteDeParakeet) {
    descargas.descargar(variante) { [settings] in
      if variante == .recomendada { settings.varianteDeParakeet = nil }
    }
  }
}

/// Una tarjeta de motor: nombre, etiqueta LOCAL, qué es y qué cuesta.
///
/// **Elegido y en uso son dos cosas**, y hasta el 2026-09-22 la tarjeta sólo
/// mostraba la primera, con un punto de radio de quince puntos sobre fondo
/// oscuro. Alfonso, con Parakeet guardado en sus preferencias, leyó la
/// pantalla y dijo que «salía Apple, no salía Parakeet»: el punto no se veía,
/// y con el modelo sin descargar quien dictaba de verdad **era** Apple. Ahora
/// la tarjeta elegida se distingue por fondo y borde además del punto, y la
/// que está dictando lo dice con todas sus letras.
struct MotorCard: View {
  let motor: SpeechEngineKind
  let elegido: Bool
  /// Si es este el que va a dictar. Distinto de `elegido` mientras Parakeet
  /// esté elegido sin su modelo en disco.
  var enUso = false
  let esUltima: Bool
  let elegir: () -> Void

  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    Button(action: elegir) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: elegido ? "largecircle.fill.circle" : "circle")
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(elegido ? SettingsTheme.accent : .white.opacity(0.45))
          .padding(.top, 1)

        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Text(motor.title)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(elegido ? SettingsTheme.accent : .white)
            EtiquetaDeOrigen(texto: motor.etiqueta)
            if enUso {
              // La respuesta a «¿con cuál estoy dictando?», en la tarjeta que
              // de verdad lo está haciendo.
              Text("Dictando con este")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(PaletaDeDilo.actual.exito.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(PaletaDeDilo.actual.exito.color.opacity(0.14), in: Capsule())
            }
            if motor == .porDefecto {
              Text("Por defecto")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
            }
          }

          Text(motor.descripcion)
            .font(.caption)
            .foregroundStyle(.white.opacity(contrast == .increased ? 0.72 : 0.48))
            .fixedSize(horizontal: false, vertical: true)

          HStack(spacing: 14) {
            ForEach(motor.detalles, id: \.self) { detalle in
              Label(detalle, systemImage: "checkmark")
                .font(.system(size: 10))
                .labelStyle(DetalleLabelStyle())
                .foregroundStyle(.white.opacity(contrast == .increased ? 0.62 : 0.38))
            }
          }
        }

        Spacer(minLength: 0)
      }
      .padding(.vertical, 13)
      .padding(.horizontal, elegido ? 10 : 0)
      .background {
        // El fondo y el borde, no sólo el punto: sobre una tarjeta oscura un
        // radio de quince puntos no alcanza para que alguien sepa qué eligió.
        if elegido {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(SettingsTheme.accent.opacity(contrast == .increased ? 0.20 : 0.10))
            .overlay {
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(SettingsTheme.accent.opacity(contrast == .increased ? 0.9 : 0.5))
            }
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(elegido ? [.isSelected] : [])
    .accessibilityValue(
      Text(enUso ? "Dictando con este" : (elegido ? "Elegido" : ""))
    )
    .overlay(alignment: .bottom) {
      if !esUltima {
        Rectangle()
          .fill(.white.opacity(contrast == .increased ? 0.16 : 0.07))
          .frame(height: 1)
      }
    }
  }
}

private struct DetalleLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 4) {
      configuration.icon.font(.system(size: 8, weight: .bold))
      configuration.title
    }
  }
}

/// LOCAL en menta, EN LÍNEA en mango. El color no decora: dice si el audio
/// sale de este Mac.
private struct EtiquetaDeOrigen: View {
  let texto: String

  private var color: Color { texto == "LOCAL" ? PaletaDeDilo.actual.exito.color : PaletaDeDilo.actual.acentoDeAjustes.color }

  var body: some View {
    Text(texto)
      .font(.system(size: 9, weight: .bold))
      .tracking(0.6)
      .foregroundStyle(color)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(color.opacity(0.14), in: Capsule())
  }
}


/// El estado de los modelos de Parakeet en disco y de la descarga en curso.
///
/// Es compartido y no de la vista porque cambiar de sección en Ajustes
/// reemplaza la vista entera, y una descarga de cientos de megas no se puede
/// morir porque alguien fue a mirar los sonidos. Es el mismo problema que el
/// árbol de origen resolvió sacando la instalación de los modelos de
/// traducción fuera de su vista. Inicio y Motor de voz miran este mismo
/// objeto. Se baja una variante a la vez.
@MainActor
@Observable
final class DescargaDeParakeet {
  static let compartida = DescargaDeParakeet()

  private let almacenes: [VarianteDeParakeet: ParakeetModelStore] = Dictionary(
    uniqueKeysWithValues: VarianteDeParakeet.allCases.map { ($0, ParakeetModelStore(variante: $0)) }
  )

  private(set) var enDisco = ParakeetModelStore.enDisco()
  private(set) var tamanos: [VarianteDeParakeet: Int64] = [:]
  private(set) var bajando: VarianteDeParakeet?
  private(set) var progreso: ProgresoDeDescarga?
  private(set) var error: String?
  /// La variante cuya descarga falló, para «Reintentar».
  private(set) var fallida: VarianteDeParakeet?

  /// Si hay algún Parakeet para dictar.
  var listo: Bool { !enDisco.isEmpty }

  /// Lo que ocupa en disco, o lo que se baja si todavía no se midió.
  func megas(de variante: VarianteDeParakeet) -> Int {
    guard let bytes = tamanos[variante], bytes > 0 else { return variante.megasDeDescarga }
    return Int((Double(bytes) / 1_048_576).rounded())
  }

  /// Mirar el disco, fuera del hilo principal: medir el modelo recorre cada
  /// archivo de sus `.mlmodelc`, y Ajustes lo hacía al aparecer Motor.
  func refrescar() {
    Task {
      let (enDisco, tamanos) = await Task.detached(priority: .userInitiated) {
        let enDisco = ParakeetModelStore.enDisco()
        var tamanos: [VarianteDeParakeet: Int64] = [:]
        for variante in enDisco { tamanos[variante] = ParakeetModelStore.tamanoEnDisco(variante) }
        return (enDisco, tamanos)
      }.value
      self.enDisco = enDisco
      self.tamanos = tamanos
    }
  }

  func descargar(_ variante: VarianteDeParakeet, alTerminar: @escaping @MainActor () -> Void = {}) {
    guard progreso == nil, let almacen = almacenes[variante] else { return }
    error = nil
    fallida = nil
    bajando = variante
    progreso = ProgresoDeDescarga(fraccion: 0, fase: String(localized: "Viendo qué falta…"))

    Task {
      do {
        try await almacen.descargar { avance in
          Task { @MainActor in self.progreso = avance }
        }
        terminar()
        alTerminar()
      } catch is CancellationError {
        terminar()
      } catch {
        terminar()
        fallida = variante
        self.error = error.localizedDescription
      }
    }
  }

  func cancelar() {
    guard let bajando, let almacen = almacenes[bajando] else { return }
    Task {
      await almacen.cancelarDescarga()
      terminar()
    }
  }

  func moverALaPapelera(_ variante: VarianteDeParakeet) {
    guard let almacen = almacenes[variante] else { return }
    Task {
      do {
        try await almacen.moverALaPapelera()
      } catch {
        self.error = error.localizedDescription
      }
      refrescar()
    }
  }

  private func terminar() {
    progreso = nil
    bajando = nil
    refrescar()
  }
}

/// La segunda pasada de **Tus palabras** en Parakeet: un CTC chico busca tus
/// términos en el audio y los escribe bien donde el motor los oyó mal.
///
/// El interruptor no hace nada hasta que el CTC está en disco, y por eso se
/// muestra apagado y sin tocar mientras falta. Aun con el CTC, viene apagado
/// (`PreferenciaDeTusPalabrasEnParakeet.deFabrica`, con la medición).
/// El CTC vive en la carpeta de FluidAudio (`ModeloDeTusPalabras`) y tiene su
/// propio «A la Papelera».
struct TusPalabrasEnParakeet: View {
  @Bindable var settings: AppSettings
  @State private var ctc = DescargaDeTusPalabras.compartida

  var body: some View {
    SettingsCard(title: "Tus palabras en Parakeet") {
      SettingsRow(
        title: "Buscar Tus palabras en el audio",
        description: "Una segunda pasada busca tus nombres y términos en lo que dijiste y los escribe como están en Tus palabras. Es de prueba: suma unos 250 ms al soltar y en español todavía cambia palabras que no son tuyas, por eso viene apagada."
      ) {
        Toggle(
          "Buscar Tus palabras en el audio",
          isOn: Binding(
            get: { ctc.listo && settings.tusPalabrasEnParakeet },
            set: { settings.tusPalabrasEnParakeet = $0 }
          )
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .disabled(!ctc.listo)
      }
      .anclaDeAjuste(.tusPalabrasEnParakeet)

      SettingsRow(
        title: "El modelo de Tus palabras",
        description: "\(ctc.detalle)"
      ) {
        if ctc.bajando {
          ProgressView().controlSize(.small)
        } else if ctc.listo {
          Button("A la Papelera") { ctc.moverALaPapelera() }
            .buttonStyle(SettingsButtonStyle())
        } else {
          Button("Bajar") { ctc.descargar() }
            .buttonStyle(SettingsButtonStyle())
        }
      }

      if let error = ctc.error {
        SettingsRow(title: "No se pudo descargar", description: "\(error)") {
          Button("Reintentar") { ctc.descargar() }
            .buttonStyle(SettingsButtonStyle())
        }
      }
    }
    .task { ctc.refrescar() }
  }
}

/// El CTC de Tus palabras en disco y su descarga. Compartido por lo mismo que
/// `DescargaDeParakeet`: cambiar de sección no puede matar una descarga.
@MainActor
@Observable
final class DescargaDeTusPalabras {
  static let compartida = DescargaDeTusPalabras()

  private let modelo = ModeloDeTusPalabras()
  private(set) var listo = ModeloDeTusPalabras.estaDescargado
  private(set) var bajando = false
  private(set) var error: String?

  var detalle: String {
    if bajando { return String(localized: "Bajando… son unos \(ModeloDeTusPalabras.megasDeDescarga) MB.") }
    if listo { return String(localized: "Está en esta compu. Se carga junto con Parakeet cuando dictas.") }
    return String(localized: "Son \(ModeloDeTusPalabras.megasDeDescarga) MB y se bajan una sola vez. Hasta entonces, Tus palabras se corrigen después del motor, como siempre.")
  }

  func refrescar() {
    Task {
      listo = await Task.detached(priority: .userInitiated) { ModeloDeTusPalabras.estaDescargado }.value
    }
  }

  func descargar() {
    guard !bajando else { return }
    bajando = true
    error = nil
    Task {
      do {
        try await modelo.descargar()
      } catch is CancellationError {
      } catch {
        self.error = error.localizedDescription
      }
      bajando = false
      refrescar()
    }
  }

  func moverALaPapelera() {
    Task {
      do {
        try await modelo.moverALaPapelera()
      } catch {
        self.error = error.localizedDescription
      }
      refrescar()
    }
  }
}
