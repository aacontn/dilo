import Foundation
import Testing

@testable import DiloConsumo

/// Los datos de los costados de la muesca, leídos de archivos armados a mano
/// con la forma exacta que escriben Codex y Claude Code (2026-09-23). Nada de
/// esto toca las carpetas de verdad de quien corre los tests.
@Suite("Datos de la muesca")
struct DiloConsumoTests {
  private func carpetaTemporal() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "dilo-consumo-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  // MARK: Codex

  private func lineaDeCodex(corta: Double, semanal: Double, reinicio: Double) -> String {
    #"{"timestamp":"2026-09-23T13:39:57.219Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":\#(corta),"window_minutes":300,"resets_at":\#(reinicio)},"secondary":{"used_percent":\#(semanal),"window_minutes":10080,"resets_at":\#(reinicio + 86400)},"plan_type":"plus"}}}"#
  }

  @Test func codexTomaLaUltimaLineaConLimites() throws {
    let raiz = try carpetaTemporal()
    let ahora = Date(timeIntervalSince1970: 1_790_180_000)
    let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: ahora)
    let dia = raiz.appending(path: String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
    try FileManager.default.createDirectory(at: dia, withIntermediateDirectories: true)
    let reinicio = ahora.timeIntervalSince1970 + 3600
    let texto = [
      lineaDeCodex(corta: 10, semanal: 20, reinicio: reinicio),
      #"{"type":"response_item","payload":{"type":"message"}}"#,
      lineaDeCodex(corta: 34, semanal: 37, reinicio: reinicio),
      #"{"type":"event_msg","payload":{"type":"task_complete"}}"#,
    ].joined(separator: "\n")
    try texto.write(to: dia.appending(path: "rollout-a.jsonl"), atomically: true, encoding: .utf8)

    let consumo = try #require(LectorDeCodex(sesiones: raiz).leer(ahora: ahora))
    #expect(consumo.ventanaCorta.porcentaje == 34)
    #expect(consumo.ventanaSemanal?.porcentaje == 37)
    #expect(consumo.plan == "plus")
    #expect(consumo.ventanaCorta.seReiniciaEn == Date(timeIntervalSince1970: reinicio))
  }

  /// Codex sólo escribe cuando se usa: si la ventana ya se reinició, lo que
  /// dice la última línea es viejo y lo gastado es cero.
  @Test func unaVentanaVencidaNoLlevaNadaGastado() {
    let ahora = Date()
    let vieja = VentanaDeUso(porcentaje: 80, seReiniciaEn: ahora.addingTimeInterval(-60), duracion: 18_000)
    #expect(vieja.vigente(en: ahora).porcentaje == 0)
    let viva = VentanaDeUso(porcentaje: 80, seReiniciaEn: ahora.addingTimeInterval(60), duracion: 18_000)
    #expect(viva.vigente(en: ahora).porcentaje == 80)
  }

  @Test func sinSesionesNoHayDato() throws {
    #expect(LectorDeCodex(sesiones: try carpetaTemporal()).leer() == nil)
  }

  // MARK: Claude Code

  private func lineaDeClaude(id: String, fecha: String, entrada: Int, salida: Int, cache: Int, leida: Int) -> String {
    #"{"type":"assistant","timestamp":"\#(fecha)","requestId":"req_\#(id)","message":{"id":"msg_\#(id)","model":"claude-opus-5","usage":{"input_tokens":\#(entrada),"output_tokens":\#(salida),"cache_creation_input_tokens":\#(cache),"cache_read_input_tokens":\#(leida)}}}"#
  }

  /// Suma entrada, salida y escritura de caché del bloque en curso, sin la
  /// lectura de caché y sin contar dos veces el mismo mensaje.
  @Test func claudeSumaElBloqueEnCursoSinRepetirMensajes() async throws {
    let raiz = try carpetaTemporal()
    let proyecto = raiz.appending(path: "-Volumes-SSD-1")
    try FileManager.default.createDirectory(at: proyecto, withIntermediateDirectories: true)
    let texto = [
      // Un bloque viejo, terminado hace rato: no cuenta.
      lineaDeClaude(id: "0", fecha: "2026-09-23T02:10:00.000Z", entrada: 5, salida: 5, cache: 5, leida: 0),
      // El bloque en curso empieza a las 10:00.
      lineaDeClaude(id: "1", fecha: "2026-09-23T10:20:00.000Z", entrada: 100, salida: 50, cache: 1_000, leida: 90_000),
      // La misma respuesta, repetida en otra línea como la escribe Claude Code.
      lineaDeClaude(id: "1", fecha: "2026-09-23T10:20:00.000Z", entrada: 100, salida: 50, cache: 1_000, leida: 90_000),
      #"{"type":"user","timestamp":"2026-09-23T10:21:00.000Z","message":{"role":"user"}}"#,
      lineaDeClaude(id: "2", fecha: "2026-09-23T12:05:30.123Z", entrada: 10, salida: 40, cache: 0, leida: 90_000),
    ].joined(separator: "\n") + "\n"
    let archivo = proyecto.appending(path: "sesion.jsonl")
    try texto.write(to: archivo, atomically: true, encoding: .utf8)

    let ahora = try #require(LectorDeClaude.fecha("2026-09-23T13:00:00Z"))
    let lector = LectorDeClaude(proyectos: raiz)
    let consumo = try #require(await lector.leer(ahora: ahora))
    #expect(consumo.ventanaCorta.tokens == 1_150 + 50)
    #expect(consumo.ventanaCorta.porcentaje == nil, "Claude Code no anota el porcentaje del plan")
    #expect(consumo.ventanaCorta.seReiniciaEn == LectorDeClaude.fecha("2026-09-23T15:00:00Z"))

    // Lo que se escribe después se suma sin volver a leer lo anterior.
    let manija = try FileHandle(forWritingTo: archivo)
    try manija.seekToEnd()
    try manija.write(contentsOf: Data((lineaDeClaude(
      id: "3", fecha: "2026-09-23T12:59:00.000Z", entrada: 0, salida: 800, cache: 0, leida: 0
    ) + "\n").utf8))
    try manija.close()
    let despues = try #require(await lector.leer(ahora: ahora))
    #expect(despues.ventanaCorta.tokens == 1_200 + 800)
  }

  /// Cinco horas después del inicio el bloque se cierra y la ventana vuelve a
  /// cero hasta el próximo mensaje.
  @Test func claudeSinActividadVuelveACero() {
    let inicio = Date(timeIntervalSince1970: 1_790_150_400)
    let mensajes = [LectorDeClaude.Mensaje(fecha: inicio.addingTimeInterval(600), tokens: 500)]
    let dentro = LectorDeClaude.ventanaActual(de: mensajes, ahora: inicio.addingTimeInterval(3600))
    #expect(dentro.tokens == 500)
    let fuera = LectorDeClaude.ventanaActual(de: mensajes, ahora: inicio.addingTimeInterval(6 * 3600))
    #expect(fuera.tokens == 0)
  }

  // MARK: El sistema

  @Test func elSistemaDaCPUDesdeLaSegundaLecturaYRAMSiempre() {
    let muestra = MuestraDelSistema()
    #expect(muestra.cpu() == nil, "la primera lectura no tiene contra qué comparar")
    _ = (0..<200_000).reduce(0, &+)
    let cpu = muestra.cpu()
    #expect(cpu.map { (0...100).contains($0) } ?? true)
    let ram = try? #require(muestra.ram())
    #expect(ram.map { $0 > 0 && $0 <= 100 } == true)
  }

  // MARK: Cómo se escribe

  @Test func losNumerosSeAbrevian() {
    #expect(TextoDelDato.tokens(950) == "950")
    #expect(TextoDelDato.tokens(12_400) == "12k")
    #expect(TextoDelDato.tokens(3_400_000) == "3,4M")
    #expect(TextoDelDato.tokens(12_600_000) == "13M")
    #expect(TextoDelDato.porcentaje(34.4) == "34%")
    let ahora = Date()
    #expect(TextoDelDato.faltaPara(ahora.addingTimeInterval(8 * 60 + 5), desde: ahora) == "8 min")
    #expect(TextoDelDato.faltaPara(ahora.addingTimeInterval(134 * 60 + 5), desde: ahora) == "2 h 14 min")
  }
}

/// El porcentaje del plan de Claude, sin red y sin Llavero: lo que se prueba
/// es cómo se lee lo que devuelven.
@Suite("Uso del plan de Claude")
struct ClienteDeUsoDeClaudeTests {
  @Test func leeLaVentanaDeCincoHorasYLaSemanal() throws {
    let json = #"{"five_hour":{"utilization":42.0,"resets_at":"2026-09-23T18:00:00.123456+00:00"},"seven_day":{"utilization":13,"resets_at":"2026-09-28T09:00:00Z"},"seven_day_opus":null}"#
    let consumo = try #require(ClienteDeUsoDeClaude.decodificar(Data(json.utf8)))
    #expect(consumo.ventanaCorta.porcentaje == 42)
    #expect(consumo.ventanaSemanal?.porcentaje == 13)
    #expect(consumo.ventanaCorta.seReiniciaEn == ClienteDeUsoDeClaude.fecha("2026-09-23T18:00:00.123456Z"))
    #expect(consumo.ventanaSemanal?.seReiniciaEn != nil)
  }

  @Test func unaSesionVencidaNoSeUsa() throws {
    let ahora = Date()
    let vencida = #"{"claudeAiOauth":{"accessToken":"x","expiresAt":\#((ahora.timeIntervalSince1970 - 60) * 1000)}}"#
    #expect(throws: ClienteDeUsoDeClaude.Falla.sesionVencida) {
      try ClienteDeUsoDeClaude.token(de: Data(vencida.utf8), ahora: ahora)
    }
    let viva = #"{"claudeAiOauth":{"accessToken":" abc ","expiresAt":\#((ahora.timeIntervalSince1970 + 600) * 1000)}}"#
    #expect(try ClienteDeUsoDeClaude.token(de: Data(viva.utf8), ahora: ahora) == "abc")
    #expect(throws: ClienteDeUsoDeClaude.Falla.sinSesion) {
      try ClienteDeUsoDeClaude.token(de: Data(#"{"mcpOAuth":{}}"#.utf8), ahora: ahora)
    }
  }
}
