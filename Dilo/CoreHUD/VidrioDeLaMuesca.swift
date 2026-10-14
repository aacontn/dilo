import SwiftUI

/// El panel del hover al estilo Dynamic Glass: negro en la muesca que se
/// funde hacia abajo en vidrio.
///
/// Técnica observada en Droppy («Black at the notch, melting into glass»):
/// su `DynamicGlassMaterialView` hereda del `NSGlassEffectView` público, y el
/// estante abierto lleva radios de 32 arriba, 40 en el estante y 44 en la
/// isla (`DroppyShellMetrics`). La implementación es propia y sólo con API
/// pública: `glassEffect(_:in:)` de SwiftUI.
///
/// **La cabecera no deja nunca de ser negra.** Es la silueta en reposo —la
/// carcasa o la franja de la barra de menús— y la muesca **es** el borde de la
/// pantalla; lo que puede ser vidrio es sólo lo que cuelga hacia el
/// escritorio, y el paso entre los dos es un degradado para que no se lea
/// como dos objetos pegados (`docs/design/2026-09-21-experiencia-dilo.md`,
/// enmienda del 2026-10-14).
///
/// Apagado de fábrica (`AppSettings.hudPanelDeVidrio`) y sólo mientras el
/// panel está abierto: en reposo no hay vidrio montado, así que el reposo
/// cuesta lo mismo que antes (spec §3). El vidrio **no sale en PNG**
/// (`ImageRenderer` no lo dibuja): se juzga en la pantalla con las escenas
/// `hover-vidrio` y `hover-completo-vidrio` del arnés.
enum PanelDeVidrio {
  /// El radio de abajo del panel abierto: el `expandedShelfCornerRadius` de
  /// Droppy. Se achica sólo si el panel es más bajo que eso.
  static let radioInferior: CGFloat = 40
  /// Cuánto mide el paso de negro a vidrio bajo la cabecera.
  static let fundido: CGFloat = 22
  /// El tinte oscuro del vidrio. Sin tinte, `.regular` sobre un fondo de
  /// pantalla claro deja el texto blanco sin contraste.
  static let tinte: Double = 0.42
  /// El radio de una tarjeta del panel, y cuánto sobresale de su contenido.
  static let radioDeTarjeta: CGFloat = 12
  static let margenDeTarjeta: CGFloat = 8
  /// El aire lateral del contenido con el vidrio puesto: el radio de 40 se
  /// come las esquinas, y con los 16 del panel negro los chips de abajo
  /// quedaban asomados por fuera de la curva.
  static let aireLateral: CGFloat = 22

  /// El radio de abajo para un panel de este alto: el de Droppy, sin pasarse
  /// de lo que cuelga bajo la cabecera ni de un cuarto del ancho.
  static func radio(para tamaño: CGSize, cabecera: CGFloat) -> CGFloat {
    max(0, min(radioInferior, tamaño.height - cabecera, tamaño.width / 4))
  }

  /// El radio de abajo de la última tarjeta: concéntrico con el del panel,
  /// menos lo que la tarjeta queda adentro.
  static func radioDeLaUltimaTarjeta(radioDelPanel: CGFloat) -> CGFloat {
    max(radioDeTarjeta, radioDelPanel - (aireLateral - margenDeTarjeta))
  }
}

/// Un resorte dicho como lo dice el diseño —respuesta y amortiguación—.
///
/// Técnica observada en DroppyKit (`DroppyAnimation.notchOpen` y
/// `notchClose`): `interpolatingSpring` con masa 1, rigidez (2π/respuesta)² y
/// amortiguación 4π·ζ/respuesta. Los números son los observados y se anotan
/// como tales; el ajuste por cuadros por segundo que Droppy también hace no
/// está acá todavía.
struct CurvaDeLaMuesca: Equatable, Sendable {
  var respuesta: Double
  var amortiguacion: Double

  /// Abrir: 0,47 s y ζ 0,76, un rebote apenas visible.
  static let apertura = CurvaDeLaMuesca(respuesta: 0.47, amortiguacion: 0.76)
  /// Cerrar: 0,54 s y ζ 0,90, casi sin rebote.
  static let cierre = CurvaDeLaMuesca(respuesta: 0.54, amortiguacion: 0.9)

  var animacion: Animation {
    let omega = 2 * Double.pi / respuesta
    return .interpolatingSpring(
      mass: 1,
      stiffness: omega * omega,
      damping: 4 * Double.pi * amortiguacion / respuesta
    )
  }

  /// Lo que se pasa del destino, como fracción: con ζ < 1 el primer máximo
  /// es e^(−πζ/√(1−ζ²)). La ventana anfitriona tiene que alojarlo.
  var sobrepaso: CGFloat {
    guard amortiguacion < 1 else { return 0 }
    let zeta = max(amortiguacion, 0.0001)
    return CGFloat(exp(-Double.pi * zeta / (1 - zeta * zeta).squareRoot()))
  }
}

/// El fondo de la forma con el vidrio puesto: negro en la cabecera, vidrio
/// debajo mientras el panel está abierto, negro entero cuando no.
struct FondoDeLaMuesca: View {
  /// Con qué se pinta lo de abajo. `imitacion` es para el render en PNG,
  /// donde el vidrio de verdad no se dibuja: un gris translúcido que deja ver
  /// el escritorio, rotulado como imitación en la lámina.
  enum Material: Sendable {
    case vidrio
    case imitacion
  }

  let silueta: SiluetaDeLaMuesca
  /// El alto de la cabecera (`HUDNotchGeometry.alturaDeCabecera`).
  let alturaDeCabecera: CGFloat
  /// Si el panel está abierto. Cerrado, la forma es negra entera y **no hay
  /// vidrio montado**.
  let abierto: Bool
  var material: Material = .vidrio

  var body: some View {
    ZStack(alignment: .top) {
      // Lo de abajo se funde: vidrio abierto, negro cerrado. Con una
      // transición de opacidad el vidrio se apaga mientras la forma se
      // encoge, en vez de pasar a negro de golpe al empezar a cerrar.
      if abierto {
        cuerpo
          .transition(.opacity)
      } else {
        silueta
          .fill(Color.black)
          .transition(.opacity)
      }
      // La cabecera, siempre y fuera de la transición: si cruzara dos
      // negros a media opacidad, la muesca parpadearía contra la barra.
      silueta
        .fill(Color.black)
        .mask(alignment: .top) { mascaraDeCabecera }
    }
  }

  @ViewBuilder
  private var cuerpo: some View {
    switch material {
    case .vidrio:
      Color.clear
        .glassEffect(.regular.tint(.black.opacity(PanelDeVidrio.tinte)), in: silueta.sinHombros)
    case .imitacion:
      silueta.sinHombros
        .fill(Color(white: 0.09).opacity(0.62))
        .overlay(silueta.sinHombros.stroke(Color.white.opacity(0.14), lineWidth: 0.5))
    }
  }

  /// La franja de la cabecera y el degradado del fundido. Más ancha que la
  /// forma: las alas cóncavas de la silueta se dibujan fuera de su marco y
  /// una máscara del ancho justo las cortaría.
  private var mascaraDeCabecera: some View {
    VStack(spacing: 0) {
      Rectangle().frame(height: alturaDeCabecera)
      LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
        .frame(height: PanelDeVidrio.fundido)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, -60)
  }
}

/// El fondo de una sección del panel puesta como tarjeta, como en Droppy:
/// un relleno blanco tenue que sobresale `margenDeTarjeta` de su contenido.
/// La última lleva abajo el radio concéntrico con el del panel.
struct TarjetaDelPanel: ViewModifier {
  var radioInferior: CGFloat = PanelDeVidrio.radioDeTarjeta

  func body(content: Content) -> some View {
    content
      .background {
        UnevenRoundedRectangle(
          topLeadingRadius: PanelDeVidrio.radioDeTarjeta,
          bottomLeadingRadius: radioInferior,
          bottomTrailingRadius: radioInferior,
          topTrailingRadius: PanelDeVidrio.radioDeTarjeta,
          style: .continuous
        )
        .fill(Color.white.opacity(0.07))
        .padding(.horizontal, -PanelDeVidrio.margenDeTarjeta)
      }
  }
}

extension View {
  /// Pone la sección en tarjeta si `enTarjeta`; si no, la deja como está.
  @ViewBuilder
  func tarjetaDelPanel(_ enTarjeta: Bool, radioInferior: CGFloat = PanelDeVidrio.radioDeTarjeta) -> some View {
    if enTarjeta {
      modifier(TarjetaDelPanel(radioInferior: radioInferior))
    } else {
      self
    }
  }
}
