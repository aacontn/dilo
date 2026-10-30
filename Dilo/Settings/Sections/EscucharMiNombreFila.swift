import DiloModes
import Observation
import SwiftUI

/// En qué está la escucha de nombres, para Ajustes. Lo escribe
/// `EscuchaDeNombres`; sin ella (las vistas previas, los renders) queda
/// apagada.
@MainActor
@Observable
final class EstadoDeLaEscucha {
  static let compartido = EstadoDeLaEscucha()
  var pausas = PausasDeLaEscucha()
}

/// «Escuchar mi nombre», en Ajustes → Claude → Conversación: el
/// interruptor, cuánto gasta y por qué está en pausa si lo está.
struct EscucharMiNombreFila: View {
  @Bindable var settings: AppSettings
  var estado = EstadoDeLaEscucha.compartido

  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    SettingsRow(
      title: "Escuchar mi nombre",
      description: "Di «Dilo, …» y se abre la conversación, sin apretar nada. El micrófono queda abierto y macOS muestra el punto naranja; lo que se oye vive unos segundos en la memoria y se pisa solo: nunca se graba, ni va al historial, ni sale del Mac. La primera vez baja un detector de voz de 1 MB."
    ) {
      Toggle("Escuchar mi nombre", isOn: $settings.escucharMiNombre)
        .labelsHidden()
        .toggleStyle(.switch)
    }
    .anclaDeAjuste(.escucharMiNombre)

    if settings.escucharMiNombre {
      VStack(alignment: .leading, spacing: 4) {
        if let pausa = porQueEnPausa {
          Text(pausa)
            .foregroundStyle(SettingsTheme.accent)
        }
        // Medido en la espiga del 2026-10-30 en un M1 (Silero y Parakeet
        // Ultra sobre 54 min de prosa y 10 de ruido,
        // `/Volumes/SSD 1/Dilo/taller/escucha`). Si cambia el camino, se
        // vuelve a medir y se cambia acá.
        Text(
          "Mientras escucha gasta menos de 1 % de un núcleo con gente hablando cerca, y menos aún en silencio (medido en un M1), y unos 10 MB de memoria; cuando oye voz usa el Parakeet del dictado. Se pausa sola mientras dictas, conversas o grabas una reunión, y con la pantalla bloqueada. Con audífonos Bluetooth escucha con el micrófono del Mac, para que la música no baje a calidad de llamada."
        )
        .foregroundStyle(.white.opacity(contrast == .increased ? 0.7 : 0.45))
      }
      .font(.caption)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var porQueEnPausa: String? {
    switch estado.pausas.motivoPrincipal {
    case .sinMotor: String(localized: "En pausa: escucha con Parakeet, y no está. Bájalo en Motor de voz.")
    case .sinDetector:
      String(localized: "En pausa: no pude bajar el detector de voz (1 MB). Revisa la conexión y vuelve a prenderla.")
    case .sinNombres: String(localized: "En pausa: ningún agente se llama por nombre.")
    case .sinMicrofono:
      String(localized: "En pausa: no hay un micrófono para dejar abierto. Un Bluetooth sólo se usa si lo eliges en la barra de la conversación.")
    case .dictado: String(localized: "En pausa mientras dictas.")
    case .conversacion: String(localized: "En pausa durante la conversación.")
    case .reunion: String(localized: "En pausa mientras grabas una reunión.")
    case .pantallaBloqueada: String(localized: "En pausa con la pantalla bloqueada.")
    case nil: nil
    }
  }
}
