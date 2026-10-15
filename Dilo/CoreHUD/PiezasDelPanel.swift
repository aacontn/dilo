import SwiftUI

// Las piezas del panel del hover, con valores sueltos y sin el contenido del
// HUD: las usa `HUDPanelDelHover` y las compila también el render de la
// muesca (`scripts/render-muesca.sh`), así la lámina dibuja las mismas vistas
// y no una copia que se separa.
//
// **La jerarquía y la densidad son las de Droppy** (2026-10-15): lo
// principal en blanco y semibold —lo último dictado—, lo secundario en gris,
// y los controles como las pestañas de su bandeja: texto chico sin fondo, y
// el elegido en una píldora gris. Letra de 10,5 a 12,5 puntos. El color va
// sólo en un detalle chico: el ícono del último dictado, el ✓ de copiado, la
// reunión que empieza.
//
// Hasta la 0.4.6 los modos eran botones de 24 con fondo, el elegido en
// blanco lleno, y «Traducir» y «Nota» otras dos píldoras con ícono y palabra:
// la fila de abajo pesaba más que lo dictado («los modos y Traducir se ven
// mal: muy grandes»). Y antes, en la 0.4.5, todo era letra de 8 a 10,5 del
// mismo gris: sin nada que mirar primero.
//
// **Los modos van en un solo botón** (2026-10-15): «en vez de que me
// muestre todos los modos de una, el botón de modo, que si lo aprietas
// aparecen dinámicamente los otros, como lo hace Droppy en sus widgets». La
// fila muestra el elegido con una flecha; al apretarlo, los demás salen de
// ahí mismo con el resorte de apertura y la píldora se corre al que eliges.

/// Lo último que pasó por Dilo: el «Blue Hour · Nova Coast» del reproductor
/// de Droppy, a la escala de un panel de texto. Un ícono con el degradado de
/// la paleta, el texto en semibold y debajo, en gris, qué es y cuándo; a la
/// derecha, copiar.
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

  /// El lado del cuadro del ícono. Los recientes de abajo alinean su ícono
  /// en esta misma columna.
  static let cuadro: CGFloat = 26

  var body: some View {
    let paleta = PaletaDeDilo.actual
    HStack(spacing: 10) {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(Color.white.opacity(0.08))
        .frame(width: Self.cuadro, height: Self.cuadro)
        .overlay {
          Image(systemName: esDictado ? "waveform" : "doc.on.clipboard")
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(LinearGradient(
              colors: [paleta.ondaBase.color, paleta.ondaPunta.color],
              startPoint: .bottomLeading,
              endPoint: .topTrailing
            ))
        }
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: titulo)
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(.white)
          .lineLimit(1)
          .truncationMode(.tail)
        if let subtitulo {
          Text(verbatim: subtitulo)
            .font(.system(size: 10.5))
            .foregroundStyle(.white.opacity(0.45))
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      if ofreceCopiar {
        Image(systemName: copiado ? "checkmark" : "doc.on.doc")
          .font(.system(size: 10.5, weight: .semibold))
          .foregroundStyle(copiado ? paleta.acuse.color : .white.opacity(0.75))
          .frame(width: 22, height: 22)
          .background(Circle().fill(Color.white.opacity(copiado ? 0.05 : 0.08)))
          .accessibilityLabel(Text(copiado ? "Copiado" : "Copiar"))
      }
    }
    .frame(height: HUDNotchGeometry.altoDelUltimo)
  }
}

/// Un reciente anterior: una línea en gris, sin competir con el último.
struct HUDFilaRecienteDelPanel: View {
  let texto: String
  var esDictado = true
  var copiado = false

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: esDictado ? "waveform" : "doc.on.clipboard")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.white.opacity(0.3))
        // El ancho del cuadro del último: las líneas arrancan en la misma
        // columna que su título.
        .frame(width: HUDUltimoDelPanel.cuadro)
      Text(verbatim: texto)
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.58))
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 8)
      // Íconos y no palabras (2026-09-24): el de copiar apagado, y un ✓ en
      // menta cuando se copió, que es cuando pasó algo.
      Image(systemName: copiado ? "checkmark" : "doc.on.doc")
        .font(.system(size: 9.5, weight: copiado ? .bold : .medium))
        .foregroundStyle(copiado ? PaletaDeDilo.actual.acuse.color : .white.opacity(0.32))
        .frame(width: 22)
    }
    .frame(height: HUDNotchGeometry.altoDeUnReciente)
  }
}

/// Un modo en la fila de abajo, como una pestaña de la bandeja de Droppy:
/// texto chico sin fondo, y el elegido en blanco sobre una píldora gris.
struct HUDChipDelPanel: View {
  let nombre: String
  let elegido: Bool
  /// Con dónde comparte la píldora el botón de modo: así, al desplegarse,
  /// la píldora del botón viaja hasta el chip elegido en vez de aparecer.
  var pildora: Namespace.ID?

  var body: some View {
    Text(verbatim: nombre)
      .font(.system(size: 11, weight: elegido ? .semibold : .medium))
      .lineLimit(1)
      .foregroundStyle(elegido ? .white : .white.opacity(0.5))
      .padding(.horizontal, 8)
      .frame(height: HUDNotchGeometry.altoDeUnControl)
      .background {
        if elegido {
          PildoraDelModo(espacio: pildora)
        }
      }
      .contentShape(Capsule(style: .continuous))
  }
}

/// El botón de modo, plegado: el modo elegido en su píldora gris y una
/// flecha que dice que hay más. Apretarlo despliega los demás en la misma
/// fila (`HUDPanelDelHover`).
struct HUDBotonDeModo: View {
  let nombre: String
  var pildora: Namespace.ID?

  var body: some View {
    HStack(spacing: 4) {
      Text(verbatim: nombre)
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
      Image(systemName: "chevron.right")
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(.white.opacity(0.5))
    }
    .foregroundStyle(.white)
    .padding(.leading, 8)
    .padding(.trailing, 7)
    .frame(height: HUDNotchGeometry.altoDeUnControl)
    .background { PildoraDelModo(espacio: pildora) }
    .contentShape(Capsule(style: .continuous))
  }
}

/// La píldora gris del modo elegido. Es una sola vista para el botón y
/// para los chips, así el `matchedGeometryEffect` la mueve de uno a otro.
private struct PildoraDelModo: View {
  let espacio: Namespace.ID?

  var body: some View {
    let pildora = Capsule(style: .continuous).fill(Color.white.opacity(0.14))
    if let espacio {
      pildora.matchedGeometryEffect(id: "pildora-del-modo", in: espacio)
    } else {
      pildora
    }
  }
}

/// Una acción al pie —«Traducir», «Nota»—: un ícono y, si hace falta, una
/// palabra corta, en gris claro y sin fondo, como los controles del
/// reproductor de Droppy. Apagado, más gris: todavía falta algo para que
/// haga lo que dice.
struct HUDBotonDelPanel: View {
  let icono: String
  /// La palabra al lado del ícono —«EN»—, o nil para el ícono solo.
  var titulo: String?
  var apagado = false

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: icono)
        .font(.system(size: 11, weight: .medium))
      if let titulo {
        Text(verbatim: titulo)
          .font(.system(size: 11, weight: .semibold))
          .lineLimit(1)
      }
    }
    .foregroundStyle(.white.opacity(apagado ? 0.32 : 0.72))
    .padding(.horizontal, titulo == nil ? 0 : 6)
    .frame(minWidth: HUDNotchGeometry.altoDeUnControl, minHeight: HUDNotchGeometry.altoDeUnControl)
    .contentShape(Capsule(style: .continuous))
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
