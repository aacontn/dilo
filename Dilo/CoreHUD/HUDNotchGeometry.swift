import CoreGraphics

/// Frames for the Direct Dictation HUD, lifted from Tilebar's NotchIsland
/// pattern (ADR-0001): a fixed-size host window pinned to the top center whose
/// origin moves but never resizes, and a measured-vs-simulated notch split.
///
/// What this type decides is what the *display* imposes: the housing
/// footprint, whether fillets exist, and the host window. Everything the user
/// can resize lives in `HUDMetrics`.
enum HUDNotchGeometry {
  /// Stand-in footprint for a display that reports no notch (ADR-0001).
  /// The menu-bar height is not a usable substitute — auto-hidden it
  /// measures zero, which would collapse the housing to nothing.
  ///
  /// Sólo le queda la píldora: el notch simulado dejó de usarlo el
  /// 2026-09-21 y mide su propia muesca desde la pantalla
  /// (`muescaSimulada(for:)`).
  static let fallbackClosedSize = CGSize(width: 185, height: 32)

  /// El ancho de la muesca simulada en reposo.
  ///
  /// **No es el ancho de un notch de MacBook.** 185 puntos en un monitor
  /// externo de 1080p se leen como un rectángulo negro puesto encima de la
  /// barra —«deja tu cuadrado terrible feo», el veredicto del 2026-09-21—,
  /// porque ahí no hay carcasa que justifique ese tamaño. Una muesca tiene
  /// que leerse como un recorte del borde: angosta y del alto de la franja
  /// que ya estaba reservada.
  static let anchoDeLaMuescaSimulada: CGFloat = 160

  /// El alto de la barra de menús de esta pantalla, con el piso de
  /// `menuBarClearanceFloor` para cuando el sistema reporta cero.
  ///
  /// Medido y no constante: en 1080p la barra son ~24 puntos y en una
  /// pantalla Retina escalada son más. Una muesca más alta que la barra
  /// sobresale al escritorio y deja de leerse como parte del borde.
  static func altoDeLaBarra(for screen: HUDScreenSnapshot) -> CGFloat {
    max(screen.menuBarHeight, menuBarClearanceFloor)
  }

  /// La muesca simulada en reposo: del alto de la barra de menús de esta
  /// pantalla y del ancho de una muesca, no de una carcasa prestada.
  static func muescaSimulada(for screen: HUDScreenSnapshot) -> CGSize {
    CGSize(width: anchoDeLaMuescaSimulada, height: altoDeLaBarra(for: screen))
  }

  /// Slack on the left, right, and bottom so the shell's drawn shadow is not
  /// clipped by the fixed window frame. Nothing is added at the top: that
  /// edge is the top of the screen and the shape is flush against it.
  static let shadowPadding: CGFloat = 44

  /// The notch this display actually reports, or nil when there is nothing
  /// to measure. Width comes from the two auxiliary areas by subtraction so
  /// the result does not depend on which coordinate space they arrive in.
  ///
  /// Optional rather than falling back here, because whether a measurement
  /// succeeded cannot be recovered from its result: a 14" MacBook Pro
  /// measures exactly the fallback numbers.
  static func measuredClosedSize(for screen: HUDScreenSnapshot) -> CGSize? {
    guard
      let left = screen.auxiliaryTopLeftArea,
      let right = screen.auxiliaryTopRightArea,
      screen.safeAreaTop > 0
    else {
      return nil
    }

    let width = screen.frame.width - left.width - right.width
    guard width > 0, width < screen.frame.width else { return nil }

    return CGSize(width: width, height: screen.safeAreaTop)
  }

  /// The housing footprint. Never scaled by the HUD size: this height is
  /// hardware on a notched display, and the menu bar's own strip on every
  /// other one.
  ///
  /// Tres ramas y no dos: con carcasa manda lo medido, con la muesca
  /// simulada manda la barra de menús de esa pantalla, y a la píldora le
  /// queda el tamaño prestado de siempre —no dibuja ninguna carcasa, así que
  /// esto sólo le sirve para dimensionar la ventana anfitriona—.
  static func closedSize(for screen: HUDScreenSnapshot) -> CGSize {
    if let medida = measuredClosedSize(for: screen) { return medida }
    return simulatesNotch(for: screen) ? muescaSimulada(for: screen) : fallbackClosedSize
  }

  /// Whether this display has a housing of its own for the HUD to hug.
  static func hasMeasuredNotch(for screen: HUDScreenSnapshot) -> Bool {
    measuredClosedSize(for: screen) != nil
  }

  /// La silueta en reposo: lo que se ve cuando nadie está dictando.
  ///
  /// El notch —real o simulado— descansa en su propio tamaño, que es lo que
  /// lo hace leerse como un notch y no como una ventanita que se abrió. La
  /// píldora descansa más chica: cuelga sobre el escritorio de la persona y
  /// no sobre una franja que el sistema ya tenía reservada.
  static func reposoSize(for screen: HUDScreenSnapshot) -> CGSize {
    dibujaPildora(for: screen) ? reposoDeLaPildora : closedSize(for: screen)
  }

  /// La píldora en reposo: lo justo para una marca centrada.
  static let reposoDeLaPildora = CGSize(width: 96, height: 20)

  /// El alto de la cabecera de la forma abierta: la franja de arriba de la
  /// que cuelga todo lo demás.
  ///
  /// **Es la silueta en reposo.** La forma abierta crece hacia abajo desde
  /// donde estaba descansando, que es lo que hace el notch de un MacBook y lo
  /// que Dilo imita en una pantalla sin carcasa. Contra hardware real la
  /// cabecera queda vacía porque ahí está la cámara; en el notch simulado y
  /// en la píldora no hay nada que esquivar y la marca de reposo vive adentro.
  ///
  /// Reemplaza la corona mango que la píldora llevaba **encima**: una franja
  /// con un micrófono arriba de la forma se lee como un segundo objeto
  /// pegado, no como el notch creciendo.
  static func alturaDeCabecera(for screen: HUDScreenSnapshot) -> CGFloat {
    reposoSize(for: screen).height
  }

  /// The HUD shape's size: the header band, whatever voice-visual band the
  /// selected visual uses, the text band unless the visual replaces it, and
  /// the shaping band while a session carries one, clamped so a narrow
  /// display never gets a shape wider than its window.
  static func contentSize(
    for screen: HUDScreenSnapshot,
    metrics: HUDMetrics,
    visualBandHeight: CGFloat,
    includesTextBand: Bool,
    shapingBandHeight: CGFloat
  ) -> CGSize {
    CGSize(
      width: min(metrics.contentWidth, windowSize(for: screen).width),
      height: alturaDeCabecera(for: screen)
        + visualBandHeight
        + (includesTextBand ? metrics.textBandHeight : 0)
        + shapingBandHeight
    )
  }

  /// El rectángulo de la ventana anfitriona que recibe el mouse, en
  /// coordenadas de la vista (origen abajo a la izquierda).
  ///
  /// La ventana es mucho más ancha que la forma —lleva holgura invisible para
  /// la sombra—, y desde que el escenario vive siempre en pantalla, dejarla
  /// entera sensible al mouse se tragaría clics en media barra de menús. Sólo
  /// la silueta toma el mouse; el resto pasa de largo (`HUDHostingView`).
  static func zonaInteractiva(for screen: HUDScreenSnapshot, tamaño: CGSize) -> CGRect {
    let ventana = windowSize(for: screen)
    let ancho = min(tamaño.width, ventana.width)
    let alto = min(tamaño.height, ventana.height)
    return CGRect(
      x: (ventana.width - ancho) / 2,
      y: ventana.height - alto,
      width: ancho,
      height: alto
    )
  }

  /// Breathing room each side of the housing, so the shape reads as wider than
  /// what it descends from rather than exactly as wide as it.
  private static let housingShoulder: CGFloat = 4

  /// The smallest scale this display can show.
  ///
  /// A shape narrower than the housing stops reading as the notch growing and
  /// becomes a tab floating under it, and its fillets land inside the cutout
  /// where there is no bezel to flare into. So a measured notch sets its own
  /// floor from its real width, and a display without one keeps the global
  /// minimum because it has nothing to cover.
  ///
  /// This cannot be a constant. The notch is a fixed physical width, but its
  /// width *in points* moves with the scaled display mode: the same 14" MacBook
  /// reports about 155 points under More Space and about 273 under Larger Text,
  /// which is a floor anywhere between 0.34 and 0.56. A single constant would
  /// have to assume the worst of those and take the small sizes away from
  /// everyone on the default mode.
  static func minimumScale(for screen: HUDScreenSnapshot) -> CGFloat {
    guard hasMeasuredNotch(for: screen) else { return HUDMetrics.minimumScale }
    let needed = closedSize(for: screen).width
      + filletSize(for: screen) * 2
      + housingShoulder * 2
    let scale = needed / HUDMetrics.standard.contentWidth
    return min(max(scale, HUDMetrics.minimumScale), HUDMetrics.maximumScale)
  }

  /// Size of the concave corner that flares the shape into the bezel.
  /// Unscaled: the flare has to match a physical bezel curve.
  ///
  /// **La muesca simulada también los lleva, desde el 2026-09-21**, y eso
  /// enmienda ADR-0001. El argumento de entonces —«sin bisel la curva se lee
  /// como dos pestañas sueltas»— valía para una forma que aparecía al dictar
  /// y se iba; ahora la muesca está siempre y pegada al borde, y son
  /// justamente esas dos curvas cóncavas las que la funden con la barra en
  /// vez de dejarla como un rectángulo apoyado encima. Un poco más chicos
  /// que contra hardware: el bisel que imitan es dibujado, no físico.
  static func filletSize(for screen: HUDScreenSnapshot) -> CGFloat {
    if hasMeasuredNotch(for: screen) { return 11 }
    return simulatesNotch(for: screen) ? filletDeLaMuescaSimulada : 0
  }

  /// El radio de las curvas cóncavas de la muesca simulada.
  static let filletDeLaMuescaSimulada: CGFloat = 9

  /// El radio de las esquinas de abajo mientras la forma descansa.
  ///
  /// La muesca las lleva más redondas que la forma abierta chica que había
  /// antes: con 8 puntos sobre 25 de alto la silueta seguía leyéndose
  /// cuadrada, que es la mitad del reclamo. La píldora se queda en 8 porque
  /// además cierra por arriba con el mismo radio y ahí una cápsula perfecta
  /// se lee como un óvalo suelto.
  static func radioEnReposo(for screen: HUDScreenSnapshot) -> CGFloat {
    dibujaPildora(for: screen) ? 8 : 11
  }

  /// Clearance between the true top of the screen and the housing, on a
  /// display with no measured notch.
  ///
  /// A real notch already sits in its own housing, clear of wherever the
  /// system draws status items. The simulated stand-in has no such housing:
  /// pinned flush to the screen's top edge it draws directly over the menu
  /// bar, hiding whatever status item sits under it — including Dilo's
  /// own (issue #83). So there the shape hangs just below the menu bar
  /// instead of over it.
  ///
  /// **El default cambió el 2026-09-21 (tarde): sin carcasa se dibuja el
  /// notch simulado.** La píldora debajo de la barra cumplía la lección 2 del
  /// spec §8 —no tapar los status items— pero no cumplía el producto: con dos
  /// monitores sin notch se leía como «una ventana que se abrió», no como el
  /// notch, que es el escenario del que cuelga toda la experiencia. La forma
  /// simulada sólo ocupa la franja del centro de la barra, que macOS deja
  /// vacía, así que ningún status item queda tapado. La píldora sigue
  /// disponible —Ajustes → Apariencia, «En pantallas sin notch»— para quien
  /// la prefiera.
  ///
  /// Quién elige entre las dos es `screen.estiloSinNotch`: con
  /// `.notchSimulado` la forma nace del borde (relleno cero) y con `.pildora`
  /// cuelga por debajo de la barra.
  static func topInset(for screen: HUDScreenSnapshot) -> CGFloat {
    guard !hasMeasuredNotch(for: screen) else { return 0 }
    guard !simulatesNotch(for: screen) else { return 0 }
    return altoDeLaBarra(for: screen) + pillDetachment
  }

  /// Si esta pantalla dibuja el notch simulado: no tiene carcasa que medir y
  /// la preferencia pide la imitación.
  ///
  /// La forma se pega a `y = 0` y queda encima de la barra de menús, que en
  /// macOS está vacía justo en el centro: los menús de la app se acomodan a
  /// la izquierda y los status items a la derecha. **El límite es ese**: una
  /// barra con tantos menús abiertos que lleguen al centro queda tapada en
  /// esa franja mientras dura el dictado, y no hay forma de evitarlo sin
  /// mover el notch de lugar —que es exactamente lo que `.pildora` hace—.
  /// La forma nunca se hace más ancha de lo que necesita: en reposo son los
  /// `anchoDeLaMuescaSimulada` puntos de la muesca, y abierta es el ancho del
  /// contenido que la persona eligió en Ajustes.
  static func simulatesNotch(for screen: HUDScreenSnapshot) -> Bool {
    !hasMeasuredNotch(for: screen) && screen.estiloSinNotch == .notchSimulado
  }

  /// Si en esta pantalla el **reposo** se esconde.
  ///
  /// Sin barra de menús no hay franja de la que la muesca cuelgue: dibujarla
  /// igual deja un bloque negro flotando sobre el borde de una app en
  /// pantalla completa, que es lo contrario de «es la barra negra que ya
  /// estaba ahí». Es sólo el reposo — dictando, procesando y el resultado
  /// aparecen igual, porque ahí la forma está diciendo algo que no puede
  /// esperar a salir del espacio.
  ///
  /// Con carcasa real no aplica: el recorte físico sigue en su lugar en
  /// pantalla completa.
  ///
  /// Se mide por la barra y no por una API de pantalla completa porque eso es
  /// exactamente lo que se quiere saber. El efecto secundario es que a quien
  /// tenga la barra en «ocultar automáticamente» la muesca en reposo también
  /// se le esconde, y es lo correcto: pidió que arriba no hubiera nada.
  static func reposoSeEsconde(for screen: HUDScreenSnapshot) -> Bool {
    !hasMeasuredNotch(for: screen) && screen.menuBarHeight <= 0
  }

  /// Lo mínimo que se le reserva a la barra de menús aunque el sistema diga
  /// que mide cero.
  ///
  /// Dentro de un espacio en pantalla completa la barra se autooculta y
  /// `visibleFrame` crece hasta el borde: sin este piso la píldora saltaría
  /// al tope de la pantalla al cambiar de espacio a media sesión, y volvería
  /// a bajar al salir. Queda donde está, que es lo que se le pide a algo que
  /// vive en el mismo lugar siempre.
  static let menuBarClearanceFloor: CGFloat = 24

  /// El aire entre la barra de menús y la píldora.
  ///
  /// Es lo que la vuelve un objeto aparte y no la continuación de la franja
  /// del sistema: macOS 27 pone ahí su propio HUD de volumen, y una píldora
  /// pegada al borde de esa franja se lee como parte de él (spec §8). Cuatro
  /// puntos bastan para separarla; con notch no aplica, porque ahí la forma
  /// nace de la carcasa.
  static let pillDetachment: CGFloat = 4

  /// Si esta pantalla dibuja la píldora de Dilo en vez de la forma que cuelga
  /// del notch. Es una propiedad de la pantalla, no una preferencia: sin
  /// carcasa no hay de qué colgar.
  static func drawsPill(for screen: HUDScreenSnapshot) -> Bool {
    !hasMeasuredNotch(for: screen)
  }

  /// El radio de las esquinas de arriba. Cero contra una carcasa real —la
  /// forma nace del recorte y no tiene borde propio ahí—, cero también en el
  /// notch simulado por la misma razón, y el mismo radio de abajo en la
  /// píldora, que flota separada y se cierra por los cuatro lados.
  static func topCornerRadius(for screen: HUDScreenSnapshot, metrics: HUDMetrics) -> CGFloat {
    closesAtTop(for: screen) ? metrics.bottomCornerRadius : 0
  }

  /// Si la forma se cierra también por arriba. Sólo la píldora: el notch
  /// —real o simulado— nace de un borde y compartirlo es lo que lo hace
  /// leerse como notch. Una imitación con el tope redondeado se ve como una
  /// pastilla mal pegada al canto de la pantalla.
  static func closesAtTop(for screen: HUDScreenSnapshot) -> Bool {
    dibujaPildora(for: screen)
  }

  /// Si acá se dibuja la píldora que cuelga debajo de la barra —la forma
  /// cerrada por los cuatro lados—, y no un notch (real o imitado).
  ///
  /// Distinto de `drawsPill`, que sólo dice que esta pantalla no tiene
  /// carcasa que medir: con el estilo simulado, una pantalla sin carcasa
  /// dibuja un notch, no una píldora.
  static func dibujaPildora(for screen: HUDScreenSnapshot) -> Bool {
    drawsPill(for: screen) && !simulatesNotch(for: screen)
  }

  /// The host window's frame: content size plus shadow slack, centered and
  /// pinned to the top (below the menu bar on a display with no notch of its
  /// own), clamped to the screen width.
  ///
  /// Sized for the standard metrics whatever the user's HUD size, so the
  /// window stays fixed per display (ADR-0001) and a smaller shape simply
  /// centers itself inside it. The window is invisible and click-through, so
  /// the unused slack costs nothing.
  static func windowFrame(for screen: HUDScreenSnapshot) -> CGRect {
    let size = windowSize(for: screen)
    return CGRect(
      x: screen.frame.midX - size.width / 2,
      y: screen.frame.maxY - size.height - topInset(for: screen),
      width: size.width,
      height: size.height
    )
  }

  /// The window's size, which does not depend on where it is pinned. Separate
  /// so the callers that only want its width need know nothing about the menu
  /// bar.
  static func windowSize(for screen: HUDScreenSnapshot) -> CGSize {
    let metrics = HUDMetrics.standard
    // The shaping band rides outside the max: it can sit under either
    // alternative, so the tallest layout is whichever band stack wins plus it.
    return CGSize(
      width: min(metrics.contentWidth + shadowPadding * 2, screen.frame.width),
      height: closedSize(for: screen).height
        + max(metrics.waveBandHeight, metrics.visualBandHeight + metrics.maxTextBandHeight)
        + metrics.shapingBandHeight
        + shadowPadding
    )
  }
}
