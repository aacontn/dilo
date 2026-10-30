import DiloEngines
import DiloModes
import Foundation
import Testing

@testable import Dilo

/// El turno es un tramo de lo que el micrófono viene oyendo, sin abrir nada.
struct OidoDeLaLlamadaTests {
  private static let voz = [Float](repeating: 0.2, count: 1_600)
  private static let silencio = [Float](repeating: 0, count: 1_600)

  private final class Anotador: @unchecked Sendable {
    private let candado = NSLock()
    private var tramos: [[Float]] = []

    var transcritos: [[Float]] { candado.withLock { tramos } }

    func anotar(_ audio: [Float]) {
      candado.withLock { tramos.append(audio) }
    }
  }

  private func oido(_ anotador: Anotador) -> (OidoDeLaLlamada, AsyncStream<[Float]>.Continuation, Task<Void, Never>) {
    let oido = OidoDeLaLlamada(
      transcribir: { audio in
        anotador.anotar(audio)
        return "lo oído"
      },
      alOir: { _, _ in }
    )
    let (flujo, continuacion) = AsyncStream.makeStream(of: [Float].self)
    return (oido, continuacion, Task { await oido.escuchar(flujo) })
  }

  private func decir(_ partes: [[Float]], por continuacion: AsyncStream<[Float]>.Continuation) async {
    partes.forEach { continuacion.yield($0) }
    try? await Task.sleep(for: .milliseconds(100))
  }

  @Test func elTurnoEmpiezaDondeSeAbrioYNoAntes() async throws {
    let anotador = Anotador()
    let (oido, continuacion, tarea) = oido(anotador)
    await decir([Self.voz, Self.voz], por: continuacion)
    let motor = oido.motor(desde: nil)
    try await motor.empezar(Locale(identifier: "es_CL"), .automatico, EngineHandlers(parcial: { _ in }))
    await decir(Array(repeating: Self.voz, count: 20), por: continuacion)
    let texto = try await motor.terminar()
    #expect(texto == "lo oído")
    #expect(anotador.transcritos.last?.count == 20 * 1_600)
    continuacion.finish()
    await tarea.value
  }

  @Test func quienInterrumpioEntraDesdeQueEmpezoAHablar() async throws {
    let anotador = Anotador()
    let (oido, continuacion, tarea) = oido(anotador)
    await decir(Array(repeating: Self.voz, count: 12), por: continuacion)
    let motor = oido.motor(desde: 2 * 1_600)
    try await motor.empezar(Locale(identifier: "es_CL"), .automatico, EngineHandlers(parcial: { _ in }))
    await decir(Array(repeating: Self.voz, count: 8), por: continuacion)
    _ = try await motor.terminar()
    #expect(anotador.transcritos.last?.count == 18 * 1_600)
    continuacion.finish()
    await tarea.value
  }

  @Test func alCallarYaEstaTranscritoYNoSeRepite() async throws {
    let anotador = Anotador()
    let (oido, continuacion, tarea) = oido(anotador)
    let motor = oido.motor(desde: nil)
    try await motor.empezar(Locale(identifier: "es_CL"), .automatico, EngineHandlers(parcial: { _ in }))
    await decir(Array(repeating: Self.voz, count: 3) + [Self.silencio], por: continuacion)
    let antes = anotador.transcritos.count
    #expect(antes == 1)
    await decir(Array(repeating: Self.silencio, count: 7), por: continuacion)
    let texto = try await motor.terminar()
    #expect(texto == "lo oído")
    #expect(anotador.transcritos.count == antes)
    continuacion.finish()
    await tarea.value
  }

  @Test func unTramoCortoSeRellenaHastaElSegundoQuePideElMotor() async throws {
    let anotador = Anotador()
    let (oido, continuacion, tarea) = oido(anotador)
    let motor = oido.motor(desde: nil)
    try await motor.empezar(Locale(identifier: "es_CL"), .automatico, EngineHandlers(parcial: { _ in }))
    await decir([Self.voz, Self.silencio], por: continuacion)
    _ = try await motor.terminar()
    #expect(anotador.transcritos.last?.count == 16_000)
    continuacion.finish()
    await tarea.value
  }

  @Test func cancelarNoTranscribe() async throws {
    let anotador = Anotador()
    let (oido, continuacion, tarea) = oido(anotador)
    let motor = oido.motor(desde: nil)
    try await motor.empezar(Locale(identifier: "es_CL"), .automatico, EngineHandlers(parcial: { _ in }))
    await motor.cancelar()
    let texto = try await motor.terminar()
    #expect(texto.isEmpty)
    #expect(anotador.transcritos.isEmpty)
    continuacion.finish()
    await tarea.value
  }

  @Test func elNivelTieneLaEscalaDeLaMuesca() {
    #expect(OidoDeLaLlamada.nivel(de: [Float](repeating: 1, count: 100)) == 1)
    #expect(OidoDeLaLlamada.nivel(de: [Float](repeating: 0, count: 100)) == 0)
    let medio = OidoDeLaLlamada.nivel(de: [Float](repeating: 0.1, count: 100))
    #expect(abs(medio - 0.6) < 0.01)
  }
}
