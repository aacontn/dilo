import AVFAudio
import DiloEngines
import DiloModes
import Foundation
import Synchronization
import Testing

@testable import Dilo

/// El turno es un tramo de lo que el micrófono viene oyendo, sin abrir nada.
struct OidoDeLaLlamadaTests {
  private static let voz = [Float](repeating: 0.2, count: 1_600)
  private static let silencio = [Float](repeating: 0, count: 1_600)

  private final class Anotador: @unchecked Sendable {
    private let candado = NSLock()
    private var tramos: [[Float]] = []
    private var trozos = 0

    var transcritos: [[Float]] { candado.withLock { tramos } }
    var oidos: Int { candado.withLock { trozos } }

    func anotar(_ audio: [Float]) {
      candado.withLock { tramos.append(audio) }
    }

    func oyo() {
      candado.withLock { trozos += 1 }
    }
  }

  private func oido(_ anotador: Anotador) -> (OidoDeLaLlamada, AsyncStream<[Float]>.Continuation, Task<Void, Never>) {
    let oido = OidoDeLaLlamada(
      transcribir: { audio in
        anotador.anotar(audio)
        return "lo oído"
      },
      alOir: { _, _ in anotador.oyo() }
    )
    let (flujo, continuacion) = AsyncStream.makeStream(of: [Float].self)
    return (oido, continuacion, Task { await oido.escuchar(flujo) })
  }

  /// Espera a que el oído haya oído todo, sin apostar a un plazo: con la suite
  /// entera corriendo, cualquier espera fija se queda corta.
  private func hasta(_ condicion: () -> Bool) async {
    let limite = ContinuousClock.now + .seconds(5)
    while !condicion(), ContinuousClock.now < limite { try? await Task.sleep(for: .milliseconds(5)) }
  }

  private func decir(
    _ partes: [[Float]],
    a anotador: Anotador,
    por continuacion: AsyncStream<[Float]>.Continuation
  ) async {
    let meta = anotador.oidos + partes.count
    partes.forEach { continuacion.yield($0) }
    await hasta { anotador.oidos >= meta }
  }

  @Test func elTurnoEmpiezaDondeSeAbrioYNoAntes() async throws {
    let anotador = Anotador()
    let (oido, continuacion, tarea) = oido(anotador)
    await decir([Self.voz, Self.voz], a: anotador, por: continuacion)
    let motor = oido.motor(desde: nil)
    try await motor.empezar(Locale(identifier: "es_CL"), .automatico, EngineHandlers(parcial: { _ in }))
    await decir(Array(repeating: Self.voz, count: 20), a: anotador, por: continuacion)
    let texto = try await motor.terminar()
    #expect(texto == "lo oído")
    #expect(anotador.transcritos.last?.count == 20 * 1_600)
    continuacion.finish()
    await tarea.value
  }

  @Test func quienInterrumpioEntraDesdeQueEmpezoAHablar() async throws {
    let anotador = Anotador()
    let (oido, continuacion, tarea) = oido(anotador)
    await decir(Array(repeating: Self.voz, count: 12), a: anotador, por: continuacion)
    let motor = oido.motor(desde: 2 * 1_600)
    try await motor.empezar(Locale(identifier: "es_CL"), .automatico, EngineHandlers(parcial: { _ in }))
    await decir(Array(repeating: Self.voz, count: 8), a: anotador, por: continuacion)
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
    await decir(Array(repeating: Self.voz, count: 3) + [Self.silencio], a: anotador, por: continuacion)
    await hasta { !anotador.transcritos.isEmpty }
    #expect(anotador.transcritos.count == 1)
    await decir(Array(repeating: Self.silencio, count: 7), a: anotador, por: continuacion)
    let texto = try await motor.terminar()
    #expect(texto == "lo oído")
    #expect(anotador.transcritos.count == 1)
    continuacion.finish()
    await tarea.value
  }

  @Test func unTramoCortoSeRellenaHastaElSegundoQuePideElMotor() async throws {
    let anotador = Anotador()
    let (oido, continuacion, tarea) = oido(anotador)
    let motor = oido.motor(desde: nil)
    try await motor.empezar(Locale(identifier: "es_CL"), .automatico, EngineHandlers(parcial: { _ in }))
    await decir([Self.voz, Self.silencio], a: anotador, por: continuacion)
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

/// El tap del mezclador corre en una cola de audio: un bloque aislado al actor
/// principal mata la app apenas suena algo.
struct MedidorDeSalidaTests {
  @Test func midePrimeroEnUnaColaDeAudioSinCaerse() async throws {
    let formato = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
    let bufer = try #require(AVAudioPCMBuffer(pcmFormat: formato, frameCapacity: 1_024))
    bufer.frameLength = 1_024
    let canal = try #require(bufer.floatChannelData?[0])
    for indice in 0 ..< 1_024 { canal[indice] = 0.2 }
    let medidor = MedidorDeSalida()
    let cuando = AVAudioTime(hostTime: 0)
    nonisolated(unsafe) let bloque = medidor.bloque
    nonisolated(unsafe) let compartido = (bufer, cuando)
    await withCheckedContinuation { (listo: CheckedContinuation<Void, Never>) in
      DispatchQueue(label: "prueba.tap.audio").async {
        bloque(compartido.0, compartido.1)
        listo.resume()
      }
    }
    let nivel = try #require(medidor.nivel.withLock { $0 })
    #expect(abs(nivel - OidoDeLaLlamada.nivel(de: [Float](repeating: 0.2, count: 1_024))) < 0.001)
  }
}
