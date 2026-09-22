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

  /// El router recuerda cuál escuchó de verdad, y sobrevive a `finish()`.
  ///
  /// El historial se escribe después de terminar, así que preguntarlo antes
  /// no sirve; y no se puede deducir de lo elegido, porque son distintos
  /// justo cuando importa. Sale de la duda de Alfonso del 2026-09-22: «si
  /// estuve usando Parakeet o Apple».
  @Test func elRouterRecuerdaQueMotorEscuchoDeVerdad() async throws {
    let apple = MotorFalso(texto: "de Apple")
    let parakeet = MotorFalso(texto: "de Parakeet")
    let motor = SpeechEngineRouter(
      apple: apple,
      parakeet: parakeet,
      elegido: .parakeet,
      parakeetDescargado: { false }
    )

    // Antes de la primera sesión no hay nada que contestar, y eso es un nil,
    // no un motor inventado.
    #expect(await motor.motorDeLaUltimaSesion() == nil)

    try await motor.start(locale: .current, handlers: EngineHandlers { _ in })
    _ = try await motor.finish()
    #expect(
      await motor.motorDeLaUltimaSesion() == .apple,
      "eligió Parakeet y escuchó Apple: eso es lo que el historial tiene que guardar"
    )
  }

  /// Y con el modelo puesto, el mismo elegido deja otra respuesta.
  @Test func conElModeloPuestoElRouterRecuerdaParakeet() async throws {
    let motor = SpeechEngineRouter(
      apple: MotorFalso(texto: "de Apple"),
      parakeet: MotorFalso(texto: "de Parakeet"),
      elegido: .parakeet,
      parakeetDescargado: { true }
    )

    try await motor.start(locale: .current, handlers: EngineHandlers { _ in })
    _ = try await motor.finish()
    #expect(await motor.motorDeLaUltimaSesion() == .parakeet)
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

/// Lo que el router le pasa al motor que sí tiene RAM que devolver.
struct ReposoDelRouterTests {
  @Test func elRouterLePasaElReposoAlMotorConModelo() async throws {
    let parakeet = MotorFalso()
    let apple = MotorFalso()
    let router = SpeechEngineRouter(
      apple: apple,
      parakeet: parakeet,
      elegido: .parakeet,
      parakeetDescargado: { true }
    )

    await router.configurarReposo(.seconds(60))

    #expect(await parakeet.reposo == .seconds(60))
    #expect(await parakeet.configuraciones == 1)
    // Apple no carga modelos propios: no tiene nada que soltar.
    #expect(await apple.configuraciones == 0)
  }
}
