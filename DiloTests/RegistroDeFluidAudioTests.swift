import DiloEngines
import Testing

/// La app callada desde que arranca: el host de los tests es la app real, y
/// `AppDelegate.main()` ya corrió cuando llega acá.
struct RegistroDeFluidAudioEnLaAppTests {
  @Test func laAppArrancaConFluidAudioCallado() {
    #expect(
      RegistroDeFluidAudio.callado,
      "FluidAudio anota el texto que transcribe; la app tiene que callarlo antes de crear un motor"
    )
  }
}
