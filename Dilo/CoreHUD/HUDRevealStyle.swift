import SwiftUI

/// How the HUD enters and leaves. All styles keep the shape's top edge glued
/// to the screen edge: bounce is expressed in scale anchored at the top, never
/// in position, so overshoot can't open a gap above the shape.
enum HUDRevealStyle: String, CaseIterable {
  /// Slides down from outside the screen edge. No bounce — a position
  /// overshoot would detach the shape from the edge.
  case slide = "Slide"
  /// Unrolls downward out of the housing, stretching past its height and
  /// settling back. The bounciest of the set.
  case unfurl = "Unfurl"
  /// Inflates from the housing while fading in, with a soft overshoot.
  case bloom = "Bloom"
  /// Barely moves: fades in while drifting down the last few points.
  /// The most understated.
  case drift = "Drift"

  /// El nombre visible; el rawValue es la elección guardada y no se toca.
  var title: String {
    switch self {
    case .slide: String(localized: "Baja")
    case .unfurl: String(localized: "Se despliega")
    case .bloom: String(localized: "Se infla")
    case .drift: String(localized: "Se asoma")
    }
  }
}

extension HUDRevealStyle {
  /// La curva de Dilo-Tauri: `cubic-bezier(0.22, 1, 0.36, 1)` en 460 ms, la
  /// misma con la que el overlay hacía su `scard-pop` y su morph de ancho
  /// (`src/overlay/RecordingOverlay.css` del repo congelado). Es la referencia
  /// que Alfonso reconoce como «la animación que teníamos antes», así que es
  /// la base de los estilos que no rebotan.
  static let aperturaDeTauri = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.46)

  /// El cierre de Tauri: la tarjeta se iba en 240 ms de opacidad y 300 ms de
  /// escala. La muesca no se va, así que de eso queda el tiempo.
  static let cierreDeTauri = Animation.easeOut(duration: 0.3)

  /// Cómo abre la forma con este estilo, dentro del escenario permanente.
  ///
  /// Vive acá y no en `HUDSurface` porque es del estilo, y porque el render
  /// fuera de pantalla compila este archivo para dibujar los fotogramas de la
  /// apertura con la misma curva (`scripts/render-muesca.swift`): dos tablas
  /// de curvas son dos animaciones que se van a separar.
  var apertura: Animation {
    switch self {
    // Baja y Se asoma no rebotan: su carácter es la curva, y ésa es la de
    // Tauri — Se asoma más corta, porque lo suyo es no hacerse notar.
    case .slide: Self.aperturaDeTauri
    case .drift: .easeOut(duration: 0.24)
    case .unfurl: .spring(duration: 0.45, bounce: 0.3)
    case .bloom: .spring(duration: 0.4, bounce: 0.25)
    }
  }

  /// Y cómo se encoge. Siempre sin rebote: la forma vuelve a ser la muesca, y
  /// una muesca que rebota al cerrarse se lee como un error.
  var cierre: Animation {
    switch self {
    case .slide, .unfurl, .bloom: Self.cierreDeTauri
    case .drift: .easeIn(duration: 0.18)
    }
  }
}

extension HUDRevealStyle {
  /// La curva de Tauri evaluada en `t` (0–1), que es lo que un render fuera de
  /// pantalla necesita y una `Animation` no sabe decir.
  ///
  /// `Animation` es opaca: no hay forma de preguntarle cuánto ha avanzado, así
  /// que los cuatro fotogramas de `apertura-*.png` se calculan con esta, y por
  /// eso los coeficientes están escritos una sola vez, acá arriba.
  static func progresoDeTauri(_ t: Double) -> Double {
    bezier(t, x1: 0.22, y1: 1, x2: 0.36, y2: 1)
  }

  /// Una `cubic-bezier` de CSS: dos puntos de control entre (0,0) y (1,1), y
  /// `t` es tiempo, no el parámetro de la curva. Se despeja el parámetro por
  /// bisección —veinte vueltas dejan el error bajo una millonésima— porque un
  /// Newton se desboca donde la curva es casi plana, que es justo el final de
  /// ésta.
  static func bezier(
    _ t: Double,
    x1: Double,
    y1: Double,
    x2: Double,
    y2: Double
  ) -> Double {
    guard t > 0 else { return 0 }
    guard t < 1 else { return 1 }
    func eje(_ p: Double, _ a: Double, _ b: Double) -> Double {
      let q = 1 - p
      return 3 * q * q * p * a + 3 * q * p * p * b + p * p * p
    }
    var bajo = 0.0
    var alto = 1.0
    var p = t
    for _ in 0..<20 {
      p = (bajo + alto) / 2
      if eje(p, x1, x2) < t { bajo = p } else { alto = p }
    }
    return eje(p, y1, y2)
  }
}
