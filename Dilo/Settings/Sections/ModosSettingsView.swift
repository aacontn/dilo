import DiloModes
import SwiftUI

/// Los modos: cada uno con su tecla y su IA.
///
/// Se acabó el "modo activo" (spec 2026-08-05). No hay un desplegable que
/// elige cuál manda: la lista muestra los cinco, cada uno dice si su texto
/// sale de esta compu, y la tecla se graba en la misma fila. Un atajo que no
/// puede dispararse no se puede guardar, y una tecla ya ocupada avisa — que
/// es lo que faltaba el día que Alfonso descubrió que de sus cinco modos uno
/// era invocable y estaba roto.
struct ModosSettingsView: View {
  @Bindable var settings: AppSettings

  @Environment(\.colorSchemeContrast) private var contrast
  @State private var modoEnEdicion: String?
  @State private var grabando: String?
  @State private var reparo: String?
  @State private var confirmandoRestaurar = false

  private let llavero = Llavero()

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsCard(title: "Tus modos") {
        ForEach(settings.modos) { modo in
          fila(modo)
        }

        SettingsRow(
          title: "Tu lista",
          description: "Aprieta la tecla de un modo desde cualquier app y dicta directo con él. El dictado normal no pasa por ninguna IA."
        ) {
          HStack(spacing: 8) {
            Button("Restaurar los de fábrica…") { confirmandoRestaurar = true }
              .buttonStyle(SettingsButtonStyle())
            Button("Agregar modo") { agregarModo() }
              .buttonStyle(SettingsButtonStyle())
          }
        }
      }

      if let reparo {
        Text(reparo)
          .font(.caption)
          .foregroundStyle(SettingsTheme.accent)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 6)
      }

      SettingsCard(title: "Un atajo, Dilo decide") {
        SettingsRow(
          title: "Que Dilo elija el modo",
          description: "Con esto prendido, el atajo de dictar de siempre elige modo solo: mira qué app tienes al frente y qué dijiste. Si no lo tiene claro, no toca nada y tu dictado sale como salió. El historial anota cuál eligió y por qué."
        ) {
          Toggle("Que Dilo elija el modo", isOn: $settings.unAtajoDiloDecide)
            .labelsHidden()
            .toggleStyle(.switch)
        }

        SettingsRow(
          title: "Cuándo corresponde cada modo",
          description: "Las apps y las palabras que delatan a cada modo son lo que Dilo mira para decidir. Se editan dentro del modo, en «Afinarlo más»."
        ) { EmptyView() }
      }

      SettingsCard(title: "Proveedor general") {
        SettingsRow(
          title: "Quién reescribe",
          description: "El que usan los modos que no eligieron uno propio."
        ) {
          Picker("Proveedor general", selection: $settings.proveedorGeneralID) {
            ForEach(settings.proveedores) { proveedor in
              Text(proveedor.nombre).tag(proveedor.id)
            }
          }
          .labelsHidden()
          .frame(width: 240)
        }

        if let indice = indiceDelGeneral {
          configuracionDelProveedor(indice)
        }
      }

      Text(
        "Las claves de API se guardan en el Llavero de macOS, nunca en un archivo de ajustes. El modelo de Apple corre acá mismo: no necesita clave, ni cuenta, ni internet."
      )
      .font(.caption)
      .foregroundStyle(.white.opacity(contrast == .increased ? 0.7 : 0.45))
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 6)
    }
    .sheet(item: modoEditado) { modo in
      if let indice = settings.modos.firstIndex(where: { $0.id == modo.id }) {
        ModoEditorView(
          modo: bindingDeModo(indice),
          proveedores: settings.proveedores,
          proveedorGeneral: settings.proveedores.proveedor(settings.proveedorGeneralID),
          alBorrar: modo.esDeFabrica ? nil : { borrarModo(modo.id) }
        )
      }
    }
    .confirmationDialog(
      "¿Volver a los modos de fábrica?",
      isPresented: $confirmandoRestaurar
    ) {
      Button("Restaurar", role: .destructive) { settings.restaurarModosDeFabrica() }
    } message: {
      Text("Reemplaza tu lista por los cinco de fábrica. No se puede deshacer.")
    }
  }

  private func fila(_ modo: Modo) -> some View {
    SettingsRow(title: "\(modo.nombre)", description: descripcion(de: modo)) {
      HStack(spacing: 10) {
        Text(etiquetaDeDestino(modo))
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.white.opacity(0.55))
        grabadorDeTecla(modo)
        Button("Editar") { modoEnEdicion = modo.id }
          .buttonStyle(SettingsButtonStyle())
      }
    }
  }

  /// La tecla del modo, grabada en la misma fila. El binding es el que valida:
  /// nada llega a los ajustes sin pasar por el validador y por la búsqueda de
  /// colisiones.
  private func grabadorDeTecla(_ modo: Modo) -> some View {
    KeyRecorderView(
      keyBinding: Binding(
        get: { modo.gatillo.flatMap(KeyBinding.init) ?? .controlCommandL },
        set: { asignar($0, a: modo.id) }
      ),
      allowsBareModifier: false,
      allowsMouseButton: false,
      isRecording: Binding(
        get: { grabando == modo.id },
        set: { armado in
          grabando = armado ? modo.id : nil
          if armado { reparo = nil }
        }
      ),
      onRecordingChanged: { settings.isRecordingKeybind = $0 }
    ) { binding, estaGrabando in
      Text(estaGrabando ? "…" : (modo.gatillo?.etiqueta ?? String(localized: "Sin tecla")))
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(estaGrabando ? SettingsTheme.accent : .white.opacity(0.8))
        .frame(minWidth: 74)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: 7)
            .fill(.white.opacity(binding.label.isEmpty ? 0.06 : 0.1))
        )
    }
  }

  private func asignar(_ binding: KeyBinding, a id: String) {
    grabando = nil
    let gatillo = binding.gatillo

    // Contra **todos** los atajos de Dilo, no sólo contra los otros modos:
    // así era como un modo podía quedarse con la tecla del dictado normal y
    // no disparar nunca sin que nada lo dijera.
    let veredicto = ValidadorDeGatillos.revisar(
      gatillo, entre: settings.gatillosEnUso, salvo: id
    )
    if let reparoDelValidador = veredicto.reparo {
      reparo = reparoDelValidador.explicacion
      return
    }
    reparo = nil
    guard let indice = settings.modos.firstIndex(where: { $0.id == id }) else { return }
    settings.modos[indice].gatillo = gatillo
  }

  /// El prompt es del usuario y sale tal cual; el vacío sí es copy nuestro.
  private func descripcion(de modo: Modo) -> LocalizedStringKey {
    let prompt = modo.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    return prompt.isEmpty ? "Todavía sin instrucciones" : "\(prompt)"
  }

  /// LOCAL o EN LÍNEA: el vistazo que responde "¿cuáles de mis modos mandan
  /// texto afuera?". Se deriva del proveedor, nunca se guarda.
  private func etiquetaDeDestino(_ modo: Modo) -> String {
    let proveedor = settings.proveedores.proveedor(modo.proveedorID)
      ?? settings.proveedores.proveedor(settings.proveedorGeneralID)
    guard let proveedor else { return "" }
    return proveedor.etiquetaLocalOEnLinea
  }

  private var indiceDelGeneral: Int? {
    settings.proveedores.firstIndex { $0.id == settings.proveedorGeneralID }
  }

  @ViewBuilder
  private func configuracionDelProveedor(_ indice: Int) -> some View {
    let proveedor = settings.proveedores[indice]
    if proveedor.dialecto == .enElChip {
      SettingsRow(
        title: "No hay nada que configurar",
        description: ClienteEnElChip.porQueNoSePuede().map { "\($0)" }
          ?? "El modelo de Apple corre en esta compu. Sin clave y sin internet."
      ) { EmptyView() }
    } else {
      SettingsRow(title: "Modelo", description: "El id tal cual lo muestra su consola.") {
        TextField(
          "Modelo",
          text: Binding(
            get: { settings.proveedores[indice].modelo },
            set: { settings.proveedores[indice].modelo = $0 }
          )
        )
        .labelsHidden()
        .frame(width: 240)
      }
      SettingsRow(
        title: "URL base",
        description: "Cámbiala si usas otra región o apuntas a tu propio servidor."
      ) {
        TextField(
          "URL base",
          text: Binding(
            get: { settings.proveedores[indice].urlBase?.absoluteString ?? "" },
            set: { settings.proveedores[indice].urlBase = URL(string: $0) }
          )
        )
        .labelsHidden()
        .frame(width: 240)
      }
      if proveedor.necesitaClave {
        SettingsRow(
          title: "API key",
          description: "Se guarda en el Llavero de macOS. Dilo no la escribe en ningún archivo ni la muestra en pantalla."
        ) {
          SecureField(
            "API key",
            text: Binding(
              get: { llavero.clave(para: proveedor.cuentaEnElLlavero) ?? "" },
              set: { nueva in
                let limpia = nueva.trimmingCharacters(in: .whitespacesAndNewlines)
                if limpia.isEmpty {
                  try? llavero.borrar(proveedor.cuentaEnElLlavero)
                } else {
                  try? llavero.guardar(limpia, para: proveedor.cuentaEnElLlavero)
                }
              }
            )
          )
          .labelsHidden()
          .frame(width: 240)
        }
      }
    }
  }

  private var modoEditado: Binding<Modo?> {
    Binding(
      get: { settings.modos.first { $0.id == modoEnEdicion } },
      set: { modoEnEdicion = $0?.id }
    )
  }

  private func bindingDeModo(_ indice: Int) -> Binding<Modo> {
    Binding(
      get: { settings.modos[indice] },
      set: { settings.modos[indice] = $0 }
    )
  }

  private func agregarModo() {
    let modo = Modo(id: UUID().uuidString, nombre: "Modo nuevo", prompt: "")
    settings.modos.append(modo)
    modoEnEdicion = modo.id
  }

  private func borrarModo(_ id: String) {
    modoEnEdicion = nil
    settings.modos.removeAll { $0.id == id }
  }
}

/// El detalle de un modo: nombre, instrucciones y su IA. La tecla se graba en
/// la lista, donde se ve junto a las otras y donde una colisión salta.
struct ModoEditorView: View {
  @Binding var modo: Modo
  let proveedores: [Proveedor]
  let proveedorGeneral: Proveedor?
  let alBorrar: (() -> Void)?

  @Environment(\.dismiss) private var cerrar

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Modo")
        .font(.system(size: 15, weight: .semibold))

      TextField("Nombre", text: $modo.nombre)
        .textFieldStyle(.roundedBorder)

      Text("Qué hacer con lo que dictaste")
        .font(.caption)
      TextEditor(text: $modo.prompt)
        .font(.system(size: 12))
        .frame(height: 110)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.12)))

      // El ejemplo y el recordatorio de cierre vienen de los prompts que
      // heredamos del árbol de origen, y son lo que alguien más trabajo se tomó en
      // escribir. Van escondidos porque casi nadie los usa, pero tienen que
      // estar: la migración los trajo y sin esto no habría dónde verlos.
      DisclosureGroup("Afinarlo más") {
        VStack(alignment: .leading, spacing: 10) {
          Text("Lo que va al final, después de lo que dictaste")
            .font(.caption)
          TextField("Por ejemplo: no inventes datos", text: $modo.instruccionFinal)
            .textFieldStyle(.roundedBorder)

          Text("Un ejemplo enseña más que una regla. Escribe un dictado con forma de pregunta y su reescritura: así el modelo aprende que una pregunta sigue siendo una pregunta, en vez de contestarla.")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
          TextField("Lo que se dictó", text: $modo.ejemploEntrada)
            .textFieldStyle(.roundedBorder)
          TextField("Cómo debería quedar", text: $modo.ejemploSalida)
            .textFieldStyle(.roundedBorder)

          Text("Cuándo corresponde este modo, si dejas que Dilo elija: las apps donde aplica y las palabras que lo delatan, separadas por coma.")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
          TextField("Apps", text: lista($modo.apps))
            .textFieldStyle(.roundedBorder)
          TextField("Palabras clave", text: lista($modo.palabrasClave))
            .textFieldStyle(.roundedBorder)
        }
        .padding(.top, 8)
      }

      Picker("IA de este modo", selection: proveedorElegido) {
        Text(textoDelGeneral).tag("")
        ForEach(proveedores) { proveedor in
          Text("\(proveedor.nombre) · \(proveedor.etiquetaLocalOEnLinea)")
            .tag(proveedor.id)
        }
      }

      HStack {
        if let alBorrar {
          Button("Eliminar modo", role: .destructive) {
            alBorrar()
            cerrar()
          }
        } else {
          Text("Los modos de fábrica no se eliminan: vuelven solos. Puedes cambiarles el nombre, las instrucciones o quitarles la tecla.")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        Button("Listo") { cerrar() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 420)
  }

  /// Una lista escrita en una línea, separada por comas. Lo vacío no cuenta,
  /// así que "correo, , mail," son dos entradas y no cuatro.
  private func lista(_ valores: Binding<[String]>) -> Binding<String> {
    Binding(
      get: { valores.wrappedValue.joined(separator: ", ") },
      set: { texto in
        valores.wrappedValue = texto
          .split(separator: ",")
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty }
      }
    )
  }

  /// "" es heredar el general. Es el default y no exige migrar nada: una
  /// configuración vieja, sin proveedor por modo, se lee igual.
  private var proveedorElegido: Binding<String> {
    Binding(
      get: { modo.proveedorID ?? "" },
      set: { modo.proveedorID = $0.isEmpty ? nil : $0 }
    )
  }

  private var textoDelGeneral: String {
    guard let proveedorGeneral else { return String(localized: "El general") }
    return String(localized: "El general (\(proveedorGeneral.nombre))")
  }
}

/// LOCAL o EN LÍNEA: la misma etiqueta la usan la fila y el editor, y las dos
/// la muestran traducida.
extension Proveedor {
  var etiquetaLocalOEnLinea: String {
    esLocal ? String(localized: "LOCAL") : String(localized: "EN LÍNEA")
  }
}
