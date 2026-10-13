import SwiftUI

/// Lo que una píldora al costado de la muesca dice: un ícono y una palabra.
/// Lo arma `HUDStage` desde la actividad sentada ahí (`AsientosDeLaMuesca`).
struct ContenidoDePildora: Equatable, Sendable {
  /// El id de la actividad: es lo que el clic le devuelve al escenario.
  let id: String
  let simbolo: String
  /// Ya pasado por el catálogo: se dibuja tal cual.
  let texto: String
  /// En mango lo que se puede hacer ahora («Reintentar»); en blanco lo que
  /// sólo avisa.
  let destacada: Bool
  /// Lo que VoiceOver dice: la acción entera, no la palabra de la píldora.
  let accesibilidad: String

  /// La toma que quedó en RAM: un clic la reintenta.
  static var toma: ContenidoDePildora {
    ContenidoDePildora(
      id: ActividadDeLaMuesca.tomaGuardada.id,
      simbolo: "arrow.clockwise",
      texto: String(localized: "Reintentar"),
      destacada: true,
      accesibilidad: String(localized: "Reintentar el dictado que no salió")
    )
  }

  /// Un dictado que no se pegó y al que otra sesión le tapó la tarjeta: un
  /// clic lo copia.
  static var retenido: ContenidoDePildora {
    ContenidoDePildora(
      id: ActividadDeLaMuesca.retenido.id,
      simbolo: "doc.on.clipboard",
      texto: String(localized: "No se pegó"),
      destacada: false,
      accesibilidad: String(localized: "Copiar el dictado que no se pegó")
    )
  }
}

/// Una píldora: la misma silueta de la muesca cerrada por los cuatro lados
/// (`SiluetaDeLaMuesca.isla`), negra, con su ícono y su palabra.
struct HUDPildora: View {
  let contenido: ContenidoDePildora
  let alto: CGFloat
  /// El mango de Dilo. Entra por parámetro para que el render de la muesca
  /// la dibuje sin traer el sistema de diseño de Ajustes.
  let acento: Color
  /// De vidrio (Liquid Glass) en vez de negra. Apagado de fábrica: es una
  /// variante en prueba que sólo enciende el arnés (`pildora-vidrio`), porque
  /// el vidrio no se dibuja fuera de pantalla y hay que verlo en la app.
  var vidrio = false
  let alTocar: () -> Void

  /// El radio de la píldora bajo la barra: una cápsula perfecta de veinte
  /// puntos se lee como un óvalo suelto (`HUDNotchGeometry.radioEnReposo`).
  static let radio: CGFloat = 8

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: contenido.simbolo)
        .font(.system(size: 9, weight: .semibold))
      Text(contenido.texto)
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .foregroundStyle(contenido.destacada ? acento : (vidrio ? Color.primary : Color.white.opacity(0.85)))
    .padding(.horizontal, 8)
    .frame(width: HUDNotchGeometry.anchoDePildora, height: alto)
    .modifier(FondoDePildora(vidrio: vidrio, radio: Self.radio))
    .contentShape(SiluetaDeLaMuesca(estilo: .isla, radioDeHombro: 0, radioInferior: Self.radio))
    .onTapGesture(perform: alTocar)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(contenido.accesibilidad))
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { alTocar() }
  }
}

/// Negro, o vidrio de macOS 26 con la misma silueta.
private struct FondoDePildora: ViewModifier {
  let vidrio: Bool
  let radio: CGFloat

  func body(content: Content) -> some View {
    let forma = SiluetaDeLaMuesca(estilo: .isla, radioDeHombro: 0, radioInferior: radio)
    if vidrio {
      content.glassEffect(.regular, in: forma)
    } else {
      content.background { forma.fill(Color.black) }
    }
  }
}

/// Las dos píldoras, colgadas a los costados de la forma.
///
/// Va como capa **de la forma** y no al lado de ella en un `HStack`: así
/// siguen al marco animado de `HUDSurface` sin medirlo —se corren solas
/// cuando la muesca crece a dictando— y salen del borde de la silueta igual
/// que las alas, por fuera del marco. Nacen desde la forma y vuelven a ella:
/// escala anclada del lado de la muesca, más opacidad.
struct HUDPildorasAlCostado: View {
  let izquierda: ContenidoDePildora?
  let derecha: ContenidoDePildora?
  let screen: HUDScreenSnapshot
  let acento: Color
  var vidrio = false
  let alTocar: (String) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var alcance: CGFloat { HUDNotchGeometry.alcanceDePildoras(for: screen) }
  private var alto: CGFloat { HUDNotchGeometry.altoDePildora(for: screen) }

  var body: some View {
    Color.clear
      .overlay(alignment: .topLeading) {
        if let izquierda {
          pildora(izquierda, ancla: .trailing)
            .offset(x: -alcance, y: HUDNotchGeometry.margenDePildora)
        }
      }
      .overlay(alignment: .topTrailing) {
        if let derecha {
          pildora(derecha, ancla: .leading)
            .offset(x: alcance, y: HUDNotchGeometry.margenDePildora)
        }
      }
      .animation(animacion, value: izquierda)
      .animation(animacion, value: derecha)
  }

  private func pildora(_ contenido: ContenidoDePildora, ancla: UnitPoint) -> some View {
    HUDPildora(contenido: contenido, alto: alto, acento: acento, vidrio: vidrio) { alTocar(contenido.id) }
      .id(contenido.id)
      .transition(
        reduceMotion ? .opacity : .scale(scale: 0.4, anchor: ancla).combined(with: .opacity)
      )
  }

  private var animacion: Animation {
    reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.35, bounce: 0.2)
  }
}
