import SwiftUI

/// Lo que la muesca dice mientras hay una sesión, en una sola línea.
///
/// Sale del veredicto del 2026-09-22: «crece mucho cuando le estoy dictando;
/// podría crecer por un 10 % del notch real y avanzar en el texto como lo está
/// haciendo actualmente, que sería lo ideal». Los 400×88 de antes eran una
/// pila de bandas —onda, texto, chip de modo— colgando de una silueta de
/// 160×24; acá la muesca mide 184×26 y todo lo que tiene que decir comparte
/// una línea: la onda de brasas encogida a la izquierda y el parcial
/// avanzando, recortado por la izquierda para que siempre se vea el final.
///
/// **Qué no cabe, y no se fuerza.** El chip de modo no tiene fila propia ni
/// entra como prefijo: con la onda puesta le quedan unos 130 puntos al texto,
/// y un nombre de modo adelante se come justo las palabras que se vienen a
/// leer. El modo se dice en reposo —si se pidió— y en el panel del hover. La
/// etiqueta de idioma vive en el mismo lugar por el mismo motivo.
///
/// Es la forma de una pantalla sin carcasa. Contra un notch real los primeros
/// puntos del borde son el recorte físico y el contenido tiene que colgar por
/// debajo, así que ahí la forma sigue siendo la pila de bandas
/// (`DictationHUDShellView`).
struct HUDLineaSobria: View {
  let content: DictationHUDContent
  /// El alto exacto de la muesca dictando, medido por la geometría
  /// (`HUDNotchGeometry.tamañoDictando`). Llega de afuera para que no haya un
  /// segundo lugar que lo calcule.
  let alto: CGFloat
  var reduceMotion = false

  /// El cuerpo de la línea. Once puntos y no quince: la cursiva del overlay
  /// de Tauri era para una banda de 26 puntos de alto colgando bajo la
  /// cabecera, y acá la línea **es** la muesca.
  private static let cuerpo: CGFloat = 11

  /// Si esta línea lleva onda. Sólo mientras el micrófono está abierto:
  /// procesando no puede parecer que sigue grabando (contrato del notch).
  private var muestraOnda: Bool {
    content.estado == .dictando
  }

  var body: some View {
    HStack(spacing: 6) {
      if muestraOnda {
        HUDOndaDeBrasas(content: content, reduceMotion: reduceMotion, compacta: true)
          .frame(width: HUDOndaDeBrasas.anchoCompacto)
      }
      texto
        .frame(maxWidth: .infinity, alignment: .leading)
      if muestraOnda {
        // El cursor mango dice lo que ninguna onda dice: que lo escrito sigue
        // creciendo. Encogido con la línea.
        HUDCursorDeDictado(scale: Self.cuerpo / 15, reduceMotion: reduceMotion)
      }
    }
    .padding(.horizontal, 10)
    .frame(height: alto)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("Dilo"))
    .accessibilityValue(Text(paraVoiceOver))
  }

  /// Dictando, el parcial en cursiva; en los demás estados, lo que el estado
  /// dice por su cuenta, recto. La cursiva es lo que separa lo que alguien
  /// acaba de decir de lo que la forma dice de sí misma.
  @ViewBuilder
  private var texto: some View {
    if content.estado == .dictando {
      parcial
        .font(.system(size: Self.cuerpo, weight: .regular).italic())
        .lineLimit(1)
        // Por la izquierda: lo último dicho es lo que se está revisando, así
        // que el final de la frase no se puede perder nunca.
        .truncationMode(.head)
    } else {
      Text(linea)
        .font(.system(size: Self.cuerpo, weight: .regular))
        .foregroundStyle(.white.opacity(0.9))
        .lineLimit(1)
        .truncationMode(.tail)
    }
  }

  /// Lo comprometido en blanco y la conjetura del reconocedor más apagada,
  /// para que las palabras nuevas se vean antes de confirmarse.
  private var parcial: Text {
    var comprometido = AttributedString(content.text)
    comprometido.foregroundColor = Color.white.opacity(0.9)
    var conjetura = AttributedString(content.volatileText)
    conjetura.foregroundColor = Color.white.opacity(0.55)
    return Text(comprometido + conjetura)
  }

  /// La línea recta de los estados que no son dictar.
  private var linea: String {
    if !content.text.isEmpty, case .resultado = content.estado { return content.text }
    return content.estado.texto ?? ""
  }

  private var paraVoiceOver: String {
    if content.estado == .dictando {
      let dicho = content.text + content.volatileText
      return dicho.isEmpty ? String(localized: "Dictando") : dicho
    }
    return linea
  }
}

#Preview("Dictando · muesca sobria") {
  HUDShellPreviewHarness(screen: HUDPreviewScreen.externalNotchSimulado)
}
