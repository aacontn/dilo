import DiloReuniones
import Foundation
import Testing

@testable import Dilo

/// Los atajos de reuniones contra un doble de la app: sin micrófono, sin tap
/// y sin disco. Lo que graba de verdad se prueba con la app abierta.
@MainActor
@Suite("Reuniones en la app")
struct ReunionesEnLaAppTests {
  final class ReunionesDeMentira: ReunionesParaAtajos {
    var resultado: ControlDeReuniones.ResultadoAlGrabar = .empezo(id: "r")
    var grabando: String?
    var guion: String?
    var encontradas: [ResultadoDeBusquedaParaAtajos] = []
    var maximoPedido: Int?

    func grabarReunion() -> ControlDeReuniones.ResultadoAlGrabar {
      if case let .empezo(id) = resultado { grabando = id }
      return resultado
    }

    func terminarReunion() -> String? {
      defer { grabando = nil }
      return grabando
    }

    func guionDeLaUltima() async -> String? { guion }

    func buscarEnReuniones(_ consulta: String, maximo: Int) async -> [ResultadoDeBusquedaParaAtajos] {
      maximoPedido = maximo
      return encontradas
    }
  }

  @Test func grabarYTerminarPorAtajo() throws {
    let app = ReunionesDeMentira()
    #expect(try EjecucionDeReuniones.grabar(app))
    try EjecucionDeReuniones.terminar(app)
    #expect(throws: FallaDeReunion.noHayReunion) { try EjecucionDeReuniones.terminar(app) }
    app.resultado = .yaGrabando(id: "r")
    #expect(try EjecucionDeReuniones.grabar(app) == false)
    app.resultado = .noSePudo("sin disco")
    #expect(throws: FallaDeReunion.noEmpezo("sin disco")) { try EjecucionDeReuniones.grabar(app) }
  }

  @Test func laUltimaYBuscar() async throws {
    let app = ReunionesDeMentira()
    await #expect(throws: FallaDeReunion.sinGuion) { try await EjecucionDeReuniones.ultima(app) }
    app.guion = "# Reunión\n"
    #expect(try await EjecucionDeReuniones.ultima(app) == "# Reunión\n")
    app.encontradas = [ResultadoDeBusquedaParaAtajos(reunion: "Reunión con Camila", linea: "Camila · 15:32 — Con despacho.")]
    let lineas = await EjecucionDeReuniones.buscar(app, consulta: "despacho", maximo: 500)
    #expect(lineas == ["Reunión con Camila: Camila · 15:32 — Con despacho."])
    // El tope es el mismo de los atajos de dictado.
    #expect(app.maximoPedido == EjecucionDeAtajos.maximoDeResultados)
  }

  /// macOS rechaza el tap sin esta clave y la pista `ellos` sale muda, sin
  /// ningún error. Xcode bota en silencio la `INFOPLIST_KEY_` de esta clave:
  /// por eso vive a mano en `Dilo/Info.plist`.
  @Test func elPermisoDelAudioDelSistemaViajaEnLaApp() throws {
    let razon = try #require(Bundle.main.object(forInfoDictionaryKey: "NSAudioCaptureUsageDescription") as? String)
    #expect(!razon.isEmpty)
  }

  @Test func elPanelDelPermisoEsElDelAudioDelSistema() {
    #expect(ControlDeReuniones.panelDelAudioDelSistema.hasSuffix("Privacy_AudioCapture"))
  }

  /// Un control recién creado no graba ni afina nada: nada de reuniones se
  /// carga hasta que alguien graba una.
  @Test func unControlNuevoNoTieneNadaEnCurso() {
    let control = ControlDeReuniones(
      defaults: UserDefaults(suiteName: "reuniones-app-\(UUID().uuidString)")!,
      respaldo: FileManager.default.temporaryDirectory.appending(path: "dilo-respaldo-\(UUID().uuidString)")
    )
    #expect(control.enCurso == nil)
    #expect(control.pasada == nil)
    #expect(!control.grabando)
    #expect(control.terminar() == nil)
  }
}
