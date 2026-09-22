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

      SettingsCard(title: "La memoria") {
        SettingsPickerRow(
          title: "Soltar el modelo de la RAM",
          description: "Sin dictar por un rato, Dilo devuelve la memoria. El dictado siguiente lo vuelve a cargar mientras hablas.",
          options: DescargaPorReposo.allCases,
          optionLabel: \.title,
          selection: $settings.descargarModeloTras,
          controlWidth: 170
        )
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

  /// Qué motor está elegido y cuál va a dictar de verdad. Son distintos
  /// mientras Parakeet esté elegido sin su modelo en disco, y ésa es
  /// justamente la confusión que Alfonso reportó el 2026-09-22: no podía
  /// saber con cuál estaba dictando.
  private var seleccion: EngineSelection {
    EngineResolver.resolver(elegido: settings.motorDeVoz, parakeetDescargado: descargas.listo)
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

      SettingsCard(title: "El modelo de Parakeet") {
        SettingsRow(
          title: "\(descargas.titulo)",
          description: "\(descargas.detalle)"
        ) {
          control
        }

        if let avance = descargas.progreso {
          VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: avance.fraccion)
              .progressViewStyle(.linear)
              .tint(SettingsTheme.accent)
            Text(avance.fase)
              .font(.caption)
              .foregroundStyle(.white.opacity(0.48))
          }
          .padding(.vertical, 12)
        }

        if let error = descargas.error {
          SettingsRow(title: "No se pudo descargar", description: "\(error)") {
            Button("Reintentar") { descargas.descargar() }
              .buttonStyle(SettingsButtonStyle())
          }
        }
      }

      if settings.motorDeVoz == .parakeet, !descargas.listo, descargas.progreso == nil {
        AvisoDeDilo(
          texto: "Mientras no descargues el modelo, Dilo dicta con Apple. No te vas a quedar sin dictar."
        )
      }
    }
    .task { descargas.refrescar() }
  }

  @ViewBuilder
  private var control: some View {
    if descargas.progreso != nil {
      Button("Cancelar") { descargas.cancelar() }
        .buttonStyle(SettingsButtonStyle())
    } else if descargas.listo {
      Button("Borrar") { descargas.borrar() }
        .buttonStyle(SettingsButtonStyle())
    } else {
      Button("Descargar") { descargas.descargar() }
        .buttonStyle(SettingsButtonStyle())
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
                .foregroundStyle(DiloBrand.menta)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(DiloBrand.menta.opacity(0.14), in: Capsule())
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

  private var color: Color { texto == "LOCAL" ? DiloBrand.menta : DiloBrand.mango }

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


/// El estado de la descarga del modelo.
///
/// Es compartido y no de la vista porque cambiar de sección en Ajustes
/// reemplaza la vista entera, y una descarga de 469 MB no se puede morir
/// porque alguien fue a mirar los sonidos. Es el mismo problema que el árbol de
/// origen resolvió sacando la instalación de los modelos de traducción fuera de su
/// vista.
@MainActor
@Observable
final class DescargaDeParakeet {
  static let compartida = DescargaDeParakeet()

  private let almacen = ParakeetModelStore()

  private(set) var listo = ParakeetModelStore.estaDescargado
  private(set) var tamano: Int64 = 0
  private(set) var progreso: ProgresoDeDescarga?
  private(set) var error: String?

  var titulo: String {
    if progreso != nil { return "Descargando el modelo" }
    return listo ? "El modelo está listo" : "Descargar el modelo"
  }

  var detalle: String {
    if progreso != nil {
      return "Puedes cancelar cuando quieras; lo bajado se borra."
    }
    if listo {
      let mb = Double(tamano) / 1_048_576
      return "Ocupa \(String(format: "%.0f", mb)) MB en esta compu. Borrarlo no borra nada de lo que dictaste."
    }
    return "Son 469 MB y se bajan una sola vez. Después dictas sin internet para siempre."
  }

  func refrescar() {
    listo = ParakeetModelStore.estaDescargado
    tamano = listo ? ParakeetModelStore.tamanoEnDisco : 0
  }

  func descargar() {
    guard progreso == nil else { return }
    error = nil
    progreso = ProgresoDeDescarga(fraccion: 0, fase: "Viendo qué falta…")

    Task {
      do {
        try await almacen.descargar { avance in
          Task { @MainActor in self.progreso = avance }
        }
        progreso = nil
        refrescar()
      } catch is CancellationError {
        progreso = nil
        refrescar()
      } catch {
        progreso = nil
        self.error = error.localizedDescription
        refrescar()
      }
    }
  }

  func cancelar() {
    Task {
      await almacen.cancelarDescarga()
      progreso = nil
      refrescar()
    }
  }

  func borrar() {
    Task {
      try? await almacen.borrar()
      refrescar()
    }
  }
}
