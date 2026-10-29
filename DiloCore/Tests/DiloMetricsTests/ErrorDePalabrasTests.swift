import Testing

@testable import DiloMetrics

/// La cuenta del WER del banco de comparación de motores.
struct ErrorDePalabrasTests {
  @Test func igualesEsCero() {
    let wer = ErrorDePalabras.medir(referencia: "Hola, ¿cómo estás?", hipotesis: "hola cómo estás")
    #expect(wer.ediciones == 0)
    #expect(wer.palabras == 3)
    #expect(wer.tasa == 0)
  }

  /// Una tilde que falta es una palabra que la persona corrige a mano.
  @Test func lasTildesCuentan() {
    let wer = ErrorDePalabras.medir(referencia: "ya está listo", hipotesis: "ya esta listo")
    #expect(wer.ediciones == 1)
  }

  @Test func cuentaSustitucionesBorradosEInserciones() {
    // «mando» por «mandé» (1), falta «el» (1), sobra «eh» (1).
    let wer = ErrorDePalabras.medir(
      referencia: "mañana te mando el informe",
      hipotesis: "eh mañana te mandé informe"
    )
    #expect(wer.ediciones == 3)
    #expect(wer.palabras == 5)
    #expect(abs(wer.tasa - 0.6) < 0.000_1)
  }

  /// El WER del corpus pesa por palabras, no por archivo.
  @Test func elCorpusSumaEdicionesYPalabras() {
    let corto = ErrorDePalabras(ediciones: 1, palabras: 2)
    let largo = ErrorDePalabras(ediciones: 1, palabras: 98)
    let total = corto + largo
    #expect(total.ediciones == 2)
    #expect(total.palabras == 100)
    #expect(abs(total.tasa - 0.02) < 0.000_1)
  }

  @Test func sinReferenciaNoDivideporCero() {
    #expect(ErrorDePalabras.medir(referencia: "", hipotesis: "").tasa == 0)
    #expect(ErrorDePalabras.medir(referencia: "", hipotesis: "algo").tasa == 1)
    #expect(ErrorDePalabras.medir(referencia: "algo", hipotesis: "").ediciones == 1)
  }
}
