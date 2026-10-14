import SwiftUI

/// Los dos gestos del gatillo, en Atajos: cuánto es un toque y si un Esc se
/// puede deshacer (`GestoDelGatillo`). Cambiar algo acá aplica al próximo
/// dictado, como todo Ajustes.
struct GestoDelGatilloCard: View {
  @Bindable var settings: AppSettings

  private var umbral: Binding<Double> {
    Binding(
      get: { Double(settings.umbralDeToqueMs) },
      set: { settings.umbralDeToqueMs = Int($0.rounded()) }
    )
  }

  var body: some View {
    SettingsCard(title: "Mantener y tocar") {
      SettingsSliderRow(
        title: "Cuánto es un toque, en ms",
        description: "Mantén la tecla para hablar y suéltala para pegar. Si la sueltas antes de esto, el dictado queda abierto hasta que la vuelvas a tocar.",
        value: umbral,
        range: Double(GestoDelGatillo.rangoDelUmbralMs.lowerBound)...Double(GestoDelGatillo.rangoDelUmbralMs.upperBound),
        step: 10,
        valueLabel: { "\(Int($0))" },
        controlWidth: 190
      )
      SettingsRow(
        title: "Deshacer un Esc",
        description: "Esc cancela el dictado sin que la tecla llegue a tu app. Durante 5 segundos, un clic en la muesca lo recupera y lo pega."
      ) {
        Toggle("Deshacer un Esc", isOn: $settings.deshacerCancelacion)
          .labelsHidden()
          .toggleStyle(.switch)
      }
    }
  }
}
