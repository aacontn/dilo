import DiloCapabilities
import DiloModes
import SwiftUI

/// Lo que un modo sabe de dónde estás dictando: cada fuente con su
/// interruptor. Vive dentro de Modos porque sólo lo usan los modos: el
/// dictado sin modo no pasa por ningún modelo y no lee nada.
///
/// Lo que lee otra app (el texto alrededor del cursor, la selección, el
/// sitio) **se esconde** donde el anfitrión no puede leerlo, como en App
/// Store: preguntar por una capacidad es antes de dibujar, nunca al apretar.
struct ContextoDeLosModosCard: View {
  @Bindable var settings: AppSettings
  var anfitrion: any HostCapabilities = Anfitrion.actual

  var body: some View {
    SettingsCard(title: "Lo que el modo sabe de dónde dictas") {
      SettingsRow(
        title: "La app",
        description: "El nombre de la app y qué tipo de app es: correo, chat, código. No dice nada de lo que escribes."
      ) {
        interruptor("La app", \.app)
      }
      .anclaDeAjuste(.contextoApp)

      if anfitrion.admite(.contextoDelCampo) {
        SettingsRow(
          title: "El texto alrededor del cursor",
          description: "Hasta 500 caracteres antes y después de donde vas a pegar, para que el modo escriba bien los nombres que ya están ahí. Se lee al empezar a dictar y se olvida al pegar."
        ) {
          interruptor("El texto alrededor del cursor", \.textoAlrededor)
        }
        .anclaDeAjuste(.contextoTexto)

        SettingsRow(
          title: "Lo que tienes seleccionado",
          description: "Si dictas con algo seleccionado, el modo lo ve como referencia. Nunca lo copia a tu texto."
        ) {
          interruptor("Lo que tienes seleccionado", \.seleccion)
        }
        .anclaDeAjuste(.contextoSeleccion)
      }

      if anfitrion.admite(.sitioDelNavegador) {
        SettingsRow(
          title: "El sitio del navegador",
          description: "Sólo el dominio y la ruta, como github.com/tu-repo. Lo que va después del «?» no se lee nunca."
        ) {
          interruptor("El sitio del navegador", \.sitio)
        }
        .anclaDeAjuste(.contextoSitio)
      }

      SettingsRow(
        title: "También a proveedores en línea",
        description: "Con el modelo de Apple, o uno que corre en este Mac, el contexto nunca sale de acá. Con un proveedor EN LÍNEA viaja junto a tu dictado sólo si prendes esto. Ni el historial ni el disco lo guardan nunca."
      ) {
        interruptor("También a proveedores en línea", \.tambienEnLinea)
      }
      .anclaDeAjuste(.contextoEnLinea)
    }
  }

  private func interruptor(
    _ nombre: LocalizedStringKey, _ fuente: WritableKeyPath<FuentesDeContexto, Bool>
  ) -> some View {
    Toggle(nombre, isOn: Binding(
      get: { settings.fuentesDeContexto[keyPath: fuente] },
      set: { settings.fuentesDeContexto[keyPath: fuente] = $0 }
    ))
    .labelsHidden()
    .toggleStyle(.switch)
  }
}
