import SwiftUI

/// La onda de brasas: la que Dilo tenía en el overlay de Tauri, traída a la
/// muesca.
///
/// Nueve barras gordas con degradado mango→rojo y un halo tenue, que es lo que
/// las hace leerse como brasas y no como un ecualizador. La altura la manda el
/// nivel del micrófono; encima corre un vaivén propio por barra —multiplicativo,
/// así que hablar y respirar se componen— para que en silencio la onda siga
/// viva en vez de quedar como una fila de palitos apagados.
///
/// Es una traducción, no una reinterpretación: los números salen de
/// `src/overlay/RecordingOverlay.css` del repo Tauri (`.swave` y `.swave i`,
/// `@keyframes wsway`) y de la fórmula de altura de `RecordingOverlay.tsx`. Lo
/// único que cambia es el fondo: allá flotaba sobre un vidrio claro y acá vive
/// adentro de la muesca negra, así que el degradado se lee más brillante y no
/// necesita el tinte que lo sostenía.
///
/// El micrófono muerto rompe el trato entero: ámbar quieto, sin vaivén
/// (CONTEXT.md — un micrófono muerto tiene que verse distinto del silencio, y
/// una onda que respira sola diría lo contrario).
struct HUDOndaDeBrasas: View {
  /// Nueve, como en Tauri. Con menos la ola no viaja y con más las barras se
  /// adelgazan hasta volver a ser un ecualizador.
  static let barras = 9

  /// El período del vaivén de cada barra, en segundos, y su desfase. Desiguales
  /// a propósito: con todas iguales las nueve suben y bajan juntas y parece un
  /// latido.
  private static let periodos: [Double] = [1.3, 0.9, 1.1, 0.7, 1.0, 0.8, 1.2, 0.9, 1.15]
  private static let desfases: [Double] = [0, 0.5, 0.2, 0.8, 0.4, 0.9, 0.1, 0.6, 0.3]

  /// Las medidas de `.swave i`, sin escalar: quien llama aplica la escala.
  private static let anchoDeBarra: CGFloat = 5
  private static let separacion: CGFloat = 4
  private static let radio: CGFloat = 3
  private static let altoMinimo: CGFloat = 7
  private static let altoMaximo: CGFloat = 16
  /// El alto de la banda en Tauri (`.swave { height: 20px }`). La franja de la
  /// muesca puede ser más alta; la onda se queda con lo suyo y se centra.
  static let altoDeLaBanda: CGFloat = 20

  let content: DictationHUDContent
  var scale: CGFloat = 1
  var reduceMotion = false

  var body: some View {
    Group {
      if reduceMotion {
        barrasQuietas
      } else {
        TimelineView(.animation) { contexto in
          let t = contexto.date.timeIntervalSinceReferenceDate
          fila { indice in vaiven(indice, en: t) }
        }
      }
    }
    .frame(height: Self.altoDeLaBanda * scale)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var barrasQuietas: some View {
    fila { _ in 1 }
  }

  private func fila(vaiven: @escaping (Int) -> CGFloat) -> some View {
    HStack(alignment: .center, spacing: Self.separacion * scale) {
      ForEach(0..<Self.barras, id: \.self) { indice in
        barra(indice, vaiven: vaiven(indice))
      }
    }
    // El alto se anima solo, no con el resto de la vista: `transition: height
    // 80ms linear` en Tauri. Más largo y la onda va atrasada respecto de la
    // voz; más corto y tiembla.
    .animation(.linear(duration: 0.08), value: content.levelHistory)
  }

  private func barra(_ indice: Int, vaiven: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: Self.radio * scale, style: .continuous)
      .fill(relleno)
      .frame(width: Self.anchoDeBarra * scale, height: alto(indice) * scale)
      // El halo de `box-shadow: 0 0 8px` — la mitad en radio de sombra, que es
      // la conversión de siempre entre el blur de CSS y el de Core Graphics.
      .shadow(color: halo, radius: 4 * scale)
      .scaleEffect(y: vaiven, anchor: .center)
  }

  /// Mango abajo, rojo arriba: el degradado de `--s-wave-lo`→`--s-wave-hi`.
  /// Con el micrófono muerto no hay brasa que mostrar.
  private var relleno: LinearGradient {
    guard content.isAudioAlive else {
      return LinearGradient(
        colors: [
          HUDVisualTokens.deadMicAmber.opacity(0.55),
          HUDVisualTokens.deadMicAmber.opacity(0.55),
        ],
        startPoint: .bottom,
        endPoint: .top
      )
    }
    return LinearGradient(
      colors: [DiloBrand.mango, DiloBrand.rojo],
      startPoint: .bottom,
      endPoint: .top
    )
  }

  private var halo: Color {
    content.isAudioAlive ? DiloBrand.rojo.opacity(0.5) : .clear
  }

  /// La altura cruda de una barra, tal cual la calculaba el overlay:
  /// `max(7, min(16, 6 + v^0.7 * 11))`. La raíz de 0,7 es lo que hace que una
  /// voz normal use casi toda la banda en vez de quedarse abajo.
  func alto(_ indice: Int) -> CGFloat {
    let v = Double(nivel(indice))
    let crudo = 6 + pow(max(0, v), 0.7) * 11
    return min(max(Self.altoMinimo, crudo), Self.altoMaximo)
  }

  /// Las nueve barras son las nueve lecturas más recientes, la más vieja a la
  /// izquierda. Tauri repartía dieciséis buckets de FFT; acá el historial es de
  /// tiempo, así que la ola viaja hacia la derecha en vez de por frecuencia —
  /// que es lo mismo que se ve, y es el historial que el resto de los estilos
  /// ya comparte.
  private func nivel(_ indice: Int) -> Float {
    let historial = content.levelHistory
    guard historial.count >= Self.barras else {
      return historial.indices.contains(indice) ? historial[indice] : 0
    }
    return historial[historial.count - Self.barras + indice]
  }

  /// El vaivén de `@keyframes wsway`: `scaleY` entre 0,55 y 1,7, con
  /// `ease-in-out`, que es una sinusoide. Con el micrófono muerto no hay
  /// vaivén: la onda se queda quieta y ámbar.
  func vaiven(_ indice: Int, en t: TimeInterval) -> CGFloat {
    guard content.isAudioAlive else { return 1 }
    let periodo = Self.periodos[indice % Self.periodos.count]
    let desfase = Self.desfases[indice % Self.desfases.count]
    let fase = (t / periodo + desfase).truncatingRemainder(dividingBy: 1)
    // 0 y 1 en 0,55; 0,5 en 1,7.
    let curva = (1 - cos(fase * 2 * .pi)) / 2
    return 0.55 + (1.7 - 0.55) * curva
  }
}
