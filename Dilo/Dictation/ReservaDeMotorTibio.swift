import AVFAudio
import AppKit
import DiloEngines
import Foundation
import os

/// Un `AVAudioEngine` fijado a su micrófono y **preparado, no corriendo**,
/// esperando el próximo dictado: ahorra armar el grafo y resolver el
/// dispositivo en el gatillo. Sin `start()` no hay hilo de audio en reposo.
///
/// **Apagado de fábrica** (`AppSettings.motorDeAudioTibio`): un motor
/// preparado ocupa memoria en reposo, y el costo —contra los 60 MB del spec
/// §3— y lo que ahorra no se han medido en un Mac con el permiso de
/// micrófono. Se mide con el ajuste encendido y apagado antes de prenderlo
/// para todos (`AGENTS.md`).
///
/// Vence a los 30 minutos (`VigenciaDeMotorTibio.vidaMaxima`), con cualquier
/// cambio de dispositivos o de la entrada del sistema, y al despertar el Mac.
/// Nunca se prepara un Bluetooth (`VigenciaDeMotorTibio.vale`).
///
/// `@unchecked Sendable` con candado, como `MicrophoneInput`: `AVAudioEngine`
/// no es `Sendable` y ésta es su única dueña mientras espera.
final class ReservaDeMotorTibio: @unchecked Sendable {
  private struct Guardado {
    let motor: AVAudioEngine
    let dispositivo: AudioDeviceID
    let epoca: Int
    let creado: ContinuousClock.Instant
  }

  private let candado = NSLock()
  private var guardado: Guardado?
  private var epoca = 0
  /// Los escuchas se arman con el primer motor preparado, no antes: con el
  /// ajuste apagado la reserva no mira nada.
  private var vigia: VigiaDeDispositivos?
  private var alDespertar: (any NSObjectProtocol)?
  private let cola = DispatchQueue(label: "cl.espaciodigital.dilo.motor-tibio", qos: .utility)

  deinit {
    if let alDespertar { NSWorkspace.shared.notificationCenter.removeObserver(alDespertar) }
  }

  /// Cualquier cambio de dispositivos vence lo preparado.
  func dispositivosCambiaron() {
    descartar(subiendoLaEpoca: true)
  }

  /// Prepara un motor para la próxima sesión, fuera del hilo que lo pide.
  /// Sin `start()`: no corre nada hasta que alguien dicte.
  func precalentar(para entrada: EntradaDeAudio) {
    guard VigenciaDeMotorTibio.vale(transporte: entrada.transporte) else { return }
    armarEscuchas()
    let epocaPedida = candado.withLock { epoca }
    cola.async { [weak self] in
      guard let self else { return }
      let inicio = ContinuousClock.now
      let motor = AVAudioEngine()
      do {
        try motor.fijarEntrada(entrada)
      } catch {
        return
      }
      // Arma la cadena de entrada antes de preparar, como la arma una sesión.
      _ = motor.inputNode.inputFormat(forBus: 0)
      motor.prepare()
      let (sobra, guardo) = candado.withLock { () -> (AVAudioEngine?, Bool) in
        // Un cambio de dispositivos mientras se preparaba: éste ya nació viejo.
        guard epoca == epocaPedida else { return (motor, false) }
        defer {
          guardado = Guardado(motor: motor, dispositivo: entrada.id, epoca: epoca, creado: .now)
        }
        return (guardado?.motor, true)
      }
      sobra?.reset()
      guard guardo else { return }
      let tardo = inicio.duration(to: .now).components
      let milisegundos = tardo.seconds * 1_000 + tardo.attoseconds / 1_000_000_000_000_000
      AppLog.audio.info(
        "motor tibio preparado para \(entrada.nombre, privacy: .public) en \(milisegundos) ms"
      )
      programarVencimiento(epoca: epocaPedida)
    }
  }

  /// El motor tibio si sirve para este micrófono; si no, nada. Lo que no
  /// sirve se suelta igual: nunca hay dos motores esperando.
  func tomar(para entrada: EntradaDeAudio) -> AVAudioEngine? {
    let (sirve, motor) = candado.withLock { () -> (Bool, AVAudioEngine?) in
      defer { guardado = nil }
      guard let guardado else { return (false, nil) }
      let sirve = VigenciaDeMotorTibio.sirve(
        guardadoPara: guardado.dispositivo, epocaGuardada: guardado.epoca,
        creado: guardado.creado, pedido: entrada.id, epocaActual: epoca, ahora: .now)
      return (sirve, guardado.motor)
    }
    guard sirve else {
      motor?.reset()
      return nil
    }
    return motor
  }

  /// Si hay un motor esperando. Para los tests y el registro.
  var hayMotor: Bool { candado.withLock { guardado != nil } }

  private func descartar(subiendoLaEpoca: Bool) {
    let viejo = candado.withLock { () -> AVAudioEngine? in
      if subiendoLaEpoca { epoca += 1 }
      defer { guardado = nil }
      return guardado?.motor
    }
    viejo?.reset()
  }

  /// Pasados los 30 minutos se suelta aunque nadie lo pida. Un solo
  /// despertador por motor, y uno viejo no bota al nuevo.
  private func programarVencimiento(epoca epocaDelMotor: Int) {
    let segundos = Double(VigenciaDeMotorTibio.vidaMaxima.components.seconds)
    cola.asyncAfter(deadline: .now() + segundos) { [weak self] in
      guard let self else { return }
      let vencido = candado.withLock { () -> AVAudioEngine? in
        guard let guardado, guardado.epoca == epocaDelMotor,
          guardado.creado.duration(to: .now) >= VigenciaDeMotorTibio.vidaMaxima
        else { return nil }
        self.guardado = nil
        return guardado.motor
      }
      vencido?.reset()
    }
  }

  /// Bajo el candado para que dos sesiones seguidas no armen dos escuchas.
  /// Los avisos llegan por la cola propia, nunca dentro del candado.
  private func armarEscuchas() {
    candado.withLock {
      guard vigia == nil else { return }
      vigia = VigiaDeDispositivos(cola: cola) { [weak self] in self?.dispositivosCambiaron() }
      alDespertar = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
      ) { [weak self] _ in self?.dispositivosCambiaron() }
    }
  }
}
