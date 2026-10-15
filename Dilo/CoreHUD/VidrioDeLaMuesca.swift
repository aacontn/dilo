import SwiftUI

/// El panel del hover: **vidrio ahumado** de punta a punta, oscuro y parejo.
///
/// Pedido de Alfonso (2026-10-15): al ver la apertura cuadro a cuadro, el
/// primer cuadro —el vidrio ahumado antes de cerrarse en negro— «se ve
/// choro». Ese cuadro pasa a ser el panel abierto: vidrio tintado de negro
/// con un velo negro encima (`negroEncima`), que sobre una página blanca o
/// un escritorio oscuro queda en un gris carbón parejo (medido en la
/// pantalla: entre #2C2C2C y #3B3B3B), donde la letra blanca se lee
/// siempre. Al abrir, un reflejo recorre el canto de abajo de izquierda a
/// derecha y se apaga; queda un filo blanco muy tenue en la curva.
///
/// **Antes fue sólo un destello** (nunca se publicó): nacía ahumado y el
/// negro lo tapaba en 0,42 s. **En la 0.4.6 se quedaba** sólo en el último
/// ~30 % del panel:
/// negro que se derretía en vidrio ahumado bajo la fila de los modos. Sobre
/// una página blanca era una mancha gris detrás de los controles —«se ve
/// mal»—. Y antes, en la 0.4.5, el panel entero era vidrio claro con letra
/// blanca encima: ilegible. Lo que vale es que el vidrio sea **parejo y
/// oscuro**: ni claro ni a medias.
///
/// Técnica observada en el video «Dynamic Glass» de Droppy (vidrio ahumado
/// y oscuro); el velo negro encima y el reflejo son propios. Sólo API
/// pública: `glassEffect(_:in:)`.
///
/// **Encendido de fábrica** (`AppSettings.hudPanelDeVidrio`, interruptor
/// «Panel con vidrio» en Ajustes → Apariencia); apagado, negro puro, sin
/// vidrio ni filo. Con «Reducir transparencia» del sistema, negro; con
/// «Reducir movimiento», el vidrio sin el reflejo. El vidrio se monta sólo
/// con el panel abierto: en reposo y dictando no hay vidrio (spec §3).
/// **No sale en PNG** (`ImageRenderer` no lo dibuja): la lámina lo imita con
/// el gris medido (`grisDeLaLamina`) y el de verdad se juzga en la pantalla
/// con las escenas `hover-vidrio` y `hover-completo-vidrio`.
enum PanelDeVidrio {
  /// El radio de abajo del panel abierto: unos 32 puntos, medidos en el
  /// cuadro de Droppy contra el ancho del panel. Se achica sólo si el panel
  /// es más bajo.
  static let radioInferior: CGFloat = 32

  /// El tinte negro del vidrio: ahumado, como el de Droppy.
  static let tinte: Double = 0.45
  /// El velo negro encima del vidrio: lo que lo deja en carbón y no en gris
  /// sobre una página blanca. Es el del cuadro que Alfonso eligió.
  static let negroEncima: Double = 0.55
  /// El gris con que la lámina imita el vidrio, que en PNG no se dibuja: el
  /// medido en la pantalla sobre fondo claro y oscuro (0x2C–0x3B).
  static let grisDeLaLamina: Double = 0.2

  /// El reflejo que recorre el canto de abajo al abrir: blanco casi entero,
  /// un 40 % del ancho, de izquierda a derecha. Arranca cuando la forma ya
  /// creció lo bastante como para tener canto.
  static let brilloDelReflejo: Double = 1
  static let anchoDelReflejo: CGFloat = 0.45
  /// La luz que el reflejo deja dentro del negro, pegada al canto: lo que
  /// hace que se lea como luz pasando por un vidrio y no como una raya.
  static let brilloDelVelo: Double = 0.16
  static let altoDelVelo: CGFloat = 16
  static let esperaDelReflejo: Double = 0.1
  static let duracionDelReflejo: Double = 0.85

  /// El filo que queda con el panel abierto: blanco y muy tenue, sólo en la
  /// curva de abajo.
  static let brilloDelBorde: Double = 0.2

  /// El aire lateral del contenido: el radio de abajo se come las esquinas.
  static let aireLateral: CGFloat = 20

  /// El radio de abajo para un panel de este alto: el de Droppy, sin pasarse
  /// de lo que cuelga bajo la cabecera ni de un cuarto del ancho.
  static func radio(para tamaño: CGSize, cabecera: CGFloat) -> CGFloat {
    max(0, min(radioInferior, tamaño.height - cabecera, tamaño.width / 4))
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

/// El fondo de la forma con el vidrio encendido: negro opaco cerrado y, con
/// el panel abierto, vidrio ahumado (`PanelDeVidrio`), un reflejo que
/// recorre el canto al abrir y el filo tenue que queda. Cerrado, negro
/// entero y nada montado encima.
struct FondoDeLaMuesca: View {
  /// Con qué se pinta el vidrio. `imitacion` es para el render en PNG,
  /// donde el vidrio de verdad no se dibuja: ahí sale el gris medido con su
  /// filo, sin reflejo.
  enum Material {
    case vidrio
    /// `fondo` se acepta por compatibilidad con la lámina, que todavía lo
    /// pasa; el vidrio ahumado no deja ver lo que hay detrás.
    case imitacion(fondo: AnyView? = nil)
  }

  @Environment(\.accessibilityReduceTransparency) private var reducirTransparencia
  @Environment(\.accessibilityReduceMotion) private var reducirMovimiento

  let silueta: SiluetaDeLaMuesca
  /// Si el panel está abierto. Cerrado, la forma es negra entera y **no hay
  /// vidrio montado**.
  let abierto: Bool
  var material: Material = .vidrio

  var body: some View {
    ZStack(alignment: .top) {
      silueta.fill(Color.black)
      if abierto {
        VidrioAhumado(
          silueta: silueta,
          vidrio: reducirTransparencia ? .ninguno : (esVidrioDeVerdad ? .deVerdad : .imitado),
          conReflejo: esVidrioDeVerdad && !reducirMovimiento
        )
        .transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.2), value: abierto)
  }

  private var esVidrioDeVerdad: Bool {
    if case .vidrio = material { return true }
    return false
  }
}

/// Lo que va encima del negro con el panel abierto: el vidrio ahumado, el
/// reflejo que cruza el canto al abrir y el filo que queda. Se monta con el
/// panel abierto y su `onAppear` es el arranque: cada apertura vuelve a
/// correr el reflejo.
private struct VidrioAhumado: View {
  enum Vidrio {
    /// `glassEffect` de verdad.
    case deVerdad
    /// El gris medido, para la lámina en PNG.
    case imitado
    /// Transparencia reducida: negro con su filo.
    case ninguno
  }

  let silueta: SiluetaDeLaMuesca
  let vidrio: Vidrio
  /// Si el reflejo recorre el canto al abrir.
  let conReflejo: Bool

  /// Dónde va el reflejo, como fracción del ancho: de antes del borde
  /// izquierdo a después del derecho.
  @State private var reflejo: CGFloat = -PanelDeVidrio.anchoDelReflejo
  @State private var reflejoVisible = true

  var body: some View {
    ZStack(alignment: .top) {
      switch vidrio {
      case .deVerdad:
        Color.clear
          .glassEffect(.regular.tint(.black.opacity(PanelDeVidrio.tinte)), in: silueta)
        silueta
          .fill(Color.black)
          .opacity(PanelDeVidrio.negroEncima)
      case .imitado:
        silueta.fill(Color(white: PanelDeVidrio.grisDeLaLamina))
      case .ninguno:
        EmptyView()
      }
      filo(brillo: PanelDeVidrio.brilloDelBorde)
      if conReflejo, reflejoVisible {
        reflejoDelCanto
      }
    }
    .onAppear(perform: arrancar)
  }

  private func arrancar() {
    guard conReflejo else { return }
    withAnimation(
      .easeInOut(duration: PanelDeVidrio.duracionDelReflejo).delay(PanelDeVidrio.esperaDelReflejo)
    ) {
      reflejo = 1
    }
    // Pasado el reflejo se desmonta: con el panel quieto no queda nada que
    // animar.
    Task { @MainActor in
      try? await Task.sleep(
        for: .seconds(PanelDeVidrio.esperaDelReflejo + PanelDeVidrio.duracionDelReflejo + 0.05)
      )
      reflejoVisible = false
    }
  }

  /// El trazo del canto de abajo, blanco, más fuerte al centro y apagándose
  /// hacia los costados. No sube por los lados ni toca la cabecera.
  private func filo(brillo: Double) -> some View {
    trazo(brillo: brillo)
      .mask { soloElCanto }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  private func trazo(brillo: Double, grosor: CGFloat = 0.75) -> some View {
    let trazo = silueta.sinHombros.stroke(
      LinearGradient(
        stops: [
          .init(color: .white.opacity(brillo * 0.3), location: 0),
          .init(color: .white.opacity(brillo), location: 0.5),
          .init(color: .white.opacity(brillo * 0.3), location: 1),
        ],
        startPoint: .leading,
        endPoint: .trailing
      ),
      lineWidth: grosor
    )
    return ZStack {
      trazo.blur(radius: 2 * grosor + 0.5).opacity(0.6)
      trazo
    }
  }

  /// El reflejo: el mismo trazo, más brillante, visto a través de una
  /// ventana blanda que cruza de izquierda a derecha.
  private var reflejoDelCanto: some View {
    ZStack {
      trazo(brillo: PanelDeVidrio.brilloDelReflejo, grosor: 1.25)
      // El velo: la luz dentro del negro, sólo pegada al canto de abajo.
      silueta.sinHombros
        .fill(LinearGradient(
          colors: [.white.opacity(0), .white.opacity(PanelDeVidrio.brilloDelVelo)],
          startPoint: .top,
          endPoint: .bottom
        ))
        .mask {
          VStack(spacing: 0) {
            Color.clear
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
              .frame(height: PanelDeVidrio.altoDelVelo)
          }
        }
    }
    .mask {
      GeometryReader { geo in
        let ancho = geo.size.width * PanelDeVidrio.anchoDelReflejo
        LinearGradient(colors: [.clear, .black, .clear], startPoint: .leading, endPoint: .trailing)
          .frame(width: ancho)
          .offset(x: reflejo * geo.size.width)
      }
      .padding(.vertical, -6)
    }
    .mask { soloElCanto }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  /// La máscara del canto: sólo la curva de abajo y un poco de lo que la
  /// luz derrama por fuera.
  private var soloElCanto: some View {
    VStack(spacing: 0) {
      Color.clear
      LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
        .frame(height: silueta.radioInferior + 6)
      Color.black.frame(height: 4)
    }
    .padding(.horizontal, -4)
    .padding(.bottom, -4)
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
