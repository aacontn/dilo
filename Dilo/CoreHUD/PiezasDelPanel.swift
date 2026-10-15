import SwiftUI

// Las piezas del panel del hover, con valores sueltos y sin el contenido del
// HUD: las usa `HUDPanelDelHover` y las compila también el render de la
// muesca (`scripts/render-muesca.sh`), así la lámina dibuja las mismas vistas
// y no una copia que se separa.
//
// **La jerarquía es la de Droppy** (2026-10-15): lo principal grande, en
// blanco y en negrita —lo último dictado, el modo elegido—; lo secundario en
// gris; los controles en blanco. El color va sólo en un detalle chico: el
// ícono del último dictado, el ✓ de copiado, la reunión que empieza. Hasta la
// 0.4.5 todo era letra de 8 a 10,5 puntos casi del mismo gris, con un
// encabezado «RECIENTES» y tarjetas: amontonado, y sin nada que mirar
// primero.

/// Lo último que pasó por Dilo, grande: el «Blue Hour · Nova Coast» del
/// reproductor de Droppy. Un ícono con el degradado de la paleta, el texto en
/// negrita y debajo, en gris, qué es y cuándo; a la derecha, copiar.
struct HUDUltimoDelPanel: View {
  let titulo: String
  /// Lo secundario: «Dictado · hace 2 min». Nil, sólo el título.
  let subtitulo: String?
  /// El ícono del cuadro: la onda para un dictado, el portapapeles para algo
  /// copiado.
  var esDictado = true
  /// Si ofrece copiar. Sin recientes, el panel nombra el modo o a Dilo y no
  /// hay nada que copiar.
  var ofreceCopiar = true
  /// Si se acaba de copiar: el botón dice ✓ en el color del acuse.
  var copiado = false

  var body: some View {
    let paleta = PaletaDeDilo.actual
    HStack(spacing: 11) {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(Color.white.opacity(0.09))
        .frame(width: 32, height: 32)
        .overlay {
          Image(systemName: esDictado ? "waveform" : "doc.on.clipboard")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(LinearGradient(
              colors: [paleta.ondaBase.color, paleta.ondaPunta.color],
              startPoint: .bottomLeading,
              endPoint: .topTrailing
            ))
        }
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: titulo)
          .font(.system(size: 13.5, weight: .bold))
          .foregroundStyle(.white)
          .lineLimit(1)
          .truncationMode(.tail)
        if let subtitulo {
          Text(verbatim: subtitulo)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      if ofreceCopiar {
        Image(systemName: copiado ? "checkmark" : "doc.on.doc")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(copiado ? paleta.acuse.color : .white)
          .frame(width: 28, height: 28)
          .background(Circle().fill(Color.white.opacity(copiado ? 0.06 : 0.1)))
          .accessibilityLabel(Text(copiado ? "Copiado" : "Copiar"))
      }
    }
    .frame(height: HUDNotchGeometry.altoDelUltimo)
  }
}

/// Un reciente anterior: una línea en gris claro, sin competir con el último.
struct HUDFilaRecienteDelPanel: View {
  let texto: String
  var esDictado = true
  var copiado = false

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: esDictado ? "waveform" : "doc.on.clipboard")
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.35))
        // El ancho del cuadro del último: las líneas arrancan en la misma
        // columna que su título.
        .frame(width: 32)
      Text(verbatim: texto)
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.62))
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 8)
      // Íconos y no palabras (2026-09-24): el de copiar apagado, y un ✓ en
      // menta cuando se copió, que es cuando pasó algo.
      Image(systemName: copiado ? "checkmark" : "doc.on.doc")
        .font(.system(size: 10.5, weight: copiado ? .bold : .semibold))
        .foregroundStyle(copiado ? PaletaDeDilo.actual.acuse.color : .white.opacity(0.4))
        .frame(width: 28)
    }
    .frame(height: HUDNotchGeometry.altoDeUnReciente)
  }
}

/// Un modo en la fila de abajo. El elegido, blanco con letra negra —el
/// control encendido de Droppy—; los demás, blanco tenue.
struct HUDChipDelPanel: View {
  let nombre: String
  let elegido: Bool

  var body: some View {
    Text(verbatim: nombre)
      .font(.system(size: 11.5, weight: elegido ? .bold : .semibold))
      .lineLimit(1)
      .foregroundStyle(elegido ? .black : .white.opacity(0.8))
      .padding(.horizontal, 11)
      .frame(height: HUDNotchGeometry.altoDeUnControl)
      .background(Capsule(style: .continuous).fill(elegido ? Color.white : Color.white.opacity(0.1)))
  }
}

/// Un botón de acción al pie —«Nota», «Traducir»—: ícono y palabra en
/// blanco. Apagado, gris: todavía falta algo para que haga lo que dice.
struct HUDBotonDelPanel: View {
  let icono: String
  let titulo: String
  var apagado = false

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: icono)
        .font(.system(size: 11, weight: .semibold))
      Text(verbatim: titulo)
        .font(.system(size: 11.5, weight: .semibold))
        .lineLimit(1)
    }
    .foregroundStyle(.white.opacity(apagado ? 0.5 : 0.95))
    .padding(.horizontal, 11)
    .frame(height: HUDNotchGeometry.altoDeUnControl)
    .background(Capsule(style: .continuous).fill(Color.white.opacity(apagado ? 0.06 : 0.1)))
  }
}

/// Los textos del panel que se arman con una fecha.
enum TextoDelPanel {
  /// «hace un momento», «hace 12 min», «hace 3 h»; más de un día, la fecha.
  /// Los recientes viven en memoria desde que Dilo abrió, así que casi
  /// siempre son minutos.
  static func hace(_ cuando: Date, ahora: Date) -> String {
    let segundos = ahora.timeIntervalSince(cuando)
    if segundos < 60 { return String(localized: "hace un momento") }
    let minutos = Int(segundos / 60)
    if minutos < 60 { return String(localized: "hace \(minutos) min") }
    let horas = minutos / 60
    if horas < 24 { return String(localized: "hace \(horas) h") }
    return cuando.formatted(.dateTime.day().month(.abbreviated))
  }
}
