import AppKit
import CoreImage
import SwiftUI

/// La lámina del vidrio rehecho (2026-10-15): el panel del hover de la 0.4.5
/// contra el nuevo, sobre una página blanca tipo web y sobre un escritorio
/// oscuro, con el cuadro de Droppy al lado.
///
/// Sale del reclamo de Alfonso con la 0.4.5 instalada: el panel con vidrio
/// «se ve mal». La 0.4.5 tenía negro sólo en la cabecera y todo lo demás
/// vidrio con un tinte de 0,3; sobre YouTube quedaba gris claro y
/// translúcido con letra blanca encima. La columna **0.4.5** se dibuja con
/// esos números, escritos acá —el material, las tarjetas y la letra de
/// entonces—. La **nueva** usa lo de la app, compilado junto con este
/// archivo: `FondoDeLaMuesca`, `PanelDeVidrio`, `FormaAbierta`, la geometría
/// del panel y sus piezas (`PiezasDelPanel.swift`).
///
/// **El vidrio de las dos columnas es una imitación**: `ImageRenderer` no
/// dibuja `glassEffect`. Se imita con lo que hay detrás desenfocado y
/// tintado con el negro de cada versión, que es lo que el vidrio hará: en la
/// nueva, negro arriba y ahumado oscuro en la franja de abajo. El de verdad
/// se mira con `scripts/muesca.sh mostrar hover-vidrio`.
///
/// El cuadro de Droppy se pasa con `--referencia <ruta>`; sin él, la lámina
/// sale sin esa columna.
extension RenderDeLaMuesca {
  static let anchoDeCeldaAD: CGFloat = 560
  static let altoDeCeldaAD: CGFloat = 232
  static let anchoDelRotuloAD: CGFloat = 170
  /// Lo que lleva el panel de la lámina: tres recientes y los modos.
  static let seccionesDelVidrio = SeccionesDelPanel(recientes: 3, modos: true)

  @MainActor
  static func escribirAntesYDespues(en carpeta: URL) throws {
    let referencia = CommandLine.arguments
      .firstIndex(of: "--referencia")
      .flatMap { i in CommandLine.arguments.indices.contains(i + 1) ? CommandLine.arguments[i + 1] : nil }
      .flatMap { NSImage(contentsOfFile: $0) }

    let filas: [(titulo: String, fondo: Fondo, vidrio: Bool)] = [
      ("Página blanca\n(tipo YouTube)", .pagina, true),
      ("Escritorio oscuro", .oscuro, true),
      ("«Panel con vidrio» apagado\no «Reducir transparencia»", .pagina, false),
    ]
    let columnas: [(titulo: String, frase: String, nueva: Bool)] = [
      (
        "0.4.5 · lo instalado",
        "Negro sólo en la cabecera; todo lo demás vidrio con tinte 0,3. Sobre blanco, gris claro con letra blanca.",
        false
      ),
      (
        "Nueva · negro con franja de vidrio",
        "Negro opaco en todo el contenido; vidrio ahumado sólo en el último 30 %, con filo de luz abajo. Radio 32.",
        true
      ),
    ]
    var celdas: [[NSImage]] = []
    for columna in columnas {
      celdas.append(try filas.map { fila in
        try imagen(celdaDelVidrio(fondo: fila.fondo, nueva: columna.nueva, vidrio: fila.vidrio))
      })
    }

    let lamina = VStack(alignment: .leading, spacing: 0) {
      Text("Dilo · el panel del hover con vidrio, 0.4.5 contra el nuevo (2026-10-15)")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.white)
      Text("El vidrio es una IMITACIÓN en PNG (ImageRenderer no dibuja glassEffect): lo de atrás desenfocado y tintado con el negro de cada versión. El real se mira con scripts/muesca.sh mostrar hover-vidrio.")
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(Color(red: 1, green: 0.8, blue: 0.45))
        .padding(.top, 4)
        .padding(.bottom, 12)
      HStack(alignment: .top, spacing: 0) {
        VStack(alignment: .leading, spacing: 0) {
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
                  .fixedSize(horizontal: false, vertical: true)
              }
              .frame(width: anchoDeCeldaAD, alignment: .leading)
              .padding(.trailing, 14)
            }
          }
          .padding(.bottom, 8)
          ForEach(Array(filas.enumerated()), id: \.offset) { f, fila in
            HStack(alignment: .top, spacing: 0) {
              Text(fila.titulo)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: anchoDelRotuloAD - 12, alignment: .leading)
                .padding(.top, 34)
                .frame(width: anchoDelRotuloAD, alignment: .leading)
              ForEach(Array(columnas.enumerated()), id: \.offset) { c, _ in
                Image(nsImage: celdas[c][f])
                  .overlay(Rectangle().stroke(Color(white: 0.28), lineWidth: 1))
                  .padding(.trailing, 14)
              }
            }
            .padding(.bottom, 10)
          }
        }
        if let referencia {
          VStack(alignment: .leading, spacing: 4) {
            Text("Droppy · referencia")
              .font(.system(size: 18, weight: .bold))
              .foregroundStyle(.white)
            Text("Cuadro del video «Dynamic Glass»: negro casi entero; el vidrio, ahumado, sólo en el último cuarto.")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(.white.opacity(0.7))
              .fixedSize(horizontal: false, vertical: true)
              .padding(.bottom, 8)
            Image(nsImage: referencia)
              .resizable()
              .aspectRatio(contentMode: .fit)
              .frame(width: anchoDeCeldaAD)
              .overlay(Rectangle().stroke(Color(white: 0.28), lineWidth: 1))
          }
          .frame(width: anchoDeCeldaAD, alignment: .leading)
        }
      }
    }
    .padding(18)
    .background(Color(white: 0.07))
    try escribir(lamina, en: carpeta, como: "antes-despues", escala: 2)
    print("Lámina en \(carpeta.appending(path: "antes-despues.png").path(percentEncoded: false))")
  }

  // MARK: Los fondos

  enum Fondo {
    /// Una página web clara, con barra de búsqueda, miniaturas y títulos:
    /// lo que había detrás cuando Alfonso miró la 0.4.5.
    case pagina
    /// Un escritorio oscuro con una ventana oscura encima.
    case oscuro
  }

  /// Lo que hay detrás de la muesca, del tamaño de la celda: la barra de
  /// menús y la página o el escritorio. Es también lo que el vidrio imitado
  /// desenfoca.
  static func fondoAD(_ fondo: Fondo) -> some View {
    let barra = HUDNotchGeometry.altoDeLaBarra(for: pantalla)
    let claro = fondo == .pagina
    return VStack(spacing: 0) {
      // La barra de menús, con los menús y los íconos de los costados.
      HStack(spacing: 14) {
        ForEach([34, 28, 40, 30], id: \.self) { ancho in
          RoundedRectangle(cornerRadius: 2).frame(width: CGFloat(ancho), height: 6)
        }
        Spacer()
        ForEach([12, 12, 12, 44], id: \.self) { ancho in
          RoundedRectangle(cornerRadius: 2).frame(width: CGFloat(ancho), height: 7)
        }
      }
      .foregroundStyle(claro ? Color(white: 0.25) : Color(white: 0.8))
      .padding(.horizontal, 12)
      .frame(height: barra)
      .background(claro ? Color(white: 0.95) : Color(white: 0.13))
      ZStack(alignment: .topLeading) {
        switch fondo {
        case .pagina: pagina
        case .oscuro: escritorioOscuro
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .clipped()
    }
    .frame(width: anchoDeCeldaAD, height: altoDeCeldaAD)
  }

  /// La página clara: barra de búsqueda arriba al centro —justo detrás del
  /// panel— y una grilla de miniaturas de colores con sus títulos.
  static var pagina: some View {
    let colores: [Color] = [
      Color(red: 0.86, green: 0.36, blue: 0.30), Color(red: 0.25, green: 0.55, blue: 0.85),
      Color(red: 0.95, green: 0.75, blue: 0.30), Color(red: 0.35, green: 0.70, blue: 0.45),
      Color(red: 0.55, green: 0.40, blue: 0.80), Color(red: 0.20, green: 0.25, blue: 0.35),
    ]
    return VStack(alignment: .leading, spacing: 0) {
      HStack {
        RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.2)).frame(width: 60, height: 12)
        Spacer()
        Capsule().stroke(Color(white: 0.8), lineWidth: 1)
          .background(Capsule().fill(Color(white: 0.98)))
          .frame(width: 230, height: 26)
          .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.55)).frame(width: 70, height: 6).padding(.leading, 14)
          }
        Spacer()
        Circle().fill(Color(white: 0.75)).frame(width: 20, height: 20)
      }
      .padding(.horizontal, 14)
      .frame(height: 42)
      HStack(alignment: .top, spacing: 12) {
        ForEach(0..<4, id: \.self) { i in
          VStack(alignment: .leading, spacing: 5) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(LinearGradient(
                colors: [colores[i], colores[(i + 2) % colores.count]],
                startPoint: .topLeading, endPoint: .bottomTrailing
              ))
              .frame(height: 72)
            RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.1)).frame(width: 100, height: 7)
            RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.1)).frame(width: 74, height: 7)
            RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.6)).frame(width: 60, height: 5)
          }
          .frame(maxWidth: .infinity)
        }
      }
      .padding(.horizontal, 14)
      .padding(.top, 4)
      Spacer(minLength: 0)
    }
    .background(Color.white)
  }

  /// El escritorio oscuro: un degradado azul noche y una ventana oscura con
  /// texto claro asomando detrás del panel.
  static var escritorioOscuro: some View {
    ZStack(alignment: .topLeading) {
      LinearGradient(
        colors: [Color(red: 0.16, green: 0.20, blue: 0.32), Color(red: 0.06, green: 0.08, blue: 0.14)],
        startPoint: .top, endPoint: .bottom
      )
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color(white: 0.17))
        .overlay(alignment: .topLeading) {
          VStack(alignment: .leading, spacing: 8) {
            ForEach([300, 250, 330, 200, 280, 240, 310], id: \.self) { ancho in
              RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.7)).frame(width: CGFloat(ancho), height: 6)
            }
          }
          .padding(16)
        }
        .frame(width: 400, height: 190)
        .offset(x: 110, y: 18)
    }
  }

  /// El fondo de la celda desenfocado como lo haría el vidrio y recortado a
  /// `recorte` (en puntos, origen arriba a la izquierda). Con Core Image y
  /// no con `blur`: en `ImageRenderer` el desenfoque de SwiftUI salía
  /// corrido y oscuro.
  @MainActor
  static func desenfocado(_ fondo: Fondo, recorte: CGRect) -> NSImage {
    let escala: CGFloat = 2
    let renderer = ImageRenderer(content: fondoAD(fondo))
    renderer.scale = escala
    guard let cg = renderer.cgImage else { return NSImage() }
    let entrada = CIImage(cgImage: cg)
    let borroso = entrada.clampedToExtent()
      .applyingGaussianBlur(sigma: 12 * escala)
      .cropped(to: entrada.extent)
    // Core Image cuenta desde abajo.
    let r = CGRect(
      x: recorte.minX * escala,
      y: entrada.extent.height - recorte.maxY * escala,
      width: recorte.width * escala,
      height: recorte.height * escala
    )
    guard let salida = CIContext().createCGImage(borroso, from: r) else { return NSImage() }
    return NSImage(cgImage: salida, size: recorte.size)
  }

  // MARK: El panel

  /// Una celda: el fondo y el panel colgando arriba al centro, con la forma
  /// abierta de cada versión. Sin vidrio, el negro entero de cada una.
  @MainActor
  static func celdaDelVidrio(fondo: Fondo, nueva: Bool, vidrio: Bool) -> some View {
    let cabecera = HUDNotchGeometry.alturaDeCabecera(for: pantalla)
    let tamaño = CGSize(
      width: metricas.contentWidth,
      height: nueva
        ? HUDNotchGeometry.altoDelPanelDeHover(for: pantalla, secciones: seccionesDelVidrio)
        : altoDelPanel045
    )
    let radio = nueva ? PanelDeVidrio.radio(para: tamaño, cabecera: cabecera) : min(40, tamaño.height - cabecera)
    let silueta = SiluetaDeLaMuesca(
      estilo: .muesca,
      radioDeHombro: FormaAbierta.hombro(para: tamaño, en: pantalla, radioInferior: radio),
      radioInferior: radio
    )
    // Lo que hay detrás de la forma, desenfocado y recortado a su marco: el
    // fondo de la celda centrado arriba, que es donde cuelga el panel.
    let detras = AnyView(
      Image(nsImage: desenfocado(fondo, recorte: CGRect(
        x: (anchoDeCeldaAD - tamaño.width) / 2, y: 0, width: tamaño.width, height: tamaño.height
      )))
      .resizable()
      .frame(width: tamaño.width, height: tamaño.height)
    )
    return ZStack(alignment: .top) {
      fondoAD(fondo)
      Group {
        if nueva {
          contenidoDelPanel(recientes: seccionesDelVidrio.recientes)
        } else {
          contenido045(enTarjetas: vidrio)
        }
      }
      .frame(width: tamaño.width, height: tamaño.height, alignment: .top)
      .background {
        Group {
          if nueva {
            FondoDeLaMuesca(
              silueta: silueta, alturaDeCabecera: cabecera, abierto: vidrio, material: .imitacion(fondo: detras)
            )
          } else {
            fondo045(silueta: silueta, cabecera: cabecera, vidrio: vidrio, detras: detras)
          }
        }
        .shadow(color: .black.opacity(0.25), radius: HUDMetrics.standard.shadowRadius, y: HUDMetrics.standard.shadowOffsetY)
        .overlay {
          // El filo de color: la 0.4.5 lo llevaba siempre en el hover; la
          // nueva, sólo en negro (con vidrio, el canto es el filo blanco).
          if !nueva || !vidrio {
            FiloDeLaMuesca(silueta: silueta.sinHombros, color: paleta.filo.color.opacity(0.6), alto: radio + 4)
          }
        }
      }
    }
    .frame(width: anchoDeCeldaAD, height: altoDeCeldaAD, alignment: .top)
    .clipped()
  }

  /// El contenido nuevo del panel con las piezas de la app: lo último en
  /// grande, los recientes anteriores en gris y la fila de controles.
  static func contenidoDelPanel(recientes: Int) -> some View {
    let anteriores: [(String, Bool, Bool)] = [
      ("revisa el informe de Kubernetes antes del jueves", true, true),
      ("https://dilo.app/precios", false, false),
    ]
    return VStack(alignment: .leading, spacing: 0) {
      Color.clear.frame(height: HUDNotchGeometry.alturaDeCabecera(for: pantalla))
      HUDUltimoDelPanel(
        titulo: "quedamos el martes a las diez en la oficina",
        subtitulo: "Dictado · hace 2 min"
      )
      ForEach(Array(anteriores.prefix(max(0, recientes - 1)).enumerated()), id: \.offset) { _, fila in
        HUDFilaRecienteDelPanel(texto: fila.0, esDictado: fila.1, copiado: fila.2)
      }
      Color.clear.frame(height: HUDNotchGeometry.altoDelSeparador)
      HStack(spacing: 6) {
        HUDChipDelPanel(nombre: "Normal", elegido: true)
        HUDChipDelPanel(nombre: "Correo", elegido: false)
        HUDChipDelPanel(nombre: "Notas", elegido: false)
        Spacer(minLength: 0)
        HUDBotonDelPanel(icono: "square.and.pencil", titulo: "Nota")
      }
      .frame(height: HUDNotchGeometry.altoDeLosModos - HUDNotchGeometry.altoDelSeparador)
    }
    .padding(.horizontal, PanelDeVidrio.aireLateral)
  }

  // MARK: La 0.4.5, con sus números

  /// El alto del panel de la 0.4.5 con tres recientes y los modos: la
  /// cabecera, el encabezado «RECIENTES» de 15, tres filas de 19, los modos
  /// de 36 y 6 de aire.
  static let altoDelPanel045: CGFloat = 24 + 15 + 3 * 19 + 36 + 6

  /// El material de la 0.4.5: vidrio con tinte 0,3 en la silueta entera, la
  /// cabecera negra con 22 puntos de fundido y un canto blanco desde ahí
  /// hacia abajo. Apagado, negro entero.
  @ViewBuilder
  static func fondo045(silueta: SiluetaDeLaMuesca, cabecera: CGFloat, vidrio: Bool, detras: AnyView) -> some View {
    if vidrio {
      ZStack(alignment: .top) {
        ZStack {
          detras
          Color.black.opacity(0.3)
        }
        .clipShape(silueta)
        silueta
          .stroke(
            LinearGradient(
              colors: [.white.opacity(0.32), .white.opacity(0.11), .white.opacity(0.19)],
              startPoint: .top, endPoint: .bottom
            ),
            lineWidth: 0.75
          )
          .mask(alignment: .top) {
            VStack(spacing: 0) {
              Color.clear.frame(height: cabecera)
              LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 22)
              Color.black
            }
            .padding(.horizontal, -60)
          }
        silueta
          .fill(Color.black)
          .mask(alignment: .top) {
            VStack(spacing: 0) {
              Rectangle().frame(height: cabecera)
              LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 22)
              Spacer(minLength: 0)
            }
            .padding(.horizontal, -60)
          }
      }
    } else {
      silueta.fill(Color.black)
    }
  }

  /// El contenido de la 0.4.5: encabezado «RECIENTES» de 8 puntos, filas de
  /// 10,5, chips de 9,5 con el modo en el degradado y «Nota» en el acento;
  /// con vidrio, las secciones en tarjetas blancas al 7 %.
  static func contenido045(enTarjetas: Bool) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Color.clear.frame(height: HUDNotchGeometry.alturaDeCabecera(for: pantalla))
      VStack(alignment: .leading, spacing: 0) {
        Text("RECIENTES")
          .font(.system(size: 8, weight: .semibold, design: .rounded))
          .tracking(0.6)
          .foregroundStyle(.white.opacity(0.42))
          .frame(height: 15, alignment: .bottom)
        filaReciente045("quedamos el martes a las diez en la oficina", icono: "waveform", copiado: false)
        filaReciente045("revisa el informe de Kubernetes antes del jueves", icono: "waveform", copiado: true)
        filaReciente045("https://dilo.app/precios", icono: "doc.on.clipboard", copiado: false)
      }
      .background { tarjeta045(enTarjetas, abajo: 12) }
      Color.clear.frame(height: 8)
      HStack(spacing: 5) {
        chip045("Normal", elegido: true)
        chip045("Correo", elegido: false)
        chip045("Notas", elegido: false)
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
      .frame(height: 28)
      .background { tarjeta045(enTarjetas, abajo: 26) }
    }
    .padding(.horizontal, 22)
  }

  @ViewBuilder
  static func tarjeta045(_ enTarjetas: Bool, abajo: CGFloat) -> some View {
    if enTarjetas {
      UnevenRoundedRectangle(
        topLeadingRadius: 12, bottomLeadingRadius: abajo, bottomTrailingRadius: abajo, topTrailingRadius: 12,
        style: .continuous
      )
      .fill(Color.white.opacity(0.07))
      .padding(.horizontal, -8)
    }
  }

  static func filaReciente045(_ texto: String, icono: String, copiado: Bool) -> some View {
    HStack(spacing: 7) {
      Image(systemName: icono)
        .font(.system(size: 8.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.4))
        .frame(width: 12)
      Text(texto)
        .font(.system(size: 10.5, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.82))
        .lineLimit(1)
      Spacer(minLength: 6)
      Image(systemName: copiado ? "checkmark" : "doc.on.doc")
        .font(.system(size: copiado ? 9.5 : 9, weight: copiado ? .bold : .semibold))
        .foregroundStyle(copiado ? paleta.acuse.color : .white.opacity(0.38))
    }
    .frame(height: 19)
  }

  static func chip045(_ nombre: String, elegido: Bool) -> some View {
    Text(nombre)
      .font(.system(size: 9.5, weight: .semibold, design: .rounded))
      .foregroundStyle(elegido ? .black : .white.opacity(0.75))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background {
        if elegido {
          Capsule(style: .continuous)
            .fill(LinearGradient(
              colors: [paleta.ondaBase.mezcla(con: paleta.ondaPunta, 0.35).color, paleta.ondaPunta.color],
              startPoint: .leading, endPoint: .trailing
            ))
            .shadow(color: paleta.halo.color.opacity(0.5), radius: 4)
        } else {
          Capsule(style: .continuous).fill(.white.opacity(0.12))
        }
      }
  }
}
