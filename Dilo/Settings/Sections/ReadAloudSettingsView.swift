import AVFAudio
import DiloEngines
import SwiftUI

/// The Read Aloud section: who reads (Phonon or Apple), Phonon's voice and
/// install state, the Apple voice that stands in for it, a spoken preview,
/// and the System Settings handoffs for Apple voices and Personal Voice.
struct ReadAloudSettingsView: View {
  @Bindable var settings: AppSettings

  @Environment(\.colorSchemeContrast) private var contrast
  /// Nil hasta que la vista aparece: el valor inicial de un `@State` se
  /// evalúa cada vez que SwiftUI reconstruye la vista, aunque se descarte, y
  /// el catálogo y el sintetizador no son gratis (`VoiceCatalog.init`).
  @State private var catalog: VoiceCatalog?
  @State private var previewSynthesizer: AVSpeechSynthesizer?
  @State private var previewPhonon: LectorPhonon?
  @State private var personalVoiceStatus: AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus?
  @State private var phonon = PhononEnDilo.compartido

  private var voces: [VoiceCatalog.Voz] { catalog?.voices ?? [] }
  private var motor: MotorDeLectura { MotorDeLectura(guardado: settings.readAloudMotor) }
  private var vozDePhonon: VozDePhonon { VocesDePhonon.voz(settings.readAloudVozPhonon) }

  /// Vacío en Ajustes es el de fábrica; el selector necesita un valor real.
  private var motorElegido: Binding<MotorDeLectura> {
    Binding(get: { motor }, set: { settings.readAloudMotor = $0.rawValue })
  }

  private var vozElegida: Binding<String> {
    Binding(get: { vozDePhonon.nombre }, set: { settings.readAloudVozPhonon = $0 })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsCard(title: "Quién lee") {
        SettingsPickerRow(
          title: "Motor",
          description: motor == .phonon
            ? "Phonon: voz neural en español, en este Mac y sin internet"
            : "Las voces instaladas en macOS",
          options: MotorDeLectura.allCases,
          optionLabel: \.titulo,
          selection: motorElegido,
          controlWidth: 200
        )
        .anclaDeAjuste(.quienLee)

        if motor == .phonon {
          SettingsPickerRow(
            title: "Voz de Phonon",
            description: "13 de España y 12 de México. No hay voces chilenas.",
            options: VocesDePhonon.todas.map(\.nombre),
            optionLabel: { VocesDePhonon.voz($0).etiqueta },
            selection: vozElegida,
            controlWidth: 200
          )
          .anclaDeAjuste(.vozDePhonon)

          estadoDePhonon
        }

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

      SettingsCard(title: "Voz de Apple") {
        SettingsPickerRow(
          title: "Voz que lee",
          description: catalog?.cargando ?? true
            ? "Buscando las voces de esta compu…"
            : motor == .phonon
              ? "Lee mientras Phonon no está listo y lo que no está en español"
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
          title: "Bajar voces premium",
          description: "En Ajustes del Sistema, entra a Contenido hablado → Voz del sistema → Gestionar voces y baja una voz Premium. Las voces de Siri no se pueden usar fuera de las apps de Apple. Las voces nuevas aparecen acá solas."
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

      VStack(alignment: .leading, spacing: 6) {
        Text(
          "Phonon 40m es de Gradium y se usa con su licencia CC BY-NC 4.0: uso personal, no comercial. Las voces son Apache 2.0. Se bajan aparte y no vienen dentro de Dilo."
        )
        .font(.caption)
        .foregroundStyle(.white.opacity(contrast == .increased ? 0.7 : 0.45))
        .fixedSize(horizontal: false, vertical: true)

        // Informational only: Personal Voice creation is Apple's UI and
        // has no API, so this stays a footnote rather than a feature row.
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
      phonon.refrescar(voz: vozDePhonon)
      personalVoiceStatus = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
      guard catalog == nil else { return }
      let nuevo = VoiceCatalog()
      catalog = nuevo
      await nuevo.refresh()
    }
    .onChange(of: settings.readAloudVozPhonon) { phonon.refrescar(voz: vozDePhonon) }
  }

  /// Qué le falta a Phonon y el botón que lo arregla. El modelo es lo único
  /// que la app no puede bajar: tiene términos de uso en Hugging Face y pide
  /// el token de quien los aceptó.
  @ViewBuilder
  private var estadoDePhonon: some View {
    if let avance = phonon.progreso {
      SettingsRow(title: "Bajando Phonon", description: "Puedes cancelar; lo bajado a medias se borra.") {
        Button("Cancelar") { phonon.cancelar(voz: vozDePhonon) }
          .buttonStyle(SettingsButtonStyle())
      }
      VStack(alignment: .leading, spacing: 8) {
        ProgressView(value: avance.fraccion)
          .progressViewStyle(.linear)
          .tint(SettingsTheme.accent)
        Text(avance.fase)
          .font(.caption)
          .foregroundStyle(.white.opacity(0.48))
      }
      .padding(.vertical, 12)
    } else if let estado = phonon.estado {
      if !estado.runtime || !estado.voz {
        SettingsRow(
          title: "Bajar Phonon",
          description: "El motor son 8 MB y cada voz 250 KB. Se bajan una vez; mientras, lee Apple."
        ) {
          Button("Bajar") { Task { await phonon.preparar(voz: vozDePhonon) } }
            .buttonStyle(SettingsButtonStyle())
        }
      }
      if !estado.modelo {
        SettingsRow(
          title: "Falta el modelo de Phonon",
          description: "Tiene términos de uso en Hugging Face y Dilo no lo baja solo. Instálalo una vez con scripts/instalar-phonon.sh (75 MB). Mientras, lee Apple."
        ) {
          EmptyView()
        }
      }
      if estado.listo {
        SettingsRow(
          title: "Phonon está listo",
          description: "Ocupa unos 100 MB en esta compu y lee sin internet."
        ) {
          Button("Borrar") { phonon.borrar(voz: vozDePhonon) }
            .buttonStyle(SettingsButtonStyle())
        }
      }
    } else {
      SettingsRow(title: "Revisando Phonon…", description: "") { EmptyView() }
    }

    if let error = phonon.error {
      SettingsRow(title: "No se pudo bajar Phonon", description: "\(error)") {
        Button("Reintentar") { Task { await phonon.preparar(voz: vozDePhonon) } }
          .buttonStyle(SettingsButtonStyle())
      }
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
    let frase = String(localized: "Hola. Así suena Dilo cuando te lee en voz alta.")
    previewSynthesizer?.stopSpeaking(at: .immediate)
    previewPhonon?.detener()
    if motor == .phonon, phonon.estado?.listo == true {
      let lector = previewPhonon ?? LectorPhonon(instalacion: phonon.instalacion)
      previewPhonon = lector
      lector.leer(frase, voz: vozDePhonon) { _ in playApple(frase) }
      return
    }
    playApple(frase)
  }

  private func playApple(_ frase: String) {
    let previewSynthesizer = previewSynthesizer ?? AVSpeechSynthesizer()
    self.previewSynthesizer = previewSynthesizer
    let utterance = AVSpeechUtterance(string: frase)
    if !settings.readAloudVoiceID.isEmpty,
      let voice = AVSpeechSynthesisVoice(identifier: settings.readAloudVoiceID)
    {
      utterance.voice = voice
    }
    previewSynthesizer.speak(utterance)
  }
}

extension MotorDeLectura {
  var titulo: String {
    switch self {
    case .phonon: String(localized: "Phonon (neural)")
    case .apple: String(localized: "Voces de Apple")
    }
  }
}

extension VozDePhonon {
  /// «Regina · México · mujer».
  var etiqueta: String {
    let acento = acento == .mexico ? String(localized: "México") : String(localized: "España")
    let genero = genero == .mujer ? String(localized: "mujer") : String(localized: "hombre")
    return "\(nombre) · \(acento) · \(genero)"
  }
}
