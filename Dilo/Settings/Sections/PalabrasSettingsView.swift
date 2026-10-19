import DiloCapabilities
import DiloModes
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
  let runtimeState: SettingsRuntimeState

  @Environment(\.colorSchemeContrast) private var contrast
  /// Si hay clave de Anthropic. Se lee al abrir la sección: la clave se pega
  /// en Modos, y volver acá vuelve a crear esta vista.
  @State private var hayClaveDeAnthropic = false
  @State private var palabraNueva = ""
  @State private var muletillaNueva = ""
  @State private var diceNuevo = ""
  @State private var escribeNuevo = ""

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

      // Lee el campo de otra app después de pegar: donde no se puede (App
      // Store), la opción no existe.
      if Anfitrion.actual.admite(.vigiaDeCorrecciones) {
        SettingsCard(title: "Aprender de tus correcciones") {
          SettingsRow(
            title: "Ofrecer lo que corrijo a mano",
            description: "Si arreglas una palabra que Dilo pegó mal, como «cuba netes» por «Kubernetes», la muesca te ofrece aprenderla. Nunca agrega nada sin que aceptes, y lo aprendido queda acá abajo, donde se borra. Mira el campo 30 segundos después de pegar, nunca un campo de contraseña, y no guarda lo que lee."
          ) {
            Toggle("Ofrecer lo que corrijo a mano", isOn: $settings.aprenderDeCorrecciones)
              .labelsHidden()
              .toggleStyle(.switch)
          }
        }
      }

      AprenderConClaudeCard(settings: settings, runtimeState: runtimeState, hayClave: hayClaveDeAnthropic)

      SettingsCard(title: "Cuando digo…") {
        SettingsRow(
          title: "Escríbelo así",
          description: "Para lo que Tus palabras no alcanza por parecido: «chat ge pe te» se escribe «ChatGPT». Las tildes no importan al comparar; la ñ sí."
        ) {
          HStack(spacing: 8) {
            TextField("Cuando digo", text: $diceNuevo)
              .frame(width: 110)
            TextField("Escríbelo así", text: $escribeNuevo)
              .frame(width: 110)
              .onSubmit { agregarReemplazo() }
            Button("Agregar") { agregarReemplazo() }
              .buttonStyle(SettingsButtonStyle())
              .disabled(!reemplazoNuevoSirve)
          }
        }

        ForEach(settings.reemplazos, id: \.self) { reemplazo in
          SettingsRow(
            title: "\(reemplazo.dice) → \(reemplazo.escribe)",
            description: reemplazo.dice.count < 4
              ? "Corto y común: va a cambiar en todas partes donde lo digas."
              : reemplazo.aprendido ? "Aprendida de una corrección tuya." : ""
          ) {
            Button("Quitar") { settings.reemplazos.removeAll { $0 == reemplazo } }
              .buttonStyle(SettingsButtonStyle())
          }
        }
      }

      SettingsCard(title: "Comandos al dictar") {
        SettingsRow(
          title: "Puntuar y editar hablando",
          description: "«Coma», «punto» al final, «nueva línea», «nuevo párrafo», «signo de interrogación», «borra eso». Corre acá mismo y sin modelo. Para escribir la palabra en vez del signo, di «literal» antes: «literal nueva línea»."
        ) {
          Toggle("Puntuar y editar hablando", isOn: $settings.comandosDeFormato)
            .labelsHidden()
            .toggleStyle(.switch)
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
    .task {
      hayClaveDeAnthropic = Llavero().tieneClave(
        para: Proveedor.anthropicDeFabrica.cuentaEnElLlavero
      )
    }
  }

  private func agregarPalabra() {
    let limpia = palabraNueva.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !limpia.isEmpty else { return }
    // Escrita a mano deja de ser aprendida: ordenar ya no la quita sola.
    settings.palabrasAprendidas.removeAll { $0.caseInsensitiveCompare(limpia) == .orderedSame }
    settings.palabrasPropias = DiccionarioPersonal.terminosParaElMotor(
      settings.palabrasPropias + [limpia]
    )
    palabraNueva = ""
  }

  private var reemplazoNuevoSirve: Bool {
    !diceNuevo.trimmingCharacters(in: .whitespaces).isEmpty
      && !escribeNuevo.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// Uno por frase: si ya había uno para lo mismo, el nuevo lo reemplaza.
  private func agregarReemplazo() {
    guard reemplazoNuevoSirve else { return }
    let nuevo = Reemplazo(
      dice: diceNuevo.trimmingCharacters(in: .whitespacesAndNewlines),
      escribe: escribeNuevo.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    settings.reemplazos.removeAll {
      $0.dice.localizedCaseInsensitiveCompare(nuevo.dice) == .orderedSame
    }
    settings.reemplazos.append(nuevo)
    diceNuevo = ""
    escribeNuevo = ""
  }

  private func agregarMuletilla() {
    let limpia = muletillaNueva.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !limpia.isEmpty, !settings.muletillasPropias.contains(limpia) else { return }
    settings.muletillasPropias.append(limpia)
    muletillaNueva = ""
  }
}
