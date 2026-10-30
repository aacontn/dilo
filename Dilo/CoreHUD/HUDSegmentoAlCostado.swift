import AppKit
import SwiftUI

/// Lo que un segmento al costado de la muesca dice: un ícono y, mientras se
/// abre, una palabra. Lo arma `HUDStage` desde la actividad sentada en ese
/// costado (`AsientosDeLaMuesca`).
struct ContenidoDelSegmento: Equatable, Sendable {
  /// El id de la actividad: es lo que el clic le devuelve al escenario.
  let id: String
  let simbolo: String
  /// Ya pasado por el catálogo: se dibuja tal cual.
  let texto: String
  /// En mango lo que se puede hacer ahora («Reintentar»); en blanco lo que
  /// sólo avisa.
  let destacada: Bool
  /// Lo que VoiceOver dice y lo que muestra el tooltip: la acción entera, no
  /// la palabra del segmento.
  let accesibilidad: String
  /// Una reunión grabando: el ícono va en el rojo de la paleta
  /// (`PaletaDeDilo.grabando`), no en el acento ni en blanco.
  var grabando = false

  /// La toma que quedó en RAM: un clic la reintenta.
  static var toma: ContenidoDelSegmento {
    ContenidoDelSegmento(
      id: ActividadDeLaMuesca.tomaGuardada.id,
      simbolo: "arrow.clockwise",
      texto: String(localized: "Reintentar"),
      destacada: true,
      accesibilidad: String(localized: "Reintentar el dictado que no salió")
    )
  }

  /// Un dictado que no se pegó y al que otra sesión le tapó la tarjeta: un
  /// clic lo copia.
  static var retenido: ContenidoDelSegmento {
    ContenidoDelSegmento(
      id: ActividadDeLaMuesca.retenido.id,
      simbolo: "doc.on.clipboard",
      texto: String(localized: "No se pegó"),
      destacada: false,
      accesibilidad: String(localized: "Copiar el dictado que no se pegó")
    )
  }

  static let tamañoDelIcono: CGFloat = 9
  static let tamañoDeLaPalabra: CGFloat = 10
  /// El aire a cada lado del contenido.
  static let aire: CGFloat = 8
  static let entreIconoYPalabra: CGFloat = 4

  /// Lo que mide el segmento: el ícono solo (`anchoDeSegmentoEncogido`), o
  /// el ícono y la palabra medida en su letra, con techo
  /// (`anchoMaximoDeSegmento`). Medido y no estimado: «No se pegó» y
  /// «Didn't paste» no miden lo mismo.
  func ancho(conPalabra: Bool) -> CGFloat {
    guard conPalabra else { return HUDNotchGeometry.anchoDeSegmentoEncogido }
    let palabra = (texto as NSString).size(
      withAttributes: [.font: NSFont.systemFont(ofSize: Self.tamañoDeLaPalabra, weight: .medium)]
    ).width.rounded(.up)
    let icono = HUDNotchGeometry.anchoDeSegmentoEncogido - Self.aire * 2
    return min(
      Self.aire + icono + Self.entreIconoYPalabra + palabra + Self.aire,
      HUDNotchGeometry.anchoMaximoDeSegmento
    )
  }
}

/// Los segmentos de los dos costados, sobre la silueta estirada.
///
/// **El negro no es de acá**: lo dibuja la silueta misma, estirada hacia cada
/// lado (`SiluetaDeLaMuesca.costados`), así que muesca y segmento son una
/// sola pieza con las alas en los extremos nuevos. Esto pone sólo el ícono y
/// la palabra en el borde de afuera, y recibe el clic.
///
/// Va como capa **de la forma**: sigue al marco animado de `HUDSurface` sin
/// medirlo y cuelga por fuera de él igual que la silueta estirada. Los anchos
/// cambian con la misma animación que los costados de la silueta, porque
/// cambian en la misma transacción.
struct HUDSegmentosAlCostado: View {
  let izquierdo: ContenidoDelSegmento?
  let derecho: ContenidoDelSegmento?
  let conPalabra: Set<LadoDelAsiento>
  let costados: CostadosDeLaSilueta
  let acento: Color
  let alTocar: (String) -> Void

  var body: some View {
    Color.clear
      .overlay(alignment: .leading) {
        if let izquierdo {
          segmento(izquierdo, lado: .izquierda)
            .offset(x: -costados.izquierda)
        }
      }
      .overlay(alignment: .trailing) {
        if let derecho {
          segmento(derecho, lado: .derecha)
            .offset(x: costados.derecha)
        }
      }
  }

  private func segmento(_ contenido: ContenidoDelSegmento, lado: LadoDelAsiento) -> some View {
    let palabra = conPalabra.contains(lado)
    return HStack(spacing: ContenidoDelSegmento.entreIconoYPalabra) {
      Image(systemName: contenido.simbolo)
        .font(.system(size: ContenidoDelSegmento.tamañoDelIcono, weight: .semibold))
        .foregroundStyle(contenido.grabando ? PaletaDeDilo.actual.grabando.color : color(de: contenido))
      if palabra {
        Text(contenido.texto)
          .font(.system(size: ContenidoDelSegmento.tamañoDeLaPalabra, weight: .medium))
          .lineLimit(1)
          .fixedSize()
          .transition(.opacity)
      }
    }
    .foregroundStyle(color(de: contenido))
    .frame(width: contenido.ancho(conPalabra: palabra))
    .frame(maxHeight: .infinity)
    // Mientras el ancho se anima, la palabra no se asoma fuera del negro.
    .clipped()
    .contentShape(Rectangle())
    .onTapGesture { alTocar(contenido.id) }
    .help(contenido.accesibilidad)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(contenido.accesibilidad))
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { alTocar(contenido.id) }
  }

  private func color(de contenido: ContenidoDelSegmento) -> Color {
    contenido.destacada ? acento : Color.white.opacity(0.85)
  }
}
