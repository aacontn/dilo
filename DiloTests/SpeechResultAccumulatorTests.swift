import DiloText
import Testing

@testable import Dilo

struct SpeechResultAccumulatorTests {
  @Test func keepsLastVolatileResultWhenFinalizationEndsTheStream() {
    var accumulator = SpeechRecognitionService.ResultAccumulator()

    _ = accumulator.receive("Hello world", isFinal: false)

    #expect(accumulator.completedText == "Hello world")
  }

  @Test func replacesVolatileTextWhenAResultBecomesFinal() {
    var accumulator = SpeechRecognitionService.ResultAccumulator()

    _ = accumulator.receive("Hello", isFinal: false)
    _ = accumulator.receive("Hello", isFinal: true)
    _ = accumulator.receive(" world", isFinal: false)

    #expect(accumulator.completedText == "Hello world")
  }

  /// El bug de 0.4.0: `SpeechTranscriber` entrega cada segmento con su propio
  /// espaciado y, cada cierto trecho, sin el espacio de adelante. Pegarlos
  /// con `+=` dejaba «no se ve como un notchTiene una línea».
  @Test func segmentosSinEspacioPropioNoQuedanPegados() {
    var accumulator = SpeechRecognitionService.ResultAccumulator()

    _ = accumulator.receive("no se ve como un notch", isFinal: true)
    _ = accumulator.receive("Tiene una línea", isFinal: true)

    #expect(accumulator.completedText == "no se ve como un notch Tiene una línea")
  }

  /// Y el que sí trae su espacio no termina con dos.
  @Test func elEspacioDelMotorNoSeDuplica() {
    var accumulator = SpeechRecognitionService.ResultAccumulator()

    _ = accumulator.receive("Igual se ve que es rápido", isFinal: true)
    _ = accumulator.receive(" Ahora habría que ver qué tan.", isFinal: true)
    _ = accumulator.receive(" Qué tan poderoso es", isFinal: true)

    #expect(
      accumulator.completedText
        == "Igual se ve que es rápido Ahora habría que ver qué tan. Qué tan poderoso es"
    )
  }

  /// La puntuación que llega como segmento propio se queda pegada a la
  /// palabra, y una apertura, a lo que abre.
  @Test func laPuntuacionNoSeSeparaDeSuPalabra() {
    var accumulator = SpeechRecognitionService.ResultAccumulator()

    _ = accumulator.receive("¿", isFinal: true)
    _ = accumulator.receive("quedó claro", isFinal: true)
    _ = accumulator.receive("?", isFinal: true)

    #expect(accumulator.completedText == "¿quedó claro?")
  }

  /// Lo volátil viaja sin tocar —el HUD lo dibuja aparte— y el espacio lo
  /// pone quien lo junta.
  @Test func loVolatilLlegaEnteroYSeJuntaConEspacio() {
    var accumulator = SpeechRecognitionService.ResultAccumulator()

    _ = accumulator.receive("Igual se ve", isFinal: true)
    let update = accumulator.receive("que es rápido", isFinal: false)

    #expect(update.volatileText == "que es rápido")
    #expect(update.displayText == "Igual se ve que es rápido")
    #expect(Union.colaDe(update.finalizedText, update.volatileText) == " que es rápido")
  }
}
