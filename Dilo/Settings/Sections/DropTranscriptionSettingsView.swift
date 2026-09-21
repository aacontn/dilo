import AppKit
import DiloCapabilities
import SwiftUI

/// The Drop Transcription section: where a transcript nobody caught is written,
/// and a reminder of the gesture that produces one.
struct DropTranscriptionSettingsView: View {
  @Bindable var settings: AppSettings

  var body: some View {
    VStack(spacing: 16) {
      DropPreviewCard(settings: settings)

      SettingsCard(title: "Transcripciones") {
        SettingsPickerRow(
          title: "Guardar en",
          description: "Dónde queda la transcripción si no la arrastras fuera de la píldora",
          options: TranscriptDestination.Preference.allCases,
          optionLabel: { $0.title },
          selection: $settings.transcriptDestination
        )

        if settings.transcriptDestination == .chosenFolder {
          SettingsRow(
            title: "Carpeta",
            description: folderDescription
          ) {
            Button("Elegir…") { chooseFolder() }
              .buttonStyle(SettingsButtonStyle())
          }
        }
      }

      SettingsCard(title: "Cómo funciona") {
        if Anfitrion.actual.admite(.arrastreDeArchivosAlNotch) {
          SettingsRow(
            title: "Arrástralo arriba",
            description: "Lleva un audio o un video al borde de arriba y la píldora se abre para recibirlo. Cuando termina, arrastra la transcripción a donde la quieras, o haz clic para copiarla. Si la dejas ahí, se guarda sola."
          ) {
            EmptyView()
          }
        } else {
          // Donde el arrastre no llega, la instrucción no puede prometerlo.
          SettingsRow(
            title: "Elígelo desde el menú",
            description: "Abre el menú de Dilo en la barra y elige \"Transcribir un archivo…\". Cuando termina, arrastra la transcripción a donde la quieras, o haz clic para copiarla. Si la dejas ahí, se guarda sola."
          ) {
            EmptyView()
          }
        }
      }
    }
  }

  /// Says where the transcript actually lands, rather than only naming the
  /// pick: an unset folder silently falls back, and that should not surprise.
  /// Una ruta no se traduce, así que sale como valor; el caso sin carpeta sí
  /// es copy y pasa por el catálogo.
  private var folderDescription: LocalizedStringKey {
    guard let folder = settings.transcriptFolder else {
      return "Sin carpeta elegida: van al Escritorio"
    }
    return "\(folder.path(percentEncoded: false))"
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Elegir"
    panel.message = "Elige dónde se guardan las transcripciones."
    NSApp.activate()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    settings.transcriptFolder = url
  }
}
