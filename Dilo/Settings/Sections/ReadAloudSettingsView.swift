import AVFAudio
import SwiftUI

/// The Read Aloud section: the voice pick (enhanced/premium/Personal only),
/// a spoken preview, and the System Settings handoffs for voice downloads
/// and Personal Voice — Dilo cannot download synthesis voices itself
/// (CONTEXT.md).
struct ReadAloudSettingsView: View {
  @Bindable var settings: AppSettings

  @Environment(\.colorSchemeContrast) private var contrast
  /// Nil hasta que la vista aparece: el valor inicial de un `@State` se
  /// evalúa cada vez que SwiftUI reconstruye la vista, aunque se descarte, y
  /// el catálogo y el sintetizador no son gratis (`VoiceCatalog.init`).
  @State private var catalog: VoiceCatalog?
  @State private var previewSynthesizer: AVSpeechSynthesizer?
  @State private var personalVoiceStatus: AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus?

  private var voces: [VoiceCatalog.Voz] { catalog?.voices ?? [] }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsCard(title: "Voz") {
        SettingsPickerRow(
          title: "Voz que lee",
          description: catalog?.cargando ?? true
            ? "Buscando las voces de esta compu…"
            : voces.isEmpty
              ? "En esta compu sólo hay voces de calidad normal"
              : "Las voces de buena calidad instaladas en esta compu",
          options: opcionesDeVoz,
          optionLabel: { identifier in
            guard !identifier.isEmpty else { return String(localized: "La del sistema") }
            return voces.first { $0.identifier == identifier }?.etiqueta ?? identifier
          },
          selection: $settings.readAloudVoiceID,
          controlWidth: 240
        )
        .anclaDeAjuste(.vozQueLee)

        SettingsRow(
          title: "Traducir antes de leer",
          description: "Si seleccionas texto en otro idioma, se lee en el idioma de la voz. Necesita el modelo del par ya instalado."
        ) {
          Toggle("Traducir antes de leer", isOn: $settings.readAloudTranslates)
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .anclaDeAjuste(.traducirAntesDeLeer)

        SettingsRow(
          title: "Escuchar",
          description: "Prueba la voz que elegiste"
        ) {
          Button("Probar") {
            playPreview()
          }
          .buttonStyle(SettingsButtonStyle())
        }
      }

      SettingsCard(title: "Más voces") {
        SettingsRow(
          title: "Bajar voces premium",
          description: "En Ajustes del Sistema, entra a Contenido hablado → Voz del sistema → Gestionar voces y baja una voz Premium. Son archivos grandes y bajan en silencio; si una se traba, reiniciar suele arreglarlo. Las voces nuevas aparecen acá solas."
        ) {
          Button("Abrir Ajustes del Sistema") {
            VoiceCatalog.openVoiceDownloadSettings()
          }
          .buttonStyle(SettingsButtonStyle())
        }
        .anclaDeAjuste(.bajarVoces)

        if personalVoiceStatus == .notDetermined {
          SettingsRow(
            title: "Voz personal",
            description: "Deja que Dilo lea con tu propia voz entrenada"
          ) {
            Button("Permitir voz personal") {
              Task {
                personalVoiceStatus = await VoiceCatalog.requestPersonalVoiceAccess()
                await catalog?.refresh()
              }
            }
            .buttonStyle(SettingsButtonStyle())
          }
        }
      }

      // Informational only: Personal Voice creation is Apple's UI and
      // has no API, so this stays a footnote rather than a feature row.
      VStack(alignment: .leading, spacing: 2) {
        Text(
          "Dilo también puede hablar con una voz entrenada con la tuya: crea una Voz personal en Ajustes del Sistema → Accesibilidad y después dale permiso a Dilo para usarla."
        )
        .font(.caption)
        .foregroundStyle(.white.opacity(contrast == .increased ? 0.7 : 0.45))
        .fixedSize(horizontal: false, vertical: true)

        Button("Abrir los ajustes de Voz personal…") {
          VoiceCatalog.openPersonalVoiceSettings()
        }
        .buttonStyle(.link)
        .font(.caption)
        .tint(SettingsTheme.accent)
      }
      .padding(.horizontal, 6)
    }
    .task {
      personalVoiceStatus = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
      guard catalog == nil else { return }
      let nuevo = VoiceCatalog()
      catalog = nuevo
      await nuevo.refresh()
    }
  }

  /// La elegida se queda en la lista aunque todavía no haya llegado la
  /// lectura: un selector sin su selección la pisa con la primera opción.
  private var opcionesDeVoz: [String] {
    var opciones = [""] + voces.map(\.identifier)
    let elegida = settings.readAloudVoiceID
    if !elegida.isEmpty, !opciones.contains(elegida) { opciones.append(elegida) }
    return opciones
  }

  private func playPreview() {
    let previewSynthesizer = previewSynthesizer ?? AVSpeechSynthesizer()
    self.previewSynthesizer = previewSynthesizer
    previewSynthesizer.stopSpeaking(at: .immediate)
    let utterance = AVSpeechUtterance(
      string: "Hola. Así suena Dilo cuando te lee en voz alta."
    )
    if !settings.readAloudVoiceID.isEmpty,
     let voice = AVSpeechSynthesisVoice(identifier: settings.readAloudVoiceID) {
      utterance.voice = voice
    }
    previewSynthesizer.speak(utterance)
  }
}
