import SwiftUI

/// What the HUD window hosts. Dictation and Drop Transcription never share the
/// shape, so the root picks one; hosting a single root view keeps the window's
/// content view stable while what it shows changes.
struct HUDRootView: View {
  let screen: HUDScreenSnapshot
  let settings: DictationSessionSettings
  let content: DictationHUDContent
  let drop: DropHUDContent
  /// La barra de llamada, cuando la sesión es una Conversación.
  var conversacion: ContenidoDeLaConversacion?
  /// El estado de sesión del HUD: `dictando` o `conversando`
  /// (`HUDSessionKind`).
  var kind: HUDSessionKind = .dictando
  var onDrop: (Int) -> Void = { _ in }
  var onCardEvent: (HUDCardEvent) -> Void = { _ in }

  var body: some View {
    if kind.surface == .conversacion, let conversacion {
      ConversacionHUDShellView(screen: screen, settings: settings, contenido: conversacion)
    } else if drop.mode == .none {
      DictationHUDShellView(
        screen: screen,
        settings: settings,
        content: content,
        kind: kind
      )
    } else {
      DropHUDView(
        screen: screen,
        settings: settings,
        drop: drop,
        onDrop: onDrop,
        onCardEvent: onCardEvent
      )
    }
  }
}
