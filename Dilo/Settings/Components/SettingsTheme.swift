import AppKit
import SwiftUI

/// Los tokens de marca de Dilo. Tinta, mango y menta salen del ícono maestro
/// (`brand/dilo-icon.svg`) y de la landing; están acá una sola vez para que la
/// superficie SwiftUI y los `NSImage` del status item no puedan derivar a dos
/// naranjas distintos.
///
/// El acento es **mango**: es el color de las acciones y el de la píldora. Las
/// paletas del Edge Glow nunca recolorean el caparazón (CONTEXT.md).
enum DiloBrand {
  /// Tinta `#0D1117` — el fondo del ícono y la base de toda superficie oscura.
  static let tintaColor = NSColor(red: 0x0D / 255, green: 0x11 / 255, blue: 0x17 / 255, alpha: 1)
  /// Mango `#FF9E1B` — acciones, el cursor del ícono, la píldora.
  static let mangoColor = NSColor(red: 0xFF / 255, green: 0x9E / 255, blue: 0x1B / 255, alpha: 1)
  /// Menta `#2EE6A8` — la onda de audio; confirma, no manda.
  static let mentaColor = NSColor(red: 0x2E / 255, green: 0xE6 / 255, blue: 0xA8 / 255, alpha: 1)
  /// Rojo `#FF5C5C` — grabando. Es la punta de la onda de brasas y nada más:
  /// en Dilo no es un color de error, es el que dice que el micrófono está
  /// abierto (viene de `--dilo-rojo` del repo Tauri).
  static let rojoColor = NSColor(red: 0xFF / 255, green: 0x5C / 255, blue: 0x5C / 255, alpha: 1)

  static let tinta = Color(nsColor: tintaColor)
  static let mango = Color(nsColor: mangoColor)
  static let menta = Color(nsColor: mentaColor)
  static let rojo = Color(nsColor: rojoColor)
}

/// La paleta oscura de la ventana de Ajustes: los tokens de los que dibuja
/// cada componente y la sección de Actividad.
enum SettingsTheme {
  static let background = Color(red: 0.025, green: 0.027, blue: 0.035)
  static let sidebar = Color(red: 0.035, green: 0.038, blue: 0.049)
  static let card = Color(red: 0.065, green: 0.069, blue: 0.087)
  static let accent = DiloBrand.mango
  /// El mismo mango para lo que se dibuja en un `NSImage` en vez de en
  /// SwiftUI: los íconos del status item.
  static let accentColor = DiloBrand.mangoColor
}
