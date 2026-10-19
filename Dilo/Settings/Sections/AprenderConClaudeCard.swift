import DiloModes
import DiloText
import SwiftUI

/// Aprender con Claude, en Ajustes → Tus palabras: el interruptor, quién
/// revisa y quién ordena, «Ordenar ahora», lo que se manda a Anthropic y el
/// registro de lo que el orden cambió, cada cambio con su deshacer.
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
        SettingsRow(
          title: "Que Claude revise y ordene",
          description: "Claude revisa lo que corriges antes de ofrecértelo y descarta lo que no es vocabulario. De vez en cuando ordena Tus palabras: junta variantes, fija cómo se escribe cada nombre y saca lo que entró por error. Sin clave, o sin conexión, Dilo aprende como antes, solo."
        ) {
          Toggle("Que Claude revise y ordene", isOn: $settings.aprenderConClaude)
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .anclaDeAjuste(.aprenderConClaude)

        if !hayClave {
          SettingsRow(
            title: "Falta la clave de Anthropic",
            description: "Pégala en Modos → Proveedor general → Anthropic → API key. Es la misma de los modos y de traducir."
          ) {
            Button("Abrir Modos") { runtimeState.seccionPedida = .modos }
              .buttonStyle(SettingsButtonStyle())
          }
        }

        Group {
          SettingsPickerRow(
            title: "Revisar cada corrección",
            description: "Una pregunta corta después de cada corrección: ¿esto se aprende, y cómo? Haiku 5.5 alcanza y cuesta casi nada.",
            options: ModelosDeAnthropic.lista.map(\.id),
            optionLabel: { etiqueta($0, recomendado: ModelosDeAnthropic.deFabricaParaRevisar) },
            selection: $settings.modeloParaRevisar,
            controlWidth: 270
          )
          .anclaDeAjuste(.modeloParaRevisar)

          SettingsPickerRow(
            title: "Ordenar Tus palabras",
            description: "Una vez por semana o después de diez palabras nuevas, nunca mientras dictas. Un error ahí se queda pegado, por eso Sonnet 5.5; Opus 5.5 si Sonnet se equivoca seguido.",
            options: ModelosDeAnthropic.lista.map(\.id),
            optionLabel: { etiqueta($0, recomendado: ModelosDeAnthropic.deFabricaParaOrdenar) },
            selection: $settings.modeloParaOrdenar,
            controlWidth: 270
          )
          .anclaDeAjuste(.modeloParaOrdenar)

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

  private func etiqueta(_ id: String, recomendado: ModeloDeAnthropic) -> String {
    let nombre = ModelosDeAnthropic.conocido(id)?.nombre ?? id
    return id == recomendado.id ? String(localized: "\(nombre) (recomendado)") : nombre
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
