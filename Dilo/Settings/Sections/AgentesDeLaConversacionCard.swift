import DiloAgentes
import DiloModes
import SwiftUI

/// Los **Agente**s de la **Conversación** en Ajustes → Claude: a quién se le
/// habla, cómo se llama y qué lo contesta. Se le habla a uno diciendo su
/// nombre al principio («Switchboard, ¿qué tengo hoy?») o eligiéndolo en la
/// barra de llamada; sin nombre, contesta el último de la llamada.
struct AgentesDeLaConversacionCard: View {
  @Bindable var settings: AppSettings

  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    SettingsCard(
      title: "Agentes de la conversación",
      icono: "person.2.wave.2.fill",
      detalle: "Dile a quién le hablas por su nombre al principio, o elígelo en la barra de llamada. Sin nombre, contesta el último al que le hablaste."
    ) {
      VStack(spacing: 0) {
        ForEach(settings.conversacionAgentes) { agente in
          fila(agente)
        }
      }
      .anclaDeAjuste(.agentesDeLaConversacion)

      HStack(spacing: 8) {
        Button("Agregar un agente", action: agregar)
          .buttonStyle(SettingsButtonStyle(compacto: true))
        if settings.conversacionAgentes != Agente.deFabrica {
          Button("Volver a los de fábrica") { settings.conversacionAgentes = Agente.deFabrica }
            .buttonStyle(SettingsButtonStyle(compacto: true))
        }
      }
      .padding(.vertical, 10)

      Text(
        "«Se llama por nombre» es para la escucha de nombres: con ella prendida, decir ese nombre abre la llamada. Cada nombre más que escucha es una falsa alarma más, por eso de fábrica sólo «Dilo»."
      )
      .font(.caption)
      .foregroundStyle(.white.opacity(contrast == .increased ? 0.7 : 0.45))
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func fila(_ agente: Agente) -> some View {
    SettingsRow(title: "\(agente.nombre)", description: "\(descripcion(de: agente.tipo))") {
      VStack(alignment: .trailing, spacing: 6) {
        HStack(spacing: 8) {
          TextField("Nombre", text: nombre(de: agente))
            .labelsHidden()
            .frame(width: 120)
            .accessibilityLabel(Text("Nombre de \(agente.nombre)"))
          Picker("Tipo", selection: tipo(de: agente)) {
            ForEach(tipos, id: \.self) { tipo in
              Text(titulo(de: tipo)).tag(tipo)
            }
          }
          .labelsHidden()
          .frame(width: 170)
          Button {
            settings.conversacionAgentes.removeAll { $0.id == agente.id }
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.white.opacity(0.6))
          .disabled(settings.conversacionAgentes.count <= 1)
          .accessibilityLabel(Text("Quitar a \(agente.nombre)"))
          .help(Text("Quitar"))
        }
        Toggle("Se llama por nombre", isOn: seLlama(agente))
          .toggleStyle(.checkbox)
          .font(.system(size: 11))
          .fixedSize()
          .help(Text("Con la escucha de nombres prendida, decir su nombre abre la llamada."))
      }
    }
  }

  /// Dilo, Claude Code y un tipo por cada servidor MCP conectado.
  private var tipos: [Agente.Tipo] {
    [.dilo, .claudeCode] + settings.servidoresMCP.map { .mcp(servidor: $0.id) }
  }

  private func titulo(de tipo: Agente.Tipo) -> String {
    switch tipo {
    case .dilo: String(localized: "Claude con herramientas")
    case .claudeCode: "Claude Code"
    case let .mcp(id):
      String(localized: "MCP: \(settings.servidoresMCP.first { $0.id == id }?.nombre ?? id)")
    }
  }

  private func descripcion(de tipo: Agente.Tipo) -> String {
    switch tipo {
    case .dilo:
      String(localized: "Claude por la API, con tus dictados, reuniones, calendario, portapapeles y los servidores MCP que dejes entrar.")
    case .claudeCode:
      String(localized: "Una sesión de Claude Code manejada por voz, con tu cuenta de Claude Code.")
    case let .mcp(id):
      settings.servidoresMCP.contains { $0.id == id }
        ? String(localized: "Claude con las herramientas de ese servidor y nada más.")
        : String(localized: "Ese servidor ya no está conectado: conéctalo abajo o elige otro tipo.")
    }
  }

  private func indice(_ agente: Agente) -> Int? {
    settings.conversacionAgentes.firstIndex { $0.id == agente.id }
  }

  private func nombre(de agente: Agente) -> Binding<String> {
    Binding(
      get: { agente.nombre },
      set: { nuevo in
        // Un nombre vacío no se puede decir: se queda el anterior.
        let limpio = nuevo.trimmingCharacters(in: .whitespaces)
        guard let i = indice(agente), !limpio.isEmpty else { return }
        settings.conversacionAgentes[i].nombre = limpio
      }
    )
  }

  private func tipo(de agente: Agente) -> Binding<Agente.Tipo> {
    Binding(
      get: { agente.tipo },
      set: { nuevo in
        guard let i = indice(agente) else { return }
        settings.conversacionAgentes[i].tipo = nuevo
      }
    )
  }

  private func seLlama(_ agente: Agente) -> Binding<Bool> {
    Binding(
      get: { agente.seLlamaPorNombre },
      set: { nuevo in
        guard let i = indice(agente) else { return }
        settings.conversacionAgentes[i].seLlamaPorNombre = nuevo
      }
    )
  }

  private func agregar() {
    let ids = Set(settings.conversacionAgentes.map(\.id))
    var numero = 1
    while ids.contains("agente-\(numero)") { numero += 1 }
    settings.conversacionAgentes.append(
      Agente(
        id: "agente-\(numero)", nombre: String(localized: "Agente \(numero)"), tipo: .dilo, seLlamaPorNombre: false
      )
    )
  }
}
