import DiloModes
import SwiftUI

/// La clave de un proveedor: si está guardada lo dice, y si no, un campo
/// que se guarda **al confirmar** —Intro o «Guardar»—, nunca por tecla.
///
/// Reemplaza al `SecureField` de Modos, que leía el Llavero en su `get:` (una
/// consulta síncrona en cada evaluación del `body`) y escribía en su `set:`
/// en cada tecla: diez letras pegadas eran diez escrituras en `securityd`
/// desde el hilo principal, y era lo que congelaba la ventana (2026-10-19).
/// Tampoco vuelve a mostrar la clave guardada, ni como puntos: lo que no
/// hace falta traer del Llavero no se trae.
struct CampoDeClave: View {
  let cuenta: String
  let claves: ClavesDeLosProveedores
  var ancho: CGFloat = 260

  @State private var borrador = ""
  @State private var cambiando = false
  @State private var guardando = false
  @State private var falla: String?

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      switch claves.estado(de: cuenta) {
      case .sinLeer, .leyendo:
        ProgressView()
          .controlSize(.small)
          .frame(height: 22)
      case .hay where !cambiando:
        HStack(spacing: 8) {
          Label("Guardada en el Llavero", systemImage: "checkmark.seal.fill")
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(PaletaDeDilo.actual.exito.color)
            .labelStyle(.titleAndIcon)
          Button("Cambiar") {
            borrador = ""
            cambiando = true
          }
          .buttonStyle(SettingsButtonStyle(compacto: true))
          Button("Quitar") { Task { await quitar() } }
            .buttonStyle(SettingsButtonStyle(compacto: true))
        }
      case .hay, .falta:
        HStack(spacing: 8) {
          SecureField("Pega tu clave", text: $borrador)
            .textFieldStyle(.roundedBorder)
            .frame(width: ancho - (cambiando ? 150 : 80))
            .onSubmit { Task { await guardar() } }
          Button(guardando ? "Guardando…" : "Guardar") { Task { await guardar() } }
            .buttonStyle(SettingsButtonStyle(compacto: true))
            .disabled(guardando || borrador.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          if cambiando {
            Button("Cancelar") {
              borrador = ""
              cambiando = false
            }
            .buttonStyle(SettingsButtonStyle(compacto: true))
          }
        }
      }
      if let falla {
        Text(falla)
          .font(.caption)
          .foregroundStyle(PaletaDeDilo.actual.error.color)
      }
    }
    .task(id: cuenta) { await claves.mirar(cuenta) }
  }

  private func guardar() async {
    guard !guardando else { return }
    guardando = true
    defer { guardando = false }
    do {
      try await claves.guardar(borrador, para: cuenta)
      borrador = ""
      cambiando = false
      falla = nil
    } catch {
      falla = String(localized: "El Llavero no la guardó. Prueba otra vez.")
    }
  }

  private func quitar() async {
    do {
      try await claves.borrar(cuenta)
      falla = nil
    } catch {
      falla = String(localized: "El Llavero no la quitó. Prueba otra vez.")
    }
  }
}
