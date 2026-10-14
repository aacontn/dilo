import Foundation
import Testing
import os

@testable import DiloEngines

struct RevisionDeTomaTests {
  /// `segundosDeVoz` de voz al principio y sala callada el resto.
  private func toma(segundosDeVoz: Double, total: Double) -> MedidaDeToma {
    var audio = AudioDePrueba.ruido(segundos: total, amplitud: 0.000_2)
    if segundosDeVoz > 0 {
      let voz = AudioDePrueba.tono(segundos: segundosDeVoz)
      audio.replaceSubrange(0..<voz.count, with: voz)
    }
    return MedidaDeToma.medir(audio)
  }

  @Test func laSegundaPasadaSoloConVozYTextoPobre() {
    let conVoz = toma(segundosDeVoz: 4, total: 6)
    #expect(RevisionDeToma.pedirSegundaOpinion(conVoz, texto: "", degenerado: false))
    #expect(RevisionDeToma.pedirSegundaOpinion(conVoz, texto: "Sí.", degenerado: false))
    #expect(RevisionDeToma.pedirSegundaOpinion(conVoz, texto: String(repeating: "x", count: 40), degenerado: true))
    #expect(!RevisionDeToma.pedirSegundaOpinion(conVoz, texto: String(repeating: "palabra ", count: 6), degenerado: false))
    // Un segundo de voz y nada de texto: rescate, aunque Ocelli pida dos.
    let corta = toma(segundosDeVoz: 1, total: 2)
    #expect(RevisionDeToma.pedirSegundaOpinion(corta, texto: "", degenerado: false))
    #expect(!RevisionDeToma.pedirSegundaOpinion(corta, texto: "Sí.", degenerado: false))
    // Sin voz no se le pregunta a nadie.
    #expect(!RevisionDeToma.pedirSegundaOpinion(toma(segundosDeVoz: 0, total: 3), texto: "", degenerado: false))
    // Ante la duda se transcribe: dos décimas de voz y nada de texto ya valen
    // una segunda opinión. Antes hacía falta medio segundo.
    let apenas = toma(segundosDeVoz: 0.2, total: 2)
    #expect(!apenas.huboVoz)
    #expect(RevisionDeToma.pedirSegundaOpinion(apenas, texto: "", degenerado: false))
  }

  /// Lo que entrega el WH-CH720N al abrirse: un segundo de ceros exactos y
  /// después una sala a −81 dBFS (medido el 14-oct). Si dijiste «sí» mientras
  /// despertaba, el motor no oyó nada, y decir «No te escuché» es culparte.
  private func tomaDeBluetooth(segundosEnCero: Double, total: Double, voz: Double = 0) -> MedidaDeToma {
    var audio = AudioDePrueba.ruido(segundos: total, amplitud: 0.000_09)
    let ceros = Int(segundosEnCero * PoliticaDeGrabacion.tasa)
    audio.replaceSubrange(0..<ceros, with: [Float](repeating: 0, count: ceros))
    if voz > 0 {
      let tono = AudioDePrueba.tono(segundos: voz)
      audio.replaceSubrange(ceros..<ceros + tono.count, with: tono)
    }
    return MedidaDeToma.medir(audio)
  }

  @Test func losCerosDelBluetoothSeCuentanYNoSonElPiso() {
    let medida = tomaDeBluetooth(segundosEnCero: 1, total: 2.5)
    #expect(medida.segundosEnCero >= 0.9 && medida.segundosEnCero <= 1.0)
    #expect(medida.microfonoDormido)
    // El piso es la sala, no los ceros: con ellos el percentil 10 daba 0.
    #expect(medida.piso > 0)
    #expect(medida.segundosConVoz == 0)
    // Una sala de verdad no es cero digital.
    #expect(!toma(segundosDeVoz: 0, total: 3).microfonoDormido)
  }

  @Test func sinTextoConElMicrofonoDormidoNoEsNadieHablo() async {
    let dormido = tomaDeBluetooth(segundosEnCero: 1, total: 2.5)
    #expect(await RevisionDeToma.revisar(crudo: "", medida: dormido, otroMotor: nil) == .microfonoDormido)
    // Con un poco de voz después de despertar se le pregunta al otro motor, y
    // lo que diga se pega.
    let conAlgo = tomaDeBluetooth(segundosEnCero: 1, total: 2.5, voz: 0.3)
    #expect(await RevisionDeToma.revisar(crudo: "", medida: conAlgo, otroMotor: { "Sí." }) == .texto("Sí."))
    // Una sala callada con el micrófono despierto sigue siendo «No te escuché».
    let muda = toma(segundosDeVoz: 0, total: 3)
    #expect(await RevisionDeToma.revisar(crudo: "", medida: muda, otroMotor: nil) == .nadieHablo)
  }

  @Test func depurarJuntaLosCuatroFiltros() {
    let muda = toma(segundosDeVoz: 0, total: 3)
    let conVoz = toma(segundosDeVoz: 3, total: 4)
    #expect(RevisionDeToma.depurar("[BLANK_AUDIO] Hola.", conVoz) == ("Hola.", false))
    #expect(RevisionDeToma.depurar("Gracias.", muda) == ("", false))
    #expect(RevisionDeToma.depurar("Gracias.", conVoz) == ("Gracias.", false))
    #expect(RevisionDeToma.depurar("Ok. Subtítulos realizados por la comunidad de Amara.org", conVoz) == ("Ok.", false))
    #expect(RevisionDeToma.depurar("..........!!!!!", conVoz) == ("", true))
    let bucle = Array(repeating: "te lo mando", count: 6).joined(separator: " ")
    #expect(RevisionDeToma.depurar(bucle, conVoz) == ("te lo mando", true))
  }

  @Test func veredictos() async {
    let conVoz = toma(segundosDeVoz: 4, total: 6)
    let muda = toma(segundosDeVoz: 0, total: 3)
    #expect(await RevisionDeToma.revisar(crudo: "Gracias.", medida: muda, otroMotor: nil) == .nadieHablo)
    #expect(await RevisionDeToma.revisar(crudo: "", medida: conVoz, otroMotor: nil) == .fallida)
    #expect(await RevisionDeToma.revisar(crudo: "", medida: conVoz, otroMotor: { nil }) == .fallida)
    #expect(
      await RevisionDeToma.revisar(
        crudo: "", medida: conVoz, otroMotor: { "Hola, ¿cómo estás? Te escribo por lo de mañana." })
        == .texto("Hola, ¿cómo estás? Te escribo por lo de mañana."))
    // La segunda opinión también pasa por los filtros.
    #expect(await RevisionDeToma.revisar(crudo: "", medida: conVoz, otroMotor: { "[BLANK_AUDIO]" }) == .fallida)
  }

  /// Un texto bueno no le pregunta a nadie: la segunda pasada es un rescate,
  /// no un costo de cada dictado.
  @Test func unTextoBuenoNoPideSegundaOpinion() async {
    let preguntas = OSAllocatedUnfairLock(initialState: 0)
    let conVoz = toma(segundosDeVoz: 3, total: 4)
    let veredicto = await RevisionDeToma.revisar(
      crudo: "Mañana te mando el informe, sin falta, antes de las diez.", medida: conVoz,
      otroMotor: {
        preguntas.withLock { $0 += 1 }
        return "otra cosa"
      })
    #expect(veredicto == .texto("Mañana te mando el informe, sin falta, antes de las diez."))
    #expect(preguntas.withLock { $0 } == 0)
  }

  /// Ocelli se queda con el más largo: el motor que se quedó corto es el que
  /// se comió palabras.
  @Test func ganaElMasLargo() async {
    let conVoz = toma(segundosDeVoz: 5, total: 6)
    #expect(
      await RevisionDeToma.revisar(crudo: "Sí.", medida: conVoz, otroMotor: { "Sí, mañana te lo mando." })
        == .texto("Sí, mañana te lo mando."))
    #expect(
      await RevisionDeToma.revisar(crudo: "Sí, mañana.", medida: conVoz, otroMotor: { "Sí." })
        == .texto("Sí, mañana."))
  }

  @Test func elPlazoCortaUnaSegundaOpinionColgada() async {
    let reloj = RelojFalso()
    let espera = Task {
      await MotorConRespaldo.conPlazo(.seconds(5), reloj: reloj) {
        try await Task.sleep(for: .seconds(3_600))
        return "tarde"
      }
    }
    await reloj.hastaQueAlguienEspere()
    await reloj.avanzar()
    #expect(await espera.value == nil)
  }

  @Test func elPlazoNoMolestaAUnaRespuestaATiempo() async {
    #expect(await MotorConRespaldo.conPlazo(.seconds(5), reloj: RelojFalso()) { "a tiempo" } == "a tiempo")
    #expect(await MotorConRespaldo.conPlazo(.seconds(5), reloj: RelojFalso()) { throw EngineError.sinMicrofono } == nil)
  }

  /// Lo que la revisión le suma a soltar→texto cuando todo sale bien: pasar
  /// la toma a Float, medirla y depurar el texto. Un minuto de dictado, en
  /// Debug, tiene que quedar lejos de los 300 ms del spec.
  @Test func elCaminoFelizCuestaPoco() async {
    let toma = TomaDeAudio(
      muestras: (0..<960_000).map { Int16(truncatingIfNeeded: ($0 * 7_919) % 6_000 - 3_000) })
    let texto = String(
      repeating: "Mañana te mando el informe del proyecto, sin falta, antes de la reunión. ", count: 14)
    // Con un solo motor la revisión no espera a nadie: su costo es medir la
    // toma y depurar el texto, y eso se mide en CPU del hilo. El `await` va
    // aparte, sólo para afirmar que el camino completo devuelve algo.
    let duro = CostoDeCPU.medir {
      let medida = MedidaDeToma.medir(toma.comoFloat())
      let depurado = RevisionDeToma.depurar(texto, medida)
      _ = RevisionDeToma.pedirSegundaOpinion(medida, texto: depurado.texto, degenerado: depurado.degenerado)
    }
    let veredicto: RevisionDeToma.Veredicto? = await RevisionDeToma.revisar(
      crudo: texto, medida: MedidaDeToma.medir(toma.comoFloat()), otroMotor: nil)
    print("Revisión de una toma de 60 s con \(texto.count) caracteres: \(duro)")
    #expect(veredicto != nil)
    #expect(duro < .milliseconds(50))
  }
}
