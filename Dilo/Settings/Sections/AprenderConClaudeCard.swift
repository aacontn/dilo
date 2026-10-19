import DiloModes
import DiloText
import SwiftUI

/// Aprender con Claude, en Ajustes → Tus palabras: quién aprende (se elige
/// en Claude), «Ordenar ahora», lo que se manda a Anthropic y el registro de
/// lo que el orden cambió, cada cambio con su deshacer.
struct AprenderConClaudeCard: View {
  @Bindable var settings: AppSettings
  let runtimeState: SettingsRuntimeState
  /// Si hay clave de Anthropic. Lo pone quien dibuja: se lee al abrir la
  /// sección, como en Idioma.
  let hayClave: Bool

  @Environment(\.colorSchemeContrast) private var contrast

  private var ordenador: OrdenadorDelDiccionario? { runtimeState.ordenador }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsCard(title: "Aprender con Claude") {
        // El interruptor y los modelos viven en Claude desde el 2026-10-19;
        // acá queda lo que es de Tus palabras: ordenar y deshacer.
        SettingsRow(title: "Quién aprende", description: "\(quienAprende)") {
          Button("Cambiar en Claude") { runtimeState.filaPedida = .aprenderConClaude }
            .buttonStyle(SettingsButtonStyle(compacto: true))
        }

        if !hayClave, settings.aprenderConClaude {
          SettingsRow(
            title: "Falta la clave de Anthropic",
            description: "Pégala en Claude. Es la misma de los modos y de traducir."
          ) {
            Button("Abrir Claude") { runtimeState.filaPedida = .claveDeAnthropic }
              .buttonStyle(SettingsButtonStyle(compacto: true))
          }
        }

        Group {
          SettingsRow(title: "Ordenar ahora", description: "\(estadoDelOrden)") {
            Button(ordenador?.ordenando == true ? LocalizedStringKey("Ordenando…") : LocalizedStringKey("Ordenar ahora")) {
              ordenador?.ordenarAhora()
            }
            .buttonStyle(SettingsButtonStyle())
            .disabled(ordenador == nil || ordenador?.ordenando == true || !hayClave || runtimeState.isDictating)
          }
          .anclaDeAjuste(.ordenarAhora)
        }
        .disabled(!settings.aprenderConClaude)
      }

      if !settings.registroDelOrden.isEmpty {
        SettingsCard(title: "Lo que ordenó Claude") {
          ForEach(settings.registroDelOrden) { pasada in
            ForEach(pasada.cambios) { cambio in
              SettingsRow(
                title: "\(resumen(cambio))",
                description: "\(detalle(cambio, en: pasada))"
              ) {
                Button(cambio.estado == .aplicado ? LocalizedStringKey("Deshacer") : LocalizedStringKey("Aplicar")) {
                  ordenador?.alternar(cambio.id, en: pasada.id)
                }
                .buttonStyle(SettingsButtonStyle())
                .disabled(ordenador == nil)
              }
            }
          }
        }
      }

      Text(
        "Qué se manda a Anthropic: al revisar, la palabra corregida con unas ocho palabras antes y después, nunca el campo entero ni el nombre de la app; al ordenar, Tus palabras y «Cuando digo…», nada de lo que dictaste. Nada de eso queda en el registro del sistema. Cada pedido se cobra a tu clave: revisar cuesta una fracción de centavo y ordenar, unos pocos centavos."
      )
      .font(.caption)
      .foregroundStyle(.white.opacity(contrast == .increased ? 0.7 : 0.45))
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 6)
    }
  }

  /// «Revisa Claude Haiku 5.5 y ordena Claude Sonnet 5.5», o que está
  /// apagado.
  private var quienAprende: String {
    guard settings.aprenderConClaude else {
      return String(localized: "Apagado: Dilo aprende solo, sin Claude.")
    }
    let revisa = ModelosDeAnthropic.conocido(settings.modeloParaRevisar)?.nombre ?? settings.modeloParaRevisar
    let ordena = ModelosDeAnthropic.conocido(settings.modeloParaOrdenar)?.nombre ?? settings.modeloParaOrdenar
    return String(localized: "Revisa \(revisa) y ordena \(ordena).")
  }

  private var estadoDelOrden: String {
    switch ordenador?.estado ?? .quieto {
    case .ordenando:
      return String(localized: "Claude está ordenando. Puedes seguir dictando.")
    case let .listo(aplicados, propuestos):
      if aplicados + propuestos == 0 { return String(localized: "Listo: nada que cambiar.") }
      return String(localized: "Listo: \(aplicados) aplicados, \(propuestos) propuestos. Están abajo, con su deshacer.")
    case let .fallo(aviso):
      return String(localized: "No se pudo: \(aviso).")
    case .quieto:
      guard let fecha = settings.ultimaPasadaDelOrden else {
        return String(localized: "Todavía no se ordena. Lo hace solo; esto es para no esperar.")
      }
      return String(localized: "La última vez fue el \(fecha.formatted(date: .abbreviated, time: .omitted)).")
    }
  }

  /// Qué cambia, en una línea: «Posthog» → «PostHog», o «Sacar «entonces»».
  private func resumen(_ cambio: CambioDelOrden) -> String {
    let c = cambio.cambio
    var partes: [String] = []
    if !c.palabrasAgregadas.isEmpty {
      partes += zip(c.palabrasQuitadas, c.palabrasAgregadas).map { "«\($0)» → «\($1)»" }
    } else if !c.palabrasQuitadas.isEmpty {
      let lista = c.palabrasQuitadas.map { "«\($0)»" }.joined(separator: ", ")
      partes.append(String(localized: "Sacar \(lista)"))
    }
    if !c.reemplazosAgregados.isEmpty {
      if c.palabrasQuitadas.isEmpty {
        partes += zip(c.reemplazosQuitados, c.reemplazosAgregados).map {
          "«\($0.dice)»: «\($0.escribe)» → «\($1.escribe)»"
        }
      }
    } else if !c.reemplazosQuitados.isEmpty {
      let lista = c.reemplazosQuitados.map { "«\($0.dice)» → «\($0.escribe)»" }.joined(separator: ", ")
      partes.append(String(localized: "Sacar \(lista)"))
    }
    return partes.joined(separator: " · ")
  }

  private func detalle(_ cambio: CambioDelOrden, en pasada: PasadaDelOrden) -> String {
    let estado = switch cambio.estado {
    case .aplicado: String(localized: "Aplicado")
    case .propuesto: String(localized: "Propuesto: lo escribiste tú o cambia letras, así que no lo apliqué solo")
    case .deshecho: String(localized: "Deshecho")
    }
    let fecha = pasada.fecha.formatted(date: .abbreviated, time: .omitted)
    let modelo = ModelosDeAnthropic.conocido(pasada.modelo)?.nombre ?? pasada.modelo
    let motivo = cambio.motivo.isEmpty ? "" : "\(cambio.motivo) "
    return "\(motivo)— \(estado). \(fecha), \(modelo)."
  }
}
