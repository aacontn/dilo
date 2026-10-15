import AppIntents

/// Las acciones que aparecen solas en Spotlight, en Siri y en la app Atajos
/// sin que nadie arme nada. Cada frase nombra la app, como exige la API; el
/// inglés se traduce desde acá en `AppShortcuts.xcstrings`.
///
/// No están todas: «Último dictado» y «Mostrar en la muesca» devuelven o
/// reciben algo y sólo tienen sentido dentro de un atajo, donde se eligen
/// igual.
struct AtajosDeDilo: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: DictarIntent(),
      phrases: [
        "Dictar con \(.applicationName)",
        "Empezar a dictar con \(.applicationName)",
        "Dictar con \(.applicationName) en \(\.$modo)",
      ],
      shortTitle: "Dictar",
      systemImageName: "mic"
    )
    AppShortcut(
      intent: DictarNotaIntent(),
      phrases: ["Dictar una nota con \(.applicationName)", "Nota rápida en \(.applicationName)"],
      shortTitle: "Dictar una nota",
      systemImageName: "note.text"
    )
    AppShortcut(
      intent: ElegirModoIntent(),
      phrases: [
        "Elegir el modo de \(.applicationName)",
        "Usar \(\.$modo) en \(.applicationName)",
      ],
      shortTitle: "Elegir modo",
      systemImageName: "wand.and.stars"
    )
    AppShortcut(
      intent: CopiarUltimoDictadoIntent(),
      phrases: ["Copiar el último dictado de \(.applicationName)", "Copiar lo último de \(.applicationName)"],
      shortTitle: "Copiar el último dictado",
      systemImageName: "doc.on.doc"
    )
    AppShortcut(
      intent: TranscribirArchivoIntent(),
      phrases: ["Transcribir un archivo con \(.applicationName)"],
      shortTitle: "Transcribir un archivo",
      systemImageName: "waveform"
    )
    AppShortcut(
      intent: BuscarEnHistorialIntent(),
      phrases: ["Buscar en el historial de \(.applicationName)"],
      shortTitle: "Buscar dictados",
      systemImageName: "magnifyingglass"
    )
  }
}
