import DiloCapabilities
import DiloModes
import SwiftUI

/// The Shortcuts section: the user's own keyboard with the bound keys lit,
/// above one row per binding. The whole row is the recorder — clicking it arms,
/// and the next keystroke or supported mouse-button press becomes the binding —
/// so the caps on the leading edge are the binding rather than a control
/// sitting beside it.
struct ShortcutsSettingsView: View {
  @Bindable var settings: AppSettings

  /// Read once and refreshed when the input source changes, rather than on
  /// every redraw: translating the whole board is cheap but not free, and the
  /// answer only moves when the user switches language or swaps keyboards.
  @State private var layout = KeyboardLayout.ansiFallback
  @State private var hovered: BindingRole?
  /// Which row is armed, and the keys clicked on the keyboard so far. Only one
  /// row can be armed, so the section owns this rather than each recorder.
  @State private var armed: BindingRole?
  @State private var picked: [Int64] = []
  /// Por qué la última tecla elegida no se guardó. Vivía sólo en Modos: acá
  /// el atajo se guardaba pasara lo que pasara, así que ⌥ derecha —el bug
  /// original— seguía siendo asignable desde esta pantalla.
  @State private var reparo: String?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Built once: a publisher constructed inside `body` is a new subscription
  /// on every update.
  private static let inputSourceChanges = DistributedNotificationCenter.default()
    .publisher(for: KeyboardLayout.inputSourceChanged)

  var body: some View {
    VStack(spacing: 16) {
      keyboardPanel
      keysCard
      if let reparo {
        Text(reparo)
          .font(.caption)
          .foregroundStyle(SettingsTheme.accent)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 6)
      }
    }
    .task {
      layout = KeyboardLayout.current()
    }
    .onReceive(Self.inputSourceChanges) { _ in
      layout = KeyboardLayout.current()
    }
  }

  // Untitled: the drawing says what it is, and the lit keys are the label.
  private var keyboardPanel: some View {
    // Explicitly typed: a ternary yielding an optional closure sends the type
    // checker off a cliff inside a view builder.
    let onPick: ((Int64) -> Void)? = armed == nil ? nil : { keyCode in pick(keyCode) }
    return KeyboardMapView(
      layout: layout,
      highlights: highlights,
      picked: Set(picked),
      onPick: onPick
    )
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.vertical, 18)
    .padding(.horizontal, 16)
    .background(
      SettingsTheme.card,
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .overlay {
      // Armed, the border lights: nothing else on screen says the drawing
      // just became something you can click.
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(
          isArmed ? SettingsTheme.accent.opacity(0.85) : .white.opacity(0.09),
          lineWidth: isArmed ? 1.5 : 1
        )
    }
    .shadow(
      color: isArmed ? SettingsTheme.accent.opacity(0.28) : .clear,
      radius: isArmed ? 12 : 0
    )
    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isArmed)
  }

  private var isArmed: Bool { armed != nil }

  private var keysCard: some View {
    SettingsCard(title: "Teclas") {
      row(
        .dictation,
        allowsBareModifier: true,
        allowsMouseButton: true,
        sentence: String(localized: "Mantén %@ y habla; suéltala y listo. Un toque corto la deja trabada y otro toque termina.")
      )

      if settings.isSecondLanguageEnabled {
        row(
          .secondLanguage,
          allowsBareModifier: true,
          allowsMouseButton: true,
          sentence: String(localized: "Mantén %@ para dictar en tu otro idioma, o tócala igual que la principal.")
        )
      }

      row(
        .translate,
        allowsBareModifier: true,
        allowsMouseButton: true,
        sentence: translateSentence
      )

      // Sin relectura del foco no hay Leer en voz alta, y un atajo para una
      // función escondida es una tecla que no hace nada.
      if Anfitrion.actual.admite(.relecturaDelFoco) {
        row(
          .readAloud,
          allowsBareModifier: false,
          allowsMouseButton: false,
          sentence: String(localized: "Aprieta %@ para leer lo seleccionado; otra vez para parar.")
        )
      }
    }
  }

  /// Names the language when there is one, because the row's job is to say
  /// what lands in the document. Without a target the binding does nothing,
  /// so the sentence says where to fix that.
  private var translateSentence: String {
    guard settings.isTranslationEnabled else {
      return String(localized: "Mantén %@ para hablar y pegar la traducción. Elige antes el idioma en Idioma.")
    }
    let name = SpeechLanguageCatalog.shortName(
      for: Locale(identifier: settings.translationTargetIdentifier)
    )
    // Dos huecos posicionales: el primero se deja tal cual para que la fila
    // meta ahí las teclas más tarde, y sólo el segundo se llena ahora. Con
    // `\(name)` dentro de `String(localized:)` el idioma caería en el hueco de
    // las teclas.
    return String(
      format: String(
        localized: "Mantén %1$@ para hablar y que salga en %2$@, o tócala para empezar y tócala de nuevo para terminar."
      ),
      "%@",
      name
    )
  }

  private func row(
    _ role: BindingRole,
    allowsBareModifier: Bool,
    allowsMouseButton: Bool,
    /// A sentence with %@ where the bound keys go, so it renames itself with
    /// the binding.
    sentence: String
  ) -> some View {
    KeyRecorderView(
      keyBinding: binding(for: role),
      allowsBareModifier: allowsBareModifier,
      allowsMouseButton: allowsMouseButton,
      isRecording: Binding(
        get: { armed == role },
        set: { isArmed in
          armed = isArmed ? role : nil
          picked = []
          if isArmed { reparo = nil }
        }
      ),
      onRecordingChanged: { settings.isRecordingKeybind = $0 }
    ) { keyBinding, isRecording in
      let caps = KeyboardMap.caps(for: keyBinding, layout: layout)
      ShortcutRow(
        caps: caps,
        title: "\(role.title)",
        description: "\(description(sentence, for: keyBinding, in: role, caps: caps))",
        isRecording: isRecording,
        accent: role.color,
        acceptsMouseButton: allowsMouseButton,
        isMouseBinding: keyBinding.isMouseButton,
        pickedCaps: isRecording ? pickedCaps : [],
        onConfirm: isRecording && !picked.isEmpty ? { commit(picked) } : nil
      )
    }
    .onHover { hovered = $0 ? role : nil }
  }

  /// What the row says under its title: what the binding does, what it costs
  /// when it is a mouse button, and whether another row already has it.
  private func description(
    _ sentence: String,
    for binding: KeyBinding,
    in role: BindingRole,
    caps: [String]
  ) -> String {
    let named = binding.isMouseButton ? binding.label : caps.joined(separator: " ")
    var description = String(format: sentence, named)
    if binding.isMouseButton {
      description += " " + String(
        localized: "Este botón conserva su función de siempre salvo que aprietes esa combinación exacta."
      )
    }
    if let other = settings.roleUsing(binding, excluding: role) {
      description += " " + String(localized: "También la usa \(other.title).")
    }
    return description
  }

  private func pick(_ keyCode: Int64) {
    switch ShortcutAssignment.click(keyCode, picked: picked) {
    case let .picking(selection): picked = selection
    case let .complete(selection): commit(selection)
    }
  }

  private func commit(_ clicked: [Int64]) {
    guard let role = armed,
       let binding = ShortcutAssignment.binding(forClicked: clicked, layout: layout)
    else { return }
    self.binding(for: role).wrappedValue = binding
    armed = nil
    picked = []
  }

  /// El atajo de este rol, con el validador de por medio al guardar.
  ///
  /// La regla que aplica es la misma que en Modos y vive en un solo lado
  /// (`ValidadorDeGatillos`): cualquier tecla física que no escriba un
  /// carácter sirve de gatillo —fn, F13 a F20, esc, § en ISO, Clear del
  /// numérico—, y lo único que se rechaza es ⌥ pelada, el volumen y el brillo,
  /// y una tecla que escribe usada sola. Rechazar es no guardar y decir por
  /// qué: el atajo anterior se queda, que es lo que la persona tenía andando.
  private func binding(for role: BindingRole) -> Binding<KeyBinding> {
    Binding(
      get: { settings.binding(for: role) },
      set: { nuevo in
        if let reparoDelValidador = ValidadorDeGatillos.revisar(nuevo.gatillo).reparo {
          reparo = reparoDelValidador.explicacion
          return
        }
        reparo = nil
        settings.setBinding(nuevo, for: role)
      }
    )
  }

  private var pickedCaps: [String] {
    guard let binding = ShortcutAssignment.binding(forClicked: picked, layout: layout)
    else { return [] }
    return KeyboardMap.caps(for: binding, layout: layout)
  }

  private var highlights: [KeyboardMapView.Highlight] {
    var result: [KeyboardMapView.Highlight] = [
      highlight(.dictation, settings.dictationTriggerBinding),
      // Ungated, like its row: the row shows the binding whether or not a
      // target is chosen, so the board has to agree with it. A cap cannot
      // spell a modifier's side, so the lit key is the only thing that says
      // the trigger is the right command and not the left.
      highlight(.translate, settings.translateTriggerBinding),
    ]
    if Anfitrion.actual.admite(.relecturaDelFoco) {
      result.append(highlight(.readAloud, settings.readAloudBinding))
    }
    if settings.isSecondLanguageEnabled {
      result.append(highlight(.secondLanguage, settings.secondaryTriggerBinding))
    }
    return result
  }

  private func highlight(
    _ role: BindingRole,
    _ keyBinding: KeyBinding
  ) -> KeyboardMapView.Highlight {
    KeyboardMapView.Highlight(
      keyCodes: KeyboardMap.highlighted(for: keyBinding),
      color: role.color,
      isEmphasized: hovered == role || hovered == nil
    )
  }
}

/// The color that identifies a binding, both where its keys light on the drawn
/// keyboard and on its own row.
private extension BindingRole {
  var color: Color {
    switch self {
    case .dictation: SettingsTheme.accent
    case .secondLanguage: Color(red: 0.45, green: 0.82, blue: 0.6)
    case .translate: Color(red: 0.66, green: 0.55, blue: 0.95)
    case .readAloud: Color(red: 0.95, green: 0.7, blue: 0.35)
    }
  }
}
