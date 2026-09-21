import SwiftUI

/// El nombre del modo que corre en esta sesión, abajo de la forma.
///
/// Reemplaza la línea «Transformar: Correo» en gris, que nombraba el
/// mecanismo en vez de la sesión y se leía como una fila de Ajustes que se
/// escapó al HUD. Acá va el nombre del modo y nada más, en mango —el acento
/// de Dilo—; sin modo no hay chip.
///
/// Sin shaders nuevos: el estado de «trabajando» se dice con opacidad y con
/// una animación de SwiftUI, no con otro `.metal` que compilar en el arranque.
struct HUDChipDeModo: View {
  struct Contenido: Equatable, Sendable {
    /// El nombre tal cual lo escribió la persona en Modos.
    let nombre: String
    /// True mientras las palabras ya dichas se están transformando.
    let trabajando: Bool
  }

  let contenido: Contenido
  var scale: CGFloat = 1
  /// El nivel del micrófono, 0–1, para que el chip acompañe la voz mientras
  /// se habla en vez de quedarse plano.
  var nivel: Double = 0
  var reduceMotion = false

  @State private var respira = false

  private var opacidad: Double {
    guard !contenido.trabajando else {
      // Nada de progreso inventado: `FoundationModels` no reporta ninguno.
      // Lo único que se promete es que algo está pasando.
      return reduceMotion ? 0.85 : (respira ? 1 : 0.55)
    }
    return 0.7 + 0.3 * min(max(nivel, 0), 1)
  }

  var body: some View {
    Text(contenido.nombre)
      .font(.system(size: 11 * scale, weight: .semibold, design: .rounded))
      .tracking(0.6 * scale)
      .lineLimit(1)
      .minimumScaleFactor(0.6)
      .foregroundStyle(DiloBrand.mango)
      .opacity(opacidad)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 12 * scale)
      .animation(.easeOut(duration: 0.12), value: nivel)
      .animation(
        contenido.trabajando && !reduceMotion
          ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil,
        value: respira
      )
      .onAppear { respira = contenido.trabajando }
      .onChange(of: contenido.trabajando) { _, trabajando in respira = trabajando }
      .allowsHitTesting(false)
      .accessibilityLabel(
        contenido.trabajando
          ? Text("Transformando con \(contenido.nombre)")
          : Text("Modo \(contenido.nombre)")
      )
  }
}
