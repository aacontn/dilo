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
  ///
  /// **Es la holgura de la ventana abierta, no la de todas.** En reposo la
  /// ventana se ajusta a la muesca con `holguraDeSombra` y nada más
  /// (`EncuadreDeLaVentana`): estos 44 puntos alrededor de una silueta de
  /// 160×24 eran 190 puntos de pantalla muerta bajo la barra de menús.
  static let shadowPadding: CGFloat = 44

  /// Cuánta ventana anfitriona pide la forma ahora mismo.
  ///
  /// La ventana **mide lo que mide el estado**. macOS le entrega a una
  /// ventana todos los clics de su rectángulo aunque ahí no haya dibujado
  /// nada, y un `hitTest` que devuelve nil no hace que el clic siga de largo
  /// hacia la ventana de abajo: lo pierde. Con una sola ventana dimensionada
  /// para el estado más alto, los ~190 puntos bajo la muesca quedaban
  /// inutilizados todo el tiempo aunque el 99 % del tiempo la forma sea una
  /// muesca de 24 puntos de alto (ADR-0001, enmienda del 2026-09-22).
  enum EncuadreDeLaVentana: Equatable, Sendable {
    /// La silueta quieta: la ventana **es** la muesca. Ni un punto debajo de
    /// ella, porque en reposo no hay sombra que alojar
    /// (`HUDSurface.proyectaSombra`); a los lados, sólo lo que las dos alas
    /// cóncavas cuelgan fuera de la silueta.
    case reposo
    /// Cualquier forma abierta o creciendo: la ventana da lugar al estado más
    /// alto, a su sombra y al sobrepaso del resorte.
    case abierta
  }

  /// Lo que la sombra dibujada necesita alrededor de la forma para no salir
  /// recortada: su desenfoque más lo que baja (`HUDMetrics.shadowRadius`,
  /// `shadowOffsetY`).
  ///
  /// Con las métricas estándar son 15 puntos. Sale de los mismos números con
  /// los que `HUDSurface` dibuja la sombra, para que no haya forma de
  /// achicarla en un lado y recortarla en el otro.
  static func holguraDeSombra(_ metrics: HUDMetrics = .standard) -> CGFloat {
    metrics.shadowRadius + metrics.shadowOffsetY
  }

  /// La holgura de la ventana **en reposo**, y sólo a los lados: lo que las
  /// dos alas cóncavas cuelgan fuera de la silueta.
  ///
  /// **La sombra ya no entra acá.** En reposo la muesca es hardware: el
  /// recorte de un MacBook no tiñe lo que tiene debajo, y la imitación
  /// tampoco puede hacerlo. Pintarla igual costaba dos cosas a la vez —un
  /// halo gris cruzando la barra de menús, y una ventana de 190×45 donde la
  /// silueta mide 160×24— y las dos se veían (veredicto del 2026-09-22: «una
  /// sombra debajo que tiñe lo que está abajo»). La holgura de sombra entra
  /// al abrir, que es cuando la forma de verdad cuelga sobre el escritorio.
  ///
  /// Las alas sí se quedan: son negro opaco de la propia silueta, y una
  /// ventana de exactamente 160 puntos se las recortaría — que es lo único
  /// que separa a la muesca de un rectángulo apoyado encima de la barra.
  static func holguraEnReposo(for screen: HUDScreenSnapshot) -> CGFloat {
    filletSize(for: screen)
  }

  /// La holgura de la ventana **abierta**: la sombra más lo que el rebote del
  /// resorte se pasa del tamaño final (`HUDRevealStyle.sobrepasoMaximo`).
  ///
  /// Con el piso histórico de `shadowPadding`, que hoy gana: el peor
  /// sobrepaso es un 9 % y la forma abierta mide 400 puntos de ancho, o sea
  /// 18 de cada lado, que con los 15 de la sombra son 33 — dentro de los 44.
  /// Se deriva igual para que subir un rebote agrande la ventana sola en vez
  /// de recortar la animación en silencio.
  static func holguraDeRevelacion(for screen: HUDScreenSnapshot) -> CGFloat {
    let sobrepaso = max(
      // El ancho rebota hacia los dos lados; el alto, sólo hacia abajo (el
      // anclaje es `.top`).
      HUDMetrics.standard.contentWidth * HUDRevealStyle.sobrepasoMaximo / 2,
      altoDeLaFormaMasAlta(for: screen) * HUDRevealStyle.sobrepasoMaximo
    )
    return max(shadowPadding, holguraDeSombra() + sobrepaso)
  }

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
    let base = dibujaPildora(for: screen) ? reposoDeLaPildora : closedSize(for: screen)
    return CGSize(width: base.width + screen.anchoDeLosLados * 2, height: base.height)
  }

  /// Lo que se alarga la muesca a cada lado cuando lleva un dato: una
  /// etiqueta corta y un número («Codex 35%», «Claude 1,7M») en once puntos,
  /// con aire contra el borde. Igual a los dos lados aunque sólo uno tenga
  /// dato, para que la muesca siga centrada sobre el notch.
  static let anchoDeUnLado: CGFloat = 72

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

  /// Cuánto se ensancha la muesca al dictar, y cuánto crece de alto.
  ///
  /// **Dictar apenas agranda la muesca** (2026-09-22). Los 400×88 de ayer
  /// eran un panel colgando de una silueta de 160×24: «crece mucho cuando le
  /// estoy dictando; podría crecer por un 10 % del notch real y avanzar en el
  /// texto como lo está haciendo actualmente, que sería lo ideal». Así que el
  /// alto es el de la barra de menús más un décimo —26 puntos donde la barra
  /// mide 24— y el ancho, un 15 % más que el reposo: lo justo para que la
  /// onda compacta y el parcial compartan una línea, y lo bastante poco para
  /// que la forma siga siendo la muesca.
  static let crecimientoAlDictar: CGFloat = 0.10
  static let ensancheAlDictar: CGFloat = 0.15

  /// La muesca mientras hay una sesión abierta: dictando, preparando,
  /// procesando y el aviso de un error.
  ///
  /// **Sin escalar, y por el mismo motivo que la carcasa**: esto sale del
  /// alto de la barra de menús de esta pantalla, que es lo que mide, no una
  /// preferencia. Lo que el tamaño elegido en Ajustes sí escala es el panel
  /// del hover, que es el único que tiene contenido de sobra que achicar.
  ///
  /// No aplica contra una carcasa real: ahí los primeros `safeAreaTop`
  /// puntos son el recorte físico, y una línea de texto dentro de ellos es
  /// una línea que nadie puede leer. Esa pantalla sigue colgando sus bandas
  /// por debajo de la carcasa (`contentSize`).
  static func tamañoDictando(for screen: HUDScreenSnapshot) -> CGSize {
    let reposo = reposoSize(for: screen)
    return CGSize(
      width: (reposo.width * (1 + ensancheAlDictar)).rounded(),
      height: (reposo.height * (1 + crecimientoAlDictar)).rounded()
    )
  }

  /// El alto del panel que abre el hover: la silueta más lo que pide una
  /// línea, con techo.
  ///
  /// Tiene su propia función porque va a crecer: el panel del hover es donde
  /// van a vivir las acciones que no son el dictado —reuniones, el último
  /// dictado, modos, ajustes— y ahí el mouse está encima a propósito, así que
  /// puede ser más alto que la muesca de dictado sin tapar nada de paso.
  ///
  /// Con datos a los costados crece además `altoDelDetalleDeDatos`: el panel
  /// es donde se lee el detalle de cada uno —la semanal, los reinicios— que
  /// en el costado no cabe.
  static func altoDelPanelDeHover(for screen: HUDScreenSnapshot) -> CGFloat {
    let detalle = screen.anchoDeLosLados > 0 ? altoDelDetalleDeDatos : 0
    return min(
      reposoSize(for: screen).height + altoDelContextoEnReposo + detalle,
      altoMaximoDelHover
    )
  }

  /// Lo que el detalle de los datos le suma al panel del hover: el nombre de
  /// cada dato y hasta dos filas —la ventana de cinco horas y la semanal de
  /// Codex; los tokens y el plan de Claude—, en letra de once puntos.
  static let altoDelDetalleDeDatos: CGFloat = 40

  /// The HUD shape's size: the header band, whatever voice-visual band the
  /// selected visual uses, the text band unless the visual replaces it, and
  /// the shaping band while a session carries one, clamped so a narrow
  /// display never gets a shape wider than its window.
  ///
  /// **Sólo contra una carcasa real, desde el 2026-09-22.** Ahí los primeros
  /// puntos del borde son el recorte físico y el contenido tiene que colgar
  /// por debajo, así que la forma abierta sigue siendo una pila de bandas.
  /// Una pantalla sin carcasa dibuja `tamañoDictando`: una sola línea, la
  /// muesca apenas más grande.
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
  static func zonaInteractiva(
    for screen: HUDScreenSnapshot,
    tamaño: CGSize,
    encuadre: EncuadreDeLaVentana = .abierta
  ) -> CGRect {
    let ventana = windowSize(for: screen, encuadre: encuadre)
    let ancho = min(tamaño.width, ventana.width)
    let alto = min(tamaño.height, ventana.height)
    return CGRect(
      x: (ventana.width - ancho) / 2,
      y: ventana.height - alto,
      width: ancho,
      height: alto
    )
  }

  /// La misma franja, pero en coordenadas de pantalla (origen abajo a la
  /// izquierda, como `NSEvent.mouseLocation`).
  ///
  /// Es lo que el monitor global del puntero compara para decidir si la
  /// ventana toma el mouse o lo deja pasar: con `ignoresMouseEvents` no hay
  /// `onHover` que consultar, así que la pregunta «¿está el puntero sobre la
  /// silueta?» se responde con geometría.
  static func siluetaEnPantalla(
    for screen: HUDScreenSnapshot,
    tamaño: CGSize,
    encuadre: EncuadreDeLaVentana = .abierta
  ) -> CGRect {
    let ventana = windowFrame(for: screen, encuadre: encuadre)
    let zona = zonaInteractiva(for: screen, tamaño: tamaño, encuadre: encuadre)
    return CGRect(
      x: ventana.minX + zona.minX,
      y: ventana.minY + zona.minY,
      width: zona.width,
      height: zona.height
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

  /// Cuánto crece la muesca hacia abajo cuando el hover abre el contexto: lo
  /// que pide una línea chica y su aire, y nada más.
  static let altoDelContextoEnReposo: CGFloat = 22

  /// El techo del panel que abre el hover. No es un tamaño, es un límite:
  /// pasar el mouse revela contexto, y algo que ocupa media pantalla sin que
  /// nadie lo haya pedido dejó de ser contexto.
  static let altoMaximoDelHover: CGFloat = 110

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
  /// Sized for the standard metrics whatever the user's HUD size, so a smaller
  /// shape simply centers itself inside it (ADR-0001). Lo que ya no es fijo es
  /// el **encuadre**: en reposo la ventana se ajusta a la muesca, y sólo crece
  /// cuando la forma se abre.
  static func windowFrame(
    for screen: HUDScreenSnapshot,
    encuadre: EncuadreDeLaVentana = .abierta
  ) -> CGRect {
    let size = windowSize(for: screen, encuadre: encuadre)
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
  static func windowSize(
    for screen: HUDScreenSnapshot,
    encuadre: EncuadreDeLaVentana = .abierta
  ) -> CGSize {
    switch encuadre {
    case .reposo:
      let silueta = reposoSize(for: screen)
      let holgura = holguraEnReposo(for: screen)
      return CGSize(
        width: min(silueta.width + holgura * 2, screen.frame.width),
        // Exactamente la silueta: **nada** debajo. Las alas cuelgan a los
        // lados y a la altura de la silueta, así que no piden alto; cada
        // punto de más sería barra de menús que la ventana se queda sin
        // dibujar nada en ella.
        height: silueta.height
      )
    case .abierta:
      let holgura = holguraDeRevelacion(for: screen)
      return CGSize(
        width: min(HUDMetrics.standard.contentWidth + holgura * 2, screen.frame.width),
        height: altoDeLaFormaMasAlta(for: screen) + holgura
      )
    }
  }

  /// El alto de la forma abierta más alta que esta pantalla puede dibujar, sin
  /// holgura ninguna. Es lo que la ventana abierta tiene que poder contener.
  ///
  /// Sin carcasa son dos candidatas y gana el panel del hover: la muesca
  /// dictando apenas crece (`tamañoDictando`) y el panel sí tiene contenido.
  static func altoDeLaFormaMasAlta(for screen: HUDScreenSnapshot) -> CGFloat {
    guard hasMeasuredNotch(for: screen) else {
      return max(tamañoDictando(for: screen).height, altoDelPanelDeHover(for: screen))
    }
    let metrics = HUDMetrics.standard
    // The shaping band rides outside the max: it can sit under either
    // alternative, so the tallest layout is whichever band stack wins plus it.
    return closedSize(for: screen).height
      + max(metrics.waveBandHeight, metrics.visualBandHeight + metrics.maxTextBandHeight)
      + metrics.shapingBandHeight
  }
}
