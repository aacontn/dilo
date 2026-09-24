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

  /// Si esta línea es el acuse: el check donde estaba la onda, sin palabras.
  private var acusa: Bool {
    guard case let .resultado(resultado) = content.estado else { return false }
    return resultado.esAcuse
  }

  var body: some View {
    Group {
      if acusa {
        // El check **reemplaza la onda y el texto**: terminar bien no agranda
        // la muesca ni la mueve, y no hay nada más que decir, así que va solo
        // y centrado (`HUDCheckDeAcuse`). Con la onda a la izquierda y el
        // resto vacío quedaba una marca arrinconada.
        HUDCheckDeAcuse(lado: HUDOndaDeBrasas.altoDeLaBandaCompacta, reduceMotion: reduceMotion)
          .frame(maxWidth: .infinity)
      } else {
        HStack(spacing: 6) {
          // Una nota lo dice antes que nada, con palabra y no sólo con ícono:
          // estas palabras van a Notas, no a donde está el cursor.
          if esNota {
            HStack(spacing: 3) {
              Image(systemName: "note.text")
                .font(.system(size: 9.5, weight: .semibold))
              Text("Nota")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
            }
            .foregroundStyle(DiloBrand.mango)
            .fixedSize()
          }
          if muestraOnda {
            HUDOndaDeBrasas(content: content, reduceMotion: reduceMotion, compacta: true)
              .frame(width: HUDOndaDeBrasas.anchoCompacto)
          }
          texto
            .frame(maxWidth: .infinity, alignment: .leading)
          if esNota {
            botonDeGuardar
          } else if muestraOnda {
            // El cursor mango dice lo que ninguna onda dice: que lo escrito
            // sigue creciendo. Encogido con la línea.
            HUDCursorDeDictado(scale: Self.cuerpo / 15, reduceMotion: reduceMotion)
          }
        }
      }
    }
    .padding(.horizontal, 10)
    .frame(height: alto)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("Dilo"))
    .accessibilityValue(Text(paraVoiceOver))
  }

  /// Si se está dictando una nota: lleva su etiqueta y el botón de guardar.
  private var esNota: Bool { content.notaEnCurso }

  /// Cómo se termina una nota, a la vista: un ✓ en mango al final de la
  /// línea. Antes no había nada que dijera cómo pararla —se abría con un clic
  /// y quedaba escuchando sin salida visible (reporte del 2026-09-24)—. El
  /// clic lo recibe la muesca entera (`HUDStage.clicDuranteLaNota`); el botón
  /// es lo que dice dónde tocar.
  private var botonDeGuardar: some View {
    Image(systemName: "checkmark")
      .font(.system(size: 8, weight: .heavy))
      .foregroundStyle(.black)
      .frame(width: 15, height: 15)
      .background(Circle().fill(DiloBrand.mango))
      .accessibilityLabel(Text("Guardar la nota"))
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

  /// La línea recta de los estados que no son dictar. Vacía en el acuse: el
  /// check lo dice todo, y las palabras que quedaron del dictado no son un
  /// mensaje —son lo que ya se pegó en otra parte—.
  private var linea: String {
    guard !acusa else { return "" }
    if !content.text.isEmpty, case .resultado = content.estado { return content.text }
    return content.estado.texto ?? ""
  }

  private var paraVoiceOver: String {
    if content.estado == .dictando {
      let dicho = content.text + content.volatileText
      return dicho.isEmpty ? String(localized: "Dictando") : dicho
    }
    // El acuse no tiene palabras en pantalla, pero sí tiene que tenerlas acá:
    // un check que VoiceOver no nombra es un acuse que no llegó.
    if case let .resultado(resultado) = content.estado, resultado.esAcuse {
      return resultado.texto
    }
    return linea
  }
}

#Preview("Dictando · muesca sobria") {
  HUDShellPreviewHarness(screen: HUDPreviewScreen.externalNotchSimulado)
}
