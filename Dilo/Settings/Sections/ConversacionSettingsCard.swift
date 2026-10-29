import DiloModes
import SwiftUI

/// La **Conversación** en Ajustes → Claude: la tecla para llamar, qué modelo
/// contesta, el tope de gasto del mes y lo que va gastado. La voz, la
/// velocidad y el micrófono se cambian en la misma barra de llamada, que es
/// donde se oyen.
struct ConversacionSettingsCard: View {
  @Bindable var settings: AppSettings

  @Environment(\.colorSchemeContrast) private var contrast
  @State private var grabando = false
  @State private var reparo: String?

  var body: some View {
    SettingsCard(
      title: "Conversación",
      icono: "bubble.left.and.text.bubble.right.fill",
      detalle: "Le hablas a Dilo y contesta en voz alta. Tu voz se transcribe en el Mac; a Anthropic viaja sólo el texto."
    ) {
      SettingsRow(
        title: "Tecla para conversar",
        description: "Apriétala para llamar; durante la llamada, apretarla te da el turno y soltarla lo termina. Sin tecla, conversas desde el panel de la barra o con el atajo «Conversar con Dilo»."
      ) {
        HStack(spacing: 8) {
          grabador
          if settings.conversacionGatillo != nil {
            Button("Quitar") { settings.conversacionGatillo = nil }
              .buttonStyle(SettingsButtonStyle(compacto: true))
          }
        }
      }
      .anclaDeAjuste(.teclaDeConversar)
      if let reparo {
        Text(reparo)
          .font(.caption)
          .foregroundStyle(SettingsTheme.accent)
          .fixedSize(horizontal: false, vertical: true)
      }

      SettingsPickerRow(
        title: "Quién contesta",
        description: "Automático parte en Sonnet, baja a Haiku para un «sí» o un «gracias» y sube a Opus cuando la conversación se pone compleja o se lo pides («piénsalo bien»). Fijo, contesta siempre ese, salvo que pidas otro de viva voz.",
        options: EleccionDeModelo.allCases,
        optionLabel: \.titulo,
        selection: $settings.conversacionModelo,
        controlWidth: 160
      )
      .anclaDeAjuste(.modeloDeLaConversacion)

      SettingsPickerRow(
        title: "Tope de gasto al mes",
        description: "\(gastadoEsteMes) Al llegar al tope, la conversación lo dice y no llama más a Anthropic hasta el mes siguiente.",
        options: TopeDeGasto.opciones,
        optionLabel: { "US$\(Int($0))" },
        selection: $settings.conversacionTope,
        controlWidth: 120
      )
      .anclaDeAjuste(.topeDeLaConversacion)

      Text(
        "Lo conversado vive en la memoria mientras dura la llamada y se olvida al colgar: no va al historial ni al registro del sistema. Una conversación de diez minutos cuesta unos centavos con Sonnet."
      )
      .font(.caption)
      .foregroundStyle(.white.opacity(contrast == .increased ? 0.7 : 0.45))
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var gastadoEsteMes: String {
    let gasto = TopeDeGasto.vigente(settings.conversacionGasto, ahora: Date())
    return String(localized: "Este mes: \(ControladorDeLaConversacion.dolares(gasto.dolares)).")
  }

  private var grabador: some View {
    KeyRecorderView(
      keyBinding: Binding(
        get: { settings.conversacionGatillo ?? .controlCommandL },
        set: asignar
      ),
      politica: .deDictado,
      isRecording: $grabando,
      onRecordingChanged: { settings.isRecordingKeybind = $0 }
    ) { _, estaGrabando in
      Text(estaGrabando ? "…" : (settings.conversacionGatillo?.label ?? String(localized: "Sin tecla")))
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(estaGrabando ? SettingsTheme.accent : .white.opacity(0.8))
        .frame(minWidth: 74)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.1)))
    }
  }

  /// La misma regla que Atajos y Modos (`ValidadorDeGatillos`), contra todos
  /// los atajos de Dilo: rechazar es no guardar y decir por qué.
  private func asignar(_ binding: KeyBinding) {
    grabando = false
    let veredicto = ValidadorDeGatillos.revisar(
      binding.gatillo, entre: settings.gatillosEnUso, salvo: AppSettings.idDeConversar
    )
    if let reparoDelValidador = veredicto.reparo {
      reparo = reparoDelValidador.explicacion
      return
    }
    reparo = nil
    settings.conversacionGatillo = binding
  }
}
