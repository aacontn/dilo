import SwiftUI

/// The General section: app-wide behaviour that is not tied to any one
/// feature. Currently just Launch at Login.
struct GeneralSettingsView: View {
  let launchAtLogin: LaunchAtLoginService

  var body: some View {
    SettingsCard(title: "Al iniciar sesión") {
      SettingsRow(
        title: "Abrir Dilo al iniciar sesión",
        description: "Dilo arranca solo cuando entras a tu cuenta"
      ) {
        Toggle("", isOn: launchAtLoginBinding)
          .labelsHidden()
          .toggleStyle(.switch)
      }
    }
  }

  private var launchAtLoginBinding: Binding<Bool> {
    Binding(
      get: { launchAtLogin.isEnabled },
      set: { launchAtLogin.setEnabled($0) }
    )
  }
}
