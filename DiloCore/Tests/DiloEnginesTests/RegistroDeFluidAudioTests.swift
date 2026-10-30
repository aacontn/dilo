import FluidAudio
import Testing

@testable import DiloEngines

/// FluidAudio no escribe lo dicho ni en la consola ni en el log.
struct RegistroDeFluidAudioTests {
  @Test func callarDejaSoloAdvertenciasYNadaEnLaConsola() {
    RegistroDeFluidAudio.callar()

    #expect(AppLogger.minimumLevel == .warning)
    #expect(!AppLogger.mirrorsToConsole)
    #expect(RegistroDeFluidAudio.callado)
    // Lo que trae el texto de cada ventana va en debug e info: por debajo
    // del piso.
    #expect(AppLogger.Level.info < RegistroDeFluidAudio.nivelMinimo)
    #expect(AppLogger.Level.debug < RegistroDeFluidAudio.nivelMinimo)
  }
}
