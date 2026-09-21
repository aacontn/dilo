import Foundation
import Testing
@testable import Dilo

/// Un juego de sonidos se elige por su `rawValue`, que es también el prefijo de
/// sus tres archivos en el bundle (`<rawValue>Begin/End/Paste.wav`). Si uno
/// falta, `HUDSounds` no falla: se queda callado, y un aviso que no suena es
/// difícil de notar en una sesión de dictado. Este test es el que lo nota.
@MainActor
struct HUDSoundsTests {
  @Test(arguments: DictationSoundSet.allCases)
  func cadaJuegoTraeSusTresArchivos(_ juego: DictationSoundSet) {
    for momento in ["Begin", "End", "Paste"] {
      let nombre = "\(juego.rawValue)\(momento)"
      #expect(
        Bundle.main.url(forResource: nombre, withExtension: "wav") != nil,
        "falta \(nombre).wav en el bundle"
      )
    }
  }

  /// Marimba es el default: si sus archivos no llegan al bundle, la app se
  /// instala muda de fábrica.
  @Test func marimbaEsReproducibleYTieneDuracion() {
    let sounds = HUDSounds()
    #expect(sounds.hasPreviewSounds(for: .marimba))
    #expect(sounds.beginDuration(for: .marimba) > 0)
  }
}
