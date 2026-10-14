import CoreGraphics
import Foundation
import Testing
@testable import Dilo

/// Un atajo, dos gestos: cuánto es un toque, el Esc entero y deshacerlo. Lo
/// que no depende de un micrófono se prueba acá, en la máquina pura, en el tap
/// con eventos sintéticos y en las preferencias.
struct GestoDelGatilloTests {
  private typealias Machine = DictationSessionMachine

  private let t0 = ContinuousClock.now

  private func en(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }

  /// Una máquina grabando un sostenido, con el gesto que se le pida.
  private func grabando(umbral: Int = 250, conDeshacer: Bool = false, conVoz: Bool = false) -> Machine {
    var machine = Machine()
    machine.fijarGesto(umbral: .milliseconds(umbral), conDeshacer: conDeshacer)
    _ = machine.reduce(.triggerPressed(now: t0))
    _ = machine.reduce(.beginApproved)
    _ = machine.reduce(.recognitionStarted(now: en(100)))
    if conVoz { _ = machine.reduce(.updateReceived(hasVisibleText: true)) }
    return machine
  }

  // Cuánto es un toque.

  @Test func conUmbralDe400SoltarALos300Traba() {
    var machine = grabando(umbral: 400)
    #expect(machine.reduce(.triggerReleased(now: en(300))) == [.showLatched])
    #expect(machine.state == .recording(.latched))
  }

  @Test func conUmbralDe400SoltarALos450Termina() {
    var machine = grabando(umbral: 400)
    let efectos = machine.reduce(.triggerReleased(now: en(450)))
    #expect(efectos.contains(.showFinalizing))
    #expect(machine.state == .finishing)
  }

  /// Ajustes a media sesión aplica a la siguiente: el gesto se fija en
  /// reposo y la sesión en curso sigue con el suyo.
  @Test func cambiarElUmbralAMediaSesionNoLaToca() {
    var machine = grabando(umbral: 400)
    machine.fijarGesto(umbral: .milliseconds(150), conDeshacer: true)
    #expect(machine.umbralDeToque == .milliseconds(400))
    #expect(!machine.conDeshacer)
    #expect(machine.reduce(.triggerReleased(now: en(300))) == [.showLatched])
  }

  /// El de fábrica es el de CONTEXT.md, con nombre y en un solo lugar.
  @Test func elUmbralDeFabricaEsElDeSiempre() {
    #expect(Machine.tapThreshold == .milliseconds(250))
    #expect(Machine().umbralDeToque == Machine.tapThreshold)
    #expect(GestoDelGatillo.rangoDelUmbralMs.contains(GestoDelGatillo.umbralDeFabricaMs))
  }

  // Esc y deshacer.

  /// Sin deshacer, un Esc es el de siempre, con voz o sin ella.
  @Test func sinDeshacerElEscTiraLoDicho() {
    var machine = grabando(conDeshacer: false, conVoz: true)
    #expect(machine.reduce(.escapePressed) == [
      .stopNoSpeechTimer, .setEscapeCapture(false), .hideHUD, .cancelRecognition,
    ])
    #expect(!machine.hayRetenido)
  }

  /// Sin voz no hay nada que recuperar: se cancela como siempre.
  @Test func unEscSinVozSeCancelaComoSiempre() {
    var machine = grabando(conDeshacer: true, conVoz: false)
    #expect(machine.reduce(.escapePressed).contains(.cancelRecognition))
    #expect(!machine.hayRetenido)
  }

  @Test func unEscConVozRetieneYSobreviveAlReset() {
    var machine = grabando(conDeshacer: true, conVoz: true)
    #expect(machine.reduce(.escapePressed) == [
      .stopNoSpeechTimer, .setEscapeCapture(false), .retenerParaDeshacer,
    ])
    #expect(machine.state == .cancelling)
    _ = machine.reduce(.sessionEnded)
    #expect(machine.state == .idle)
    #expect(machine.hayRetenido)
  }

  @Test func deshacerEnReposoEntregaLoRetenido() {
    var machine = grabando(conDeshacer: true, conVoz: true)
    _ = machine.reduce(.escapePressed)
    _ = machine.reduce(.sessionEnded)
    #expect(machine.reduce(.deshacerCancelacion) == [.entregarLoRetenido])
    #expect(machine.state == .finishing)
    #expect(!machine.hayRetenido)
    // Y termina como cualquier entrega.
    _ = machine.reduce(.sessionEnded)
    #expect(machine.state == .idle)
  }

  /// Un clic rapidísimo, antes de que lo retenido termine de reconocerse,
  /// no se pierde: se entrega en cuanto llega.
  @Test func deshacerMientrasTerminaDeReconocerSeEntregaAlLlegar() {
    var machine = grabando(conDeshacer: true, conVoz: true)
    _ = machine.reduce(.escapePressed)
    #expect(machine.reduce(.deshacerCancelacion).isEmpty)
    let efectos = machine.reduce(.sessionEnded)
    #expect(efectos.last == .entregarLoRetenido)
    #expect(machine.state == .finishing)
  }

  @Test func alVencerSeDescarta() {
    var machine = grabando(conDeshacer: true, conVoz: true)
    _ = machine.reduce(.escapePressed)
    _ = machine.reduce(.sessionEnded)
    #expect(machine.reduce(.retencionVencida) == [.descartarLoRetenido])
    #expect(!machine.hayRetenido)
    // Vencido, deshacer ya no tiene qué entregar.
    #expect(machine.reduce(.deshacerCancelacion).isEmpty)
    #expect(machine.state == .idle)
  }

  /// Si lo retenido salió vacío, el controlador lo vence antes del reset, y
  /// un deshacer pedido entre medio tampoco entrega nada.
  @Test func loRetenidoVacioNoSeEntregaAunqueLoPidan() {
    var machine = grabando(conDeshacer: true, conVoz: true)
    _ = machine.reduce(.escapePressed)
    _ = machine.reduce(.deshacerCancelacion)
    _ = machine.reduce(.retencionVencida)
    #expect(!machine.reduce(.sessionEnded).contains(.entregarLoRetenido))
    #expect(machine.state == .idle)
  }

  /// Empezar otro dictado es la respuesta a «¿lo recupero?»: no.
  @Test func apretarElGatilloConAlgoRetenidoLoDescartaYEmpieza() {
    var machine = grabando(conDeshacer: true, conVoz: true)
    _ = machine.reduce(.escapePressed)
    _ = machine.reduce(.sessionEnded)
    #expect(machine.reduce(.triggerPressed(now: en(2_000))) == [.descartarLoRetenido, .checkAndBegin])
    #expect(!machine.hayRetenido)
  }

  @Test func deshacerSinNadaRetenidoNoHaceNada() {
    var machine = Machine()
    #expect(machine.reduce(.deshacerCancelacion).isEmpty)
    #expect(machine.reduce(.retencionVencida).isEmpty)
    #expect(machine.state == .idle)
  }

  // El Esc entero en el tap.

  private func esc(_ abajo: Bool, repeticion: Bool = false) throws -> CGEvent {
    let evento = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: abajo))
    evento.flags = []
    if repeticion { evento.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
    return evento
  }

  /// El Esc que cancela no llega a la app ni al apretar ni al soltar,
  /// aunque la sesión apague la captura entre los dos. Su autorrepetición
  /// tampoco.
  @Test func elEscQueCancelaSeTragaEnteroAunqueLaCapturaSeApague() throws {
    let log = EventLog()
    let monitor = GlobalKeyEventMonitor(handler: log.append)
    monitor.setEscapeCaptureEnabled(true)

    #expect(monitor.process(type: .keyDown, event: try esc(true)) == nil)
    #expect(log.events == [.cancelPressed])
    // La sesión cancelada apaga la captura antes de que el dedo suba.
    monitor.setEscapeCaptureEnabled(false)
    #expect(monitor.process(type: .keyDown, event: try esc(true, repeticion: true)) == nil)
    #expect(monitor.process(type: .keyUp, event: try esc(false)) == nil)
    #expect(log.events == [.cancelPressed])

    // El Esc siguiente, sin sesión, es de la app entero.
    #expect(monitor.process(type: .keyDown, event: try esc(true)) != nil)
    #expect(monitor.process(type: .keyUp, event: try esc(false)) != nil)
  }

  /// Si el keyUp se perdió —el tap se apagó entre medio—, el Esc nuevo no
  /// puede quedar tragado: es de la app.
  @Test func unEscNuevoNoQuedaTragadoPorUnKeyUpPerdido() throws {
    let log = EventLog()
    let monitor = GlobalKeyEventMonitor(handler: log.append)
    monitor.setEscapeCaptureEnabled(true)
    _ = monitor.process(type: .keyDown, event: try esc(true))
    monitor.setEscapeCaptureEnabled(false)

    #expect(monitor.process(type: .keyDown, event: try esc(true)) != nil)
    #expect(monitor.process(type: .keyUp, event: try esc(false)) != nil)
  }

  /// Sin sesión, Esc no se toca nunca.
  @Test func sinSesionElEscPasa() throws {
    let monitor = GlobalKeyEventMonitor(handler: { _ in })
    #expect(monitor.process(type: .keyDown, event: try esc(true)) != nil)
    #expect(monitor.process(type: .keyUp, event: try esc(false)) != nil)
  }

  // Las preferencias.

  private func defaultsNuevos() -> UserDefaults {
    let nombre = "GestoDelGatilloTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: nombre)!
    defaults.removePersistentDomain(forName: nombre)
    return defaults
  }

  @MainActor @Test func deFabricaUnToqueEs250YDeshacerVieneEncendido() {
    let settings = AppSettings(defaults: defaultsNuevos())
    #expect(settings.umbralDeToqueMs == 250)
    #expect(settings.deshacerCancelacion)
  }

  /// Las claves no se renombran: renombrar una borra la preferencia de quien
  /// ya la tiene.
  @MainActor @Test func seGuardanConSusClavesYVuelven() {
    let defaults = defaultsNuevos()
    let settings = AppSettings(defaults: defaults)
    settings.umbralDeToqueMs = 400
    settings.deshacerCancelacion = false
    #expect(defaults.integer(forKey: "diloUmbralDeToqueMs") == 400)
    #expect(defaults.object(forKey: "diloDeshacerCancelacion") as? Bool == false)
    let releido = AppSettings(defaults: defaults)
    #expect(releido.umbralDeToqueMs == 400)
    #expect(!releido.deshacerCancelacion)
  }

  /// Un valor fuera del rango se acerca al borde en vez de perderse.
  @MainActor @Test func unUmbralFueraDeRangoSeAcercaAlBorde() {
    let defaults = defaultsNuevos()
    defaults.set(5_000, forKey: GestoDelGatillo.claveDelUmbral)
    #expect(AppSettings(defaults: defaults).umbralDeToqueMs == 600)
    defaults.set(10, forKey: GestoDelGatillo.claveDelUmbral)
    #expect(AppSettings(defaults: defaults).umbralDeToqueMs == 150)
  }

  // La muesca del deshacer.

  /// El aviso de deshacer dura exactamente su ventana, toma el clic, y desde
  /// él se puede pasar a procesar: es lo que hace la entrega al deshacer.
  @Test func elAvisoDeDeshacerPasaAProcesar() {
    let aviso = AvisoConAccion(texto: "Cancelado", accion: .deshacerCancelacion)
    #expect(ResultadoDelNotch.accionable(aviso).duracion == GestoDelGatillo.ventanaParaDeshacer)
    #expect(EstadoDelNotch.resultado(.accionable(aviso)).tomaElMouse)

    var maquina = MaquinaDelNotch()
    _ = maquina.recibir(.escuchar)
    _ = maquina.recibir(.entregar(.accionable(aviso)))
    _ = maquina.recibir(.procesar)
    #expect(maquina.estado == .procesando)

    // Un aviso de arreglo, en cambio, no es una sesión que siga.
    var otra = MaquinaDelNotch()
    _ = otra.recibir(.entregar(.accionable(AvisoConAccion(texto: "x", accion: .abrirAjustes("y")))))
    #expect(otra.recibir(.procesar).isEmpty)
  }
}

/// Lo que el gatillo lee antes de abrir el micrófono no puede cobrarle al
/// arranque del dictado. Se mide en CPU del hilo y no en reloj de pared: lo
/// que se afirma es lo que cuesta, no que el runner estuvo libre.
struct LecturaParaDictarTests {
  private func cpu() -> Duration {
    var t = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
    return .seconds(t.tv_sec) + .nanoseconds(t.tv_nsec)
  }

  @MainActor @Test func leerLoQueImpideDictarYaTibioCuestaMenosDeDosMilisegundos() {
    // La primera lectura es la que la preparación hace por adelantado.
    _ = LecturaParaDictar.leer()
    var mejor = Duration.seconds(1)
    for _ in 0..<3 {
      let antes = cpu()
      _ = LecturaParaDictar.leer()
      mejor = min(mejor, cpu() - antes)
    }
    #expect(mejor < .milliseconds(2), "leer costó \(mejor) de CPU")
  }
}
