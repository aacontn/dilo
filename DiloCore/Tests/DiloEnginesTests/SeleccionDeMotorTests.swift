import Foundation
import Testing

@testable import DiloEngines

/// Qué motor corre, qué se guarda y qué pasa cuando el modelo no está.
struct SeleccionDeMotorTests {
  @Test func elMotorPorDefectoEsParakeet() {
    // El spec lo deja marcado como ambigüedad: si la segunda prueba de
    // Alfonso con SpeechAnalyzer en es_CL sale mejor, esta constante cambia
    // y este test cambia con ella. Está acá para que ese cambio sea a ojos
    // vistas y no un default que se corrió solo.
    #expect(SpeechEngineKind.porDefecto == .parakeet)
  }

  @Test func sinModeloParakeetCaeAApple() {
    let seleccion = EngineResolver.resolver(elegido: .parakeet, parakeetDescargado: false)

    #expect(seleccion.efectivo == .apple)
    #expect(seleccion.elegido == .parakeet)
    #expect(seleccion.cayoAApple)
    #expect(seleccion.aviso != nil)
  }

  @Test func conModeloParakeetCorreParakeet() {
    let seleccion = EngineResolver.resolver(elegido: .parakeet, parakeetDescargado: true)

    #expect(seleccion.efectivo == .parakeet)
    #expect(!seleccion.cayoAApple)
    #expect(seleccion.aviso == nil)
  }

  @Test func appleNuncaSeCae() {
    for descargado in [true, false] {
      let seleccion = EngineResolver.resolver(elegido: .apple, parakeetDescargado: descargado)
      #expect(seleccion.efectivo == .apple)
      #expect(seleccion.aviso == nil)
    }
  }

  @Test func elRouterCorreAppleYAvisaCuandoParakeetNoEsta() async throws {
    let apple = MotorFalso(texto: "de Apple")
    let parakeet = MotorFalso(texto: "de Parakeet")
    let avisos = AvisoRecibido()
    let motor = SpeechEngineRouter(
      apple: apple,
      parakeet: parakeet,
      elegido: .parakeet,
      parakeetDescargado: { false },
      avisar: { avisos.guardar($0) }
    )

    try await motor.start(locale: .current, handlers: EngineHandlers { _ in })
    let texto = try await motor.finish()

    #expect(texto == "de Apple")
    #expect(await parakeet.arranques == 0)
    #expect(avisos.ultimo?.cayoAApple == true)
    #expect(await motor.avisoVigente() != nil)
  }

  @Test func laSeleccionSeGuardaYSeVuelveALeer() throws {
    let defaults = try #require(UserDefaults(suiteName: "cl.espaciodigital.dilo.tests.motor"))
    defaults.removePersistentDomain(forName: "cl.espaciodigital.dilo.tests.motor")

    #expect(EnginePreference.leer(defaults) == .porDefecto)

    EnginePreference.guardar(.apple, in: defaults)
    #expect(EnginePreference.leer(defaults) == .apple)

    EnginePreference.guardar(.parakeet, in: defaults)
    #expect(EnginePreference.leer(defaults) == .parakeet)

    defaults.removePersistentDomain(forName: "cl.espaciodigital.dilo.tests.motor")
  }

  @Test func unValorGuardadoQueYaNoExisteCaeAlDefault() throws {
    let suite = "cl.espaciodigital.dilo.tests.motor.viejo"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)

    defaults.set("whisper-turbo", forKey: EnginePreference.clave)
    #expect(EnginePreference.leer(defaults) == .porDefecto)

    defaults.removePersistentDomain(forName: suite)
  }

  @Test func losDosMotoresSonLocales() {
    for motor in SpeechEngineKind.allCases {
      #expect(motor.etiqueta == "LOCAL")
      #expect(!motor.title.isEmpty)
      #expect(!motor.descripcion.isEmpty)
    }
  }
}

private final class AvisoRecibido: @unchecked Sendable {
  private let candado = NSLock()
  private var valor: EngineSelection?

  func guardar(_ seleccion: EngineSelection) {
    candado.withLock { valor = seleccion }
  }

  var ultimo: EngineSelection? { candado.withLock { valor } }
}
