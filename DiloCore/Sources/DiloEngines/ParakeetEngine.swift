import Foundation
import os

/// El **Motor de voz** Parakeet TDT v3 (int8) corriendo en Core ML, por
/// FluidAudio (Apache 2.0).
///
/// Acumula el audio mientras la persona habla y transcribe el buffer completo
/// al soltar: el modelo es batch, no streaming, así que esa pasada final es la
/// que manda. Los parciales de en medio son una cortesía para que el HUD no
/// esté mudo, y se calculan sobre los trozos nuevos arrastrando el estado del
/// decoder, que cuesta lineal en vez de cuadrático.
///
/// **El modelo entra a la RAM en el `start` y se va solo.** Nunca al arrancar
/// la app ni al abrir Ajustes: cargarlo ahí dejaba el reposo en 46,4 MB
/// —contra 18,8 MB con el motor de Apple— por un dictado que quizá no pasa
/// nunca (plan, Tarea 9). La carga arranca cuando la persona aprieta el
/// gatillo y corre **en paralelo a la grabación**, que es cuando no cuesta
/// nada; si suelta antes de que el modelo esté listo, `finish()` espera y el
/// buffer se transcribe igual. Tras `descargarModeloTras` sin dictar, el
/// modelo se suelta y el dictado siguiente lo vuelve a cargar.
///
/// **Medido en este M1** (16 GB, macOS 27) con un dictado de 8,9 s hecho con
/// `say -v Mónica`, 5 repeticiones tras una pasada de calentamiento
/// (`MedicionDeMotoresTests`):
///
/// | | soltar → texto |
/// | --- | --- |
/// | Parakeet v3 int8, buffer de 8,9 s | **198 ms** (min 198, max 206) |
/// | Apple `SpeechTranscriber`, mismo audio en vivo | **35 ms** (min 32, max 76) |
///
/// Los dos pasan los 300 ms del spec §3. Apple llega antes porque transcribe
/// mientras hablas y al soltar sólo le queda cerrar; Parakeet transcribe todo
/// de una y a cambio pone las comas donde van —en esta misma frase Apple se
/// comió tres— y dicta igual en cualquier Mac.
///
/// El modelo pesa **469 MB** en disco (23 archivos, int8) y se baja en ~60 s
/// con fibra. La primera compilación del encoder a Core ML cuesta **28 s** y
/// pasa una sola vez, dentro de la descarga: por eso la barra termina en
/// "Preparando el modelo…" y no en 100 %.
///
/// **Cuánto se espera por la carga**, medido con
/// `MedicionDeMotoresTests.cargaEnFrioDelModelo` en este M1 con la caché de
/// Core ML ya hecha: **172–412 ms** en meterlo a la RAM, **195 ms** la primera
/// predicción y 127 ms las siguientes. Menos que un dictado corto: la carga
/// que arranca con el gatillo termina antes que la frase, y por eso no hace
/// falta precalentar nada.
///
/// La excepción es **la primera vez después de descargar el modelo**: ahí Core
/// ML compila el encoder para el Neural Engine y son ~28 s que pasan una sola
/// vez. Es la espera que vio la Tarea 9 al medir con el modelo recién bajado.
/// Mientras dure, la píldora dice "Cargando el modelo…" y el buffer espera:
/// el dictado sale tarde, pero sale entero.
public actor ParakeetEngine: SpeechEngine, MotorConModeloEnMemoria {
  private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "engines")

  /// Parakeet trabaja a 16 kHz mono. No es configurable: es el modelo.
  public static let sampleRate: Double = 16_000

  /// Cada cuánto se intenta un parcial. Dos segundos es el trozo más corto
  /// que le da al TDT contexto suficiente para no cortar palabras a la mitad.
  private static let segundosPorParcial: Double = 2

  /// **Los parciales están encendidos porque salen baratos en este M1.**
  /// Un trozo de 2 s se transcribe en **124 ms** arrastrando el estado del
  /// decoder: 6 % de ocupación mientras la persona habla, y nunca dos a la
  /// vez. Si en una máquina más lenta esto empezara a morder, se apaga acá y
  /// el HUD queda mostrando sólo la forma de onda hasta que sueltas.
  private static let parcialesEncendidos = true

  private let captura: any AudioCapture
  private let cargador: any CargadorDeModelo
  private let reloj: any RelojDeReposo

  /// El modelo en la RAM, o nada. Que esto sea `nil` es el estado normal de
  /// una app que lleva la tarde abierta sin que nadie dicte.
  private var modelo: (any ModeloDeVoz)?
  /// La carga en vuelo. Existe para que apretar el gatillo no espere veinte
  /// segundos antes de empezar a grabar: la captura arranca al tiro y el
  /// modelo termina de cargar mientras la persona habla.
  private var carga: Task<any ModeloDeVoz, any Error>?
  /// La carga que arrancó el gatillo, con su aviso a la píldora colgando
  /// atrás. Se guarda para poder esperarla desde `swift test` en vez de
  /// dormir una cifra al ojo; en la app nadie la mira.
  private var cargaConAviso: Task<Void, Never>?
  /// Cada cuánto se suelta el modelo sin dictar. `nil` es "nunca".
  private var reposo: Duration?
  /// La cuenta regresiva en curso hacia la descarga.
  private var descarga: Task<Void, Never>?

  private var handlers: EngineHandlers?
  /// A quién avisarle que el modelo está cargando. Se guarda aparte de
  /// `handlers` porque sobrevive al `finish`: si la persona soltó antes de que
  /// el modelo estuviera, la píldora tiene que seguir diciendo por qué espera.
  private var avisarCarga: (@Sendable (Bool) -> Void)?
  private var activa = false
  private var muestras: [Float] = []
  /// Hasta dónde ya se leyó para parciales.
  private var leidoHastaParcial = 0
  private var textoParcial = ""
  /// Si al modelo ya se le limpió el estado de parciales de la sesión
  /// anterior. El modelo vive más que una sesión: sin esto, el segundo
  /// dictado empezaría arrastrando el decoder del primero.
  private var parcialesReiniciados = false
  /// Un parcial a la vez: si el anterior no ha terminado, este trozo espera
  /// al siguiente turno en vez de apilar trabajo sobre el Neural Engine.
  private var parcialEnVuelo = false

  public init(
    captura: any AudioCapture,
    cargador: any CargadorDeModelo = CargadorDeParakeet(),
    reloj: any RelojDeReposo = RelojDelSistema(),
    reposo: Duration? = DescargaPorReposo.porDefecto.intervalo
  ) {
    self.captura = captura
    self.cargador = cargador
    self.reloj = reloj
    self.reposo = reposo
  }

  public var estaListo: Bool { modelo != nil }

  /// Cuánto audio lleva acumulado la sesión. Sólo lo mira `swift test`, para
  /// esperar a que el trozo hablado llegue de verdad al motor en vez de
  /// dormir una cifra al ojo.
  var muestrasEnElBuffer: Int { muestras.count }

  /// La cuenta regresiva hacia soltar el modelo, o nada si no hay ninguna.
  /// Sólo la mira `swift test`, para esperar a que termine.
  var cuentaDeReposo: Task<Void, Never>? { descarga }

  /// La carga que arrancó el último `start`. Misma razón que la de arriba.
  var cargaDelGatillo: Task<Void, Never>? { cargaConAviso }

  public func tieneModeloEnMemoria() async -> Bool { modelo != nil }

  /// **No carga nada.** Precalentar corre al arrancar la app y cada vez que
  /// cambian los idiomas; el modelo de Parakeet entra a la RAM recién cuando
  /// alguien dicta (ver la cabecera del tipo). Sigue existiendo para cumplir
  /// el contrato y para que el router no tenga que saber quién es quién.
  public func prewarm(locale: Locale) async throws {}

  /// Carga el modelo una sola vez, aunque se lo pidan tres veces seguidas.
  private func cargarModelo() async throws -> any ModeloDeVoz {
    if let modelo { return modelo }
    return try await tareaDeCarga().value
  }

  /// La carga en vuelo, o una nueva. Vuelve sincrónica a propósito: el
  /// `start` se queda con la tarea sin esperar a nadie.
  ///
  /// **El estado lo escribe la tarea antes de terminar, nunca quien la
  /// espera.** El gatillo pide la carga y `finish()` espera a esa misma
  /// tarea; los dos resumen cuando termina y el orden entre ellos no está
  /// definido. Cuando el estado se escribía afuera, el `finish()` que ganaba
  /// la carrera armaba el reposo con `modelo` todavía en nil: la cuenta no
  /// arrancaba nunca y el modelo se quedaba en la RAM hasta cerrar la app.
  private func tareaDeCarga() -> Task<any ModeloDeVoz, any Error> {
    if let carga { return carga }

    let cargador = self.cargador
    let tarea = Task { [weak self] () async throws -> any ModeloDeVoz in
      do {
        let listo = try await cargador.cargar()
        await self?.anotarCargado(listo)
        return listo
      } catch {
        await self?.olvidarLaCarga()
        throw error
      }
    }
    carga = tarea
    return tarea
  }

  private func anotarCargado(_ listo: any ModeloDeVoz) {
    modelo = listo
    carga = nil
    parcialesReiniciados = true
    Self.logger.info("Parakeet cargado y listo")
  }

  private func olvidarLaCarga() {
    carga = nil
  }

  /// Cada cuánto se suelta el modelo si nadie dicta. Se lee de Ajustes al
  /// empezar cada dictado, como todo lo demás.
  public func configurarReposo(_ intervalo: Duration?) async {
    guard intervalo != reposo else { return }
    reposo = intervalo
    // Pasar a "nunca" con el modelo cargado y sin dictar apaga la cuenta ahí
    // mismo, en vez de esperar al próximo dictado para que aplique.
    if !activa { armarDescargaPorReposo() }
  }

  /// Suelta el modelo de la RAM. La sesión siguiente lo vuelve a cargar.
  public func descargarDeMemoria() async {
    descarga?.cancel()
    descarga = nil
    guard let modelo else { return }
    self.modelo = nil
    await modelo.liberar()
    Self.logger.info("Parakeet soltó el modelo de la RAM")
  }

  public func start(locale: Locale, handlers: EngineHandlers) async throws {
    guard !activa else { throw EngineError.sesionActiva }
    guard cargador.disponible else { throw EngineError.modeloNoDescargado }

    // Nadie suelta el modelo a media frase.
    descarga?.cancel()
    descarga = nil

    // El modelo se carga en paralelo a la grabación: recién se necesita al
    // soltar. Grabar desde el primer milisegundo importa más que tenerlo todo
    // listo antes de escuchar.
    if modelo == nil {
      avisarCarga = handlers.cargando
      handlers.cargando(true)
      let tarea = tareaDeCarga()
      cargaConAviso = Task { [weak self] in
        _ = try? await tarea.value
        await self?.avisarQueLaCargaTermino()
      }
    }

    muestras.removeAll(keepingCapacity: true)
    leidoHastaParcial = 0
    textoParcial = ""
    parcialesReiniciados = false
    parcialEnVuelo = false
    self.handlers = handlers
    activa = true

    do {
      try captura.iniciar(
        sampleRate: Self.sampleRate,
        muestras: { [weak self] trozo in
          Task { await self?.recibir(trozo) }
        },
        nivel: handlers.nivel,
        falla: handlers.falla
      )
    } catch {
      activa = false
      self.handlers = nil
      throw error
    }
  }

  public func finish() async throws -> String {
    guard activa else { throw EngineError.sinSesion }
    activa = false
    captura.detener()
    handlers = nil

    let audio = muestras
    muestras.removeAll(keepingCapacity: false)
    // Un apretón sin voz no vale una pasada por el modelo.
    guard audio.count > Int(Self.sampleRate * 0.2) else {
      armarDescargaPorReposo()
      return ""
    }

    // Acá se espera al modelo si todavía viene en camino. Las palabras ya
    // están grabadas: perderlas por llegar antes que Core ML sería la peor
    // manera de ahorrar RAM.
    let modelo = try await cargarModelo()
    defer { armarDescargaPorReposo() }
    return try await modelo.transcribir(audio).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func cancel() async {
    guard activa else { return }
    activa = false
    captura.detener()
    handlers = nil
    avisarCarga?(false)
    avisarCarga = nil
    muestras.removeAll(keepingCapacity: false)
    textoParcial = ""
    armarDescargaPorReposo()
  }

  private func avisarQueLaCargaTermino() {
    avisarCarga?(false)
    avisarCarga = nil
  }

  /// Arranca la cuenta regresiva hacia soltar el modelo. Sin modelo cargado,
  /// sin intervalo, o con un dictado andando, no hay nada que contar.
  private func armarDescargaPorReposo() {
    descarga?.cancel()
    descarga = nil
    guard !activa, modelo != nil, let reposo else { return }

    let reloj = self.reloj
    descarga = Task { [weak self] in
      do { try await reloj.dormir(reposo) } catch { return }
      guard !Task.isCancelled else { return }
      await self?.descargarSiNadieDicto()
    }
  }

  private func descargarSiNadieDicto() async {
    // Un dictado que empezó mientras corría la cuenta la gana: el `start` ya
    // canceló la tarea, y esto es el cinturón por si llegó tarde.
    guard !activa, carga == nil else { return }
    await descargarDeMemoria()
  }

  private func recibir(_ trozo: [Float]) {
    guard activa else { return }
    muestras.append(contentsOf: trozo)
    guard Self.parcialesEncendidos, !parcialEnVuelo else { return }

    let pendientes = muestras.count - leidoHastaParcial
    guard pendientes >= Int(Self.sampleRate * Self.segundosPorParcial) else { return }

    let corte = muestras.count
    let nuevo = Array(muestras[leidoHastaParcial..<corte])
    leidoHastaParcial = corte
    parcialEnVuelo = true
    Task { await self.transcribirParcial(nuevo) }
  }

  private func transcribirParcial(_ trozo: [Float]) async {
    defer { parcialEnVuelo = false }
    // Mientras el modelo no haya terminado de cargar no hay parcial que dar;
    // el trozo se pierde y el texto de verdad igual sale de la pasada final.
    guard activa, let modelo else { return }
    if !parcialesReiniciados {
      parcialesReiniciados = true
      await modelo.reiniciarParciales()
    }
    guard activa else { return }

    do {
      let texto = try await modelo.transcribirParcial(trozo)
      guard activa else { return }
      textoParcial += texto
      // Todo lo que Parakeet entrega ya viene firme: el modelo no revisa lo
      // que dijo. Por eso no hay nada volátil que mostrar.
      handlers?.parcial(EngineUpdate(finalizado: textoParcial, volatil: ""))
    } catch {
      // Un parcial que falla no rompe la sesión: el texto de verdad sale de
      // la pasada final sobre el buffer entero.
      Self.logger.debug("parcial de Parakeet falló: \(error.localizedDescription, privacy: .public)")
    }
  }
}
