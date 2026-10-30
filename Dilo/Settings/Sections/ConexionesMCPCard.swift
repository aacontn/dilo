import DiloAgentes
import SwiftUI

/// Los servidores MCP que la persona conecta a la **Conversación**, en
/// Ajustes → Claude: nombre, comando, argumentos y variables de entorno sin
/// secretos. Sus herramientas entran al agente Dilo (si se deja) y a un
/// agente propio del tipo «MCP».
///
/// Dilo no los descubre leyendo la configuración de otras herramientas: se
/// agregan acá. «Probar» lanza el servidor y lista sus herramientas, sólo al
/// apretarlo.
struct ConexionesMCPCard: View {
  @Bindable var settings: AppSettings

  @Environment(\.colorSchemeContrast) private var contrast
  @State private var editando: String?
  @State private var pruebas: [String: String] = [:]
  @State private var instalados: [String: Bool] = [:]

  var body: some View {
    SettingsCard(
      title: "Conexiones MCP",
      icono: "point.3.connected.trianglepath.dotted",
      detalle: "Servidores que Dilo lanza en tu Mac para usar sus herramientas en la conversación. Lo que no dice que sólo lee, pide un clic antes de correr."
    ) {
      VStack(spacing: 0) {
        ForEach(settings.servidoresMCP) { servidor in
          fila(servidor)
          if editando == servidor.id, let indice = indice(servidor.id) {
            EditorDeServidorMCP(servidor: $settings.servidoresMCP[indice])
          }
        }
      }
      .anclaDeAjuste(.conexionesMCP)

      HStack(spacing: 8) {
        Button("Agregar un servidor", action: agregar)
          .buttonStyle(SettingsButtonStyle(compacto: true))
        if !settings.servidoresMCP.contains(where: { $0.id == ServidorMCPConfigurado.switchboard.id }) {
          Button("Agregar Switchboard") { settings.servidoresMCP.append(.switchboard) }
            .buttonStyle(SettingsButtonStyle(compacto: true))
        }
      }
      .padding(.vertical, 10)

      Text(
        "Switchboard: la primera vez que Dilo lo lanza, Switchboard muestra una solicitud con un código en su ventana «Agentes». Autorízala ahí y elige qué herramientas y proyectos puede usar Dilo; hasta entonces sólo deja ver su estado."
      )
      .font(.caption)
      .foregroundStyle(.white.opacity(contrast == .increased ? 0.7 : 0.45))
      .fixedSize(horizontal: false, vertical: true)
    }
    .task(id: settings.servidoresMCP.map(\.comando)) { await revisarInstalados() }
  }

  private func fila(_ servidor: ServidorMCPConfigurado) -> some View {
    SettingsRow(title: "\(servidor.nombre)", description: "\(descripcion(servidor))") {
      HStack(spacing: 8) {
        Toggle("En Dilo", isOn: campo(servidor.id, \.enDilo))
          .toggleStyle(.checkbox)
          .disabled(!servidor.encendido)
          .help(Text("Sus herramientas también entran al agente Dilo."))
        Button(editando == servidor.id ? "Listo" : "Editar") {
          editando = editando == servidor.id ? nil : servidor.id
        }
        .buttonStyle(SettingsButtonStyle(compacto: true))
        Button("Probar") { probar(servidor) }
          .buttonStyle(SettingsButtonStyle(compacto: true))
          .disabled(!servidor.encendido || pruebas[servidor.id] == String(localized: "Probando…"))
        Toggle("", isOn: campo(servidor.id, \.encendido))
          .labelsHidden()
          .toggleStyle(.switch)
          .accessibilityLabel(Text("Conectar \(servidor.nombre)"))
        Button {
          settings.servidoresMCP.removeAll { $0.id == servidor.id }
          if editando == servidor.id { editando = nil }
        } label: {
          Image(systemName: "minus.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.6))
        .accessibilityLabel(Text("Quitar \(servidor.nombre)"))
        .help(Text("Quitar"))
      }
    }
  }

  private func descripcion(_ servidor: ServidorMCPConfigurado) -> String {
    let linea = ([servidor.comando] + [LineaDeArgumentos.juntar(servidor.argumentos)])
      .filter { !$0.isEmpty }.joined(separator: " ")
    if let prueba = pruebas[servidor.id] { return "\(linea)\n\(prueba)" }
    if instalados[servidor.id] == false {
      return "\(linea)\n" + String(localized: "No encuentro ese programa en este Mac.")
    }
    return linea
  }

  private func indice(_ id: String) -> Int? {
    settings.servidoresMCP.firstIndex { $0.id == id }
  }

  private func campo(_ id: String, _ ruta: WritableKeyPath<ServidorMCPConfigurado, Bool>) -> Binding<Bool> {
    Binding(
      get: { indice(id).map { settings.servidoresMCP[$0][keyPath: ruta] } ?? false },
      set: { nuevo in
        guard let i = indice(id) else { return }
        settings.servidoresMCP[i][keyPath: ruta] = nuevo
      }
    )
  }

  private func agregar() {
    let ids = Set(settings.servidoresMCP.map(\.id))
    var numero = 1
    while ids.contains("servidor-\(numero)") { numero += 1 }
    let id = "servidor-\(numero)"
    settings.servidoresMCP.append(
      ServidorMCPConfigurado(id: id, nombre: String(localized: "Servidor \(numero)"), comando: "", encendido: false)
    )
    editando = id
  }

  /// Lanza el servidor, lista sus herramientas y lo cierra. Sólo con el clic.
  private func probar(_ servidor: ServidorMCPConfigurado) {
    pruebas[servidor.id] = String(localized: "Probando…")
    Task {
      let cliente = ClienteMCP(servidor: servidor)
      let resultado: String
      do {
        let herramientas = try await cliente.herramientas()
        let lectura = herramientas.filter(\.soloLectura).count
        let nombres = herramientas.prefix(6).map(\.nombre).joined(separator: ", ")
        resultado = String(
          localized: "Conecta: \(herramientas.count) herramientas (\(lectura) de lectura). \(nombres)"
        )
      } catch {
        resultado = (error as? FallaDelClienteMCP)?.mensaje ?? error.localizedDescription
      }
      await cliente.cerrar()
      pruebas[servidor.id] = resultado
    }
  }

  /// Si el programa de cada servidor existe, fuera del hilo principal.
  private func revisarInstalados() async {
    let servidores = settings.servidoresMCP
    let resultado = await Task.detached(priority: .utility) {
      Dictionary(uniqueKeysWithValues: servidores.map { servidor -> (String, Bool) in
        let comando = (servidor.comando as NSString).expandingTildeInPath
        // Un nombre suelto se busca en el `PATH` al lanzar: acá no se sabe.
        guard comando.contains("/") else { return (servidor.id, true) }
        return (servidor.id, FileManager.default.isExecutableFile(atPath: comando))
      })
    }.value
    instalados = resultado
  }
}

/// Los campos de un servidor MCP. Las variables de entorno se escriben
/// `NOMBRE=valor`, una por línea, y se guardan sólo si pasan
/// `ReglaDelEntorno`: nada que parezca un secreto.
struct EditorDeServidorMCP: View {
  @Binding var servidor: ServidorMCPConfigurado

  @State private var argumentos = ""
  @State private var entorno = ""
  @State private var reparo: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SettingsRow(title: "Nombre", description: "Cómo se dice, y el nombre de su agente.") {
        TextField("Nombre", text: $servidor.nombre)
          .labelsHidden()
          .frame(width: 260)
      }
      SettingsRow(title: "Comando", description: "La ruta del programa, o un nombre que esté en el PATH (npx, uvx).") {
        TextField("Comando", text: $servidor.comando)
          .labelsHidden()
          .frame(width: 260)
      }
      SettingsRow(title: "Argumentos", description: "Separados por espacios; entre comillas lo que lleva espacios.") {
        TextField("Argumentos", text: $argumentos)
          .labelsHidden()
          .frame(width: 260)
          .onSubmit { servidor.argumentos = LineaDeArgumentos.partir(argumentos) }
          .onChange(of: argumentos) { servidor.argumentos = LineaDeArgumentos.partir(argumentos) }
      }
      SettingsRow(
        title: "Variables de entorno",
        description: "NOMBRE=valor, una por línea. Sin claves ni tokens: Ajustes no es el Llavero."
      ) {
        VStack(alignment: .trailing, spacing: 4) {
          TextEditor(text: $entorno)
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 260, height: 54)
            .scrollContentBackground(.hidden)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06)))
            .onChange(of: entorno) { guardarEntorno() }
          if let reparo {
            Text(reparo)
              .font(.caption)
              .foregroundStyle(SettingsTheme.accent)
              .frame(width: 260, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
    .padding(.leading, 14)
    .onAppear {
      argumentos = LineaDeArgumentos.juntar(servidor.argumentos)
      entorno = servidor.entorno.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }
  }

  /// Guarda las líneas que pasan la regla y dice por qué no la primera que
  /// no.
  private func guardarEntorno() {
    var nuevo: [String: String] = [:]
    var primerReparo: String?
    for linea in entorno.split(whereSeparator: \.isNewline) {
      let partes = linea.split(separator: "=", maxSplits: 1).map(String.init)
      guard let nombre = partes.first?.trimmingCharacters(in: .whitespaces), !nombre.isEmpty else { continue }
      let valor = partes.count > 1 ? partes[1] : ""
      if let problema = ReglaDelEntorno.reparo(nombre: nombre, valor: valor) {
        primerReparo = primerReparo ?? problema
        continue
      }
      nuevo[nombre] = valor
    }
    reparo = primerReparo
    servidor.entorno = nuevo
  }
}
