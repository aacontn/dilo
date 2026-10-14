import DiloEngines
import SwiftUI

/// La tarjeta «Micrófono» de Ajustes → Dictado: con cuál escucha Dilo.
///
/// Lo elegido aplica sólo al motor de Dilo. **Nunca** cambia la entrada del
/// sistema: las demás apps siguen con la suya.
struct MicrofonoSettingsCard: View {
  @Bindable var settings: AppSettings

  @State private var microfonos = MicrofonosConectados()

  var body: some View {
    SettingsCard(title: "Micrófono") {
      SettingsPickerRow(
        title: "Con cuál te escucho",
        description: "Automático usa el del sistema, salvo que sea Bluetooth: ahí usa uno con cable —el del Mac primero— para que tus audífonos no bajen al sonido de llamada mientras dictas. La entrada del sistema no se toca.",
        options: OpcionesDeMicrofono.opciones(
          conectadas: microfonos.conectadas, eleccion: settings.microfonoDeDictado
        ),
        optionLabel: etiqueta,
        selection: $settings.microfonoDeDictado,
        controlWidth: 210
      )
    }
    .onAppear { microfonos.mirar() }
    .onDisappear { microfonos.dejarDeMirar() }
  }

  private func etiqueta(_ eleccion: EleccionDeMicrofono) -> String {
    switch eleccion {
    case .automatico:
      return String(localized: "Automático")
    case .delSistema:
      return String(localized: "El del sistema")
    case let .elegido(_, nombre):
      // Lo elegido que no está se queda en la lista, dicho: si desapareciera,
      // el selector pisaría la elección con la primera opción en silencio.
      guard OpcionesDeMicrofono.estaConectada(eleccion, en: microfonos.conectadas) else {
        return String(localized: "\(nombre) (no conectado)")
      }
      return nombre
    }
  }
}

/// Los micrófonos conectados, vivos mientras la tarjeta está a la vista. El
/// escucha de la HAL se suelta al irse: con Ajustes cerrado no se mira nada.
@MainActor
@Observable
final class MicrofonosConectados {
  private(set) var conectadas: [EntradaDeAudio] = []
  @ObservationIgnored private var vigia: VigiaDeDispositivos?

  func mirar() {
    refrescar()
    guard vigia == nil else { return }
    vigia = VigiaDeDispositivos { [weak self] in
      Task { @MainActor in self?.refrescar() }
    }
  }

  func dejarDeMirar() {
    vigia = nil
  }

  private func refrescar() {
    conectadas = DispositivosDeAudio.entradas()
  }
}
