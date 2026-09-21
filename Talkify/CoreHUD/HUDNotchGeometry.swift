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
  static let fallbackClosedSize = CGSize(width: 185, height: 32)

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

  /// The housing footprint, falling back to the simulated stand-in. Never
  /// scaled by the HUD size: this height is hardware on a notched display,
  /// and the menu bar's clearance on every other one.
  static func closedSize(for screen: HUDScreenSnapshot) -> CGSize {
    measuredClosedSize(for: screen) ?? fallbackClosedSize
  }

  /// Whether this display has a housing of its own for the HUD to hug.
  static func hasMeasuredNotch(for screen: HUDScreenSnapshot) -> Bool {
    measuredClosedSize(for: screen) != nil
  }

  /// The HUD shape's size: the housing band, whatever voice-visual band the
  /// selected visual uses, the text band unless the visual replaces it, and
  /// the shaping band while a session carries one, clamped so a narrow
  /// display never gets a shape wider than its window.
  /// - Parameter housingBandHeight: El alto de la banda de arriba cuando no
  ///   es la carcasa. La píldora de Dilo no tiene cámara que esquivar, así que
  ///   cambia esos 32 puntos vacíos por una corona mango más baja; con notch
  ///   se deja en nil y manda el hardware.
  static func contentSize(
    for screen: HUDScreenSnapshot,
    metrics: HUDMetrics,
    visualBandHeight: CGFloat,
    includesTextBand: Bool,
    shapingBandHeight: CGFloat,
    housingBandHeight: CGFloat? = nil
  ) -> CGSize {
    CGSize(
      width: min(metrics.contentWidth, windowSize(for: screen).width),
      height: (housingBandHeight ?? closedSize(for: screen).height)
        + visualBandHeight
        + (includesTextBand ? metrics.textBandHeight : 0)
        + shapingBandHeight
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

  /// Size of the concave corner that flares the shape into the bezel, and
  /// zero on a display with no housing to flare into — there the curve reads
  /// as two detached tabs (ADR-0001: the simulated notch omits fillets).
  /// Unscaled: the flare has to match a physical bezel curve.
  static func filletSize(for screen: HUDScreenSnapshot) -> CGFloat {
    hasMeasuredNotch(for: screen) ? 11 : 0
  }

  /// Clearance between the true top of the screen and the housing, on a
  /// display with no measured notch.
  ///
  /// A real notch already sits in its own housing, clear of wherever the
  /// system draws status items. The simulated stand-in has no such housing:
  /// pinned flush to the screen's top edge it draws directly over the menu
  /// bar, hiding whatever status item sits under it — including Talkify's
  /// own (issue #83). So there the shape hangs just below the menu bar
  /// instead of over it.
  ///
  /// En Dilo eso no es una preferencia con dos lados buenos: la píldora
  /// **siempre** va debajo (spec §8, `AGENTS.md`). Alfonso dictó diez minutos
  /// con la de Talkify encima y le tapó sus propios status items en dos
  /// monitores sin notch, que es el 80 % de su uso. El ajuste sigue existiendo
  /// para quien quiera la imitación exacta del notch, pero viene encendido.
  /// - Parameter clearsMenuBar: Whether a display with no housing hangs the
  ///   shape below the menu bar instead of over it. Over it looks like the
  ///   notch it imitates; below it keeps the status items reachable, which is
  ///   what someone with a crowded menu bar needs (issue #83).
  static func topInset(for screen: HUDScreenSnapshot, clearsMenuBar: Bool) -> CGFloat {
    guard !hasMeasuredNotch(for: screen) else { return 0 }
    guard clearsMenuBar else { return 0 }
    return max(screen.menuBarHeight, menuBarClearanceFloor) + pillDetachment
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
  /// forma nace del recorte y no tiene borde propio ahí— y el mismo radio de
  /// abajo en la píldora, que flota separada y se cierra por los cuatro
  /// lados.
  static func topCornerRadius(for screen: HUDScreenSnapshot, metrics: HUDMetrics) -> CGFloat {
    drawsPill(for: screen) ? metrics.bottomCornerRadius : 0
  }

  /// The host window's frame: content size plus shadow slack, centered and
  /// pinned to the top (below the menu bar on a display with no notch of its
  /// own), clamped to the screen width.
  ///
  /// Sized for the standard metrics whatever the user's HUD size, so the
  /// window stays fixed per display (ADR-0001) and a smaller shape simply
  /// centers itself inside it. The window is invisible and click-through, so
  /// the unused slack costs nothing.
  static func windowFrame(
    for screen: HUDScreenSnapshot,
    clearsMenuBar: Bool
  ) -> CGRect {
    let size = windowSize(for: screen)
    return CGRect(
      x: screen.frame.midX - size.width / 2,
      y: screen.frame.maxY - size.height - topInset(for: screen, clearsMenuBar: clearsMenuBar),
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
