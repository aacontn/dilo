import AppIntents

/// Las acciones que aparecen solas en Spotlight, en Siri y en la app Atajos
/// sin que nadie arme nada. Cada frase nombra la app, como exige la API; el
/// inglés se traduce desde acá en `AppShortcuts.xcstrings`.
///
/// No están todas: «Último dictado», «Mostrar en la muesca», «Última
/// reunión» y «Buscar en tus reuniones» devuelven o reciben algo y sólo
/// tienen sentido dentro de un atajo, donde se eligen igual. Apple deja diez.
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
      intent: GrabarReunionIntent(),
      phrases: ["Grabar una reunión con \(.applicationName)", "Grabar la reunión con \(.applicationName)"],
      shortTitle: "Grabar una reunión",
      systemImageName: "record.circle"
    )
    AppShortcut(
      intent: TerminarReunionIntent(),
      phrases: ["Terminar la reunión en \(.applicationName)"],
      shortTitle: "Terminar la reunión",
      systemImageName: "stop.circle"
    )
    AppShortcut(
      intent: BuscarEnHistorialIntent(),
      phrases: ["Buscar en el historial de \(.applicationName)"],
      shortTitle: "Buscar dictados",
      systemImageName: "magnifyingglass"
    )
  }
}
