import CoreAudio
import Foundation

extension PlanDeMicrofono {
  /// Qué micrófono abre la pista `yo` de una **reunión**.
  ///
  /// La misma regla que el dictado (`decidir`), porque aquí pesa más: una
  /// reunión tiene el micrófono abierto por horas, y abrir uno Bluetooth deja
  /// los audífonos en el perfil de llamada mientras dure. A diferencia de la
  /// escucha de nombres, sin otro micrófono sí abre el Bluetooth: perder tu
  /// voz en una reunión es peor que oírla a calidad de teléfono.
  ///
  /// Un micrófono elegido que se desenchufó tampoco cae a un Bluetooth si hay
  /// otro con cable: la reunión sigue con lo que diría automático.
  public static func paraLaReunion(
    uidElegido: String?,
    entradas: [EntradaDeAudio],
    entradaDelSistema: AudioDeviceID?,
    tapaCerrada: Bool
  ) -> Decision {
    let eleccion = uidElegido.map { EleccionDeMicrofono.elegido(uid: $0, nombre: "") } ?? .automatico
    let decision = decidir(
      eleccion: eleccion, entradas: entradas, entradaDelSistema: entradaDelSistema, tapaCerrada: tapaCerrada
    )
    guard decision.motivo == .elegidoAusente else { return decision }
    let automatico = decidir(
      eleccion: .automatico, entradas: entradas, entradaDelSistema: entradaDelSistema, tapaCerrada: tapaCerrada
    )
    return Decision(fijarA: automatico.fijarA, motivo: .elegidoAusente)
  }
}
