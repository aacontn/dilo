import CoreGraphics

/// Pure display selection for the Direct Dictation HUD. UI-free so tests can
/// drive it with plain display bounds, a pointer location, and an optional
/// target display ID.
enum HUDPlacement {
  /// Selection order: la pantalla que la persona eligió a mano si está
  /// conectada, después la del destino con foco si se sabe cuál es, después
  /// la que tiene el puntero, y si no la principal. The first element of
  /// `displays` is the main display, matching `NSScreen.screens`.
  ///
  /// La elección a mano va primero a propósito: quien la hizo quiere la
  /// muesca **ahí**, no donde ande el cursor. Si esa pantalla se desconectó,
  /// se cae al orden automático en vez de dejar a Dilo sin escenario.
  static func selectDisplay(
    from displays: [HUDScreenSnapshot],
    targetDisplayID: CGDirectDisplayID?,
    pointerLocation: CGPoint,
    pantallaElegida: String = ""
  ) -> HUDScreenSnapshot? {
    if !pantallaElegida.isEmpty,
     let elegida = displays.first(where: { $0.nombre == pantallaElegida }) {
      return elegida
    }
    if let targetDisplayID,
     let target = displays.first(where: { $0.id == targetDisplayID }) {
      return target
    }
    if let pointer = displays.first(where: { contains($0.frame, pointerLocation) }) {
      return pointer
    }
    return displays.first
  }

  /// Unlike `CGRect.contains`, treats the top and right edges as inside:
  /// `NSEvent.mouseLocation` reports exactly `maxY` when the cursor rests
  /// at the top edge of a screen.
  private static func contains(_ frame: CGRect, _ point: CGPoint) -> Bool {
    point.x >= frame.minX && point.x <= frame.maxX
      && point.y >= frame.minY && point.y <= frame.maxY
  }
}
