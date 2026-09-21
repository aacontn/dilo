import CoreGraphics

/// The HUD shape's dimensions at the user's chosen HUD size.
///
/// A full-size shape costs nothing on a MacBook, where the housing band sits
/// behind hardware that already covers those pixels. On a display without a
/// notch every one of those points is screen the user was working in, so the
/// shape scales down as one piece rather than dropping its voice visual.
///
/// The housing band and the fillets are deliberately absent here: neither
/// scales. The housing height is hardware on a notched display and menu-bar
/// clearance everywhere else, and a fillet exists to meet a physical bezel.
struct HUDMetrics: Equatable {
  /// The smallest shape the user can pick: 108 points wide.
  ///
  /// This is narrower than any notch, and deliberately so. It is reachable on
  /// a display that has no housing to cover, which is where a smaller HUD is
  /// actually wanted — there every point the shape covers is screen the user
  /// was working in. A display with a notch raises its own floor from what it
  /// measures (`HUDNotchGeometry.minimumScale(for:)`), and a layout built
  /// around draft text raises one of its own (`minimumReadableScale`).
  static let minimumScale: CGFloat = 0.2
  static let maximumScale: CGFloat = 1

  /// The smallest size that still leaves the draft readable. Below this the
  /// draft falls under 6 points, which is not text anyone reads — the
  /// sizes beneath it are for the visuals that replace the draft entirely.
  static let minimumReadableScale: CGFloat = 0.4

  /// The floor for a given voice visual. Compact and Edge Glow + Draft are
  /// built around the live draft, and Reduce Motion restores the draft for
  /// every visual, so those stop where the text stops being legible. Waveform
  /// and Edge Glow replace the draft entirely and go all the way down.
  ///
  /// Read from the session's own settings rather than from what the HUD happens
  /// to be showing, so a shape cannot change size partway through a session.
  static func minimumScale(for visual: HUDVoiceVisualStyle, reduceMotion: Bool) -> CGFloat {
    visual.showsDraftWhileListening || reduceMotion ? minimumReadableScale : minimumScale
  }

  /// The unscaled shape. The host window is sized from this, so the window
  /// stays fixed while the shape inside it changes size.
  static let standard = HUDMetrics(scale: 1)

  let scale: CGFloat

  init(scale: CGFloat) {
    self.scale = min(max(scale, Self.minimumScale), Self.maximumScale)
  }


  /// Width of the HUD shape; the housing sits centered inside it.
  ///
  /// **Bajó de 540 a 400 el 2026-09-21**: con la muesca ya arreglada, la
  /// forma abierta seguía siendo un panel de media barra de menús. Es el
  /// ancho de las apps de notch que sirven de referencia, y sigue siendo más
  /// del doble de la silueta en reposo, que es lo que hace que crecer se
  /// note.
  var contentWidth: CGFloat { 400 * scale }

  /// Height of the strip below the housing where the draft text lives, kept
  /// out of the housing band so text never collides with the camera.
  ///
  /// Una línea de 13 puntos con cuatro de aire arriba y abajo. Era una de 15
  /// con nueve de aire: treinta y seis puntos de banda para una sola línea,
  /// que es de dónde salía la mitad del alto de sobra.
  var textBandHeight: CGFloat { 26 * scale }

  /// The tallest the text band ever gets: the downward-growing long-draft
  /// variant caps at a few wrapped lines. Sólo con carcasa real: en la muesca
  /// el borrador es siempre una línea (`DictationHUDShellView`).
  var maxTextBandHeight: CGFloat { 88 * scale }

  /// Height of the quiet level-meter strip (the Reduce Motion visual),
  /// shown between the housing and the text band.
  var visualBandHeight: CGFloat { 20 * scale }

  /// Edge Glow + Draft hanging band: 24-point type plus 5 points above
  /// y abajo. Still tall enough that the line does not kiss the stroke.
  var glowDraftStageHeight: CGFloat { 34 * scale }

  /// Height of the waveform band.
  ///
  /// Sesenta y cuatro puntos eran el escenario de concierto que la forma
  /// abierta no necesita: la onda dice «te estoy oyendo», no dibuja un
  /// espectro para mirar. Veinticuatro alcanzan para leer el nivel y para que
  /// un micrófono muerto se vea distinto del silencio.
  var waveBandHeight: CGFloat { 24 * scale }

  /// Height of the shaping label's band, the shape's bottom strip while a
  /// session can cycle its shaping pick. Sized for an 11-point caption, not
  /// for reading: the pick is context, and a band big enough to read first
  /// took the glance the visual and the draft are there for.
  var shapingBandHeight: CGFloat { 14 * scale }

  var bottomCornerRadius: CGFloat { 18 * scale }
}
