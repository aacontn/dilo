import Foundation
import Testing
import os

@testable import DiloEngines

/// Un micrófono que no oye nada y entrega los trozos que le pase la prueba.
final class CapturaFalsa: AudioCapture {
  private struct Estado {
    var muestras: (@Sendable ([Float]) -> Void)?
    var andando = false
    var arranques = 0
  }

  private let estado = OSAllocatedUnfairLock(initialState: Estado())

  var andando: Bool { estado.withLock { $0.andando } }
  var arranques: Int { estado.withLock { $0.arranques } }

  func iniciar(
    sampleRate: Double,
    muestras: @escaping @Sendable ([Float]) -> Void,
    nivel: @escaping @Sendable (Float) -> Void,
    falla: @escaping @Sendable (String) -> Void
  ) throws {
    estado.withLock {
      $0.muestras = muestras
      $0.andando = true
      $0.arranques += 1
    }
  }

  func detener() {
    estado.withLock { $0.andando = false }
  }

  /// Lo que "se habló": `segundos` de audio a 16 kHz.
  func hablar(segundos: Double) {
    let trozo = [Float](repeating: 0.1, count: Int(ParakeetEngine.sampleRate * segundos))
    estado.withLock { $0.muestras }?(trozo)
  }
}

/// Un modelo cargado que contesta siempre lo mismo y anota si lo soltaron.
actor ModeloFalso: ModeloDeVoz {
  private let texto: String
  private(set) var liberaciones = 0
  private(set) var reinicios = 0

  init(texto: String) {
    self.texto = texto
  }

  func transcribir(_ muestras: [Float]) async throws -> String { texto }
  func transcribirParcial(_ trozo: [Float]) async throws -> String { texto }
  func reiniciarParciales() { reinicios += 1 }
  func liberar() { liberaciones += 1 }
}

/// Un cargador que cuenta cuántas veces lo llamaron y que puede quedarse
/// colgado a propósito, para probar qué pasa cuando alguien suelta el gatillo
/// antes de que el modelo esté.
actor CargadorFalso: CargadorDeModelo {
  private let texto: String
  private var abierto: Bool
  private var esperando: [CheckedContinuation<Void, Never>] = []
  private(set) var cargas = 0
  private(set) var ultimoModelo: ModeloFalso?
  /// Si el modelo está en disco. `CargadorDeModelo` lo pregunta sincrónico,
  /// así que vive en un candado y no en el estado del actor.
  private let disco: OSAllocatedUnfairLock<Bool>

  init(texto: String = "lo que dictaste", enDisco: Bool = true, abierto: Bool = true) {
    self.texto = texto
    self.abierto = abierto
    disco = OSAllocatedUnfairLock(initialState: enDisco)
  }

  nonisolated var disponible: Bool { disco.withLock { $0 } }

  nonisolated func ponerEnDisco(_ hay: Bool) {
    disco.withLock { $0 = hay }
  }

  /// Cuántas cargas están esperando a que la prueba abra la puerta.
  private(set) var esperandoLaPuerta = 0

  func cargar() async throws -> any ModeloDeVoz {
    cargas += 1
    if !abierto {
      esperandoLaPuerta += 1
      await withCheckedContinuation { esperando.append($0) }
      esperandoLaPuerta -= 1
    }
    let modelo = ModeloFalso(texto: texto)
    ultimoModelo = modelo
    return modelo
  }

  /// Deja pasar a las cargas que estaban esperando.
  func abrir() {
    abierto = true
    for continuacion in esperando { continuacion.resume() }
    esperando = []
  }
}

/// Un reloj que no avanza hasta que la prueba se lo dice.
actor RelojFalso: RelojDeReposo {
  private var esperando: [CheckedContinuation<Void, any Error>] = []
  /// Quienes esperan a que alguien empiece a dormir acá.
  private var mirando: [CheckedContinuation<Void, Never>] = []
  private(set) var esperas: [Duration] = []

  func dormir(_ intervalo: Duration) async throws {
    esperas.append(intervalo)
    try await withCheckedThrowingContinuation { continuacion in
      esperando.append(continuacion)
      // Recién ahora hay algo que avanzar: quien mira despierta con la espera
      // ya anotada, nunca antes.
      for quien in mirando { quien.resume() }
      mirando = []
    }
  }

  /// Vuelve cuando alguien está durmiendo en este reloj —al tiro si ya lo
  /// está—. Es la costura que deja avanzar el reloj sin carrera: sin esto, la
  /// prueba avanzaba un reloj en el que la tarea de reposo todavía no había
  /// alcanzado a registrar su espera, y no avanzaba nada.
  func hastaQueAlguienEspere() async {
    guard esperando.isEmpty else { return }
    await withCheckedContinuation { mirando.append($0) }
  }

  /// Da por cumplido el intervalo que estaba corriendo.
  func avanzar() {
    for continuacion in esperando { continuacion.resume() }
    esperando = []
  }
}

/// Espera a que algo pase en vez de dormir una cifra elegida al ojo.
func esperarA(
  _ que: String,
  hasta limite: Duration = .seconds(5),
  _ condicion: @Sendable () async -> Bool
) async throws {
  let fin = ContinuousClock.now + limite
  while ContinuousClock.now < fin {
    if await condicion() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("no llegó a pasar: \(que)")
}
