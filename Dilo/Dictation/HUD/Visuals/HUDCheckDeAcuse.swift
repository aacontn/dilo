import SwiftUI

/// El check que acusa un dictado bien terminado, donde estaba la onda.
///
/// Es el `.scheck` del overlay de Dilo-Tauri, traído tal cual: el mismo
/// trazado sobre un lienzo de 16×16 —`M3.5 8.5 L6.5 11.5 L12.5 4.5`—, el
/// mismo grosor de 1,8, las mismas puntas y uniones redondeadas. Allá
/// acusaba una nota guardada; acá acusa un dictado que aterrizó donde tenía
/// que aterrizar.
///
/// Sale del veredicto del 2026-09-22: «al finalizar de dictar me sale Listo y
/// Copiar al lado, porque también es innecesario; podría reemplazarse la onda
/// por un check o algo así como lo hacíamos en el Tauri». La muesca no crece
/// para decirlo y no ofrece ningún botón: el check ocupa el lugar de la onda
/// dentro de la misma forma y se va en menos de un segundo
/// (`MaquinaDelNotch.duracionDelAcuse`).
///
/// **En menta y no en mango**, que es lo único que cambia respecto de Tauri.
/// Allá el overlay tenía un solo acento y el check lo usaba; acá el mango es
/// el acento de lo que está pasando —la onda, el cursor, el punto de reposo—
/// y la menta es la de lo que salió bien (`DiloBrand`). Un check del mismo
/// color que la onda que reemplaza no se lee como un cambio de estado.
struct HUDCheckDeAcuse: View {
  /// El lado del check, en puntos. Quince en Tauri; acá lo manda quien
  /// reparte la línea, que sabe cuánto alto tiene la muesca.
  var lado: CGFloat = 15
  var reduceMotion = false

  /// Cuánto tarda en trazarse, en segundos. Corto: el acuse entero dura
  /// 700 ms, así que una entrada larga se comería la mitad de su propia vida.
  static let trazado = 0.18

  @State private var dibujado = false

  var body: some View {
    TrazoDelCheck()
      .trim(from: 0, to: dibujado || reduceMotion ? 1 : 0)
      .stroke(
        DiloBrand.menta,
        style: StrokeStyle(lineWidth: 1.8 * (lado / 15), lineCap: .round, lineJoin: .round)
      )
      .frame(width: lado, height: lado)
      .animation(reduceMotion ? nil : .easeOut(duration: Self.trazado), value: dibujado)
      .onAppear { dibujado = true }
      .accessibilityHidden(true)
  }
}

/// El trazado de `.scheck`, en su lienzo original de 16×16 y escalado al
/// tamaño que le toque. Los tres puntos son los del SVG de Tauri; copiarlos
/// es lo que hace que el check se vea idéntico al que Alfonso recuerda.
struct TrazoDelCheck: Shape {
  func path(in rect: CGRect) -> Path {
    let k = min(rect.width, rect.height) / 16
    var path = Path()
    path.move(to: CGPoint(x: rect.minX + 3.5 * k, y: rect.minY + 8.5 * k))
    path.addLine(to: CGPoint(x: rect.minX + 6.5 * k, y: rect.minY + 11.5 * k))
    path.addLine(to: CGPoint(x: rect.minX + 12.5 * k, y: rect.minY + 4.5 * k))
    return path
  }
}

#Preview("Acuse · check") {
  HUDCheckDeAcuse()
    .padding(20)
    .background(Color.black)
}
