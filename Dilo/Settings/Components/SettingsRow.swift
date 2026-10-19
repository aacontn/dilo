import SwiftUI

/// One preference row: title, optional description, trailing control.
struct SettingsRow<Control: View>: View {
  let title: LocalizedStringKey
  var description: LocalizedStringKey = ""
  /// Tope de líneas del título, para las filas cuyo título es un dato largo
  /// (un dictado del historial). Nil: todas las que pida.
  var lineasDelTitulo: Int? = nil
  @ViewBuilder let control: Control

  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    // La densidad del panel de la muesca (2026-10-19): título de 12,5 casi
    // blanco, lo secundario en 11 y gris, y menos aire que antes —diez
    // puntos arriba y abajo en vez de trece—.
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(.white.opacity(contrast == .increased ? 1 : 0.92))
          .lineLimit(lineasDelTitulo)
        if description != "" {
          Text(description)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(contrast == .increased ? 0.72 : 0.5))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 12)
      control
    }
    .padding(.vertical, 10)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(.white.opacity(contrast == .increased ? 0.16 : 0.06))
        .frame(height: 1)
    }
  }
}

/// A SettingsRow whose control is a slider over a continuous range, with the
/// current value read out beside it. For preferences with no natural set of
/// named choices, where a picker would only invent arbitrary steps.
struct SettingsSliderRow: View {
  let title: LocalizedStringKey
  var description: LocalizedStringKey = ""
  @Binding var value: Double
  let range: ClosedRange<Double>
  /// The slider still steps: a stored value the user cannot land on again
  /// makes the preference feel unrepeatable.
  var step: Double = 0.05
  let valueLabel: (Double) -> String
  var controlWidth: CGFloat = 150

  /// A stepping `Slider` draws tick marks under the track. The snap happens
  /// here instead so the slider stays continuous and the track stays clean.
  private var steppedValue: Binding<Double> {
    Binding(
      get: { value },
      set: { newValue in
        let steps = ((newValue - range.lowerBound) / step).rounded()
        let snapped = range.lowerBound + steps * step
        value = min(max(snapped, range.lowerBound), range.upperBound)
      }
    )
  }

  /// What the readout says. A stored value can sit outside the range when the
  /// range itself narrows — a preference kept from a state that allowed it —
  /// and the slider already shows the thumb clamped, so the number has to
  /// agree with it rather than report the value behind it.
  private var displayedValue: Double {
    min(max(value, range.lowerBound), range.upperBound)
  }

  var body: some View {
    SettingsRow(title: title, description: description) {
      HStack(spacing: 10) {
        Slider(value: steppedValue, in: range)
          .labelsHidden()
          .tint(SettingsTheme.accent)
          .accessibilityLabel(title)
          .accessibilityValue(valueLabel(displayedValue))
        Text(valueLabel(displayedValue))
          .font(.system(size: 11.5, weight: .medium))
          .monospacedDigit()
          .foregroundStyle(.white.opacity(0.62))
          .frame(width: 36, alignment: .trailing)
      }
      .frame(width: controlWidth)
    }
  }
}

/// The repeated shape of most preference rows: a SettingsRow whose control
/// is the standard trailing menu picker.
struct SettingsPickerRow<Value: Hashable>: View {
  let title: LocalizedStringKey
  var description: LocalizedStringKey = ""
  let options: [Value]
  let optionLabel: (Value) -> String
  @Binding var selection: Value
  var controlWidth: CGFloat = 150

  var body: some View {
    SettingsRow(title: title, description: description) {
      Picker(title, selection: $selection) {
        ForEach(options, id: \.self) { option in
          Text(optionLabel(option)).tag(option)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .controlSize(.small)
      .frame(width: controlWidth, alignment: .trailing)
    }
  }
}
