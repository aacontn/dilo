import AppKit
import SwiftUI

/// La línea de un dictado que no se pegó, en la misma banda donde va el
/// resultado: dice qué pasó y ofrece el texto. Un clic lo copia; arrastrarla
/// lleva el texto a donde iba. Con el puntero encima, la línea cambia a la
/// pista de esos dos gestos, que de otro modo no se ven.
///
/// Los gestos son los de la tarjeta de una grabación (`TranscriptDragView`):
/// la vista de AppKit es la que sabe distinguir un clic de un arrastre.
struct HUDTarjetaDeRespaldo: View {
  let tarjeta: TarjetaDeRespaldo
  let fuente: Font
  /// Como las demás líneas de su banda: a la izquierda en la muesca sobria,
  /// centrada contra una carcasa real.
  var alineacion: Alignment = .center
  let alTocar: () -> Void

  @State private var punteroEncima = false

  var body: some View {
    Text(punteroEncima ? TarjetaDeRespaldo.pista : tarjeta.titulo)
      .font(fuente)
      .foregroundStyle(.white.opacity(punteroEncima ? 0.75 : 0.9))
      .lineLimit(1)
      .truncationMode(.tail)
      // Sólo a lo ancho: un alto goloso adentro de la forma se queda con la
      // ventana entera y el negro detrás (AGENTS.md, «La ventana grande no
      // es la forma»).
      .frame(maxWidth: .infinity, alignment: alineacion)
      .contentShape(Rectangle())
      .overlay {
        TranscriptDragView(
          url: nil,
          text: tarjeta.texto,
          makeDragImage: { Self.imagenDeArrastre(tarjeta.texto) },
          onEvent: { evento in
            switch evento {
            case let .hover(encima): punteroEncima = encima
            case .clicked: alTocar()
            case .dragBegan, .dragEnded: break
            }
          }
        )
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(tarjeta.titulo))
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { alTocar() }
  }

  /// Lo que se ve viajar con el puntero: el principio del dictado, para que
  /// lo que sale de la muesca sea lo que estaba en ella.
  @MainActor
  static func imagenDeArrastre(_ texto: String) -> NSImage? {
    let vista = Text(texto.prefix(48) + (texto.count > 48 ? "…" : ""))
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(.white)
      .lineLimit(1)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(Capsule().fill(Color.black.opacity(0.85)))
    let renderer = ImageRenderer(content: vista)
    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
    return renderer.nsImage
  }
}
