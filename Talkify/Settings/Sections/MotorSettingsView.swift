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

  @State private var descargas = DescargaDeParakeet.compartida

  var body: some View {
    VStack(spacing: 16) {
      SettingsCard(title: "Motor de voz") {
        ForEach(Array(SpeechEngineKind.allCases.enumerated()), id: \.element) { indice, motor in
          MotorCard(
            motor: motor,
            elegido: settings.motorDeVoz == motor,
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
        AvisoDeCaida()
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
private struct MotorCard: View {
  let motor: SpeechEngineKind
  let elegido: Bool
  let esUltima: Bool
  let elegir: () -> Void

  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    Button(action: elegir) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: elegido ? "largecircle.fill.circle" : "circle")
          .font(.system(size: 15))
          .foregroundStyle(elegido ? SettingsTheme.accent : .white.opacity(0.3))
          .padding(.top, 1)

        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Text(motor.title)
              .font(.system(size: 13, weight: .semibold))
            EtiquetaDeOrigen(texto: motor.etiqueta)
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
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
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

private struct AvisoDeCaida: View {
  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "info.circle.fill")
        .foregroundStyle(SettingsTheme.accent)
      Text("Mientras no descargues el modelo, Dilo dicta con Apple. No te vas a quedar sin dictar.")
        .font(.caption)
        .foregroundStyle(.white.opacity(0.62))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(14)
    .background(SettingsTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
  }
}

/// El estado de la descarga del modelo.
///
/// Es compartido y no de la vista porque cambiar de sección en Ajustes
/// reemplaza la vista entera, y una descarga de 469 MB no se puede morir
/// porque alguien fue a mirar los sonidos. Es el mismo problema que Talkify
/// resolvió sacando la instalación de los modelos de traducción fuera de su
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
