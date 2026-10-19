import AppKit
import DiloPlataforma
import SwiftUI

/// La tarjeta «Agentes» de Datos en la muesca: el interruptor, las líneas
/// que se pegan en Claude Code y en Codex con su «Copiar», y «Probar».
///
/// Dilo **no instala** las líneas: la configuración de otra herramienta es de
/// la persona, y un *hook* mal puesto le falla a ella, no a Dilo. Por eso la
/// tarjeta las muestra enteras, con la ruta del script de esta copia, y
/// «Probar» pone el aviso sin pasar por el agente.
struct AgentesSettingsCard: View {
  @Bindable var settings: AppSettings
  /// Pone «Claude te espera» en la muesca. Nil en los renders, que no
  /// tienen muesca: entonces no hay botón.
  var probar: (() -> Void)?
  /// La ruta del script dentro de esta copia de Dilo. Se inyecta para que
  /// los renders muestren una ruta estable.
  var script: String = AgentesSettingsCard.rutaDelScript

  @State private var copiado: String?

  static var rutaDelScript: String {
    let nombre = (LineasDeLosHooks.nombreDelScript as NSString).deletingPathExtension
    return Bundle.main.url(forResource: nombre, withExtension: "sh")?.path(percentEncoded: false)
      ?? "/Applications/Dilo.app/Contents/Resources/\(LineasDeLosHooks.nombreDelScript)"
  }

  var body: some View {
    SettingsCard(title: "Agentes") {
      SettingsRow(
        title: "Mostrar agentes en la muesca",
        description: "Claude Code, Codex y otros avisan por su hook cuando trabajan, terminan o te esperan, y la muesca lo muestra al costado. Dilo no lee sus archivos ni sus credenciales: sólo sabe lo que el agente le avisa."
      ) {
        Toggle("", isOn: $settings.hudAgentes)
          .labelsHidden()
          .toggleStyle(.switch)
          .accessibilityLabel(Text("Mostrar agentes en la muesca"))
      }
      .anclaDeAjuste(.agentesEnLaMuesca)

      if settings.hudAgentes {
        LineaParaCopiar(
          titulo: "Claude Code",
          detalle: "En ~/.claude/settings.json (o el de un proyecto), dentro del objeto de más afuera:",
          texto: Self.soloElBloque(LineasDeLosHooks.claudeCode(script: script)),
          copiado: $copiado
        )
        LineaParaCopiar(
          titulo: "Codex",
          detalle: "En ~/.codex/config.toml. Codex avisa sólo al terminar cada turno:",
          texto: LineasDeLosHooks.codex(script: script),
          copiado: $copiado
        )
        if let probar {
          SettingsRow(
            title: "Probar",
            description: "Pone «Claude te espera» al costado de la muesca, como lo haría el hook. Un clic en el segmento lo quita."
          ) {
            Button("Probar") { probar() }
              .buttonStyle(SettingsButtonStyle())
          }
        }
      }
    }
  }

  /// El JSON sin las llaves de afuera: lo que se pega dentro de un
  /// `settings.json` que ya tiene otras cosas.
  static func soloElBloque(_ json: String) -> String {
    var lineas = json.components(separatedBy: "\n")
    guard lineas.first == "{", lineas.last == "}" else { return json }
    lineas.removeFirst()
    lineas.removeLast()
    return lineas.map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0 }.joined(separator: "\n")
  }
}

/// Un bloque de texto monoespaciado con su «Copiar».
private struct LineaParaCopiar: View {
  let titulo: LocalizedStringKey
  let detalle: LocalizedStringKey
  let texto: String
  @Binding var copiado: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(titulo)
            .font(.system(size: 13, weight: .medium))
          Text(detalle)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 12)
        Button(copiado == texto ? "Copiado" : "Copiar") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(texto, forType: .string)
          copiado = texto
        }
        .buttonStyle(SettingsButtonStyle())
      }
      ScrollView(.horizontal) {
        Text("\(texto)")
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(.white.opacity(0.8))
          .textSelection(.enabled)
          .fixedSize()
          .padding(10)
      }
      .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .padding(.vertical, 11)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(.white.opacity(0.07))
        .frame(height: 1)
    }
  }
}
