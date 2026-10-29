import AppKit

/// La **Conversación** en el escenario: la barra de llamada ocupa la forma
/// mientras dura la llamada, toma el mouse en toda su silueta —sus botones—
/// y no deja que el hover abra el panel encima.
///
/// La máquina del contrato (`MaquinaDelNotch`) no se mueve: la conversación
/// no es un dictado y sus turnos no son estados del notch. Lo que la vuelve
/// visible es el ocupante (`Occupant.conversacion`) y la sesión
/// (`HUDSessionKind.conversando`), que es lo que `HUDRootView` mira para
/// dibujar `ConversacionHUDShellView` en vez del dictado.
extension HUDStage {
  /// Pone la barra de llamada en la muesca, en la pantalla del puntero o la
  /// elegida en Ajustes.
  ///
  /// `ajustes` es lo que la forma usa para dibujarse (el estilo de apertura,
  /// el tamaño): quien llama pasa `sessionSettingsParaDibujar`, que no le
  /// pregunta nada al Llavero en el hilo principal.
  func abrirLaConversacion(
    en pantallaPedida: HUDScreenSnapshot? = nil,
    dibujandoCon ajustes: DictationSessionSettings? = nil
  ) {
    guard var pantalla = pantallaPedida ?? screen() else { return }
    pantalla.llevaConversacion = true
    claim(.conversacion, on: pantalla, rendering: ajustes, kind: .conversando)
    reaplicarElEstado()
    Task { @MainActor [conversacionContent] in
      conversacionContent.isRevealed = true
    }
  }

  /// La barra cambió de alto (la transcripción o los ajustes se
  /// desplegaron): la zona que recibe el mouse se vuelve a medir.
  func remedirLaConversacion() {
    guard occupant == .conversacion else { return }
    reaplicarElEstado()
  }

  /// Saca la barra de llamada y deja la muesca en reposo. Si la forma ya es
  /// de otro —un dictado que empezó—, no toca nada.
  func cerrarLaConversacion() {
    guard occupant == .conversacion else { return }
    retract()
  }

  /// Si la barra de llamada está en la muesca.
  var muestraLaConversacion: Bool { occupant == .conversacion }
}
