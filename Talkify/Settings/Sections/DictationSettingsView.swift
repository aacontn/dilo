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
      SettingsCard(title: "Dónde aterriza") {
        SettingsPickerRow(
          title: "Entregar el texto",
          description: "Pegar en la app lo escribe donde tenías el cursor y te devuelve lo que tenías copiado. Copiar al portapapeles no pega nada. Pegar y copiar hace las dos y deja el texto copiado.",
          options: InsertionDestination.allCases,
          optionLabel: { $0.title },
          selection: $settings.insertionDestination
        )
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

        SettingsRow(
          title: "Carpeta",
          description: "\(settings.resolvedHistoryFolder.path(percentEncoded: false))"
        ) {
          Button("Elegir…") { chooseFolder() }
            .buttonStyle(SettingsButtonStyle())
        }
        .disabled(!settings.dictationHistoryEnabled)

        SettingsRow(
          title: "Borrar el historial",
          description: "Borra los archivos diarios que Dilo escribió en esa carpeta. Nada más de la carpeta se toca."
        ) {
          Button("Borrar historial…") { isConfirmingClear = true }
            .buttonStyle(SettingsButtonStyle())
        }
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
