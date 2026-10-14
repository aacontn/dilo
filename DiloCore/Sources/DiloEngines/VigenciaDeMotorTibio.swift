import CoreAudio
import Foundation

// Técnica observada en Ocelli (Ghidra: motor fijado y `prepare()` sin
// `start()`, vida de 30 min, una época que sube con cada cambio de
// dispositivos, y sólo con micrófonos cableados); implementación propia.

/// Si un motor de audio preparado de antemano todavía sirve. Pura, para
/// probarla sin hardware; el motor en sí vive en la app
/// (`ReservaDeMotorTibio`).
public enum VigenciaDeMotorTibio {
  /// Cuánto espera un motor preparado. Pasado esto se suelta aunque nadie
  /// lo haya pedido: no se guarda memoria para un dictado que no viene.
  public static let vidaMaxima: Duration = .seconds(30 * 60)

  public static func sirve(
    guardadoPara dispositivo: AudioDeviceID,
    epocaGuardada: Int,
    creado: ContinuousClock.Instant,
    pedido: AudioDeviceID,
    epocaActual: Int,
    ahora: ContinuousClock.Instant
  ) -> Bool {
    dispositivo == pedido && epocaGuardada == epocaActual
      && creado.duration(to: ahora) < vidaMaxima
  }

  /// Sólo se deja preparado un micrófono cableado o el del Mac. Preparar uno
  /// Bluetooth puede despertar su perfil de llamada y degradar la música de
  /// alguien que no está dictando; uno de Continuity o virtual no se sabe
  /// qué hace.
  public static func vale(transporte: EntradaDeAudio.Transporte) -> Bool {
    transporte == .interno || transporte == .cableado
  }

  /// A qué micrófono se fija el motor de un dictado. Lo que decidió el plan;
  /// y si el plan sigue al sistema pero el motor tibio está encendido, la
  /// entrada del sistema misma —si vale—, porque un motor tibio sólo sirve
  /// para un dispositivo que se nombra. Apagado, seguir al sistema es no
  /// fijar nada, como siempre.
  public static func entradaDelMotor(
    plan: PlanDeMicrofono.Decision,
    entradaDelSistema: EntradaDeAudio?,
    tibio: Bool
  ) -> EntradaDeAudio? {
    if let fijada = plan.fijarA { return fijada }
    guard tibio, let entradaDelSistema, vale(transporte: entradaDelSistema.transporte) else {
      return nil
    }
    return entradaDelSistema
  }
}
