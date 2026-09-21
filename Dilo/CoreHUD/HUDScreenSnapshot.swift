import CoreGraphics

/// Pure geometry of one display, captured from `NSScreen` so the notch math
/// and display selection stay UI-free and testable.
struct HUDScreenSnapshot: Equatable, Sendable {
  let id: CGDirectDisplayID
  /// Global screen coordinates (bottom-left origin, y up).
  let frame: CGRect
  let safeAreaTop: CGFloat
  let auxiliaryTopLeftArea: CGRect?
  let auxiliaryTopRightArea: CGRect?
  /// This display's own reserved strip for the system menu bar, i.e. `frame`
  /// minus `visibleFrame` at the top. Zero on a display that shows no menu
  /// bar of its own. Distinct from `safeAreaTop`: that is the *notch*, a
  /// housing the HUD hugs; this is the *menu bar*, a bar of status items the
  /// HUD must clear (issue #83).
  let menuBarHeight: CGFloat
  /// Qué se dibuja acá cuando esta pantalla no tiene notch.
  ///
  /// Viaja con la pantalla en vez de ser un parámetro de cada función porque
  /// la ventana anfitriona, el contorno de la forma y el relleno de arriba
  /// tienen que estar de acuerdo: un parámetro suelto se olvida en uno de los
  /// tres y la forma queda pegada arriba con las esquinas redondeadas.
  /// Con notch real no se mira. El default es el notch simulado desde el
  /// 2026-09-21: el escenario de Dilo es el notch, y en una pantalla sin
  /// carcasa la imitación es lo que más se le parece.
  var estiloSinNotch: HUDEstiloSinNotch = .notchSimulado
}
