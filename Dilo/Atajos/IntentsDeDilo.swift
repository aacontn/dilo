import AppIntents
import AppKit
import Foundation
import UniformTypeIdentifiers
import os

// Los App Intents de Dilo: lo que Atajos, Spotlight y Siri pueden pedirle
// (fase 5, plan cap. 4 §7 y cap. 5 §6; 2026-10-15). Propio de Dilo sobre la
// API pública. El juego —dictar, último dictado— sale de la idea de Muesli
// (MIT), que no aporta código; Dilo suma la nota, el modo, copiar, archivos,
// el historial y la muesca.
//
// Todos corren en segundo plano (`supportedModes = .background`): Dilo vive
// en la barra y traerlo al frente le robaría el foco a la app donde vas a
// pegar. Ninguno tiene lógica propia: llaman a `EjecucionDeAtajos` con la app
// viva (`PuenteDeAtajos`), que a su vez llama a lo mismo que el menú de la
// barra y el panel del hover.

/// Empieza un dictado trabado —como un toque al gatillo— o termina el que
/// está en curso.
struct DictarIntent: AppIntent {
  static let title: LocalizedStringResource = "Dictar"
  static let description = IntentDescription(
    "Empieza a dictar donde está el cursor, como un toque al atajo de Dilo. Vuelve a correrlo, toca el atajo o haz clic en la muesca para terminar; Esc cancela."
  )
  static let supportedModes: IntentModes = .background

  @Parameter(
    title: "Modo",
    description: "Vacío usa el modo del atajo general, el que eliges en el panel de la muesca."
  )
  var modo: ModoDeDilo?

  static var parameterSummary: some ParameterSummary {
    Summary("Dictar con \(\.$modo)")
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    let acciones = try PuenteDeAtajos.requerido()
    let respuesta = try EjecucionDeAtajos.dictar(acciones, modo: modo)
    AppLog.plataforma.info("Atajo «Dictar»: \(String(describing: respuesta), privacy: .public)")
    return .result()
  }
}

/// La **Conversación**: hablarle a Dilo y que conteste en voz alta. Correrlo
/// otra vez cuelga.
struct ConversarIntent: AppIntent {
  static let title: LocalizedStringResource = "Conversar con Dilo"
  static let description = IntentDescription(
    "Llama a Dilo para conversar en voz alta: tú hablas, tu voz se transcribe en el Mac y Claude contesta con una voz del Mac. Sólo viaja texto. Córrelo otra vez, o aprieta Colgar en la muesca, para terminar."
  )
  static let supportedModes: IntentModes = .background

  @MainActor
  func perform() async throws -> some IntentResult {
    let conversando = EjecucionDeAtajos.conversar(try PuenteDeAtajos.requerido())
    AppLog.plataforma.info("Atajo «Conversar»: \(conversando ? "llama" : "cuelga", privacy: .public)")
    return .result()
  }
}

/// Una nota rápida: lo que digas termina en Apple Notas, no donde está el
/// cursor.
struct DictarNotaIntent: AppIntent {
  static let title: LocalizedStringResource = "Dictar una nota"
  static let description = IntentDescription(
    "Dicta una nota rápida que se guarda en Apple Notas. Termina con el atajo de Dilo o con un clic en la muesca."
  )
  static let supportedModes: IntentModes = .background

  @MainActor
  func perform() async throws -> some IntentResult {
    try PuenteDeAtajos.requerido().dictarNota()
    return .result()
  }
}

/// El modo que usa el atajo general, como elegirlo en el panel del hover.
struct ElegirModoIntent: AppIntent {
  static let title: LocalizedStringResource = "Elegir el modo de Dilo"
  static let description = IntentDescription(
    "Cambia el modo que usa el atajo general de Dilo. «Sin modo» dicta tal como lo dices, sin pasar por ninguna IA. Los modos con tecla propia siguen con la suya."
  )
  static let supportedModes: IntentModes = .background

  @Parameter(title: "Modo")
  var modo: ModoDeDilo

  static var parameterSummary: some ParameterSummary {
    Summary("Usar \(\.$modo) en el atajo general")
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let nombre = try EjecucionDeAtajos.elegirModo(try PuenteDeAtajos.requerido(), modo)
    guard let nombre else {
      return .result(dialog: "Listo: el atajo general dicta sin modo.")
    }
    return .result(dialog: "Listo: el atajo general usa \(nombre).")
  }
}

/// Devuelve lo último que dictaste, para encadenarlo en un atajo.
struct UltimoDictadoIntent: AppIntent {
  static let title: LocalizedStringResource = "Último dictado"
  static let description = IntentDescription(
    "Devuelve lo último que dictaste con Dilo. Vive sólo en memoria: después de cerrar Dilo no hay nada."
  )
  static let supportedModes: IntentModes = .background

  @Parameter(title: "Versión", default: .entregado)
  var mitad: MitadDelDictado

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    .result(value: try EjecucionDeAtajos.ultimoDictado(try PuenteDeAtajos.requerido(), mitad: mitad))
  }
}

/// «Copiar el último dictado» del menú de la barra, como acción.
struct CopiarUltimoDictadoIntent: AppIntent {
  static let title: LocalizedStringResource = "Copiar el último dictado"
  static let description = IntentDescription(
    "Deja lo último que dictaste en el portapapeles, como el ítem del menú de Dilo, y lo devuelve."
  )
  static let supportedModes: IntentModes = .background

  @Parameter(title: "Versión", default: .entregado)
  var mitad: MitadDelDictado

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    let texto = try EjecucionDeAtajos.copiarUltimo(try PuenteDeAtajos.requerido(), mitad: mitad)
    return .result(value: texto, dialog: "Copiado.")
  }
}

/// Transcribe un audio o un video en este Mac, con el reconocimiento de
/// Apple y el idioma principal, y devuelve el texto. Es lo mismo que
/// arrastrar el archivo a la muesca, sin la tarjeta.
struct TranscribirArchivoIntent: AppIntent {
  static let title: LocalizedStringResource = "Transcribir un archivo"
  static let description = IntentDescription(
    "Transcribe un audio o un video en este Mac, sin mandarlo a ningún lado, y devuelve el texto."
  )
  static let supportedModes: IntentModes = .background

  @Parameter(title: "Archivo", supportedContentTypes: [.audio, .movie])
  var archivo: IntentFile

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let acciones = try PuenteDeAtajos.requerido()
    let texto = try await EjecucionDeAtajos.conArchivo(archivo) { url in
      try await acciones.transcribir(url)
    }
    return .result(value: texto)
  }
}

/// Busca en el historial, si está encendido.
struct BuscarEnHistorialIntent: AppIntent {
  static let title: LocalizedStringResource = "Buscar en el historial de Dilo"
  static let description = IntentDescription(
    "Dictados guardados que contienen un texto, del más nuevo al más viejo. Sólo con el historial encendido; vacío devuelve los últimos."
  )
  static let supportedModes: IntentModes = .background

  @Parameter(title: "Buscar", default: "")
  var consulta: String

  @Parameter(title: "Cuántos", default: 5, inclusiveRange: (1, 50))
  var maximo: Int

  static var parameterSummary: some ParameterSummary {
    Summary("Buscar \(\.$consulta) en el historial") {
      \.$maximo
    }
  }

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
    let acciones = try PuenteDeAtajos.requerido()
    return .result(value: try await EjecucionDeAtajos.buscar(acciones, consulta: consulta, maximo: maximo))
  }
}

/// Pone un aviso corto al costado de la muesca: la forma más barata de que
/// un atajo, un script (`shortcuts run`) o un *hook* muestren algo sin
/// escribir una extensión (plan cap. 5 §6).
struct MostrarEnLaMuescaIntent: AppIntent {
  static let title: LocalizedStringResource = "Mostrar en la muesca"
  static let description = IntentDescription(
    "Pone un aviso corto al costado de la muesca de Dilo por unos segundos. Un clic lo quita."
  )
  static let supportedModes: IntentModes = .background

  @Parameter(title: "Texto", inputConnectionBehavior: .connectToPreviousIntentResult)
  var texto: String

  @Parameter(title: "Símbolo", description: "El nombre de un SF Symbol, como bell o checkmark.circle.", default: "bell")
  var simbolo: String

  @Parameter(title: "Segundos", default: 8, inclusiveRange: (1, 120))
  var segundos: Int

  static var parameterSummary: some ParameterSummary {
    Summary("Mostrar \(\.$texto) en la muesca") {
      \.$simbolo
      \.$segundos
    }
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    try EjecucionDeAtajos.mostrar(
      try PuenteDeAtajos.requerido(), texto: texto, simbolo: simbolo, segundos: segundos,
      simboloExiste: { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
    )
    return .result()
  }
}
