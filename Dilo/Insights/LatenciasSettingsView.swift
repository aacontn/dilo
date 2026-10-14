import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Dónde se van los milisegundos de un dictado, fase por fase
/// (`RegistroDeLatencias`), y cómo sacarlos de la compu: un CSV que la
/// persona guarda o copia. Nada de esto sale solo.
///
/// Lee el archivo cada vez que aparece y no se suscribe a nada: el registro
/// cambia una vez por dictado, y mientras Ajustes está abierto no se dicta.
struct LatenciasSettingsView: View {
  @State private var registro = RegistroDeLatencias()
  @State private var aviso: String?

  /// Las fases que se muestran: las que suman al «soltar → texto» y la que
  /// cuesta al apretar. El CSV las lleva todas.
  private static let fasesALaVista: [Fase] = [
    .activacion, .motor, .revision, .limpieza, .modo, .pegado, .acuse, .total,
  ]

  var body: some View {
    SettingsCard(title: "LATENCIA POR FASE") {
      if registro.sesiones.count < RegistroDeLatencias.minimoParaPercentiles {
        SettingsRow(
          title: "Todavía no hay suficientes dictados",
          description: "Con cinco dictados aparece la mediana y el p95 de cada fase."
        ) {
          EmptyView()
        }
      } else {
        ForEach(Self.fasesALaVista, id: \.self) { fase in
          SettingsRow(title: "\(Self.nombre(de: fase))") {
            Text(Self.lectura(registro.percentiles(fase)))
              .font(.system(size: 12, weight: .medium))
              .monospacedDigit()
              .foregroundStyle(.white.opacity(0.62))
          }
        }
      }
      SettingsRow(
        title: "\(String(localized: "\(registro.sesiones.count) dictados medidos"))",
        description: "Se guardan sólo en esta compu, sin texto ni apps: las últimas 500 sesiones."
      ) {
        HStack(spacing: 8) {
          Button("Copiar CSV") { copiar() }
          #if !DILO_MAS
            // En App Store no: guardar donde la persona elija pide un
            // entitlement que el sandbox de Dilo no tiene. Copiar sirve igual.
            Button("Exportar latencias…") { exportar() }
          #endif
        }
        .disabled(registro.sesiones.isEmpty)
      }
      if let aviso {
        Text(aviso)
          .font(.caption)
          .foregroundStyle(SettingsTheme.accent)
          .padding(.vertical, 8)
      }
    }
    .task {
      registro = await AlmacenDeLatencias().registro()
    }
  }

  private static func nombre(de fase: Fase) -> String {
    switch fase {
    case .activacion: String(localized: "Gatillo → micrófono abierto")
    case .primerAudio: String(localized: "Micrófono → primer audio")
    case .primerParcial: String(localized: "Primer audio → primer texto")
    case .habla: String(localized: "Hablando")
    case .motor: String(localized: "Soltar → texto del motor")
    case .revision: String(localized: "Revisión de la toma")
    case .limpieza: String(localized: "Limpieza")
    case .modo: String(localized: "Modo")
    case .traduccion: String(localized: "Traducción")
    case .pegado: String(localized: "Preparar el pegado")
    case .acuse: String(localized: "⌘V → acuse de la app")
    case .total: String(localized: "Soltar → entregado")
    }
  }

  private static func lectura(_ percentiles: (p50: Int, p95: Int)?) -> String {
    guard let percentiles else { return "—" }
    return String(localized: "\(percentiles.p50) ms · p95 \(percentiles.p95) ms")
  }

  private func copiar() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(registro.csv(), forType: .string)
    aviso = String(localized: "Copiado: pégalo en Numbers o en un reporte.")
  }

  #if !DILO_MAS
    private func exportar() {
      let panel = NSSavePanel()
      panel.nameFieldStringValue = "latencias-dilo.csv"
      panel.allowedContentTypes = [.commaSeparatedText]
      let csv = registro.csv()
      panel.begin { respuesta in
        guard respuesta == .OK, let url = panel.url else { return }
        do {
          try csv.write(to: url, atomically: true, encoding: .utf8)
          aviso = String(localized: "Guardado en \(url.lastPathComponent).")
        } catch {
          aviso = error.localizedDescription
        }
      }
    }
  #endif
}
