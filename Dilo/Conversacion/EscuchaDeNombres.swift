import AppKit
import DiloEngines
import DiloModes
import Foundation
import os

/// La **escucha de nombres**: con «Escuchar mi nombre» prendido en Ajustes,
/// decir «Dilo, …» abre la conversación con ese agente sin apretar nada.
///
/// Apagada de fábrica. Prendida, el micrófono queda abierto —macOS muestra el
/// punto naranja— y lo que se oye vive en un búfer de RAM de doce segundos
/// que se pisa solo (`BuferDeEscucha`): nunca va a disco, ni a un log, ni al
/// historial, ni fuera del Mac. Es la excepción declarada al ~0 % de CPU en
/// reposo, y sólo mientras está prendida; cuánto gasta se mide en la espiga
/// (`/Volumes/SSD 1/Dilo/taller/escucha/README.md`) y se dice en Ajustes.
///
/// Se pausa sola mientras hay dictado, conversación o reunión, con la
/// pantalla bloqueada y con el Mac durmiendo (`PausasDeLaEscucha`). «No
/// molestar» no: saber si está puesto pide `INFocusStatusCenter`, que trae
/// su propio permiso y un entitlement de comunicaciones. El audio
/// lo trabaja `OidoDeLaEscucha` fuera del hilo principal; acá sólo se decide
/// si el micrófono va abierto.
///
/// Para conectarla: `oyoUnNombre` recibe el agente y lo que se dijo después
/// del nombre (nil si sólo se dijo el nombre), en el actor principal.
@MainActor
final class EscuchaDeNombres {
  private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "escucha")

  /// Se oyó un nombre. Lo conecta la raíz de composición con la conversación
  /// (`ControladorDeLaConversacion.llamar(agente:primerTurno:)`).
  var oyoUnNombre: ((_ agente: Agente, _ primerTurno: String?) -> Void)?
  /// Los agentes, con sus nombres y su «Se llama por nombre». De fábrica, los
  /// de `Agente.deFabrica`; la raíz de composición lo apunta a los de Ajustes.
  var agentes: () -> [Agente] = { Agente.deFabrica }
  /// Si hay Parakeet en disco: la escucha transcribe con él.
  var hayMotor: () -> Bool = { DiloSpeechStack.cargadorDeParakeet.disponible }

  private let settings: AppSettings
  private(set) var pausas = PausasDeLaEscucha()
  private var abierta: Abierta?
  private var vigia: VigiaDeDispositivos?
  private var observadores: [(NotificationCenter, any NSObjectProtocol)] = []
  private var revision: Task<Void, Never>?
  /// Cuántas veces se prendió el micrófono, para que una revisión vieja que
  /// termina tarde no pise a una nueva.
  private var generacion = 0

  /// El micrófono abierto y quien escucha lo que entrega.
  private struct Abierta {
    let microfono: MicrofonoDeLaEscucha
    let oido: OidoDeLaEscucha
    let flujo: AsyncStream<[Float]>.Continuation
    let tarea: Task<Void, Never>
    let plan: PlanDeMicrofono.Decision
  }

  init(settings: AppSettings) {
    self.settings = settings
  }

  /// Empieza a mirar Ajustes, la pantalla y los dispositivos. No abre nada si
  /// la escucha está apagada.
  func empezar() {
    observarAjustes()
    let espacio = NSWorkspace.shared.notificationCenter
    let distribuido = DistributedNotificationCenter.default()
    func mirar(_ centro: NotificationCenter, _ nombre: Notification.Name, _ bloqueada: Bool?) {
      let observador = centro.addObserver(forName: nombre, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.marcar(.pantallaBloqueada, bloqueada ?? Self.pantallaBloqueada)
        }
      }
      observadores.append((centro, observador))
    }
    mirar(distribuido, Notification.Name("com.apple.screenIsLocked"), true)
    mirar(distribuido, Notification.Name("com.apple.screenIsUnlocked"), false)
    mirar(espacio, NSWorkspace.willSleepNotification, true)
    // Al despertar, la pantalla puede seguir bloqueada o no: se pregunta.
    mirar(espacio, NSWorkspace.didWakeNotification, nil)
    pausas.marcar(.pantallaBloqueada, Self.pantallaBloqueada)
    revisar()
  }

  /// La app se cierra.
  func detener() {
    for (centro, observador) in observadores { centro.removeObserver(observador) }
    observadores.removeAll()
    vigia = nil
    revision?.cancel()
    cerrar()
  }

  /// Algo que ya usa el micrófono empezó o terminó: el dictado, la
  /// conversación, la reunión.
  func marcar(_ motivo: PausasDeLaEscucha.Motivo, _ presente: Bool) {
    guard pausas.motivos.contains(motivo) != presente else { return }
    pausas.marcar(motivo, presente)
    revisar()
  }

  /// Si la pantalla está bloqueada ahora, según la sesión de la ventana.
  static var pantallaBloqueada: Bool {
    guard let sesion = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (sesion["CGSSessionScreenIsLocked"] as? Bool) ?? false
  }

  private func observarAjustes() {
    withObservationTracking {
      _ = settings.escucharMiNombre
      _ = settings.conversacionMicrofono
      // Renombrar a un agente cambia lo que se escucha sin cerrar el micrófono.
      _ = settings.conversacionAgentes
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.revisar()
        self?.observarAjustes()
      }
    }
  }

  /// Vuelve a decidir si el micrófono va abierto, y con cuál. Lo que lee la
  /// HAL va fuera del hilo principal.
  private func revisar() {
    pausas.prendida = settings.escucharMiNombre
    pausas.marcar(.sinMotor, !hayMotor())
    let regla = NombreQueDespierta(agentes: agentes())
    pausas.marcar(.sinNombres, !regla.hayNombres)
    // La falta de micrófono o de detector se vuelve a probar en cada
    // revisión: pudieron enchufar uno, o volvió la red.
    pausas.marcar(.sinMicrofono, false)
    pausas.marcar(.sinDetector, false)
    vigilarDispositivos(pausas.prendida)

    guard pausas.abreElMicrofono else {
      revision?.cancel()
      cerrar()
      publicar()
      return
    }
    publicar()
    revision?.cancel()
    generacion += 1
    let esta = generacion
    let eleccion = settings.conversacionMicrofono
    revision = Task { [weak self] in
      let plan = await Task.detached(priority: .utility) {
        PlanDeMicrofono.paraLaEscucha(
          eleccion: eleccion,
          entradas: DispositivosDeAudio.entradas(),
          entradaDelSistema: DispositivosDeAudio.entradaDelSistema(),
          tapaCerrada: Tapa.estaCerrada
        )
      }.value
      guard let self, !Task.isCancelled, esta == self.generacion, self.pausas.abreElMicrofono else { return }
      await self.abrir(plan: plan, regla: regla)
    }
  }

  private func abrir(plan: PlanDeMicrofono.Decision?, regla: NombreQueDespierta) async {
    guard let plan else {
      Self.logger.notice("sin micrófono para escuchar: sólo hay uno Bluetooth que nadie eligió, o la tapa está cerrada")
      cerrar()
      pausas.marcar(.sinMicrofono, true)
      publicar()
      return
    }
    // El mismo micrófono que ya escucha: nada que hacer, salvo los nombres.
    if let abierta, abierta.plan == plan {
      await abierta.oido.cambiarRegla(regla)
      return
    }
    cerrar()

    // El detector antes que el micrófono: la primera vez lo baja (~1 MB), y
    // sin él no hay qué escuchar.
    let detector = DetectorDeVozSilero()
    do {
      try await detector.preparar()
    } catch {
      Self.logger.error("no pude cargar el detector de voz: \(error.localizedDescription, privacy: .public)")
      pausas.marcar(.sinDetector, true)
      publicar()
      return
    }
    guard pausas.abreElMicrofono else { return }
    let (flujo, continuacion) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .bufferingNewest(64))
    let oido = OidoDeLaEscucha(
      regla: regla,
      detector: { try await detector.probabilidad($0) },
      reiniciarDetector: { await detector.reiniciar() },
      transcribir: { audio in
        try await ParakeetCompartido.motor.conElModelo { try await $0.transcribir(audio) }
      },
      avisar: { [weak self] llamado in
        Task { @MainActor [weak self] in self?.oyoUnNombre?(llamado.agente, llamado.primerTurno) }
      }
    )
    let microfono = MicrofonoDeLaEscucha { continuacion.yield($0) }
    microfono.alFallar = { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.cerrar()
        self?.pausas.marcar(.sinMicrofono, true)
        self?.publicar()
      }
    }
    // Arrancar un motor de audio tarda decenas de milisegundos: fuera del
    // hilo principal.
    let entrada = plan.fijarA
    let abrio = await Task.detached(priority: .userInitiated) { () -> Bool in
      do {
        try microfono.empezar(entrada: entrada)
        return true
      } catch {
        return false
      }
    }.value
    guard abrio, pausas.abreElMicrofono else {
      microfono.detener()
      continuacion.finish()
      if !abrio {
        Self.logger.error("no pude abrir el micrófono de la escucha")
        pausas.marcar(.sinMicrofono, true)
        publicar()
      }
      return
    }
    let tarea = Task.detached(priority: .utility) { await oido.escuchar(flujo) }
    abierta = Abierta(microfono: microfono, oido: oido, flujo: continuacion, tarea: tarea, plan: plan)
    Self.logger.notice("escuchando nombres")
  }

  /// Lo que Ajustes dice de la escucha (`EscucharMiNombreFila`).
  private func publicar() {
    EstadoDeLaEscucha.compartido.pausas = pausas
  }

  /// Cierra el micrófono y borra todo lo oído.
  private func cerrar() {
    guard let abierta else { return }
    self.abierta = nil
    abierta.microfono.detener()
    abierta.flujo.finish()
    let oido = abierta.oido
    let tarea = abierta.tarea
    Task.detached(priority: .utility) {
      await tarea.value
      await oido.olvidar()
    }
    Self.logger.notice("escucha en pausa")
  }

  /// Con la escucha prendida, un micrófono que se enchufa o se desenchufa
  /// vuelve a decidir con cuál se escucha. Apagada, nadie mira la HAL.
  private func vigilarDispositivos(_ prendida: Bool) {
    guard prendida else {
      vigia = nil
      return
    }
    guard vigia == nil else { return }
    vigia = VigiaDeDispositivos { [weak self] in
      Task { @MainActor [weak self] in
        // Los avisos llegan en ráfaga al enchufar algo: se espera a que se
        // calmen.
        try? await Task.sleep(for: .milliseconds(600))
        self?.revisar()
      }
    }
  }
}
