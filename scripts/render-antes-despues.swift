import AppKit
import SwiftUI

/// La lámina del cambio de imagen visible (2026-10-14): antes y después de
/// cada estado de la muesca, sobre barra clara y oscura.
///
/// Sale del reclamo de Alfonso con la 0.4.4 instalada: «no le veo mucho
/// cambio a los colores en el notch» y «no le veo mucho vidrio ni la forma
/// linda de Droppy». La columna **Antes** es la 0.4.4 —hombros de 9 y radio
/// de 11 en todo lo abierto, el panel negro porque el vidrio venía apagado, la
/// onda con un solo degradado vertical, el check sin disco, el aviso en una
/// línea coral de 184×26— dibujada con esos números escritos acá. Las de
/// **Después** usan la geometría y la paleta de la app, compiladas junto con
/// este archivo: `FormaAbierta`, `FiloDeLaMuesca`, `FondoDeLaMuesca`,
/// `PaletaDeDilo.coloresDeLaBarra`. El contenido es de mentira con las
/// medidas de las vistas de verdad, como en el resto del render.
///
/// El vidrio no sale en PNG (`ImageRenderer` no dibuja `glassEffect`): la
/// fila del panel usa la imitación de `FondoDeLaMuesca` y lo dice en su
/// rótulo. El de verdad se mira con `scripts/muesca.sh mostrar hover-vidrio`.
extension RenderDeLaMuesca {
  enum Version {
    case antes
    case despues
  }

  static let anchoDeCeldaAD: CGFloat = 500
  static let anchoDelRotuloAD: CGFloat = 150

  /// La Glaciar de la 0.4.4: el halo más bajo y sin filo.
  static var glaciarDeAntes: PaletaDeDilo {
    var p = PaletaDeDilo.glaciar
    p.halo = Tono(hex: 0x64D2FF, alfa: 0.45)
    return p
  }

  @MainActor
  static func escribirAntesYDespues(en carpeta: URL) throws {
    let original = paleta
    defer { paleta = original }

    let columnas: [(titulo: String, frase: String, version: Version, paleta: PaletaDeDilo)] = [
      ("Antes · 0.4.4", "Hombros de 9 y radio 11 en todo lo abierto. Vidrio apagado de fábrica. Color sólo en la onda y el cursor.", .antes, glaciarDeAntes),
      ("Después · Glaciar", "Forma abierta de Droppy, vidrio de fábrica, filo de color en el borde, onda azul→celeste por barra.", .despues, .glaciar),
      ("Después · Grafito", "La misma forma, sobria: blanco y gris, color sólo en el acuse (verde) y el error (coral).", .despues, .grafito),
    ]
    let altoDelPanel = max(
      HUDNotchGeometry.windowSize(for: pantalla).height,
      HUDNotchGeometry.altoDelPanelDeHover(for: pantalla, secciones: seccionesDeLaLamina)
    ) + 30
    let filas: [(String, CGFloat, (Version) -> AnyView)] = [
      ("Reposo\n160×24, no cambia", 44, { _ in AnyView(reposoAD) }),
      ("Dictando\n184×26, no cambia", 52, { v in AnyView(dictandoAD(v)) }),
      ("Acuse", 52, { v in AnyView(acuseAD(v)) }),
      ("Panel del hover\n(vidrio: imitación en PNG; el real, con el arnés)", altoDelPanel, { v in AnyView(panelAD(v)) }),
      ("Aviso", 62, { v in AnyView(avisoAD(v, texto: "No pude pegarlo: quedó en el portapapeles", arreglo: nil)) }),
      ("Aviso con arreglo", 62, { v in
        AnyView(avisoAD(v, texto: "Falta el permiso del micrófono", arreglo: "Abrir"))
      }),
    ]

    var celdas: [[(claro: NSImage, oscuro: NSImage)]] = []
    for columna in columnas {
      paleta = columna.paleta
      celdas.append(try filas.map { fila in
        (
          claro: try imagen(celdaAD(claro: true, alto: fila.1) { fila.2(columna.version) }),
          oscuro: try imagen(celdaAD(claro: false, alto: fila.1) { fila.2(columna.version) })
        )
      })
    }

    let lamina = VStack(alignment: .leading, spacing: 0) {
      Text("Dilo · la muesca antes y después del cambio de imagen visible (2026-10-14) — en cada columna, barra clara | barra oscura")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.bottom, 10)
      HStack(alignment: .top, spacing: 0) {
        Color.clear.frame(width: anchoDelRotuloAD, height: 1)
        ForEach(Array(columnas.enumerated()), id: \.offset) { _, columna in
          VStack(alignment: .leading, spacing: 4) {
            Text(columna.titulo)
              .font(.system(size: 18, weight: .bold))
              .foregroundStyle(.white)
            Text(columna.frase)
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(.white.opacity(0.7))
          }
          .frame(width: anchoDeCeldaAD * 2, alignment: .leading)
          .padding(.trailing, 14)
        }
      }
      .padding(.bottom, 6)
      ForEach(Array(filas.enumerated()), id: \.offset) { f, fila in
        HStack(alignment: .top, spacing: 0) {
          Text(fila.0)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: anchoDelRotuloAD - 12, alignment: .leading)
            .padding(.top, 6)
            .frame(width: anchoDelRotuloAD, alignment: .leading)
          ForEach(Array(columnas.enumerated()), id: \.offset) { c, _ in
            HStack(spacing: 0) {
              Image(nsImage: celdas[c][f].claro)
              Image(nsImage: celdas[c][f].oscuro)
            }
            .overlay(Rectangle().stroke(Color(white: 0.28), lineWidth: 1))
            .padding(.trailing, 14)
          }
        }
        .padding(.top, 6)
      }
    }
    .padding(16)
    .background(Color(white: 0.07))
    try escribir(lamina, en: carpeta, como: "antes-despues", escala: 2)
    print("Lámina en \(carpeta.appending(path: "antes-despues.png").path(percentEncoded: false))")
  }

  /// Una celda: la barra de menús y el escritorio, más claro o más oscuro.
  /// Distinta de la de `render-paletas` sólo en el ancho.
  static func celdaAD(claro: Bool, alto: CGFloat, @ViewBuilder forma: () -> some View) -> some View {
    ZStack(alignment: .top) {
      VStack(spacing: 0) {
        (claro ? Color(white: 0.93) : Color(white: 0.12))
          .frame(height: HUDNotchGeometry.altoDeLaBarra(for: pantalla))
        LinearGradient(
          colors: claro
            ? [Color(red: 0.62, green: 0.72, blue: 0.86), Color(red: 0.42, green: 0.52, blue: 0.68)]
            : [Color(red: 0.16, green: 0.20, blue: 0.32), Color(red: 0.07, green: 0.09, blue: 0.16)],
          startPoint: .top,
          endPoint: .bottom
        )
      }
      forma()
    }
    .frame(width: anchoDeCeldaAD, height: alto, alignment: .top)
    .clipped()
  }

  // MARK: La forma

  /// Una forma colgando arriba al centro, sin el marco de la ventana: la
  /// silueta con sus dos radios, el fondo —negro, o el vidrio en imitación—
  /// y el filo de color del borde de abajo si lo lleva.
  static func formaAD(
    tamaño: CGSize,
    hombro: CGFloat,
    radio: CGFloat,
    sombra: Bool = true,
    vidrio: Bool = false,
    filo: Color? = nil,
    @ViewBuilder contenido: () -> some View
  ) -> some View {
    let silueta = SiluetaDeLaMuesca(estilo: .muesca, radioDeHombro: hombro, radioInferior: radio)
    return contenido()
      .frame(width: tamaño.width, height: tamaño.height, alignment: .top)
      .background {
        Group {
          if vidrio {
            FondoDeLaMuesca(
              silueta: silueta,
              alturaDeCabecera: HUDNotchGeometry.alturaDeCabecera(for: pantalla),
              abierto: true,
              material: .imitacion
            )
          } else {
            silueta.fill(Color.black)
          }
        }
        .shadow(
          color: .black.opacity(sombra ? (vidrio ? 0.25 : 0.35) : 0),
          radius: sombra ? HUDMetrics.standard.shadowRadius : 0,
          y: sombra ? HUDMetrics.standard.shadowOffsetY : 0
        )
        .overlay {
          if let filo {
            FiloDeLaMuesca(silueta: silueta.sinHombros, color: filo, alto: radio + 4)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .top)
  }

  static var hombroDeLaCarcasa: CGFloat { HUDNotchGeometry.filletSize(for: pantalla) }

  static var reposoAD: some View {
    let reposo = HUDNotchGeometry.reposoSize(for: pantalla)
    return formaAD(
      tamaño: reposo, hombro: hombroDeLaCarcasa, radio: HUDNotchGeometry.radioEnReposo(for: pantalla), sombra: false
    ) {
      marcaDeReposo(alto: reposo.height)
    }
  }

  static func dictandoAD(_ v: Version) -> some View {
    formaAD(
      tamaño: tamañoAbierto, hombro: hombroDeLaCarcasa, radio: radioDictando,
      filo: v == .despues ? paleta.filo.color : nil
    ) {
      lineaSobria {
        ondaAD(v)
        Text("…el martes a las diez")
          .font(.system(size: 11, weight: .regular).italic())
          .foregroundStyle(.white.opacity(0.9))
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
        cursor
      }
    }
  }

  /// La onda compacta: antes un solo degradado vertical, después repartido
  /// por la fila (`PaletaDeDilo.coloresDeLaBarra`) y con el halo más cerrado.
  static func ondaAD(_ v: Version) -> some View {
    HStack(alignment: .center, spacing: 2) {
      ForEach(Array(niveles.prefix(5).enumerated()), id: \.offset) { i, nivel in
        let colores = v == .despues
          ? paleta.coloresDeLaBarra(i, de: 5)
          : (abajo: paleta.ondaBase, arriba: paleta.ondaPunta)
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
          .fill(LinearGradient(colors: [colores.abajo.color, colores.arriba.color], startPoint: .bottom, endPoint: .top))
          .frame(width: 3, height: min(max(4, (6 + pow(nivel, 0.7) * 11) * 11 / 16), 11))
          .shadow(color: paleta.halo.color, radius: 3)
      }
    }
    .frame(width: 23, height: 13)
  }

  static func acuseAD(_ v: Version) -> some View {
    formaAD(
      tamaño: tamañoAbierto, hombro: hombroDeLaCarcasa, radio: radioDictando,
      filo: v == .despues ? paleta.acuse.color.opacity(0.85) : nil
    ) {
      lineaSobria {
        Group {
          if v == .despues {
            // `HUDCheckDeAcuse` terminado de trazar: el disco tenue y el
            // trazo con su luz.
            ZStack {
              Circle()
                .fill(paleta.acuse.color.opacity(0.16))
                .frame(width: 13 * HUDCheckDeAcuse.disco, height: 13 * HUDCheckDeAcuse.disco)
              TrazoDelCheck()
                .stroke(paleta.acuse.color, style: StrokeStyle(lineWidth: 1.8 * 13 / 15, lineCap: .round, lineJoin: .round))
                .shadow(color: paleta.acuse.color.opacity(0.7), radius: 3)
                .frame(width: 13, height: 13)
            }
          } else {
            check
          }
        }
        .frame(maxWidth: .infinity)
      }
    }
  }

  /// El aviso: antes la línea coral en la muesca de dictar; después la forma
  /// del aviso (`HUDNotchGeometry.tamañoDelAviso`) con los radios de Droppy,
  /// el ícono en su disco, la frase en blanco y, si lo hay, el botón.
  static func avisoAD(_ v: Version, texto: String, arreglo: String?) -> some View {
    Group {
      if v == .antes {
        formaAD(tamaño: tamañoAbierto, hombro: hombroDeLaCarcasa, radio: radioDictando) {
          lineaSobria {
            Text(arreglo == nil ? texto : "\(texto): clic para abrir")
              .font(.system(size: 11, weight: .regular))
              .foregroundStyle(arreglo == nil ? paleta.error.color : .white.opacity(0.9))
              .lineLimit(1)
              .truncationMode(.tail)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      } else {
        let tamaño = HUDNotchGeometry.tamañoDelAviso(for: pantalla)
        let radio = FormaAbierta.radioDelAviso(para: tamaño)
        let color = arreglo == nil ? paleta.error.color : paleta.acento.color
        formaAD(
          tamaño: tamaño,
          hombro: FormaAbierta.hombro(para: tamaño, en: pantalla, radioInferior: radio),
          radio: radio,
          filo: arreglo == nil ? paleta.error.color.opacity(0.75) : paleta.filo.color
        ) {
          HStack(spacing: 6) {
            Image(systemName: arreglo == nil ? "exclamationmark" : "gearshape.fill")
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(color)
              .frame(width: 19, height: 19)
              .background(Circle().fill(color.opacity(0.18)))
            Text(texto)
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(.white.opacity(0.92))
              .lineLimit(1)
              .truncationMode(.tail)
              .frame(maxWidth: .infinity, alignment: .leading)
            if let arreglo {
              Text(arreglo)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(paleta.acento.color))
                .fixedSize()
            }
          }
          .padding(.horizontal, 16)
          .frame(height: tamaño.height)
        }
      }
    }
  }

  /// El panel del hover con dos recientes y los modos. Antes: negro, con los
  /// radios del reposo. Después: la forma abierta de Droppy, el vidrio en
  /// imitación, las secciones en tarjetas y el modo elegido en degradado.
  static func panelAD(_ v: Version) -> some View {
    let despues = v == .despues
    let tamaño = CGSize(
      width: metricas.contentWidth,
      height: HUDNotchGeometry.altoDelPanelDeHover(for: pantalla, secciones: seccionesDeLaLamina)
    )
    let cabecera = HUDNotchGeometry.alturaDeCabecera(for: pantalla)
    let radio = despues ? PanelDeVidrio.radio(para: tamaño, cabecera: cabecera) : HUDNotchGeometry.radioEnReposo(for: pantalla)
    let hombro = despues
      ? FormaAbierta.hombro(para: tamaño, en: pantalla, radioInferior: radio)
      : hombroDeLaCarcasa
    let ultima = PanelDeVidrio.radioDeLaUltimaTarjeta(radioDelPanel: radio)
    return formaAD(
      tamaño: tamaño, hombro: hombro, radio: radio, vidrio: despues,
      filo: despues ? paleta.filo.color.opacity(0.6) : nil
    ) {
      VStack(alignment: .leading, spacing: 0) {
        Color.clear.frame(height: cabecera)
        VStack(alignment: .leading, spacing: 0) {
          Text("RECIENTES")
            .font(.system(size: 8, weight: .semibold, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.42))
            .frame(height: HUDNotchGeometry.altoDelEncabezadoDeSeccion, alignment: .bottom)
          filaReciente("quedamos el martes a las diez en la oficina", copiado: true)
          filaReciente("revisa el informe de Kubernetes antes del jueves", copiado: false)
        }
        .tarjetaDelPanel(despues)
        Rectangle()
          .fill(.white.opacity(despues ? 0 : 0.08))
          .frame(height: 1)
          .frame(height: HUDNotchGeometry.altoDelSeparador)
        HStack(spacing: 5) {
          chipAD("Normal", elegido: true, v)
          chipAD("Correo", elegido: false, v)
          chipAD("Notas", elegido: false, v)
          Spacer(minLength: 0)
          HStack(spacing: 4) {
            Image(systemName: "square.and.pencil").font(.system(size: 9, weight: .bold))
            Text("Nota").font(.system(size: 9.5, weight: .semibold, design: .rounded))
          }
          .foregroundStyle(paleta.acento.color)
          .padding(.horizontal, 9)
          .padding(.vertical, 3)
          .background(Capsule(style: .continuous).fill(paleta.acento.color.opacity(0.16)))
        }
        .frame(height: HUDNotchGeometry.altoDeLosModos - HUDNotchGeometry.altoDelSeparador)
        .tarjetaDelPanel(despues, radioInferior: ultima)
      }
      .padding(.horizontal, despues ? PanelDeVidrio.aireLateral : 16)
    }
  }

  /// El chip de un modo: antes el acento liso; después el degradado de la
  /// onda con su luz (`HUDPanelDelHover.fondoDelChip`).
  static func chipAD(_ nombre: String, elegido: Bool, _ v: Version) -> some View {
    Text(nombre)
      .font(.system(size: 9.5, weight: .semibold, design: .rounded))
      .foregroundStyle(elegido ? .black : .white.opacity(0.75))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background {
        if elegido, v == .despues {
          Capsule(style: .continuous)
            .fill(LinearGradient(
              colors: [paleta.ondaBase.mezcla(con: paleta.ondaPunta, 0.35).color, paleta.ondaPunta.color],
              startPoint: .leading,
              endPoint: .trailing
            ))
            .shadow(color: paleta.halo.color.opacity(0.5), radius: 4)
        } else {
          Capsule(style: .continuous).fill(elegido ? paleta.acento.color : .white.opacity(0.12))
        }
      }
  }
}
