import AppKit
import DiloModes
import SwiftUI

/// **Claude Code por voz** en Ajustes → Claude: dónde está la CLI, con qué
/// modelo, y los proyectos que se nombran al hablarle («Claude Code, en
/// Dilo, revisa los tests»).
///
/// De fábrica cada carpeta de `~/Developer` es un proyecto con su nombre; uno
/// escrito acá le gana al de `~/Developer` con el mismo nombre. Lo que mira
/// el disco o corre la CLI va en `Task.detached`, nunca en el `body`.
struct ClaudeCodeSettingsCard: View {
  @Bindable var settings: AppSettings

  @Environment(\.colorSchemeContrast) private var contrast
  /// Qué se encontró de la CLI: versión y ruta, o que no está.
  @State private var estado: String?
  @State private var deDeveloper: [ProyectoDeClaudeCode] = []

  /// Los alias que entiende `--model`. Vacío: el de la persona.
  private static let modelos = ["", "sonnet", "opus", "haiku"]

  var body: some View {
    SettingsCard(
      title: "Claude Code por voz",
      icono: "terminal.fill",
      detalle: "Dile «Claude Code, en Dilo, revisa los tests» y abre una sesión en esa carpeta. Usa tu cuenta de Claude Code, no tu clave de Anthropic."
    ) {
      SettingsRow(
        title: "Dónde está Claude Code",
        description: "\(estado ?? String(localized: "Buscando…")) Vacío, Dilo lo busca donde lo deja el instalador y en tu shell."
      ) {
        TextField("Automático", text: $settings.claudeCodeRuta)
          .labelsHidden()
          .frame(width: 200)
          .onSubmit { Task { await mirar() } }
      }
      .anclaDeAjuste(.rutaDeClaudeCode)

      SettingsPickerRow(
        title: "Modelo de Claude Code",
        description: "El de tu Claude Code es el que tengas configurado en él. Lo que hace Claude Code se cobra a tu plan, no a tu clave.",
        options: Self.modelos,
        optionLabel: Self.etiqueta,
        selection: $settings.claudeCodeModelo,
        controlWidth: 200
      )
      .anclaDeAjuste(.modeloDeClaudeCode)

      SettingsRow(
        title: "Proyectos de ~/Developer",
        description: "Cada carpeta de ~/Developer se nombra por su nombre: «en dilo landing», «en switchboard». Hoy son \(deDeveloper.count)."
      ) {
        Toggle("Proyectos de ~/Developer", isOn: $settings.claudeCodeIncluirDeveloper)
          .labelsHidden()
          .toggleStyle(.switch)
      }
      .anclaDeAjuste(.proyectosDeDeveloper)

      SettingsRow(
        title: "Tus proyectos",
        description: "Un nombre para decir y su carpeta. Le gana a uno de ~/Developer con el mismo nombre: así «Dilo» puede ir a otra carpeta."
      ) {
        Button("Agregar carpeta…") { agregar() }
          .buttonStyle(SettingsButtonStyle(compacto: true))
      }
      .anclaDeAjuste(.proyectosDeClaudeCode)

      ForEach($settings.claudeCodeProyectos) { $proyecto in
        HStack(spacing: 10) {
          TextField("Nombre", text: $proyecto.nombre)
            .labelsHidden()
            .frame(width: 140)
          Text(verbatim: proyecto.carpeta)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
            .truncationMode(.middle)
            .help(proyecto.carpeta)
          Spacer(minLength: 8)
          Button("Quitar") { quitar(proyecto) }
            .buttonStyle(SettingsButtonStyle(compacto: true))
        }
        .padding(.vertical, 6)
      }

      Text(
        "Cada permiso que pide Claude Code se aprueba con un clic en la muesca; la voz nunca aprueba. Dilo no lee los archivos de Claude Code: qué sesiones hay se lo pregunta a la CLI."
      )
      .font(.caption)
      .foregroundStyle(.white.opacity(contrast == .increased ? 0.7 : 0.45))
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 8)
    }
    .task { await mirar() }
  }

  private static func etiqueta(_ modelo: String) -> String {
    switch modelo {
    case "": String(localized: "El de tu Claude Code")
    case "sonnet": "Sonnet"
    case "opus": "Opus"
    case "haiku": "Haiku"
    default: modelo
    }
  }

  /// Busca la CLI y lista `~/Developer`, fuera del hilo principal.
  private func mirar() async {
    let ruta = settings.claudeCodeRuta
    let (encontrado, proyectos) = await Task.detached(priority: .utility) {
      (ClaudeCodeSettingsCard.describir(ruta: ruta), DestinoClaudeCode.proyectosDeDeveloper())
    }.value
    estado = encontrado
    deDeveloper = proyectos
  }

  nonisolated private static func describir(ruta: String) -> String {
    guard let ejecutable = DestinoClaudeCode.ubicar(ruta: ruta) else {
      return String(localized: "No encontré la CLI claude.")
    }
    let lugar = (ejecutable.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    return String(localized: "Encontrada en \(lugar).")
  }

  private func agregar() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = String(localized: "Agregar")
    panel.message = String(localized: "Elige la carpeta del proyecto. Su nombre es el que vas a decir; lo puedes cambiar.")
    NSApp.activate()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let carpeta = url.path(percentEncoded: false)
    let sinBarra = carpeta.hasSuffix("/") ? String(carpeta.dropLast()) : carpeta
    guard !settings.claudeCodeProyectos.contains(where: { $0.carpeta == sinBarra }) else { return }
    settings.claudeCodeProyectos.append(ProyectoDeClaudeCode(nombre: url.lastPathComponent, carpeta: sinBarra))
  }

  private func quitar(_ proyecto: ProyectoDeClaudeCode) {
    settings.claudeCodeProyectos.removeAll { $0.carpeta == proyecto.carpeta }
  }
}
