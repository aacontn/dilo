import SwiftUI

/// El panel del hover al estilo Dynamic Glass: **negro opaco** en todo lo
/// que tiene texto, y el vidrio sólo en una franja ahumada al pie.
///
/// Técnica observada en el video «Dynamic Glass» de Droppy (cuadro guardado
/// en el taller, `droppy-dynamic-glass-referencia.jpg`): el panel abierto es
/// negro casi entero y recién en su último cuarto el negro «se derrite» en
/// vidrio oscuro, con un filo de luz en el borde de abajo. El fondo apenas se
/// adivina a través de esa franja y el texto queda siempre sobre negro, así
/// que se lee igual sobre una página blanca que sobre un escritorio oscuro.
/// Implementación propia y sólo con API pública: `glassEffect(_:in:)`.
///
/// **Hasta la 0.4.5 era al revés** (2026-10-15): negro sólo en la cabecera y
/// 22 puntos de fundido, y todo lo demás vidrio con un tinte de 0,3 «para que
/// se leyera como vidrio». Sobre YouTube el panel quedaba gris claro y
/// translúcido con letra blanca encima: «se ve mal». El vidrio claro con
/// texto encima no vuelve.
///
/// **Encendido de fábrica** (`AppSettings.hudPanelDeVidrio`, interruptor
/// «Panel con vidrio» en Ajustes → Apariencia); apagado, la misma forma en
/// negro entero. Sólo mientras el panel está abierto: en reposo no hay vidrio
/// montado, así que el reposo cuesta lo mismo que antes (spec §3). Con
/// «Reducir transparencia» del sistema cae a negro. El vidrio **no sale en
/// PNG** (`ImageRenderer` no lo dibuja): la lámina lo imita con
/// `FondoDeLaMuesca.Material.imitacion` y se juzga en la pantalla con las
/// escenas `hover-vidrio` y `hover-completo-vidrio` del arnés.
enum PanelDeVidrio {
  /// El radio de abajo del panel abierto: unos 32 puntos, medidos en el
  /// cuadro de Droppy contra el ancho del panel (eran 40, el
  /// `expandedShelfCornerRadius` de su estante, y en el panel se veía más
  /// redondo que la referencia). Se achica sólo si el panel es más bajo.
  static let radioInferior: CGFloat = 32

  /// Qué parte del alto del panel ocupa la franja de vidrio, contada desde
  /// el borde de abajo: el último ~30 %, como en Droppy, entre un mínimo que
  /// deja ver el vidrio en el panel de una línea y un máximo que nunca le
  /// llega al texto principal.
  static let proporcionDeLaFranja: CGFloat = 0.3
  static let franjaMinima: CGFloat = 26
  static let franjaMaxima: CGFloat = 60

  /// El tinte negro del vidrio de la franja. Alto a propósito: el vidrio
  /// de Droppy es ahumado, no claro.
  static let tinte: Double = 0.5
  /// Cuánto negro queda encima del vidrio en el mismo borde de abajo, donde
  /// el degradado es más translúcido. El negro **nunca** llega a cero: es lo
  /// que garantiza que la fila de abajo —los modos, «Nota»— quede sobre
  /// vidrio oscuro aunque detrás haya una página blanca.
  static let negroAlPie: Double = 0.35

  /// Lo que deja pasar del fondo el borde de abajo, el punto más claro del
  /// panel: el vidrio tintado por el negro que le queda encima. Sobre una
  /// página blanca es un gris de un tercio, y la letra blanca sigue
  /// leyéndose; el resto del panel deja pasar menos, y arriba nada.
  static var transmisionAlPie: Double { (1 - tinte) * (1 - negroAlPie) }

  /// El filo de luz del borde de abajo: blanco, fino, y sólo en la curva de
  /// abajo, que es lo que hace que la franja se lea como el canto de un
  /// vidrio y no como un gris translúcido.
  static let brilloDelBorde: Double = 0.38

  /// El aire lateral del contenido: el radio de abajo se come las esquinas.
  static let aireLateral: CGFloat = 22

  /// El radio de abajo para un panel de este alto: el de Droppy, sin pasarse
  /// de lo que cuelga bajo la cabecera ni de un cuarto del ancho.
  static func radio(para tamaño: CGSize, cabecera: CGFloat) -> CGFloat {
    max(0, min(radioInferior, tamaño.height - cabecera, tamaño.width / 4))
  }

  /// Cuánto mide la franja de vidrio en un panel de este alto, sin subir
  /// nunca por encima de la cabecera.
  static func franja(para alto: CGFloat, cabecera: CGFloat) -> CGFloat {
    let libre = max(0, alto - cabecera)
    return min(libre, max(franjaMinima, min(franjaMaxima, alto * proporcionDeLaFranja)))
  }

  /// Dónde empieza la franja, como fracción del alto desde arriba: el
  /// `location` del degradado de la máscara.
  static func inicioDeLaFranja(para alto: CGFloat, cabecera: CGFloat) -> CGFloat {
    guard alto > 0 else { return 1 }
    return 1 - franja(para: alto, cabecera: cabecera) / alto
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

/// El fondo de la forma con el vidrio puesto: negro opaco arriba y en todo
/// el contenido, y vidrio ahumado sólo en la franja de abajo mientras el
/// panel está abierto (`PanelDeVidrio`). Cerrado, negro entero y sin vidrio
/// montado.
///
/// Son tres capas: el vidrio tintado al fondo, encima un negro con una
/// máscara que va de opaco a `negroAlPie` en la franja, y encima un negro
/// entero que se apaga al abrir. El negro de la máscara está siempre —la
/// cabecera nunca cruza dos negros a media opacidad, que haría parpadear la
/// muesca contra la barra— y el entero es lo que lleva el paso de negro a
/// vidrio sin un salto, al abrir y al cerrar.
struct FondoDeLaMuesca: View {
  /// Con qué se pinta lo de abajo. `imitacion` es para el render en PNG,
  /// donde el vidrio de verdad no se dibuja: lo que hay detrás desenfocado y
  /// tintado con el mismo negro, rotulado como imitación en la lámina.
  enum Material {
    case vidrio
    /// `fondo` es lo que hay detrás de la forma, **ya desenfocado** y
    /// recortado a su marco —el `blur` de SwiftUI no sale bien en
    /// `ImageRenderer`, y la lámina lo desenfoca con Core Image—; sin él, el
    /// tinte solo sobre lo que haya debajo.
    case imitacion(fondo: AnyView? = nil)
  }

  @Environment(\.accessibilityReduceTransparency) private var reducirTransparencia

  let silueta: SiluetaDeLaMuesca
  /// El alto de la cabecera (`HUDNotchGeometry.alturaDeCabecera`).
  let alturaDeCabecera: CGFloat
  /// Si el panel está abierto. Cerrado, la forma es negra entera y **no hay
  /// vidrio montado**.
  let abierto: Bool
  var material: Material = .vidrio

  /// «Reducir transparencia» manda: el panel se dibuja negro entero, que es
  /// lo que el sistema promete con ese ajuste.
  private var conVidrio: Bool { abierto && !reducirTransparencia }

  var body: some View {
    ZStack(alignment: .top) {
      if conVidrio {
        vidrio
          .transition(.opacity)
      }
      // El negro con la franja: opaco hasta donde empieza, y de ahí al
      // `negroAlPie` en el borde. Es lo que deja todo el texto sobre negro.
      silueta
        .fill(Color.black)
        .mask { mascaraDelNegro }
      // El negro entero, que tapa el vidrio mientras el panel está cerrado o
      // la transparencia está reducida, y se apaga al abrir.
      silueta
        .fill(Color.black)
        .opacity(conVidrio ? 0 : 1)
      if conVidrio {
        brillo
          .transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.25), value: conVidrio)
  }

  /// El vidrio con la silueta entera, alas incluidas: arriba lo tapa el
  /// negro, y así no hay costura entre los dos en ningún punto.
  @ViewBuilder
  private var vidrio: some View {
    switch material {
    case .vidrio:
      Color.clear
        .glassEffect(.regular.tint(.black.opacity(PanelDeVidrio.tinte)), in: silueta)
    case let .imitacion(fondo):
      ZStack {
        if let fondo {
          fondo
        }
        Color.black.opacity(PanelDeVidrio.tinte)
      }
      .clipShape(silueta)
    }
  }

  /// La máscara del negro: opaca hasta la franja, y de ahí un degradado
  /// suave —tres paradas, para que el negro «se derrita» y no corte— hasta
  /// `negroAlPie`. Más ancha que la forma: las alas cóncavas se dibujan
  /// fuera de su marco y una máscara del ancho justo las cortaría.
  private var mascaraDelNegro: some View {
    GeometryReader { geo in
      let inicio = PanelDeVidrio.inicioDeLaFranja(para: geo.size.height, cabecera: alturaDeCabecera)
      let pie = PanelDeVidrio.negroAlPie
      LinearGradient(
        stops: [
          .init(color: .black, location: 0),
          .init(color: .black, location: inicio),
          .init(color: .black.opacity(pie + (1 - pie) * 0.45), location: inicio + (1 - inicio) * 0.45),
          .init(color: .black.opacity(pie), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    }
    .padding(.horizontal, -60)
  }

  /// El canto del vidrio: un filo blanco fino en la curva de abajo, más
  /// fuerte al centro y apagándose hacia los costados, con un halo apenas
  /// visible. No sube por los lados ni toca la cabecera, que es negra.
  private var brillo: some View {
    let radio = silueta.radioInferior
    let trazo = silueta.sinHombros.stroke(
      LinearGradient(
        stops: [
          .init(color: .white.opacity(PanelDeVidrio.brilloDelBorde * 0.4), location: 0),
          .init(color: .white.opacity(PanelDeVidrio.brilloDelBorde), location: 0.5),
          .init(color: .white.opacity(PanelDeVidrio.brilloDelBorde * 0.4), location: 1),
        ],
        startPoint: .leading,
        endPoint: .trailing
      ),
      lineWidth: 0.75
    )
    return ZStack {
      trazo.blur(radius: 2).opacity(0.6)
      trazo
    }
    .mask {
      VStack(spacing: 0) {
        Color.clear
        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
          .frame(height: radio + 6)
        Color.black.frame(height: 4)
      }
      .padding(.horizontal, -4)
      .padding(.bottom, -4)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
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
