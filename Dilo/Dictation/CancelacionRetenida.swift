import DiloModes
import Foundation

/// Lo dicho antes de un Esc, mientras dura la ventana para deshacerlo
/// (`GestoDelGatillo.ventanaParaDeshacer`). En RAM y nada más: nunca va al
/// historial ni al disco, y se suelta al vencer, al empezar otro dictado o al
/// entregarse.
///
/// Lleva todo lo que la entrega lee de la sesión, porque la sesión cancelada
/// ya terminó cuando alguien toca «Deshacer» y el reset borró su foto: el
/// destino, los ajustes congelados, el modo, si era nota y qué tecla la abrió.
struct CancelacionRetenida {
  var crudo: String
  let destino: TextInsertionService.Target?
  let sesion: DictationSessionSettings
  let modo: Modo?
  let modoElegidoAMano: Bool
  let esNota: Bool
  let ranura: GlobalKeyEventMonitor.TriggerSlot
  let tecla: KeyBinding?
  let segundosDeVoz: TimeInterval
}
