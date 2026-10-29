import Observation
import SwiftUI

/// Lo que la muesca muestra de la **Conversación**: la foto de la barra de
/// llamada y los botones. Lo escribe `ControladorDeLaConversacion`; lo dibuja
/// `ConversacionHUDShellView`. Vive en el escenario, como el contenido del
/// dictado, porque la forma es una sola.
@MainActor
@Observable
final class ContenidoDeLaConversacion {
  var foto = FotoDeLaConversacion()
  /// Si la forma está abierta. Se prende un ciclo después de montar, como el
  /// dictado, para que la apertura tenga desde dónde animarse.
  var isRevealed = false
  @ObservationIgnored var acciones = AccionesDeLaLlamada()
}

/// La superficie de la **Conversación**: la misma forma negra de todas
/// (`HUDSurface`), del tamaño de la barra de llamada, con la forma abierta de
/// Droppy y el filo del color del estado.
struct ConversacionHUDShellView: View {
  let screen: HUDScreenSnapshot
  let settings: DictationSessionSettings
  let contenido: ContenidoDeLaConversacion

  var body: some View {
    let foto = contenido.foto
    HUDSurface(
      screen: screen,
      metrics: settings.hudMetrics,
      revealStyle: settings.revealStyle,
      isRevealed: contenido.isRevealed,
      size: HUDNotchGeometry.tamañoDeLaConversacion(for: screen, desplegada: foto.desplegada),
      tamañoEnReposo: HUDNotchGeometry.reposoSize(for: screen),
      formaGrande: true,
      filo: filo(foto),
      content: {
        BarraDeLlamada(
          foto: foto,
          acciones: contenido.acciones,
          altoDeCabecera: HUDNotchGeometry.alturaDeCabecera(for: screen)
        )
        .opacity(contenido.isRevealed ? 1 : 0)
      },
      overlays: { EmptyView() }
    )
  }

  /// El acento mientras escucha, más tenue mientras piensa o habla, ámbar
  /// silenciada y coral con un aviso.
  private func filo(_ foto: FotoDeLaConversacion) -> Color? {
    let paleta = PaletaDeDilo.actual
    if foto.aviso != nil { return paleta.error.color.opacity(0.75) }
    if foto.silenciada { return paleta.aviso.color.opacity(0.6) }
    switch foto.fase {
    case .escuchando: return paleta.filo.color
    case .pensando, .hablando: return paleta.filo.color.opacity(0.55)
    }
  }
}
