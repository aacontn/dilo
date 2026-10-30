import AppIntents
import DiloReuniones
import Foundation
import os

// Los App Intents de Reuniones (spec, «App Intents»): grabar, terminar, la
// última y buscar. Como los de dictado, sin lógica propia y en segundo plano:
// llaman a `EjecucionDeReuniones` con la app viva (`PuenteDeAtajos.reuniones`),
// que llama a lo mismo que el panel de la barra. Grabar abre el micrófono, así
// que no hay ruta `dilo://` para esto (AGENTS.md, «Lo que entra de afuera»).

/// Lo que los intents de reuniones necesitan de la app viva. Aparte de
/// `AccionesParaAtajos` para que los atajos de dictado no cambien.
@MainActor
protocol ReunionesParaAtajos: AnyObject {
  func grabarReunion() -> ControlDeReuniones.ResultadoAlGrabar
  func terminarReunion() -> String?
  func guionDeLaUltima() async -> String?
  func buscarEnReuniones(_ consulta: String, maximo: Int) async -> [ResultadoDeBusquedaParaAtajos]
}

/// Una línea encontrada, como la devuelve el atajo: con la reunión y la hora
/// para citarla.
struct ResultadoDeBusquedaParaAtajos: Equatable, Sendable {
  var reunion: String
  var linea: String
}

extension ControlDeReuniones: ReunionesParaAtajos {
  func grabarReunion() -> ResultadoAlGrabar { grabar() }
  func terminarReunion() -> String? { terminar() }
  func buscarEnReuniones(_ consulta: String, maximo: Int) async -> [ResultadoDeBusquedaParaAtajos] {
    await buscar(consulta, maximo: maximo).map {
      ResultadoDeBusquedaParaAtajos(reunion: $0.titulo, linea: "\($0.hablante) · \($0.hora) — \($0.texto)")
    }
  }
}

enum FallaDeReunion: Error, Equatable, CustomLocalizedStringResourceConvertible {
  case noEmpezo(String)
  case noHayReunion
  case sinGuion

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case let .noEmpezo(motivo): "La reunión no empezó: \(motivo)"
    case .noHayReunion: "No hay ninguna reunión grabando."
    case .sinGuion: "Todavía no hay ninguna reunión con guion."
    }
  }
}

/// Lo que hace cada intent, separado del `perform()` para probarlo con un
/// doble.
@MainActor
enum EjecucionDeReuniones {
  static func grabar(_ reuniones: any ReunionesParaAtajos) throws(FallaDeReunion) -> Bool {
    switch reuniones.grabarReunion() {
    case .empezo: return true
    case .yaGrabando: return false
    case let .noSePudo(motivo): throw .noEmpezo(motivo)
    }
  }

  static func terminar(_ reuniones: any ReunionesParaAtajos) throws(FallaDeReunion) {
    guard reuniones.terminarReunion() != nil else { throw .noHayReunion }
  }

  static func ultima(_ reuniones: any ReunionesParaAtajos) async throws(FallaDeReunion) -> String {
    guard let guion = await reuniones.guionDeLaUltima() else { throw .sinGuion }
    return guion
  }

  static func buscar(_ reuniones: any ReunionesParaAtajos, consulta: String, maximo: Int) async -> [String] {
    let tope = min(max(maximo, 1), EjecucionDeAtajos.maximoDeResultados)
    return await reuniones.buscarEnReuniones(consulta, maximo: tope).map { "\($0.reunion): \($0.linea)" }
  }
}

struct GrabarReunionIntent: AppIntent {
  static let title: LocalizedStringResource = "Grabar una reunión"
  static let description = IntentDescription(
    "Empieza a grabar una reunión en este Mac: tu micrófono y el audio del Mac, cada uno en su pista. Al terminar sale el guion con quién dijo qué. Nada sale de esta compu."
  )
  static let supportedModes: IntentModes = .background

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let nueva = try EjecucionDeReuniones.grabar(try PuenteDeAtajos.requeridoParaReuniones())
    AppLog.plataforma.info("Atajo «Grabar una reunión»: \(nueva ? "empezó" : "ya grababa", privacy: .public)")
    return .result(dialog: nueva ? "Grabando la reunión." : "Ya estaba grabando una reunión.")
  }
}

struct TerminarReunionIntent: AppIntent {
  static let title: LocalizedStringResource = "Terminar la reunión"
  static let description = IntentDescription(
    "Termina la reunión que Dilo está grabando. El guion sale en unos minutos, cuando termina de afinarlo."
  )
  static let supportedModes: IntentModes = .background

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try EjecucionDeReuniones.terminar(try PuenteDeAtajos.requeridoParaReuniones())
    return .result(dialog: "Listo. El guion sale cuando Dilo termine de afinarlo.")
  }
}

struct UltimaReunionIntent: AppIntent {
  static let title: LocalizedStringResource = "Última reunión"
  static let description = IntentDescription(
    "Devuelve el guion de la última reunión que grabó Dilo, en Markdown: quién dijo qué y cuándo."
  )
  static let supportedModes: IntentModes = .background

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    .result(value: try await EjecucionDeReuniones.ultima(try PuenteDeAtajos.requeridoParaReuniones()))
  }
}

struct BuscarEnReunionesIntent: AppIntent {
  static let title: LocalizedStringResource = "Buscar en tus reuniones"
  static let description = IntentDescription(
    "Líneas de tus reuniones que contienen un texto o que dijo una persona, sin importar tildes ni mayúsculas."
  )
  static let supportedModes: IntentModes = .background

  @Parameter(title: "Buscar")
  var consulta: String

  @Parameter(title: "Cuántas", default: 10, inclusiveRange: (1, 50))
  var maximo: Int

  static var parameterSummary: some ParameterSummary {
    Summary("Buscar \(\.$consulta) en tus reuniones") {
      \.$maximo
    }
  }

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
    let reuniones = try PuenteDeAtajos.requeridoParaReuniones()
    return .result(value: await EjecucionDeReuniones.buscar(reuniones, consulta: consulta, maximo: maximo))
  }
}
