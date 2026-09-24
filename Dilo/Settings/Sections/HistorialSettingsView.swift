import AppKit
import SwiftUI

/// El historial, desde adentro: buscar, copiar y borrar una entrada.
///
/// Los archivos diarios siguen siendo texto plano en una carpeta que ves en
/// el Finder, y eso no cambia — es lo que te deja leerlos, buscarlos y
/// borrarlos con tus propias herramientas. Esto es lo mismo sin salir de
/// Dilo, con el modo con que dictaste cada cosa.
struct HistorialSettingsView: View {
  @Bindable var settings: AppSettings

  @Environment(\.colorSchemeContrast) private var contrast
  @State private var consulta = ""
  @State private var entradas: [DictationHistoryStore.Entrada] = []
  @State private var copiada: String?

  private let store = DictationHistoryStore()

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsCard(title: "Historial") {
        SettingsRow(
          title: "Buscar",
          description: settings.dictationHistoryEnabled
            ? "Busca en lo que dictaste, en la app y en el modo. Sin tildes y sin mayúsculas: se busca como se recuerda."
            : "El historial está apagado. Préndelo en Dictado para empezar a guardar lo que dictas."
        ) {
          TextField("Buscar", text: $consulta)
            .frame(width: 200)
            .onSubmit { cargar() }
            .onChange(of: consulta) { _, _ in cargar() }
        }

        if entradas.isEmpty {
          SettingsRow(
            title: consulta.isEmpty ? "Todavía no hay nada" : "Nada que calce",
            description: consulta.isEmpty
              ? "Lo que dictes aparece acá, con el modo que usaste."
              : "Prueba con otra palabra."
          ) { EmptyView() }
        }

        ForEach(entradas.prefix(50)) { entrada in
          fila(entrada)
        }
      }

      if entradas.count > 50 {
        Text("Se muestran las 50 más nuevas. Busca para acotar.")
          .font(.caption)
          .foregroundStyle(.white.opacity(contrast == .increased ? 0.7 : 0.45))
          .padding(.horizontal, 6)
      }
    }
    .onAppear { cargar() }
  }

  private func fila(_ entrada: DictationHistoryStore.Entrada) -> some View {
    // Lo dictado, la fecha, la app, el modo y el motor son datos: van como
    // valor, no como copy. El motor entra en `procedencia` desde el
    // 2026-09-22, para que «¿esto se transcribió con Apple o con Parakeet?»
    // tenga respuesta sin abrir el archivo.
    let sello = entrada.procedencia.isEmpty
      ? "\(entrada.dia) \(entrada.hora)"
      : "\(entrada.dia) \(entrada.hora) · \(entrada.procedencia)"
    return SettingsRow(
      title: "\(entrada.texto)",
      description: "\(sello)"
    ) {
      HStack(spacing: 8) {
        // Íconos y no palabras, como en el notch (2026-09-24): el nombre va en
        // la ayuda y para VoiceOver.
        Button { copiar(entrada) } label: {
          Image(systemName: copiada == entrada.id ? "checkmark" : "doc.on.doc")
            .foregroundStyle(copiada == entrada.id ? DiloBrand.menta : .primary)
        }
        .buttonStyle(SettingsButtonStyle())
        .help(copiada == entrada.id ? "Copiado" : "Copiar")
        .accessibilityLabel(Text(copiada == entrada.id ? "Copiado" : "Copiar"))
        Button { borrar(entrada) } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(SettingsButtonStyle())
        .help("Borrar")
        .accessibilityLabel(Text("Borrar"))
      }
    }
  }

  private func cargar() {
    let carpeta = settings.resolvedHistoryFolder
    let busqueda = consulta
    Task {
      let encontradas = await Task.detached {
        (try? await DictationHistoryStore().buscar(busqueda, in: carpeta)) ?? []
      }.value
      entradas = encontradas
    }
  }

  /// Copiar es siempre una acción explícita: Dilo no toca tu portapapeles
  /// por su cuenta.
  private func copiar(_ entrada: DictationHistoryStore.Entrada) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(entrada.texto, forType: .string)
    copiada = entrada.id
  }

  private func borrar(_ entrada: DictationHistoryStore.Entrada) {
    let carpeta = settings.resolvedHistoryFolder
    Task {
      try? await store.borrar(entrada, in: carpeta)
      cargar()
    }
  }
}
