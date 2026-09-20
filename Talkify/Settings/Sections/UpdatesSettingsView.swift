import SwiftUI

/// The Updates section: the running version, a manual check, and the two
/// automatic behaviours. Sparkle owns the update UI itself, so this pane only
/// states what is true and gets out of the way.
struct UpdatesSettingsView: View {
  let updater: SparkleUpdaterService

  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsCard(title: "Versión") {
        SettingsRow(
          title: "Dilo \(Self.version)",
          description: updater.availableVersion.map { "Hay una versión \($0) disponible." }
            ?? lastCheckedDescription
        ) {
          Button("Buscar ahora") {
            updater.checkForUpdates()
          }
          .buttonStyle(SettingsButtonStyle())
          .disabled(!updater.canCheckForUpdates)
        }
      }

      SettingsCard(title: "Automático") {
        SettingsRow(
          title: "Buscar actualizaciones solo",
          description: "Una vez al día, en segundo plano"
        ) {
          Toggle("", isOn: automaticChecks)
            .labelsHidden()
            .toggleStyle(.switch)
        }

        SettingsRow(
          title: "Bajarlas solo",
          description: "Baja la actualización de antemano. Instalarla sigue esperándote, y nunca interrumpe un dictado."
        ) {
          Toggle("", isOn: automaticDownloads)
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(!updater.automaticallyChecksForUpdates)
        }
      }

      Text(
        "Las actualizaciones bajan desde GitHub y se verifican con una firma EdDSA antes de instalarse. La que no pasa la verificación se descarta."
      )
      .font(.caption)
      .foregroundStyle(.white.opacity(contrast == .increased ? 0.7 : 0.45))
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 6)
    }
  }

  private var lastCheckedDescription: String {
    guard let date = updater.lastCheckedAt else {
      return "Dilo todavía no ha buscado actualizaciones."
    }
    return "Última búsqueda \(date.formatted(.relative(presentation: .named)))."
  }

  private var automaticChecks: Binding<Bool> {
    Binding(
      get: { updater.automaticallyChecksForUpdates },
      set: { updater.automaticallyChecksForUpdates = $0 }
    )
  }

  private var automaticDownloads: Binding<Bool> {
    Binding(
      get: { updater.automaticallyDownloadsUpdates },
      set: { updater.automaticallyDownloadsUpdates = $0 }
    )
  }

  static var version: String {
    let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    return "\(short) (\(build))"
  }
}
