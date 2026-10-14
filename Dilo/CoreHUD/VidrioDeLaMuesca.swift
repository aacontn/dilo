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
/// **Encendido de fábrica desde el 2026-10-14** (`AppSettings.hudPanelDeVidrio`,
/// interruptor en Ajustes → Apariencia): apagado y escondido en Debug, nadie
/// lo veía —«no le veo mucho vidrio»—. Sólo mientras el panel está abierto:
/// en reposo no hay vidrio montado, así que el reposo cuesta lo mismo que
/// antes (spec §3). Con «Reducir transparencia» del sistema cae a negro. El
/// vidrio **no sale en PNG** (`ImageRenderer` no lo dibuja): se juzga en la
/// pantalla con las escenas `hover-vidrio` y `hover-completo-vidrio` del
/// arnés.
enum PanelDeVidrio {
  /// El radio de abajo del panel abierto: el `expandedShelfCornerRadius` de
  /// Droppy. Se achica sólo si el panel es más bajo que eso.
  static let radioInferior: CGFloat = 40
  /// Cuánto mide el paso de negro a vidrio bajo la cabecera.
  static let fundido: CGFloat = 22
  /// El tinte oscuro del vidrio. Sin tinte, `.regular` sobre un fondo de
  /// pantalla claro deja el texto blanco sin contraste; con los 0,42 de la
  /// primera versión el vidrio se leía como un gris oscuro y no como vidrio.
  static let tinte: Double = 0.3
  /// El brillo del borde: un filo blanco que se apaga hacia abajo, que es lo
  /// que hace que el vidrio se lea como un objeto con canto y no como un
  /// gris translúcido.
  static let brilloDelBorde: Double = 0.32
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

/// Las medidas de la muesca **abierta**, al estilo de Droppy: hombros
/// grandes que se abren hacia el borde de la pantalla y el borde de abajo
/// bien redondeado.
///
/// Técnica observada en Droppy (`DroppyShellMetrics`): notch abierto con 32
/// de radio arriba —el hombro cóncavo— y 28 abajo en sus HUD, 40 en el
/// estante y 44 en la isla. Implementación propia. Hasta el 2026-10-14 la
/// forma abierta llevaba los hombros de la carcasa (9 en la muesca simulada)
/// y 11 abajo en el panel negro: se abría como un rectángulo
/// («no le veo […] la forma linda de Droppy»).
///
/// **Sólo la forma abierta.** El reposo (160×24, alas de 9) y dictar
/// (184×26) quedan como estaban: `HUDSurface` pide estas medidas sólo para
/// el panel del hover y para la forma grande —el aviso sin carcasa, la pila
/// de bandas contra una carcasa real—.
enum FormaAbierta {
  /// El hombro de Droppy abierto (`expandedNotchTopRadius`).
  static let hombro: CGFloat = 32
  /// El radio de abajo de un HUD abierto de Droppy: el del aviso y el de la
  /// forma grande contra una carcasa.
  static let radioDelAviso: CGFloat = 28

  /// El hombro para una forma de este tamaño: el de Droppy, sin pasarse de
  /// lo que la ventana abierta tiene a cada lado para las alas y su sombra,
  /// ni de lo que deja libre la esquina de abajo —si no, la silueta achica
  /// los dos radios juntos y el aviso pierde el borde redondo entero—. La
  /// píldora no lleva alas: cero.
  static func hombro(
    para tamaño: CGSize,
    en screen: HUDScreenSnapshot,
    radioInferior: CGFloat = 0
  ) -> CGFloat {
    let carcasa = HUDNotchGeometry.filletSize(for: screen)
    guard carcasa > 0 else { return 0 }
    let ventana = HUDNotchGeometry.windowSize(for: screen, encuadre: .abierta)
    let lugar = (ventana.width - tamaño.width) / 2 - HUDNotchGeometry.holguraDeSombra()
    let libre = tamaño.height - radioInferior
    return max(carcasa, min(hombro, lugar, libre))
  }

  /// El radio de abajo del aviso: el de Droppy, o redondo entero si la forma
  /// es más baja que eso.
  static func radioDelAviso(para tamaño: CGSize) -> CGFloat {
    max(0, min(radioDelAviso, tamaño.height / 2, tamaño.width / 4))
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

  @Environment(\.accessibilityReduceTransparency) private var reducirTransparencia

  let silueta: SiluetaDeLaMuesca
  /// El alto de la cabecera (`HUDNotchGeometry.alturaDeCabecera`).
  let alturaDeCabecera: CGFloat
  /// Si el panel está abierto. Cerrado, la forma es negra entera y **no hay
  /// vidrio montado**.
  let abierto: Bool
  var material: Material = .vidrio

  /// «Reducir transparencia» manda: el panel se dibuja negro, con las mismas
  /// tarjetas encima. Es lo que el sistema promete con ese ajuste, y el negro
  /// ya era el panel de antes.
  private var conVidrio: Bool { abierto && !reducirTransparencia }

  var body: some View {
    ZStack(alignment: .top) {
      // Lo de abajo se funde: vidrio abierto, negro cerrado. Con una
      // transición de opacidad el vidrio se apaga mientras la forma se
      // encoge, en vez de pasar a negro de golpe al empezar a cerrar.
      if conVidrio {
        cuerpo
          .overlay { brillo }
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

  /// El vidrio con la silueta entera, alas incluidas: los hombros grandes de
  /// la forma abierta bajan más que la cabecera, y lo que asoma debajo del
  /// fundido tiene que ser vidrio y no un hueco.
  @ViewBuilder
  private var cuerpo: some View {
    switch material {
    case .vidrio:
      Color.clear
        .glassEffect(.regular.tint(.black.opacity(PanelDeVidrio.tinte)), in: silueta)
    case .imitacion:
      silueta
        .fill(Color(white: 0.09).opacity(0.58))
    }
  }

  /// El canto del vidrio: un filo blanco en el contorno del cuerpo que se
  /// apaga hacia abajo y no toca la cabecera, que es negra.
  private var brillo: some View {
    silueta.sinHombros
      .stroke(
        LinearGradient(
          colors: [
            .white.opacity(PanelDeVidrio.brilloDelBorde),
            .white.opacity(PanelDeVidrio.brilloDelBorde * 0.35),
            .white.opacity(PanelDeVidrio.brilloDelBorde * 0.6),
          ],
          startPoint: .top,
          endPoint: .bottom
        ),
        lineWidth: 0.75
      )
      .mask(alignment: .top) {
        VStack(spacing: 0) {
          Color.clear.frame(height: alturaDeCabecera)
          LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
            .frame(height: PanelDeVidrio.fundido)
          Color.black
        }
        .padding(.horizontal, -60)
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

/// El filo de color del borde de abajo de la muesca abierta: una luz fina en
/// el acento que sigue la curva de las esquinas y se apaga hacia los
/// costados.
///
/// Es la manera de que el color se vea **sin ensuciar el negro**, que es el
/// criterio de Droppy: negro y blanco, y un acento sólo donde pasa algo. El
/// cuerpo sigue negro entero; lo que cambia de color es el canto, como el
/// borde iluminado de un objeto, y dice en qué está la muesca sin una
/// palabra —el acento dictando, la menta en el acuse, el coral en un error—.
/// Estático: no anima ni redibuja nada mientras la forma está quieta, así
/// que no cuesta CPU (spec §3). En reposo no se monta.
struct FiloDeLaMuesca: View {
  /// La silueta del cuerpo, sin alas (`SiluetaDeLaMuesca.sinHombros`).
  let silueta: SiluetaDeLaMuesca
  let color: Color
  /// Cuánto sube el filo desde el borde de abajo. Con el radio de la
  /// esquina basta para que la luz doble la curva y no siga por el costado.
  let alto: CGFloat

  var body: some View {
    let trazo = silueta.stroke(
      LinearGradient(
        stops: [
          .init(color: color.opacity(0), location: 0),
          .init(color: color, location: 0.3),
          .init(color: color, location: 0.7),
          .init(color: color.opacity(0), location: 1),
        ],
        startPoint: .leading,
        endPoint: .trailing
      ),
      lineWidth: 1.25
    )
    ZStack {
      // La luz difusa y el filo nítido: sin el halo, una línea de un punto
      // sobre la barra clara se lee como un error de dibujo.
      trazo.blur(radius: 3)
      trazo
    }
    .mask {
      // Más grande que la forma: el trazo va centrado en el borde y su luz
      // cae por fuera.
      VStack(spacing: 0) {
        Color.clear
        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
          .frame(height: alto)
        Color.black.frame(height: 6)
      }
      .padding(.horizontal, -6)
      .padding(.bottom, -6)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
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
