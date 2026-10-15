import SwiftUI

/// The HUD's black shape and its reveal, shared by every surface that descends
/// from the notch: the dictation shell, the Drop Transcription target, and the
/// finished transcript card.
///
/// This exists so the rules that break on real hardware live in one file.
/// Bounce is expressed only in top-anchored scale, never in position, because a
/// position overshoot lifts the shape off the screen edge and opens a visible
/// gap. Fillets exist only where there is a physical housing to flare into. The
/// host window never resizes, so the shape top-aligns inside whatever frame it
/// is handed.
///
/// **La ventana grande no es la forma.** La anfitriona está dimensionada para
/// el estado más alto y lleva holgura de sombra; la forma mide lo que mide su
/// estado y el resto de la ventana queda transparente. Lo que rompió eso una
/// vez fue un hijo goloso de alto, no la geometría — ver `MarcoDeLaForma`,
/// que sigue sin ofrecerle al contenido el alto de la ventana.
struct HUDSurface<Content: View, Overlays: View>: View {
  /// With Reduce Motion every style collapses to a quiet fade.
  static var reducedMotionFade: Animation { .easeOut(duration: 0.12) }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let screen: HUDScreenSnapshot
  let metrics: HUDMetrics
  let revealStyle: HUDRevealStyle
  let isRevealed: Bool
  let size: CGSize
  /// Bumped to fire the one-shot ripple across the housing; ignored when the
  /// ripple is disabled.
  var rippleTrigger: Int = 0
  var rippleEnabled: Bool = false
  /// Grows the shape out of the housing instead of moving a full-size shape
  /// into place, and overrides `revealStyle` entirely where it is on.
  ///
  /// This is how Drop Transcription opens and closes, after NotchDrop: closed,
  /// the black really is the size of the housing; open, it is the full shape;
  /// and a spring with overshoot carries it between the two. It belongs to the
  /// drop surfaces alone — dictation is a status surface, not a target, and
  /// keeps the reveal styles the user picks between.
  var growsFromHousing: Bool = false
  /// La silueta a la que la forma vuelve cuando nadie la ocupa, o nil para
  /// las superficies que sí se van de la pantalla.
  ///
  /// Con esto el HUD deja de ser una ventana que aparece y desaparece: el
  /// notch está siempre, y lo que cambia es su tamaño. No hay parqueo fuera
  /// de pantalla ni desvanecimiento — una forma que se va y vuelve se lee
  /// como una notificación, y el contrato del notch pide lo contrario
  /// (`EstadoDelNotch`).
  var tamañoEnReposo: CGSize? = nil
  /// Clips the content to the shape.
  ///
  /// Off by default: the dictation visuals bloom past the silhouette on
  /// purpose. The Drop Transcription surfaces want the opposite — their well
  /// and its border are laid out against a width that is still animating, and
  /// without this they can be drawn outside the black for a frame or two,
  /// which reads as a glitch on a shape whose whole job is to look like
  /// hardware.
  var clipsContent: Bool = false
  /// Cuánto se estira la silueta hacia cada lado por los segmentos de los
  /// asientos (`HUDSegmentosAlCostado`). Cero y cero, lo de siempre.
  var costados = CostadosDeLaSilueta()
  /// El panel del hover de vidrio ahumado (`PanelDeVidrio`), con los radios
  /// y resortes de Droppy. Encendido de fábrica
  /// desde el 2026-10-14; sólo cambia algo mientras el hover está abierto.
  var vidrio = false
  /// Si la forma abierta de este estado es la grande, con los hombros y el
  /// borde redondo de Droppy (`FormaAbierta`): el aviso sin carcasa, la pila
  /// de bandas contra una carcasa. La muesca de dictar (184×26) no lo es:
  /// sigue con los radios de la carcasa.
  var formaGrande = false
  /// El color del filo del borde de abajo mientras la forma está abierta
  /// (`FiloDeLaMuesca`), o nil para ninguno. En reposo no se dibuja nunca.
  var filo: Color? = nil
  @ViewBuilder let content: Content
  @ViewBuilder let overlays: Overlays

  /// La forma negra, en una sola pieza (`SiluetaDeLaMuesca`). Contra una
  /// carcasa real —y contra el notch simulado, que también nace del borde de
  /// la pantalla— el tope es recto y lleva las dos curvas cóncavas que la
  /// funden con el borde: con carcasa imitan el bisel físico, y en la muesca
  /// simulada hacen el mismo trabajo contra la barra de menús
  /// (`HUDNotchGeometry.filletSize`). La píldora de Dilo flota separada de la
  /// barra, así que se cierra por los cuatro lados y no lleva curvas — una
  /// píldora con el tope recto se lee como algo que se asoma desde arriba,
  /// que es justo lo que no es.
  ///
  /// El radio de abajo es `cornerRadius` y no el de la geometría: el de acá
  /// se achica al colapsar contra la carcasa, y esa transición es de la
  /// superficie.
  private var silueta: SiluetaDeLaMuesca {
    SiluetaDeLaMuesca.para(
      screen,
      radioInferior: cornerRadius,
      radioDeHombro: abiertaAlEstiloDroppy
        ? FormaAbierta.hombro(para: renderedSize, en: screen, radioInferior: cornerRadius)
        : nil,
      costados: costados
    )
  }

  /// Si la forma dibujada ahora es la abierta de Droppy: el panel del hover,
  /// o un estado revelado que pidió la forma grande.
  private var abiertaAlEstiloDroppy: Bool {
    panelDelHoverAbierto || (formaGrande && !isCollapsedIntoHousing)
  }

  /// Descansando manda la silueta en reposo, que depende de la forma que esta
  /// pantalla dibuja (`HUDNotchGeometry.radioEnReposo`); abierta, las
  /// métricas. Con 8 puntos sobre los 25 de alto de la muesca la silueta
  /// seguía leyéndose cuadrada.
  private var cornerRadius: CGFloat {
    // El panel del hover abre con la forma de Droppy, con vidrio o en
    // negro: el radio de 40 de su estante. Antes eran los 11 del reposo y el
    // panel se abría como un rectángulo.
    if panelDelHoverAbierto {
      return PanelDeVidrio.radio(
        para: renderedSize, cabecera: HUDNotchGeometry.alturaDeCabecera(for: screen)
      )
    }
    if formaGrande, !isCollapsedIntoHousing {
      return FormaAbierta.radioDelAviso(para: renderedSize)
    }
    guard !isCollapsedIntoHousing else { return HUDNotchGeometry.radioEnReposo(for: screen) }
    // Una forma abierta apenas más alta que la muesca —la sobria dictando,
    // 184×26— lleva el radio de la muesca. Con los 18 de la forma grande las
    // esquinas continuas se comían el cuerpo entero y la muesca se leía como
    // una gota colgando, no como el recorte un poco más grande.
    guard size.height >= metrics.bottomCornerRadius * 2 else {
      return HUDNotchGeometry.radioEnReposo(for: screen)
    }
    return metrics.bottomCornerRadius
  }

  /// Si la silueta en reposo está abierta por el hover: recogida, pero de
  /// otro tamaño que la de fábrica.
  private var panelDelHoverAbierto: Bool {
    isCollapsedIntoHousing && tamañoEnReposo != nil
      && renderedSize != HUDNotchGeometry.reposoSize(for: screen)
  }

  private var isCollapsedIntoHousing: Bool {
    (growsFromHousing || tamañoEnReposo != nil) && !isRevealed
  }

  private var renderedSize: CGSize {
    guard isCollapsedIntoHousing else { return size }
    return tamañoEnReposo ?? HUDNotchGeometry.closedSize(for: screen)
  }

  /// Si la forma proyecta sombra.
  ///
  /// **En reposo no.** La muesca quieta es hardware: el recorte de un MacBook
  /// no tiñe la barra de menús ni lo que hay debajo, y una imitación que sí lo
  /// hace se delata sola —«una sombra debajo que tiñe lo que está abajo», el
  /// veredicto del 2026-09-22—. Y no era sólo el gris: la ventana anfitriona
  /// se dimensiona con lo que la sombra necesita, así que pintarla cerrada
  /// obligaba a un reposo de 190×45 con una silueta de 160×24 adentro
  /// (`HUDNotchGeometry.holguraEnReposo`).
  ///
  /// Abierta sí, y el hover también: ahí la forma de verdad cuelga sobre el
  /// escritorio y la sombra es lo que la despega de él. Se decide por el
  /// tamaño dibujado y no por `isRevealed` porque el hover crece sin revelar
  /// nada.
  private var proyectaSombra: Bool {
    guard isCollapsedIntoHousing else { return true }
    return renderedSize != HUDNotchGeometry.reposoSize(for: screen)
  }

  /// Growing from the housing, the content exists only while the shape is open
  /// and flies in from behind it, which is NotchDrop's transition exactly.
  @ViewBuilder
  private var contentLayer: some View {
    if growsFromHousing {
      Group {
        if isRevealed { content }
      }
      .transition(
        .scale
          .combined(with: .opacity)
          .combined(with: .offset(y: -size.height / 2))
      )
    } else {
      content
    }
  }

  var body: some View {
    MarcoDeLaForma(
      ancho: renderedSize.width,
      alto: renderedSize.height,
      apertura: isCollapsedIntoHousing ? 0 : 1
    ) {
      contentLayer
    }
    // El recorte es lo que esconde el contenido abierto mientras la forma
    // todavía no creció hasta él: ya estaba acá, y con el marco animado
    // pasa a ser lo que hace que la forma se abra en vez de aparecer.
    .clipShape(clipsContent ? AnyShape(silueta.sinHombros) : AnyShape(Rectangle()))
    .background { housing }
    .overlay { overlays }
    .opacity(revealOpacity)
    .scaleEffect(x: revealScale.x, y: revealScale.y, anchor: .top)
    .offset(y: revealOffset)
    .animation(revealAnimation, value: isRevealed)
    // La silueta en reposo también cambia de tamaño sin que `isRevealed`
    // se mueva: el hover la abre para mostrar contexto.
    .animation(animacionDelTamaño, value: renderedSize)
    // Un segmento que entra, dice su palabra o se encoge estira la silueta
    // con el resorte de apertura del estilo, el mismo de la muesca; con
    // Reducir movimiento es un corte.
    .animation(reduceMotion ? nil : revealStyle.apertura, value: costados)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  /// Con qué curva cambia de tamaño la silueta en reposo, que es lo que hace
  /// el hover: crecer al posarse y volver al irse.
  ///
  /// `revealAnimation` no sirve para esto, porque elige la curva por
  /// `isRevealed` y el hover no revela nada: el panel se abría con la curva
  /// de **cierre**, sin carácter y más corta, y por eso se veía como un
  /// salto y no como la muesca abriéndose. La dirección la dice el tamaño:
  /// volver a la silueta de fábrica es cerrar, cualquier otro es abrir.
  private var animacionDelTamaño: Animation? {
    guard tamañoEnReposo != nil else { return nil }
    guard !reduceMotion else { return revealAnimation }
    // Revelada, la forma sólo cambia de tamaño entre estados de la sesión:
    // de la muesca de dictar al aviso, que se abre con el resorte de Droppy.
    if isRevealed {
      return formaGrande ? CurvaDeLaMuesca.apertura.animacion : revealAnimation
    }
    let vuelveAlReposo = renderedSize == HUDNotchGeometry.reposoSize(for: screen)
    // El panel del hover, con vidrio o en negro, abre y cierra con los
    // resortes de Droppy (0,47/0,76 al abrir, 0,54/0,90 al cerrar): son parte
    // de cómo se ve la forma abierta, no del estilo elegido.
    return vuelveAlReposo ? CurvaDeLaMuesca.cierre.animacion : CurvaDeLaMuesca.apertura.animacion
  }

  /// Growing from the housing never parks: there is no transform to hide the
  /// shape with, because the shape itself is the animation.
  private var isParked: Bool {
    !isRevealed && !reduceMotion && !growsFromHousing && tamañoEnReposo == nil
  }

  /// Where position moves at all, hidden means at or above the window's top
  /// edge — never below — so no style can open a gap against the screen edge.
  private var revealOffset: CGFloat {
    guard isParked else { return 0 }
    switch revealStyle {
    case .slide: return -(size.height + 20)
    case .unfurl, .bloom: return 0
    case .drift: return -14
    }
  }

  private var revealScale: (x: CGFloat, y: CGFloat) {
    guard isParked else { return (1, 1) }
    switch revealStyle {
    case .slide, .drift: return (1, 1)
    case .unfurl: return (1, 0.001)
    case .bloom: return (0.55, 0.55)
    }
  }

  private var revealOpacity: Double {
    // Una forma que descansa en pantalla nunca se desvanece: está, y lo que
    // cambia es su tamaño.
    if tamañoEnReposo != nil { return 1 }
    if reduceMotion {
      return isRevealed ? 1 : 0
    }
    // Growing from the housing never fades: the shape is always there, it is
    // just the size of the housing when closed, which is what makes it read as
    // the notch itself.
    if growsFromHousing { return 1 }
    switch revealStyle {
    case .slide, .unfurl: return 1
    case .bloom, .drift: return isRevealed ? 1 : 0
    }
  }

  /// Bounce lives only in top-anchored scale (unfurl, bloom) or in the shape's
  /// own size (growing from the housing); the styles that move position (slide,
  /// drift) stay bounce-free, because a position overshoot would detach the
  /// shape from the screen edge.
  private var revealAnimation: Animation {
    // El escenario permanente crece y se encoge, hacia abajo y desde la
    // muesca: la cabecera de la forma abierta **es** la silueta en reposo y
    // el anclaje es `.top`, así que el rebote sólo puede empujar hacia el
    // escritorio y nunca despega la forma del borde de la pantalla.
    //
    // **El estilo elegido vuelve a mandar.** Un único resorte de 0,32 para
    // todos era lo que había dejado la revelación sin carácter: «Baja» y «Se
    // infla» abrían exactamente igual y el ajuste no hacía nada. Lo que el
    // escenario sí impone es que no hay parqueo —la muesca no se va de la
    // pantalla, así que ningún estilo puede moverla de lugar ni apagarla— y
    // por eso las curvas se aplican al **tamaño** y no a la posición.
    if tamañoEnReposo != nil {
      if reduceMotion { return Self.reducedMotionFade }
      return isRevealed ? revealStyle.apertura : revealStyle.cierre
    }
    if reduceMotion {
      return Self.reducedMotionFade
    }
    // NotchDrop's spring, verbatim, in both directions — it is symmetric there.
    if growsFromHousing {
      return .interactiveSpring(
        duration: 0.5,
        extraBounce: HUDRevealStyle.reboteExtraDelArrastre,
        blendDuration: 0.125
      )
    }
    if isRevealed {
      switch revealStyle {
      case .slide: return .spring(duration: 0.4, bounce: 0)
      case .unfurl: return .spring(duration: 0.45, bounce: 0.3)
      case .bloom: return .spring(duration: 0.4, bounce: 0.25)
      case .drift: return .easeOut(duration: 0.24)
      }
    }
    switch revealStyle {
    case .slide, .unfurl, .bloom: return .spring(duration: 0.28, bounce: 0)
    case .drift: return .easeIn(duration: 0.18)
    }
  }

  /// The ripple sits between the clip and the shadow: it displaces the
  /// housing's pixels, and the shadow outside the effect stays still instead of
  /// shimmering with the wave.
  private var housing: some View {
    fondo
      .overlay {
        if let filo, !isCollapsedIntoHousing || panelDelHoverAbierto {
          FiloDeLaMuesca(silueta: silueta.sinHombros, color: filo, alto: cornerRadius + 4)
            .transition(.opacity)
        }
      }
      .animation(.easeOut(duration: 0.25), value: filo)
  }

  @ViewBuilder
  private var fondo: some View {
    if vidrio {
      // Sin la onda del borde: el vidrio sólo vive en reposo y en el hover,
      // y la onda es del arranque de una sesión, cuando la forma es negra.
      FondoDeLaMuesca(
        silueta: silueta,
        abierto: panelDelHoverAbierto
      )
      .shadow(
        color: .black.opacity(proyectaSombra ? 0.25 : 0),
        radius: proyectaSombra ? metrics.shadowRadius : 0,
        y: proyectaSombra ? metrics.shadowOffsetY : 0
      )
    } else {
      housingNegro
    }
  }

  private var housingNegro: some View {
    // Plain values for the @Sendable keyframeAnimator content closure.
    let rippleOrigin = CGPoint(
      x: size.width / 2,
      y: HUDNotchGeometry.closedSize(for: screen).height
    )
    let ripplePlays = !reduceMotion && rippleEnabled
    // En reposo la muesca no hace sombra, y la ventana en reposo tampoco
    // tiene dónde alojarla: los dos números van a cero juntos o uno de los
    // dos recorta al otro.
    let sombra = proyectaSombra
    // Las alas se dibujan fuera del marco del cuerpo: un `Shape` no se
    // recorta a su marco, y nada de lo que viene después lo recorta.
    return silueta
      .fill(Color.black)
      .keyframeAnimator(
        initialValue: 0.0,
        trigger: rippleTrigger
      ) { view, elapsed in
        view.modifier(
          HUDRippleModifier(
            origin: rippleOrigin,
            elapsedTime: elapsed,
            isEnabled: ripplePlays
          )
        )
      } keyframes: { _ in
        MoveKeyframe(0.0)
        LinearKeyframe(
          HUDRippleModifier.duration,
          duration: HUDRippleModifier.duration
        )
      }
      // Los dos números salen de las métricas y no de acá: la ventana
      // anfitriona se dimensiona con ellos (`HUDNotchGeometry.holguraDeSombra`),
      // y una sombra que crece sin que la ventana se entere sale recortada.
      .shadow(
        color: .black.opacity(sombra ? 0.35 : 0),
        radius: sombra ? metrics.shadowRadius : 0,
        y: sombra ? metrics.shadowOffsetY : 0
      )
  }
}

extension HUDSurface where Overlays == EmptyView {
  init(
    screen: HUDScreenSnapshot,
    metrics: HUDMetrics,
    revealStyle: HUDRevealStyle,
    isRevealed: Bool,
    size: CGSize,
    growsFromHousing: Bool = false,
    clipsContent: Bool = false,
    @ViewBuilder content: () -> Content
  ) {
    self.init(
      screen: screen,
      metrics: metrics,
      revealStyle: revealStyle,
      isRevealed: isRevealed,
      size: size,
      growsFromHousing: growsFromHousing,
      clipsContent: clipsContent,
      content: content,
      overlays: { EmptyView() }
    )
  }
}

/// Mide la forma mientras crece o se encoge, interpolando el ancho y el alto
/// juntos entre la silueta en reposo y la forma abierta.
///
/// **Existe porque el alto estaba en manos del contenido.** Antes la forma era
/// `fixedSize` vertical más un `frame(minHeight:)`: el contenido nuevo entra a
/// su alto final en el acto —una vista que aparece no anima su tamaño—, y el
/// mínimo animado nunca le gana a un contenido más alto que él. Al abrir,
/// entonces, el negro saltaba primero al alto de la forma abierta con el ancho
/// de la muesca y recién después se ensanchaba: la muesca «trabada» al
/// agrandarse que Alfonso reportó el 2026-09-23. Al cerrar no pasaba porque
/// el contenido de reposo es más bajo que el mínimo que se anima.
///
/// Acá el alto es `alto + (lo que el contenido pide por encima) × apertura`, y
/// los tres números se animan. Cerrada (`apertura` 0) la forma mide lo que
/// declara el estado aunque el contenido pida más —lo que sobra lo recorta
/// `HUDSurface`—; abierta (`apertura` 1) el contenido puede seguir creciendo
/// sobre lo declarado, que es lo que la banda de texto hace contra una
/// carcasa real (`HUDLongDraftStyle.growDown`).
///
/// Y sigue proponiendo alto nil, que es lo que hacía `fixedSize`: ofrecerle
/// al contenido el alto de la ventana anfitriona es lo que una vez estiró la
/// muesca en reposo a 160×196 en un monitor externo.
struct MarcoDeLaForma: Layout {
  var ancho: CGFloat
  /// El alto que el estado declara: la silueta en reposo o la forma abierta.
  var alto: CGFloat
  /// 0 con la forma recogida en la carcasa, 1 abierta.
  var apertura: CGFloat

  var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
    get { AnimatablePair(AnimatablePair(ancho, alto), apertura) }
    set {
      ancho = newValue.first.first
      alto = newValue.first.second
      apertura = newValue.second
    }
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    CGSize(width: ancho, height: altoDibujado(subviews))
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    for subview in subviews {
      // A su alto pedido y colgando del borde de arriba, aunque la forma
      // todavía no llegue hasta abajo: lo que se asoma de más no se ve.
      subview.place(
        at: CGPoint(x: bounds.midX, y: bounds.minY),
        anchor: .top,
        proposal: ProposedViewSize(width: ancho, height: altoPedido(por: subview))
      )
    }
  }

  private func altoPedido(por subview: LayoutSubview) -> CGFloat {
    subview.sizeThatFits(ProposedViewSize(width: ancho, height: nil)).height
  }

  private func altoDibujado(_ subviews: Subviews) -> CGFloat {
    let pedido = subviews.map(altoPedido(por:)).max() ?? 0
    return alto + max(0, pedido - alto) * apertura
  }
}
