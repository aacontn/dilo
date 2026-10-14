import SwiftUI

/// La silueta de la muesca en **un solo** `Shape`: el cuerpo, las dos curvas
/// cóncavas que la funden con el borde de la pantalla y las esquinas de abajo.
///
/// Antes la forma eran tres piezas: un `UnevenRoundedRectangle` y dos
/// `NotchFilletShape` pegadas encima con `offset`. Tres piezas son tres
/// lugares que hay que mover juntos —el negro, el recorte del contenido, lo
/// que algún día sea vidrio— y una costura de antialias entre el cuerpo y
/// cada ala. Con una sola trayectoria todos leen el mismo contorno, y los dos
/// radios se animan juntos.
///
/// **Las alas se dibujan fuera del rectángulo**, a los costados, igual que
/// antes: el cuerpo mide lo que mide el estado y el layout no cambia. Es la
/// regla de la ventana en reposo, que mide exactamente la silueta más lo que
/// las alas cuelgan (`HUDNotchGeometry.holguraEnReposo`).
///
/// Las piezas son las mismas de antes y no una aproximación: el cuerpo con
/// esquinas continuas y cada ala con la geometría exacta de
/// `NotchFilletShape`, en una sola trayectoria. Por eso cambiar de tres piezas a una no mueve
/// un píxel del reposo (`scripts/render-muesca.sh` lo compara).
struct SiluetaDeLaMuesca: Shape {
  enum Estilo: Equatable, Sendable {
    /// Nace del borde de arriba: notch real o simulado. Tope recto y alas.
    case muesca
    /// Flota separada y se cierra por los cuatro lados: la píldora bajo la
    /// barra, y las píldoras de los asientos.
    case isla
  }

  var estilo: Estilo
  /// Radio de las dos curvas cóncavas de arriba. Sólo en `.muesca`.
  var radioDeHombro: CGFloat
  /// Radio de las esquinas de abajo (y de las de arriba en `.isla`).
  var radioInferior: CGFloat
  /// Cuánto se estira la silueta más allá de su marco hacia cada lado, para
  /// llevar un segmento al costado (`HUDSegmentosAlCostado`). Las alas se
  /// corren a los extremos nuevos: una sola pieza, sin hueco. Sólo en
  /// `.muesca`.
  var costados = CostadosDeLaSilueta()
  /// Si dibuja las alas. Sin ellas es el cuerpo solo, pero con las esquinas
  /// que el cuerpo tiene **con** alas: cuando los dos radios no caben se
  /// achican juntos, y el vidrio o el recorte tienen que seguir el mismo
  /// borde que el negro.
  var conAlas = true

  var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
    get {
      AnimatablePair(
        AnimatablePair(radioDeHombro, radioInferior),
        AnimatablePair(costados.izquierda, costados.derecha)
      )
    }
    set {
      radioDeHombro = newValue.first.first
      radioInferior = newValue.first.second
      costados = CostadosDeLaSilueta(izquierda: newValue.second.first, derecha: newValue.second.second)
    }
  }

  /// La misma silueta sin alas ni costados: lo que recorta el contenido y lo
  /// que dibuja lo que no toca ningún borde.
  var sinHombros: SiluetaDeLaMuesca {
    SiluetaDeLaMuesca(estilo: estilo, radioDeHombro: radioDeHombro, radioInferior: radioInferior, conAlas: false)
  }

  nonisolated func path(in rect: CGRect) -> Path {
    guard rect.width > 0, rect.height > 0 else { return Path() }
    var abajo = max(0, radioInferior)
    switch estilo {
    case .isla:
      return UnevenRoundedRectangle(
        topLeadingRadius: abajo,
        bottomLeadingRadius: abajo,
        bottomTrailingRadius: abajo,
        topTrailingRadius: abajo,
        style: .continuous
      )
      .path(in: rect)
    case .muesca:
      let rect = CGRect(
        x: rect.minX - max(0, costados.izquierda),
        y: rect.minY,
        width: rect.width + max(0, costados.izquierda) + max(0, costados.derecha),
        height: rect.height
      )
      // Los dos radios se achican juntos si no caben uno sobre el otro, como
      // hace Droppy con su forma (`DroppyNotchShellShape.path(in:)`): un ala
      // que baja más allá de donde empieza la esquina de abajo deja una
      // muesca entre las dos. Con los radios de reposo y de dictar caben
      // siempre (9 + 11 en 24), así que esto sólo toca la forma abierta.
      var hombro = min(max(0, radioDeHombro), rect.height)
      if hombro + abajo > rect.height, hombro + abajo > 0 {
        let escala = rect.height / (hombro + abajo)
        hombro *= escala
        abajo *= escala
      }
      let cuerpo = UnevenRoundedRectangle(
        topLeadingRadius: 0,
        bottomLeadingRadius: abajo,
        bottomTrailingRadius: abajo,
        topTrailingRadius: 0,
        style: .continuous
      )
      .path(in: rect)
      // Un ala más alta que el cuerpo se asomaría por debajo de él: ya
      // quedó acotada arriba.
      guard conAlas, hombro > 0 else { return cuerpo }
      let izquierda = NotchFilletShape(side: .leading).path(
        in: CGRect(x: rect.minX - hombro, y: rect.minY, width: hombro, height: hombro)
      )
      let derecha = NotchFilletShape(side: .trailing).path(
        in: CGRect(x: rect.maxX, y: rect.minY, width: hombro, height: hombro)
      )
      // Sumadas y no unidas: las tres piezas se tocan sin pisarse, y la unión
      // booleana de `Path` aplana las curvas y corre el antialias del borde
      // —medio punto en el costado del cuerpo, medido contra los PNG de
      // antes—.
      var silueta = cuerpo
      silueta.addPath(izquierda)
      silueta.addPath(derecha)
      return silueta
    }
  }
}

extension SiluetaDeLaMuesca {
  /// La silueta que esta pantalla dibuja: muesca con alas contra una carcasa
  /// o en el notch simulado, isla en la píldora bajo la barra.
  ///
  /// `radioDeHombro` nil es el de la carcasa (`HUDNotchGeometry.filletSize`);
  /// la forma abierta pide los hombros grandes de `FormaAbierta`.
  static func para(
    _ screen: HUDScreenSnapshot,
    radioInferior: CGFloat,
    radioDeHombro: CGFloat? = nil,
    costados: CostadosDeLaSilueta = CostadosDeLaSilueta()
  ) -> SiluetaDeLaMuesca {
    SiluetaDeLaMuesca(
      estilo: HUDNotchGeometry.closesAtTop(for: screen) ? .isla : .muesca,
      radioDeHombro: radioDeHombro ?? HUDNotchGeometry.filletSize(for: screen),
      radioInferior: radioInferior,
      costados: costados
    )
  }
}

/// Cuánto se estira la silueta hacia cada lado más allá del marco de su
/// cuerpo, en puntos. Cero y cero es la muesca de siempre.
struct CostadosDeLaSilueta: Equatable, Sendable {
  var izquierda: CGFloat = 0
  var derecha: CGFloat = 0

  var total: CGFloat { izquierda + derecha }
}
