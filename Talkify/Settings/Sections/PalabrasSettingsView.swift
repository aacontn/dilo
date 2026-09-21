import DiloText
import SwiftUI

/// Tu español: las palabras que Dilo tiene que respetar y las muletillas que
/// tiene que sacar.
///
/// Las dos listas se quedan en esta compu. Las palabras se le pasan al motor
/// antes de reconocer y se corrigen después; las muletillas se limpian sin
/// pasar por ninguna IA, que es lo que hace que el dictado salga listo para
/// pegar estando sin internet.
struct PalabrasSettingsView: View {
  @Bindable var settings: AppSettings

  @Environment(\.colorSchemeContrast) private var contrast
  @State private var palabraNueva = ""
  @State private var muletillaNueva = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsCard(title: "Tus palabras") {
        SettingsRow(
          title: "Nombres, proyectos, siglas",
          description: "Enséñale a Dilo cómo se escriben las palabras que usas. Se quedan sólo acá. Sirven de a varias: «Espacio Digital» se arregla aunque lo dictes en dos."
        ) {
          HStack(spacing: 8) {
            TextField("Agregar una palabra", text: $palabraNueva)
              .frame(width: 180)
              .onSubmit { agregarPalabra() }
            Button("Agregar") { agregarPalabra() }
              .buttonStyle(SettingsButtonStyle())
              .disabled(palabraNueva.trimmingCharacters(in: .whitespaces).isEmpty)
          }
        }

        ForEach(settings.palabrasPropias, id: \.self) { palabra in
          SettingsRow(title: "\(palabra)", description: "") {
            Button("Quitar") { settings.palabrasPropias.removeAll { $0 == palabra } }
              .buttonStyle(SettingsButtonStyle())
          }
        }
      }

      SettingsCard(title: "Muletillas") {
        SettingsRow(
          title: "Sacar las muletillas",
          description: "Los «eh», los «o sea» y los arranques en falso salen solos, acá mismo y sin internet. El voseo, los modismos y el spanglish técnico se quedan enteros: no son un defecto."
        ) {
          Toggle("Sacar las muletillas", isOn: $settings.limpiarMuletillas)
            .labelsHidden()
            .toggleStyle(.switch)
        }

        SettingsRow(
          title: "Tu lista",
          description: settings.muletillasPropias.isEmpty
            ? "Vacía: Dilo usa las de fábrica."
            : "Con algo adentro reemplaza a las de fábrica enteras."
        ) {
          HStack(spacing: 8) {
            TextField("Agregar una muletilla", text: $muletillaNueva)
              .frame(width: 180)
              .onSubmit { agregarMuletilla() }
            Button("Agregar") { agregarMuletilla() }
              .buttonStyle(SettingsButtonStyle())
              .disabled(muletillaNueva.trimmingCharacters(in: .whitespaces).isEmpty)
          }
        }
        .disabled(!settings.limpiarMuletillas)

        ForEach(settings.muletillasPropias, id: \.self) { muletilla in
          SettingsRow(title: "\(muletilla)", description: "") {
            Button("Quitar") {
              settings.muletillasPropias.removeAll { $0 == muletilla }
            }
            .buttonStyle(SettingsButtonStyle())
          }
        }
      }

      Text(
        "Las de fábrica son los sonidos de duda («eh», «ehm», «mmm») y las muletillas que sólo salen cuando vienen puntuadas como pausa: «o sea,», «este,», «dale, cachái». «¿Cachái lo que digo?» se queda, porque ahí es un verbo."
      )
      .font(.caption)
      .foregroundStyle(.white.opacity(contrast == .increased ? 0.7 : 0.45))
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 6)
    }
  }

  private func agregarPalabra() {
    let limpia = palabraNueva.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !limpia.isEmpty else { return }
    settings.palabrasPropias = DiccionarioPersonal.terminosParaElMotor(
      settings.palabrasPropias + [limpia]
    )
    palabraNueva = ""
  }

  private func agregarMuletilla() {
    let limpia = muletillaNueva.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !limpia.isEmpty, !settings.muletillasPropias.contains(limpia) else { return }
    settings.muletillasPropias.append(limpia)
    muletillaNueva = ""
  }
}
