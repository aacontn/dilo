import Foundation
import Testing

@testable import DiloEngines

/// El recorte de bordes contra Parakeet de verdad: que el texto salga igual y
/// que soltar→texto no empeore. Pide un modelo descargado (v3 o Ultra) y voz
/// sintetizada; sin alguno de los dos, se salta diciendo cuál faltó.
///
/// Se enciende a mano porque cargar el modelo en un proceso de pruebas nuevo
/// cuesta ~30 s de Core ML cada vez, y `swift test` corre seguido:
///
/// ```bash
/// DILO_PARAKEET=1 swift test --filter "RecorteConParakeetTests"
/// ```
///
/// Medido en este M1 el 2026-10-13, con 2,5 s de sala a cada lado de una
/// frase de 3,2 s: 158 ms sin recorte y 142 ms con recorte (mediana de 3).
@Suite(
  .enabled(if: ProcessInfo.processInfo.environment["DILO_PARAKEET"] == "1", "se enciende con DILO_PARAKEET=1: carga el modelo y tarda ~30 s"),
  .enabled(if: !ParakeetModelStore.enDisco().isEmpty, "el modelo de Parakeet no está descargado en este Mac"),
  .enabled(if: AudioDePrueba.haySintesis, "esta máquina no tiene `say` para fabricar voz"),
  .serialized
)
struct RecorteConParakeetTests {
  @Test func recortarNoCambiaElTextoYNoAgregaLatencia() async throws {
    let frase = "Hola, mañana te mando el informe del proyecto sin falta."
    let voz = try AudioDePrueba.voz(frase)
    // Dos segundos y medio de sala a cada lado: lo que queda grabado cuando
    // alguien aprieta, piensa y suelta un rato después de terminar.
    let completo = AudioDePrueba.ruido(segundos: 2.5, amplitud: 0.000_4)
      + voz + AudioDePrueba.ruido(segundos: 2.5, amplitud: 0.000_4, semilla: 3)

    let modelo = try await CargadorDeParakeet().cargar()
    defer { Task { await modelo.liberar() } }
    // La primera predicción compila el grafo de Core ML: no la mide nadie con
    // la tecla en la mano.
    _ = try await modelo.transcribir(completo)

    let reloj = ContinuousClock()
    var sinRecorte: [Duration] = []
    var conRecorte: [Duration] = []
    var textoSin = ""
    var textoCon = ""
    for _ in 0..<3 {
      sinRecorte.append(try await reloj.measure { textoSin = try await modelo.transcribir(completo) })
      conRecorte.append(
        try await reloj.measure {
          var audio = completo
          let tramo = try #require(RecorteDeBordes.preparar(&audio))
          textoCon = try await modelo.transcribir(Array(audio[tramo]))
        })
    }
    let medianaSin = sinRecorte.sorted()[1]
    let medianaCon = conRecorte.sorted()[1]
    print("Parakeet sin recorte: \(medianaSin) → «\(textoSin)»")
    print("Parakeet con recorte: \(medianaCon) → «\(textoCon)»")

    for palabra in ["mañana", "informe", "proyecto", "falta"] {
      #expect(textoCon.lowercased().contains(palabra), "se perdió «\(palabra)»")
    }
    // El recorte transcribe menos audio: no puede salir más lento que no
    // recortar, salvo el ruido de la medición.
    #expect(medianaCon <= medianaSin + .milliseconds(30))
  }

  /// Sólo sala, sin voz: el motor no recibe nada sobre lo que inventar.
  @Test func unaSalaCalladaNoLlegaAlModelo() async throws {
    var sala = AudioDePrueba.ruido(segundos: 4, amplitud: 0.000_8)
    #expect(RecorteDeBordes.preparar(&sala) == nil)
  }

  /// El rescate entero con el modelo de verdad: escuchó Apple, Apple no sacó
  /// nada, y Parakeet transcribe el mismo audio desde la RAM.
  @Test func parakeetRescataUnaTomaDesdeLaRAM() async throws {
    let voz = try AudioDePrueba.voz("Te mando el informe del proyecto mañana temprano.")
    let toma = AudioDePrueba.ruido(segundos: 0.8, amplitud: 0.000_3) + voz
      + AudioDePrueba.ruido(segundos: 0.8, amplitud: 0.000_3, semilla: 9)

    let parakeet = ParakeetEngine(captura: CapturaFalsa())
    let grabadora = GrabadoraEnRAM()
    let router = SpeechEngineRouter(
      apple: MotorFalso(texto: ""), parakeet: parakeet, elegido: .apple, parakeetDescargado: { true })
    let respaldo = MotorConRespaldo(
      motores: router, grabadora: grabadora,
      transcribir: { motor, muestras, _ in
        guard motor == .parakeet else { throw EngineError.sinMicrofono }
        return try await parakeet.transcribirSinSesion(muestras)
      })

    try await respaldo.start(locale: Locale(identifier: "es-CL"), handlers: EngineHandlers { _ in })
    toma.withUnsafeBufferPointer { _ = grabadora.agregar($0) }
    let reloj = ContinuousClock()
    var texto = ""
    let duro = try await reloj.measure { texto = try await respaldo.finish() }
    print("Rescate con Parakeet desde RAM (con carga del modelo): \(duro) → «\(texto)»")
    for palabra in ["informe", "proyecto", "mañana"] {
      #expect(texto.lowercased().contains(palabra), "se perdió «\(palabra)»")
    }
    await parakeet.descargarDeMemoria()
  }
}
