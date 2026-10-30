import SwiftUI

/// Acerca de: qué versión corre, bajo qué licencia y qué trabajo ajeno lleva
/// adentro. Las licencias de terceros no son una cortesía opcional — son la
/// condición de esas licencias y la costumbre de la casa: cuando se toma
/// trabajo de otro, se dice de quién es, en la app y en el README.
struct AboutSettingsView: View {
  @Environment(\.colorSchemeContrast) private var contrast

  private static var version: String {
    let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    return "\(short) (\(build))"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsCard(title: "Dilo") {
        SettingsRow(
          title: "Dilo \(Self.version)",
          description: "Dictado en español para Mac. Aprieta, habla, suelta."
        ) {
          EmptyView()
        }

        SettingsRow(
          title: "Todo pasa acá",
          description: "El reconocimiento, la lectura en voz alta y la transformación de texto corren en esta compu. Dilo no guarda audio. Sólo los modos con proveedor en línea mandan texto afuera, y la tarjeta siempre lo dice."
        ) {
          EmptyView()
        }
      }
      .anclaDeAjuste(.version)

      SettingsCard(title: "Licencias") {
        SettingsRow(
          title: "Licencia",
          description: "MIT. © 2026 Alfonso Contreras / Espacio Digital."
        ) {
          EmptyView()
        }

        SettingsRow(
          title: "Licencias de terceros",
          description: "Talkify, de Tornike Gomareli (MIT) · Handy, de CJ Pais (MIT) · FluidAudio, de FluidInference (Apache 2.0) · imnotpayingforwisprflow, de Yosef Shammout (MIT) · Muesli, de Pranav Hari (MIT) · meeting-transcriber, de pasrom (MIT) · Sparkle, de Andy Matuschak y otros (MIT). Se bajan aparte, para leer en voz alta: Phonon 40m, de Gradium (CC BY-NC 4.0, uso personal y no comercial), hecho sobre Pocket TTS y Mimi de Kyutai · sus voces (Apache 2.0) · el motor ptts, de Gradium (MIT o Apache 2.0)."
        ) {
          EmptyView()
        }
        .anclaDeAjuste(.licencias)
      }

      Text(
        "El Dilo multiplataforma hecho en Tauri quedó congelado en 0.3.2 y sigue disponible para Intel, Windows y Linux. Esta es la versión nativa de Mac, y continúa la numeración."
      )
      .font(.caption)
      .foregroundStyle(.white.opacity(contrast == .increased ? 0.7 : 0.45))
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 6)
    }
  }
}
