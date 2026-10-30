import AppKit
import SwiftUI

/// The Dictation section: where a finished Direct Dictation session's text
/// goes, and whether a copy is kept. Both choices are captured into the
/// session settings snapshot at session start (CONTEXT.md).
struct DictationSettingsView: View {
  @Bindable var settings: AppSettings

  private let historyStore = DictationHistoryStore()
  @State private var isConfirmingClear = false

  var body: some View {
    VStack(spacing: 16) {
      SettingsCard(title: "Aprieta, habla, suelta.") {
        SettingsRow(
          title: "Dictar desde cualquier app",
          description: "Mantén el gatillo mientras hablas y suéltalo para entregar el texto. Un toque corto deja el dictado encendido; otro toque lo termina. Esc cancela."
        ) {
          Text(settings.dictationTriggerBinding.label)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .anclaDeAjuste(.atajoDeDictar)
      }

      MicrofonoSettingsCard(settings: settings)

      SettingsCard(title: "Dónde aterriza") {
        SettingsPickerRow(
          title: "Entregar el texto",
          description: "Pegar en la app lo escribe donde tenías el cursor y te devuelve lo que tenías copiado. Copiar al portapapeles no pega nada. Pegar y copiar hace las dos y deja el texto copiado.",
          options: InsertionDestination.allCases,
          optionLabel: { $0.title },
          selection: $settings.insertionDestination
        )
        .anclaDeAjuste(.entregarElTexto)

        // Las dos leen o aprietan en otra app: donde el anfitrión no puede,
        // se esconden (`HostCapabilities`).
        if AjusteID.mayusculaSegunElCursor.estaDisponible {
          SettingsRow(
            title: "Adaptar la mayúscula al cursor",
            description: "A mitad de frase el dictado entra con minúscula y con un espacio; después de un punto, con mayúscula. Los nombres y Tus palabras se quedan como están. Mira los tres caracteres antes del cursor al empezar."
          ) {
            Toggle("Adaptar la mayúscula al cursor", isOn: $settings.mayusculaSegunElCursor)
              .labelsHidden()
              .toggleStyle(.switch)
          }
          .anclaDeAjuste(.mayusculaSegunElCursor)
        }

        if AjusteID.envioHablado.estaDisponible {
          SettingsRow(
            title: "Decir «envía» al final manda el mensaje",
            description: "Termina con «envía», «envíalo» o «mándalo», después de un punto o una pausa, y Dilo aprieta ↩ tras pegar. Nunca en una terminal, en un campo de contraseña ni si no supo que el texto entró. «Literal envía» la escribe."
          ) {
            Toggle("Decir «envía» al final manda el mensaje", isOn: $settings.envioHablado)
              .labelsHidden()
              .toggleStyle(.switch)
          }
          .anclaDeAjuste(.envioHablado)

          if settings.envioHablado {
            SettingsRow(
              title: "Las frases que mandan",
              description: "Separadas por comas. Vacío vuelve a las de fábrica."
            ) {
              TextField(
                "envía, envíalo, mándalo",
                text: Binding(
                  get: { settings.frasesDeEnvio.joined(separator: ", ") },
                  set: { settings.frasesDeEnvio = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                )
              )
              .textFieldStyle(.roundedBorder)
              .frame(width: 200)
            }
          }
        }
      }

      SettingsCard(title: "Historial") {
        SettingsRow(
          title: "Guardar lo que dictas",
          description: "Un archivo de texto por día, que puedes abrir en el Finder. Viene apagado, y nada sale de acá: los archivos se quedan en esta compu."
        ) {
          Toggle("Guardar lo que dictas", isOn: $settings.dictationHistoryEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .anclaDeAjuste(.guardarElHistorial)

        SettingsRow(
          title: "Carpeta",
          description: "\(settings.resolvedHistoryFolder.path(percentEncoded: false))"
        ) {
          Button("Elegir…") { chooseFolder() }
            .buttonStyle(SettingsButtonStyle())
        }
        .anclaDeAjuste(.carpetaDelHistorial)
        .disabled(!settings.dictationHistoryEnabled)

        SettingsRow(
          title: "Borrar el historial",
          description: "Borra los archivos diarios que Dilo escribió en esa carpeta. Nada más de la carpeta se toca."
        ) {
          Button("Borrar historial…") { isConfirmingClear = true }
            .buttonStyle(SettingsButtonStyle())
        }
        .anclaDeAjuste(.borrarElHistorial)
      }

    }
    .confirmationDialog(
      "¿Borrar el historial?",
      isPresented: $isConfirmingClear
    ) {
      Button("Borrar historial", role: .destructive) { clearHistory() }
    } message: {
      Text("Borra todos los archivos diarios que Dilo escribió en la carpeta del historial. No se puede deshacer.")
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Elegir"
    panel.message = "Elige dónde se guarda el historial de dictados."
    NSApp.activate()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    settings.dictationHistoryFolder = url
  }

  private func clearHistory() {
    let folder = settings.resolvedHistoryFolder
    Task {
      try? await historyStore.clear(folder: folder)
    }
  }
}
