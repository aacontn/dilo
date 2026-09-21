import Foundation
import Testing

@testable import DiloMetrics

/// Los umbrales del spec §3 como test que falla.
///
/// El test de verdad es el último: lee `docs/metricas/ultima-medicion.json`, que
/// `scripts/metrics.sh` reescribe en cada corrida y que se versiona a propósito.
/// Así un cambio que empeora un número rompe `swift test` en la máquina de quien
/// lo hizo, con el diff del JSON al lado, y no tres semanas después.
struct UmbralesTests {
  static let raiz = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

  static let ultimaMedicion = raiz.appending(path: "docs/metricas/ultima-medicion.json")

  static func reporte(_ valores: [Metrica: Double]) -> Reporte {
    Reporte(app: "/tmp/Dilo.app", maquina: "prueba", valores: valores)
  }

  static let justoPorDebajo: [Metrica: Double] = [
    .ramEnReposo: 59.9,
    .cpuEnReposo: 0.99,
    .arranqueEnFrio: 0.999,
    .latenciaSoltarTexto: 0.299,
    .tamanoDelApp: 24.9,
  ]

  @Test func unaCorridaQueCumpleNoTieneProblemas() {
    let reporte = Self.reporte(Self.justoPorDebajo)
    #expect(reporte.cumple)
    #expect(reporte.problemas.isEmpty)
  }

  @Test("cada umbral es un techo estricto", arguments: Metrica.allCases)
  func elUmbralExactoNoPasa(_ metrica: Metrica) {
    var valores = Self.justoPorDebajo
    valores[metrica] = metrica.umbral
    let reporte = Self.reporte(valores)
    #expect(!reporte.cumple, "\(metrica.titulo) pasó estando justo en el umbral")
    #expect(reporte.problemas.count == 1)
    #expect(reporte.problemas[0].contains(metrica.titulo))
  }

  @Test("una métrica sin medir es un fallo", arguments: Metrica.allCases)
  func loQueNoSeMideNoPasa(_ metrica: Metrica) {
    var valores = Self.justoPorDebajo
    valores[metrica] = nil
    let reporte = Self.reporte(valores)
    #expect(!reporte.cumple, "\(metrica.titulo) sin medir pasó como si cumpliera")
    #expect(reporte.problemas[0].contains("no se midió"))
  }

  /// CI no tiene Accesibilidad y no la va a tener: ahí la latencia no se mide
  /// y eso no puede ser un fallo. Lo que no se negocia es que la razón salga
  /// escrita, para que "no medible acá" nunca se confunda con "cumple".
  @Test func loQueElEntornoNoPuedeMedirNoTumbaLaCorrida() {
    var valores = Self.justoPorDebajo
    valores[.latenciaSoltarTexto] = nil
    let reporte = Reporte(
      app: "/tmp/Dilo.app",
      maquina: "un runner",
      valores: valores,
      sinMedirEnEsteEntorno: [.latenciaSoltarTexto: "el runner no tiene Accesibilidad"]
    )
    #expect(reporte.cumple)
    #expect(reporte.problemas.isEmpty)
    #expect(reporte.tabla().contains("no medible acá"))
    #expect(reporte.tabla().contains("el runner no tiene Accesibilidad"))
  }

  /// La excusa es para lo que no se pudo medir, no para lo que se midió y
  /// salió mal. Un número medido por encima del umbral falla igual.
  @Test func excusarAlEntornoNoTapaUnUmbralRoto() {
    var valores = Self.justoPorDebajo
    valores[.tamanoDelApp] = 34.9
    let reporte = Reporte(
      app: "/tmp/Dilo.app",
      maquina: "un runner",
      valores: valores,
      sinMedirEnEsteEntorno: [.tamanoDelApp: "una excusa que no corresponde"]
    )
    #expect(!reporte.cumple)
    #expect(reporte.problemas.count == 1)
    #expect(reporte.problemas[0].contains(Metrica.tamanoDelApp.titulo))
  }

  /// El campo llegó después de las primeras mediciones versionadas. Si un
  /// reporte viejo dejara de leerse, `swift test` fallaría por el formato y
  /// no por un número, que es justo lo que este archivo existe para evitar.
  @Test func unaMedicionAnteriorSeLeeSinElCampoNuevo() throws {
    let json = #"{"app":"/tmp/Dilo.app","generado":"2026-09-20T00:25:35Z","maquina":"prueba","#
      + #""nota":"","valores":{"ramEnReposo":18.7,"cpuEnReposo":0.04,"#
      + #""arranqueEnFrio":0.11,"latenciaSoltarTexto":0.08,"tamanoDelApp":17.2}}"#
    let archivo = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "dilo-reporte-viejo-\(UUID().uuidString).json")
    try Data(json.utf8).write(to: archivo)
    defer { try? FileManager.default.removeItem(at: archivo) }
    let leido = try Reporte.leer(de: archivo)
    #expect(leido.sinMedirEnEsteEntorno.isEmpty)
    #expect(leido.cumple)
  }

  @Test func losUmbralesSonLosDelSpec() {
    // Si alguien relaja uno, que sea acá y con el spec abierto.
    #expect(Metrica.ramEnReposo.umbral == 60)
    #expect(Metrica.cpuEnReposo.umbral == 1)
    #expect(Metrica.arranqueEnFrio.umbral == 1)
    #expect(Metrica.latenciaSoltarTexto.umbral == 0.3)
    #expect(Metrica.tamanoDelApp.umbral == 25)
  }

  @Test func elReporteViajaPorJSONSinPerderNada() throws {
    let original = Self.reporte(Self.justoPorDebajo)
    let archivo = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "dilo-reporte-\(UUID().uuidString).json")
    try original.escribir(en: archivo)
    defer { try? FileManager.default.removeItem(at: archivo) }
    let leido = try Reporte.leer(de: archivo)
    #expect(leido.valores == original.valores)
    #expect(leido.app == original.app)
  }

  @Test func laTablaNombraLasCincoMetricas() {
    let tabla = Self.reporte(Self.justoPorDebajo).tabla()
    for metrica in Metrica.allCases {
      #expect(tabla.contains(metrica.titulo))
    }
  }

  @Test func laUltimaMedicionCumpleLosNumerosDelSpec() throws {
    let reporte = try Reporte.leer(de: Self.ultimaMedicion)
    #expect(
      reporte.cumple,
      """
      Los números del spec §3 se rompieron en \(Self.ultimaMedicion.lastPathComponent):
      \(reporte.problemas.joined(separator: "\n"))

      \(reporte.tabla())

      Vuelve a medir con ./scripts/metrics.sh antes de dar el trabajo por hecho.
      """
    )
  }
}
