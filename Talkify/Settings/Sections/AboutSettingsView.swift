import AppKit
import SwiftUI

/// Acerca de: qué versión corre, de dónde viene Dilo y a quién hay que
/// agradecerle. La atribución a Talkify no es una cortesía opcional — es la
/// condición de la licencia MIT y la costumbre de la casa: cuando se toma
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
          description: "El reconocimiento, la lectura en voz alta y la "
            + "transformación de texto corren en esta compu, con frameworks de "
            + "Apple. Dilo no guarda audio. Sólo los modos con proveedor en "
            + "línea mandan texto afuera, y la tarjeta siempre lo dice."
        ) {
          EmptyView()
        }
      }

      SettingsCard(title: "De dónde viene") {
        SettingsRow(
          title: "Un fork con cariño",
          description: "Dilo es un fork con cariño de Talkify "
            + "(Tornike Gomareli, MIT). De ahí vienen la píldora del notch, la "
            + "máquina de sesión y el tap de teclado, y están bien hechos."
        ) {
          Button("Ver Talkify") {
            open("https://github.com/tornikegomareli/Talkify")
          }
          .buttonStyle(SettingsButtonStyle())
        }

        SettingsRow(
          title: "Licencia",
          description: "MIT. © 2026 Tornike Gomareli (Talkify) · "
            + "© 2026 Alfonso Contreras / Espacio Digital (Dilo)."
        ) {
          EmptyView()
        }
      }

      Text(
        "El Dilo multiplataforma hecho en Tauri quedó congelado en 0.3.2 y "
          + "sigue disponible para Intel, Windows y Linux. Esta es la versión "
          + "nativa de Mac, y continúa la numeración."
      )
      .font(.caption)
      .foregroundStyle(.white.opacity(contrast == .increased ? 0.7 : 0.45))
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 6)
    }
  }

  private func open(_ string: String) {
    guard let url = URL(string: string) else { return }
    NSWorkspace.shared.open(url)
  }
}
