import CoreAudio
import Foundation

extension PlanDeMicrofono {
  /// Qué micrófono abre la **escucha de nombres**, o nil si no abre ninguno.
  ///
  /// La misma regla que el dictado (`decidir`), con una diferencia: la
  /// escucha tiene el micrófono abierto todo el rato, y abrir uno Bluetooth
  /// deja los audífonos en el perfil de llamada —la música suena a teléfono—
  /// mientras dure. Por eso un Bluetooth sólo se abre si la persona lo eligió
  /// por su nombre; en automático, sin uno con cable, la escucha no abre nada
  /// y lo dice. «El del sistema» elegido a mano se respeta: es una elección.
  public static func paraLaEscucha(
    eleccion: EleccionDeMicrofono,
    entradas: [EntradaDeAudio],
    entradaDelSistema: AudioDeviceID?,
    tapaCerrada: Bool
  ) -> Decision? {
    let decision = decidir(
      eleccion: eleccion, entradas: entradas, entradaDelSistema: entradaDelSistema, tapaCerrada: tapaCerrada
    )
    guard eleccion == .automatico || decision.motivo == .elegidoAusente else { return decision }
    let abre = decision.fijarA ?? entradas.first { $0.id == entradaDelSistema }
    if abre?.transporte == .bluetooth { return nil }
    // Con la tapa cerrada el micrófono del Mac entrega ceros: escuchar ahí es
    // gastar sin oír nada.
    if tapaCerrada, abre?.transporte == .interno { return nil }
    return decision
  }
}
