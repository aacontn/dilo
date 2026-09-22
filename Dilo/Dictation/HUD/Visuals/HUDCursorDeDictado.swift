import SwiftUI

/// El cursor mango que parpadea al final del texto parcial mientras el
/// micrófono está abierto.
///
/// Es el `.scaret` del overlay de Dilo-Tauri: dos puntos de ancho, el alto de
/// una línea, mango, y un parpadeo de 1,05 s en `steps(1)` —encendido o
/// apagado, nunca a media luz—. Dice lo que ninguna onda dice: que lo escrito
/// **sigue creciendo**. Por eso se va en cuanto la sesión deja de escuchar: un
/// cursor sobre un texto que ya no cambia promete palabras que no van a venir.
///
/// Con Reducir movimiento se queda encendido. La barra sigue marcando el final
/// del texto; lo que se saca es el parpadeo, que es el movimiento.
struct HUDCursorDeDictado: View {
  /// El período del parpadeo, en segundos (`scaret-blink 1.05s steps(1)`).
  static let periodo: TimeInterval = 1.05

  var scale: CGFloat = 1
  var reduceMotion = false

  var body: some View {
    Group {
      if reduceMotion {
        barra(visible: true)
      } else {
        // `steps(1)` es un interruptor, no una curva: la mitad del período
        // encendido y la otra apagado. Un `TimelineView` periódico lo dice
        // igual y no deja una animación infinita corriendo en el árbol.
        TimelineView(.periodic(from: .now, by: Self.periodo / 2)) { contexto in
          barra(visible: encendido(en: contexto.date))
        }
      }
    }
    .accessibilityHidden(true)
  }

  private func barra(visible: Bool) -> some View {
    RoundedRectangle(cornerRadius: 1 * scale, style: .continuous)
      .fill(DiloBrand.mango)
      .frame(width: 2 * scale, height: 15 * scale)
      .opacity(visible ? 1 : 0)
  }

  /// Si en este instante el cursor está encendido. Puro para poder afirmar el
  /// parpadeo sin mirarlo.
  static func encendido(en fecha: Date, periodo: TimeInterval = HUDCursorDeDictado.periodo) -> Bool {
    let fase = fecha.timeIntervalSinceReferenceDate
      .truncatingRemainder(dividingBy: periodo)
    return fase < periodo / 2
  }

  private func encendido(en fecha: Date) -> Bool {
    Self.encendido(en: fecha)
  }
}
