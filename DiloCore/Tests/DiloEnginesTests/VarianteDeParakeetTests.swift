import Foundation
import Testing

@testable import DiloEngines

/// Qué Parakeet dicta, qué se ofrece bajar y qué se ofrece mandar a la
/// Papelera, sin bajar un giga de modelos.
struct VarianteDeParakeetTests {
  @Test func laRecomendadaEsUltra() {
    // Una instalación nueva baja Ultra. Si la comparación con dictados
    // reales en español dice otra cosa, cambia esta constante y este test.
    #expect(VarianteDeParakeet.recomendada == .ultra)
  }

  @Test func sinNadaEnDiscoNoDictaNingunParakeet() {
    #expect(ResolucionDeParakeet.enUso(enDisco: [], elegida: nil) == nil)
    #expect(ResolucionDeParakeet.enUso(enDisco: [], elegida: .ultra) == nil)
  }

  /// Quien ya tenía v3 sigue dictando con v3: nada se baja solo.
  @Test func conV3YSinUltraSigueDictandoV3() {
    #expect(ResolucionDeParakeet.enUso(enDisco: [.v3], elegida: nil) == .v3)
    // Elegir Ultra sin tenerla no deja a nadie sin dictar.
    #expect(ResolucionDeParakeet.enUso(enDisco: [.v3], elegida: .ultra) == .v3)
    #expect(ResolucionDeParakeet.paraBajar(enDisco: [.v3]) == .ultra)
  }

  /// Al terminar de bajar Ultra, pasa a Ultra y ofrece mandar v3 a la
  /// Papelera.
  @Test func conLasDosDictaUltraYOfreceBorrarV3() {
    let enUso = ResolucionDeParakeet.enUso(enDisco: [.v3, .ultra], elegida: nil)
    #expect(enUso == .ultra)
    #expect(ResolucionDeParakeet.paraBajar(enDisco: [.v3, .ultra]) == nil)
    #expect(ResolucionDeParakeet.paraBorrar(enDisco: [.v3, .ultra], enUso: enUso) == .v3)
  }

  /// Quien comparó y prefiere v3 la elige a mano, y entonces no se le
  /// ofrece borrarla.
  @Test func loElegidoAManoGanaSiEstaEnDisco() {
    let enUso = ResolucionDeParakeet.enUso(enDisco: [.v3, .ultra], elegida: .v3)
    #expect(enUso == .v3)
    #expect(ResolucionDeParakeet.paraBorrar(enDisco: [.v3, .ultra], enUso: enUso) == nil)
  }

  @Test func unaInstalacionNuevaOfreceBajarUltra() {
    #expect(ResolucionDeParakeet.paraBajar(enDisco: []) == .ultra)
    #expect(ResolucionDeParakeet.paraBorrar(enDisco: [], enUso: nil) == nil)
    #expect(ResolucionDeParakeet.paraBorrar(enDisco: [.ultra], enUso: .ultra) == nil)
  }

  @Test func elResolverDiceCualParakeetDicta() {
    let conV3 = EngineResolver.resolver(elegido: .parakeet, parakeetEnDisco: [.v3], varianteElegida: nil)
    #expect(conV3.efectivo == .parakeet)
    #expect(conV3.varianteDeParakeet == .v3)

    let sinNada = EngineResolver.resolver(elegido: .parakeet, parakeetEnDisco: [], varianteElegida: nil)
    #expect(sinNada.efectivo == .apple)
    #expect(sinNada.varianteDeParakeet == nil)
    #expect(sinNada.aviso != nil)

    // Con Apple elegido no hay Parakeet que nombrar, aunque estén las dos.
    let apple = EngineResolver.resolver(elegido: .apple, parakeetEnDisco: [.v3, .ultra], varianteElegida: nil)
    #expect(apple.varianteDeParakeet == nil)
  }

  /// Las carpetas son las que FluidAudio arma sola: el v3 que ya está en disco
  /// se sigue encontrando donde siempre.
  @Test func lasCarpetasSonLasDeSiempre() {
    #expect(VarianteDeParakeet.v3.nombreDeCarpeta == "parakeet-tdt-0.6b-v3")
    #expect(VarianteDeParakeet.ultra.nombreDeCarpeta == "parakeet-ultra")
  }

  @Test func laVarianteElegidaSeGuardaYSeBorra() throws {
    let suite = "cl.espaciodigital.dilo.tests.variante"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)

    #expect(PreferenciaDeVariante.leer(defaults) == nil)
    PreferenciaDeVariante.guardar(.v3, in: defaults)
    #expect(PreferenciaDeVariante.leer(defaults) == .v3)
    PreferenciaDeVariante.guardar(nil, in: defaults)
    #expect(PreferenciaDeVariante.leer(defaults) == nil)
    // Un valor que ya no existe es «la mejor que haya», no un error.
    defaults.set("v4", forKey: PreferenciaDeVariante.clave)
    #expect(PreferenciaDeVariante.leer(defaults) == nil)

    defaults.removePersistentDomain(forName: suite)
  }

  /// La clave del motor no cambió: quien venía con `parakeet` guardado sigue
  /// con Parakeet.
  @Test func laClaveDelMotorNoSeRenombro() {
    #expect(EnginePreference.clave == "speechEngine")
    #expect(SpeechEngineKind.parakeet.rawValue == "parakeet")
  }

  @Test func elCargadorSinModelosNoEstaDisponible() throws {
    let vacia = FileManager.default.temporaryDirectory
      .appendingPathComponent("dilo-sin-modelos-\(UUID().uuidString)", isDirectory: true)
    let cargador = CargadorDeParakeet(carpeta: vacia)
    #expect(!cargador.disponible)
    #expect(cargador.varianteEnUso == nil)
    #expect(ParakeetModelStore.enDisco(en: vacia).isEmpty)
  }
}

/// El motor suelta el modelo cargado cuando ya no es el que toca.
struct CambioDeVarianteTests {
  private let locale = Locale(identifier: "es-CL")

  @Test func siUltraTerminaDeBajarElDictadoSiguienteLaCarga() async throws {
    let captura = CapturaFalsa()
    let cargador = CargadorFalso()
    let motor = ParakeetEngine(captura: captura, cargador: cargador, reloj: RelojFalso(), reposo: nil)

    try await motor.start(locale: locale, handlers: EngineHandlers { _ in })
    await (try #require(await motor.cargaDelGatillo)).value
    captura.hablar(segundos: 1)
    _ = try await motor.finish()
    let primero = try #require(await cargador.ultimoModelo)
    #expect(primero.firma == "v3")

    // Ultra terminó de bajar con v3 en la RAM.
    cargador.cambiarFirma("ultra")
    try await motor.start(locale: locale, handlers: EngineHandlers { _ in })
    await (try #require(await motor.cargaDelGatillo)).value
    await motor.cancel()

    #expect(await primero.liberaciones == 1, "v3 tenía que soltarse antes del dictado")
    #expect(await cargador.cargas == 2)
    #expect(await cargador.ultimoModelo?.firma == "ultra")
  }

  @Test func sinCambioNoSeVuelveACargar() async throws {
    let captura = CapturaFalsa()
    let cargador = CargadorFalso()
    let motor = ParakeetEngine(captura: captura, cargador: cargador, reloj: RelojFalso(), reposo: nil)

    for _ in 0..<2 {
      try await motor.start(locale: locale, handlers: EngineHandlers { _ in })
      if let carga = await motor.cargaDelGatillo { await carga.value }
      await motor.cancel()
    }
    #expect(await cargador.cargas == 1)
  }
}
