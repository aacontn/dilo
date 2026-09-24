import Foundation
import Testing

@testable import DiloConsumo

/// Lo que la sección «Datos en la muesca» de Ajustes calcula sin dibujar: qué
/// va en cada costado, qué no cabe, si cada fuente tiene de dónde leer y qué
/// filas lleva el detalle del hover.
@Suite("Sección de la muesca")
struct SeccionDeLaMuescaTests {
  // MARK: Disposición

  @Test func encenderVaAlPrimerCostadoLibre() {
    var d = DisposicionDeLaMuesca()
    d.encender(.codex)
    d.encender(.cpu)
    #expect(d.costado(de: .codex) == .izquierdo)
    #expect(d.costado(de: .cpu) == .derecho)
    #expect(d.dato(en: .izquierdo) == .codex)
    #expect(d.dato(en: .derecho) == .cpu)
  }

  /// Lo que no cabe se dice: el tercero queda esperando y sabe quién le
  /// ocupa el lugar; no se recorta en silencio ni desplaza a nadie.
  @Test func loQueNoCabeSabeQuienLeOcupaElLugar() {
    var d = DisposicionDeLaMuesca()
    d.encender(.claude)
    d.encender(.codex)
    d.encender(.ram)
    #expect(d.costado(de: .ram) == .izquierdo)
    #expect(d.dato(en: .izquierdo) == .claude)
    #expect(d.quienOcupa(elLugarDe: .ram) == .claude)
    #expect(d.quienOcupa(elLugarDe: .claude) == nil)
    // Si el primero se apaga, el que esperaba se ve solo.
    d.apagar(.claude)
    #expect(d.dato(en: .izquierdo) == .ram)
    #expect(d.quienOcupa(elLugarDe: .ram) == nil)
  }

  /// Mover no desplaza a quien ya estaba en ese costado.
  @Test func moverEntraAlFinalDeLaFila() {
    var d = DisposicionDeLaMuesca()
    d.encender(.codex, en: .izquierdo)
    d.encender(.cpu, en: .derecho)
    d.mover(.cpu, a: .izquierdo)
    #expect(d.dato(en: .izquierdo) == .codex)
    #expect(d.dato(en: .derecho) == .ninguno)
    #expect(d.quienOcupa(elLugarDe: .cpu) == .codex)
  }

  /// En App Store Claude y Codex no ocupan lugar: la CPU que esperaba detrás
  /// de Claude se ve.
  @Test func loQueElAnfitrionNoAdmiteNoOcupaLugar() {
    var d = DisposicionDeLaMuesca()
    d.encender(.claude, en: .izquierdo)
    d.encender(.cpu, en: .izquierdo)
    let sinIA: (DatoDeLaMuesca) -> Bool = { !$0.leeArchivosDeOtraApp }
    #expect(d.dato(en: .izquierdo, disponible: sinIA) == .cpu)
    #expect(d.quienOcupa(elLugarDe: .cpu, disponible: sinIA) == nil)
    #expect(d.quienOcupa(elLugarDe: .claude, disponible: sinIA) == nil)
  }

  @Test func seGuardaYSeLeeIgual() {
    var d = DisposicionDeLaMuesca()
    d.encender(.claude, en: .derecho)
    d.encender(.ram, en: .izquierdo)
    #expect(d.guardado == "claude:derecho,ram:izquierdo")
    #expect(DisposicionDeLaMuesca(guardado: d.guardado) == d)
    // Lo que no se entiende se salta; lo demás se conserva.
    let rara = DisposicionDeLaMuesca(guardado: "gemini:izquierdo,cpu:arriba,codex:derecho,codex:izquierdo")
    #expect(rara.elecciones == [.init(dato: .codex, costado: .derecho)])
    #expect(DisposicionDeLaMuesca(guardado: "") == DisposicionDeLaMuesca())
  }

  /// Quien ya tenía un dato en cada picker de Apariencia lo sigue teniendo.
  @Test func laEleccionDeLosDosPickersSeMigra() {
    let d = DisposicionDeLaMuesca.migrada(izquierdo: .codex, derecho: .ninguno)
    #expect(d.dato(en: .izquierdo) == .codex)
    #expect(d.dato(en: .derecho) == .ninguno)
    #expect(d.elecciones.count == 1)
  }

  // MARK: Detección

  /// Un disco de mentira: las carpetas que existen y lo que tiene cada una.
  struct DiscoDeMentira: SistemaDeArchivos {
    var carpetas: [String: [String]]

    func contenido(de carpeta: URL) -> [URL]? {
      carpetas[carpeta.path(percentEncoded: false).trimmingSuffix("/")]?
        .map { carpeta.appending(path: $0) }
    }
  }

  private let casa = URL(filePath: "/Users/prueba")

  @Test func claudeEstaListoConUnaSesion() {
    let disco = DiscoDeMentira(carpetas: [
      "/Users/prueba/.claude/projects": ["-Users-prueba-web", "-Users-prueba-api"],
      "/Users/prueba/.claude/projects/-Users-prueba-web": ["memoria"],
      "/Users/prueba/.claude/projects/-Users-prueba-web/memoria": [],
      "/Users/prueba/.claude/projects/-Users-prueba-api": ["a1b2.jsonl"],
    ])
    let d = DeteccionDeFuentes(inicio: casa, admiteArchivosDeOtrasApps: true, sistema: disco)
    #expect(d.estado(de: .claude) == .listo)
  }

  /// La carpeta sin sesiones —Claude Code instalado y nunca usado— y la
  /// carpeta que no existe dicen lo mismo: no hay nada que leer todavía.
  @Test func sinSesionesNoSeEncuentra() {
    let vacia = DiscoDeMentira(carpetas: [
      "/Users/prueba/.claude/projects": ["-Users-prueba-web"],
      "/Users/prueba/.claude/projects/-Users-prueba-web": [],
      "/Users/prueba/.codex": ["config.toml"],
    ])
    let d = DeteccionDeFuentes(inicio: casa, admiteArchivosDeOtrasApps: true, sistema: vacia)
    #expect(d.estado(de: .claude) == .noEncontrado)
    #expect(d.estado(de: .codex) == .noEncontrado)
  }

  @Test func codexBuscaEnLasCarpetasDeFecha() {
    let disco = DiscoDeMentira(carpetas: [
      "/Users/prueba/.codex/sessions": ["2026"],
      "/Users/prueba/.codex/sessions/2026": ["09"],
      "/Users/prueba/.codex/sessions/2026/09": ["22", "23"],
      "/Users/prueba/.codex/sessions/2026/09/22": [],
      "/Users/prueba/.codex/sessions/2026/09/23": ["rollout-2026-09-23T10-00-00-abc.jsonl"],
    ])
    let d = DeteccionDeFuentes(inicio: casa, admiteArchivosDeOtrasApps: true, sistema: disco)
    #expect(d.estado(de: .codex) == .listo)
    // Un `.jsonl` suelto más abajo de lo que Codex escribe no cuenta.
    let honda = DiscoDeMentira(carpetas: [
      "/Users/prueba/.codex/sessions": ["a"],
      "/Users/prueba/.codex/sessions/a": ["b"],
      "/Users/prueba/.codex/sessions/a/b": ["c"],
      "/Users/prueba/.codex/sessions/a/b/c": ["d"],
      "/Users/prueba/.codex/sessions/a/b/c/d": ["e"],
      "/Users/prueba/.codex/sessions/a/b/c/d/e": ["x.jsonl"],
    ])
    #expect(DeteccionDeFuentes(inicio: casa, admiteArchivosDeOtrasApps: true, sistema: honda)
      .estado(de: .codex) == .noEncontrado)
  }

  /// En App Store no se mira el disco: el sandbox sólo vería el contenedor.
  @Test func enAppStoreClaudeYCodexNoEstanDisponiblesYElSistemaSi() {
    let llena = DiscoDeMentira(carpetas: [
      "/Users/prueba/.claude/projects": ["x.jsonl"],
    ])
    let d = DeteccionDeFuentes(inicio: casa, admiteArchivosDeOtrasApps: false, sistema: llena)
    #expect(d.estado(de: .claude) == .noDisponibleEnEstaVersion)
    #expect(d.estado(de: .codex) == .noDisponibleEnEstaVersion)
    #expect(d.estado(de: .cpu) == .listo)
    #expect(d.estado(de: .ram) == .listo)
  }

  @Test func lasCarpetasSonLasQueLeenLosLectores() {
    #expect(DeteccionDeFuentes.carpeta(de: .claude, en: casa)?.path == "/Users/prueba/.claude/projects")
    #expect(DeteccionDeFuentes.carpeta(de: .codex, en: casa)?.path == "/Users/prueba/.codex/sessions")
    #expect(DeteccionDeFuentes.carpeta(de: .cpu, en: casa) == nil)
    #expect(DatoDeLaMuesca.fuentes == [.claude, .codex, .cpu, .ram])
  }

  // MARK: Detalle del hover

  @Test func codexDetallaLasDosVentanasConSuReinicio() {
    let ahora = Date(timeIntervalSince1970: 1_790_180_000)
    let consumo = ConsumoDeIA(
      ventanaCorta: VentanaDeUso(porcentaje: 34.6, seReiniciaEn: ahora.addingTimeInterval(3600), duracion: 18_000),
      ventanaSemanal: VentanaDeUso(porcentaje: 12, seReiniciaEn: ahora.addingTimeInterval(86_400), duracion: 604_800)
    )
    let filas = DetalleDelDato.codex(consumo, ahora: ahora)
    #expect(filas.map(\.cual) == [.cincoHoras, .semana])
    #expect(filas.map(\.valor) == ["35%", "12%"])
    #expect(filas[0].seReiniciaEn == ahora.addingTimeInterval(3600))
    #expect(DetalleDelDato.codex(nil, ahora: ahora).isEmpty)
  }

  @Test func claudeDetallaTokensYPlanSiLoHay() {
    let ahora = Date(timeIntervalSince1970: 1_790_180_000)
    let tokens = ConsumoDeIA(ventanaCorta: VentanaDeUso(
      tokens: 1_700_000, seReiniciaEn: ahora.addingTimeInterval(7200), duracion: 18_000))
    let plan = ConsumoDeIA(ventanaCorta: VentanaDeUso(
      porcentaje: 42, seReiniciaEn: ahora.addingTimeInterval(5400), duracion: 18_000))
    let soloTokens = DetalleDelDato.claude(tokens: tokens, plan: nil, ahora: ahora)
    #expect(soloTokens.map(\.cual) == [.tokensDelBloque])
    #expect(soloTokens.first?.valor == "1,7M")
    let conPlan = DetalleDelDato.claude(tokens: tokens, plan: plan, ahora: ahora)
    #expect(conPlan.map(\.cual) == [.tokensDelBloque, .planCincoHoras])
    #expect(conPlan.last?.valor == "42%")
    #expect(conPlan.last?.nivel == 42)
  }

  @Test func elSistemaDetallaSuValor() {
    #expect(DetalleDelDato.sistema(23.4) == [FilaDelDetalle(cual: .ahora, valor: "23%", nivel: 23.4)])
    #expect(DetalleDelDato.sistema(nil).isEmpty)
  }

  // MARK: Probar ahora

  @Test func cadaErrorSeDiceComoUnaFalla() {
    #expect(ClienteDeUsoDeClaude.Falla.de(URLError(.notConnectedToInternet)) == .sinRed)
    #expect(ClienteDeUsoDeClaude.Falla.de(ClienteDeUsoDeClaude.Falla.sesionVencida) == .sesionVencida)
    #expect(ClienteDeUsoDeClaude.Falla.de(CocoaError(.fileReadUnknown)) == .respuesta(codigo: 0))
  }
}

private extension String {
  func trimmingSuffix(_ sufijo: String) -> String {
    hasSuffix(sufijo) && count > 1 ? String(dropLast(sufijo.count)) : self
  }
}
